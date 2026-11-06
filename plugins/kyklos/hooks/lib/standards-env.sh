#!/usr/bin/env bash
# standards-env.sh (Kyklos hook lib) — SAFELY load a repo's .claude/standards.env.
#
# WHY THIS EXISTS: hooks used to `.`/`source` standards.env to read its knobs. Sourcing runs the file as SHELL
# (CWE-829 "Inclusion of Functionality from an Untrusted Control Sphere"), so ANY line that is not a clean
# KEY=VALUE — an unquoted multi-word value, a stray token, a value with shell metacharacters — is EXECUTED. A single
# malformed line (e.g. `X=a b c` or a bare word) then (a) breaks the guard under `set -e`, and (b) spews
# "<word>: command not found" into the agent's TUI on EVERY tool call. This parser reads the file as DATA: it can
# never execute anything in it, and it silently ignores comments + malformed lines.
#
# load_standards_env <file> — export every well-formed `KEY=VALUE` (KEY a valid identifier). Best-effort + silent:
# a missing/unreadable file, a comment, or a malformed line is skipped, never fatal. One layer of surrounding quotes
# is stripped; an unquoted trailing ` # inline comment` is dropped (matching how the file was read when sourced).

# STANDARDS_ENV_FOREIGN_KEYS - the ONLY keys a repository OUTSIDE the session's own workspace may contribute: its story
# identity. Such a file is not under the session's control, and the parser below would otherwise export ANY key it
# names (PATH, BASH_ENV, a proxy, the API endpoint, the token variable...), handing the next curl/jq - and the session
# token in reach of it - to that repository. [CySec] CWE-426 / CWE-829 / CWE-522.
STANDARDS_ENV_FOREIGN_KEYS="STORY_BACKEND STORY_GITLAB_PROJECT STORY_GITLAB_LABEL"

# load_standards_env_keys <file> <key>... — the same parser, exporting ONLY the named keys (for a foreign repo's file).
load_standards_env_keys() {
    local f="${1:-}"; shift || true
    [ "$#" -gt 0 ] || return 0
    _standards_env_parse "$f" " $* "
}

# standards_env_value <file> <key> — the value <file> declares for <key>, read by the same parser, nothing exported.
standards_env_value() {
    ( unset "$2" 2>/dev/null; _standards_env_parse "${1:-}" " $2 "; printf '%s' "${!2:-}" )
}

# standards_env_same_instance <file> — rc 0 when <file> (a foreign repo's settings) names no GitLab API address or the
# same one as this session (trailing slashes ignored). A repository whose stories live on ANOTHER GitLab instance must
# never have its project number used against this session's instance: that would read or write an unrelated issue.
# Both sides are resolved by gitlab_api_base (lib/gitlab-api-base.sh), the way every Kyklos tool resolves its
# GitLab instance. A session that relies on the container-wide setting is
# therefore compared correctly, instead of every foreign repository looking like another instance.
standards_env_same_instance() {
    local theirs ours
    theirs="$(standards_env_value "${1:-}" STORY_GITLAB_API)"
    [ -n "$theirs" ] || theirs="$(standards_env_value "${1:-}" KYKLOS_ISSUES_API)"
    theirs="${theirs%/}"
    [ -n "$theirs" ] || return 0
    command -v gitlab_api_base >/dev/null 2>&1 \
        || . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gitlab-api-base.sh" 2>/dev/null
    ours="$(gitlab_api_base STORY_GITLAB_API 2>/dev/null)" || ours=""
    [ "$theirs" = "$ours" ]
}

load_standards_env() {
    _standards_env_parse "${1:-}" ""
}

# _standards_env_parse <file> <allow> — <allow> is " KEY1 KEY2 " (space-padded) or empty for every key.
_standards_env_parse() {
    local f="${1:-}" allow="${2:-}" line key val
    [ -n "$f" ] && [ -f "$f" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        # skip blanks and comment lines (leading-whitespace-tolerant)
        case "${line#"${line%%[![:space:]]*}"}" in ''|'#'*) continue ;; esac
        case "$line" in *=*) : ;; *) continue ;; esac            # not KEY=VALUE -> ignore (never execute)
        key="${line%%=*}"; val="${line#*=}"
        key="${key#"${key%%[![:space:]]*}"}"; key="${key%"${key##*[![:space:]]}"}"   # trim ws around KEY
        # a valid shell identifier ONLY (glob '*' would match a space, so reject any non-identifier char explicitly)
        case "$key" in ''|[!A-Za-z_]*|*[!A-Za-z0-9_]*) continue ;; esac
        if [ -n "$allow" ]; then case "$allow" in *" $key "*) : ;; *) continue ;; esac; fi
        val="${val#"${val%%[![:space:]]*}"}"                                          # ltrim the value
        case "$val" in
            \"*) val="${val#\"}"; val="${val%%\"*}" ;;    # "double-quoted" -> take inside the quotes
            \'*) val="${val#\'}"; val="${val%%\'*}" ;;    # 'single-quoted' -> take inside the quotes
            *)   val="${val%%[[:space:]]#*}"; val="${val%"${val##*[![:space:]]}"}" ;;  # drop ' # comment' + rtrim
        esac
        export "$key=$val"
    done < "$f"
}
