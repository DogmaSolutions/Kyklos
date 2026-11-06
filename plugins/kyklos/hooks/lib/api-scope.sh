#!/usr/bin/env bash
# api-scope.sh -- which GitLab tokens can the agent in this container read, and which of them can call the API?
# Source it; it defines functions only.
#
# A project whose api-scoped token is host-only (the bridge uses it, the agent's secret_read is refused) must never
# get an API-capable token back into the agent's reach. These functions look at exactly what the agent can read:
# the names the bridge serves (KYKLOS_BRIDGE_SECRETS) and token variables in the environment. Each readable GitLab
# token is introspected with GET /personal_access_tokens/self through gitlab_curl, so the value never reaches a
# variable of this script, a trace, a log or the output: only its scopes are printed.
#
#   api_scope_names                 -> candidate names, one per line (bridge-served names + *TOKEN* variables)
#   api_scope_probe <name> <api>    -> one line: "<name> api-capable <scopes>" | "<name> ok <scopes>" |
#                                      "<name> not-readable" | "<name> not-checked <reason>"
#   api_scope_state                 -> the project's declared state: serve (default) | transition | host-only;
#                                      rc 2 and a message for any other value
#   api_scope_report <api>          -> one probe line per candidate name
#   api_scope_verdict <state> <report> -> rc 0 fine | 1 warning (api-capable token readable, serve/transition) |
#                                      2 error (api-capable token readable while host-only)

. "$(dirname "${BASH_SOURCE[0]}")/gitlab-curl.sh"

# Variables that hold the container's own plumbing, never a GitLab token the agent should be judged on.
# Also skipped: settings that hold the NAME of a token (*_TOKEN_ENV, *_TOKEN_NAME), not a token.
_API_SCOPE_IGNORED_VARS='^(KYKLOS_BRIDGE_AUTH_TOKEN|CLAUDE_CODE_OAUTH_TOKEN|CLAUDE_CODE_MESSAGING_TOKEN|ANTHROPIC_AUTH_TOKEN|GITHUB_TOKEN|.*_TOKEN_ENV|.*_TOKEN_NAME)$'

api_scope_names() {
    {
        printf '%s\n' "${KYKLOS_BRIDGE_SECRETS:-}" | tr ';, ' '\n\n\n'
        compgen -e | grep -E 'TOKEN' || true
    } | grep -E '^[A-Za-z_][A-Za-z0-9_]*$' | grep -vE "$_API_SCOPE_IGNORED_VARS" | sort -u
}

api_scope_probe() {
    local name="$1" api="$2" resp code body scopes
    case "$name" in
        *GITLAB*|*Gitlab*|*gitlab*) ;;
        *) printf '%s not-checked not a GitLab token name\n' "$name"; return 0 ;;
    esac
    if ! gitlab_token_present "$name"; then
        printf '%s not-readable\n' "$name"; return 0
    fi
    resp="$(gitlab_curl "$name" -s --max-time 12 -w $'\n%{http_code}' "$api/personal_access_tokens/self" 2>/dev/null)" || {
        printf '%s not-checked GitLab did not answer\n' "$name"; return 0; }
    code="$(printf '%s' "$resp" | tail -n1)"; body="$(printf '%s' "$resp" | sed '$d')"
    case "$code" in
        200) ;;
        401) printf '%s not-checked GitLab refused the token (expired or revoked)\n' "$name"; return 0 ;;
        *)   printf '%s not-checked GitLab answered %s\n' "$name" "${code:-nothing}"; return 0 ;;
    esac
    scopes="$(printf '%s' "$body" | jq -r '(.scopes // []) | join(",")' 2>/dev/null)" || {
        printf '%s not-checked unreadable answer\n' "$name"; return 0; }
    case ",$scopes," in
        *,api,*|*,write_api,*) printf '%s api-capable %s\n' "$name" "$scopes" ;;
        *) printf '%s ok %s\n' "$name" "${scopes:-none}" ;;
    esac
}

api_scope_state() {
    local s="${KYKLOS_API_TOKEN_STATE:-serve}"
    case "$s" in
        serve|transition|host-only) printf '%s' "$s" ;;
        *) printf 'kyklos: KYKLOS_API_TOKEN_STATE must be serve, transition or host-only, not "%s".\n' "$s" >&2
           return 2 ;;
    esac
}

api_scope_report() {
    local api="$1" n
    while IFS= read -r n; do
        [ -n "$n" ] && api_scope_probe "$n" "$api"
    done < <(api_scope_names)
}

api_scope_verdict() {
    local state="$1" report="$2"
    printf '%s\n' "$report" | grep -c ' api-capable ' >/dev/null || return 0
    [ "$state" = host-only ] && return 2
    return 1
}
