#!/usr/bin/env bash
# inbound-issues-fetch.sh — the ONE shared "who is waiting on us?" query, sourced by every inbound-issues
# trigger so they all run identical logic: kyklos-inbound-issues-guard.sh (all modes, see its header),
# kyklos-inbound-monitor-init.sh and lib/agent-msg-lib.sh.
#
# It answers: which OPEN Issues in our scopes have the ball in OUR court (their last human note is not ours, or nobody
# has answered and someone else opened them)? The KyklosBridge answers it (verb coordination_inbox) with its own
# GitLab token and the identity that token belongs to; this file decides only whether the check is configured and
# maps the answer onto the gate's return codes. The container holds no token for it.
#
# Contract — source this file, then call `inbound_issues_collect`:
#   rc 0 : inbound Issues exist. INBOUND_LINES = human-readable bullet list; INBOUND_IIDSET = "pid:iid ..." tokens.
#   rc 1 : configured + answered, and NOTHING is waiting on us (clean).
#   rc 2 : NOT CONFIGURED (no GitLab address, or no scope: project | group | scopes). There is nothing to check, so
#          callers ALLOW (this is "not applicable", not a failure).
#   rc 3 : CONFIGURED but the check COULD NOT RUN (no curl+jq, the bridge down or without a coordination stack, GitLab
#          unreachable, a malformed answer, an unknown scope token). [no-fail-open, by design] [RiskMitigation RA-04] Callers must never treat
#          it as "nothing waiting": each caller says how it handles rc 3 (the inbound guard announces it loudly).
#
# Configuration (env vars, persisted by the launcher; READ-only here):
#   KYKLOS_ISSUES_API        the GitLab API base — present means the gate is configured (the bridge holds the token)
#   KYKLOS_ISSUES_PROJECT    numeric project id            (one of PROJECT / GROUP / SCOPES is required)
#   KYKLOS_ISSUES_GROUP      group/subgroup path or id     (used when PROJECT is unset)
#   KYKLOS_ISSUES_SCOPES     space/comma list of scope tokens for a CROSS-PROJECT agent whose backlog is a UNION:
#                              `instance` (instance-wide coordination issues addressed to us), `project:<id>` (ALL open
#                              issues in the project), `group:<id|path>` (ALL open issues in the group). When set it
#                              REPLACES the single PROJECT/GROUP scope. An unknown token fails CLOSED (rc 3).
#
# bash + curl + jq only. No side effects on source (defines functions); the query runs only when called.
# shellcheck source=lib/json-answer.sh
. "$(dirname "${BASH_SOURCE[0]}")/json-answer.sh"   # json_test / json_read: an empty or cut answer is never valid
_INBOUND_LIB_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bridge-mcp.sh
. "$_INBOUND_LIB_HERE/bridge-mcp.sh"

# Populated by inbound_issues_collect.
INBOUND_LINES=""
INBOUND_IIDSET=""

# inbound_issues_collect -> see contract above. Never prints; sets the two globals.
inbound_issues_collect() {
    INBOUND_LINES=""
    INBOUND_IIDSET=""
    local api="${KYKLOS_ISSUES_API:-}"
    local project="${KYKLOS_ISSUES_PROJECT:-}"
    local group="${KYKLOS_ISSUES_GROUP:-}"
    local scopes="${KYKLOS_ISSUES_SCOPES:-}"
    # A gate that was CONFIGURED earlier this container leaves a marker. If a required var later goes
    # set->unset, that is SUSPICIOUS (an agent unconfiguring a working coordination gate to dodge it) -> fail CLOSED
    # (rc 3), not open (rc 2). A gate NEVER configured (no marker) still fail-opens (rc 2) — genuinely not-applicable.
    local _cfg_marker="${KYKLOS_STATE_DIR:-/tmp/kyklos-state}/inbound-configured"
    local _unconf_rc=2; [ -f "$_cfg_marker" ] && _unconf_rc=3
    [ -n "$api" ] || return "$_unconf_rc"
    [ -n "$project" ] || [ -n "$group" ] || [ -n "$scopes" ] || return "$_unconf_rc"
    # All required config vars present -> record that this gate WAS configured, so a later set->unset fail-closes.
    { mkdir -p "$(dirname "$_cfg_marker")" 2>/dev/null && : > "$_cfg_marker" 2>/dev/null; } || true
    command -v curl >/dev/null 2>&1 || return 3
    command -v jq   >/dev/null 2>&1 || return 3
    local args resp text
    args="$(jq -cn --arg scopes "${scopes//,/ }" --arg project "$project" --arg group "$group" \
        '$ARGS.named | with_entries(select(.value != ""))')" || return 3
    # 45 s, under the 60 s a hook may run: a slow bridge ends here as a loud "cannot check" (rc 3), never as a hook the
    # harness kills silently.
    resp="$(bridge_mcp_call coordination_inbox "$args" 45)" || return 3
    # A refusal (GitLab unreachable, an unknown scope) or a bridge without the coordination stack is "cannot check".
    bridge_mcp_is_error "$resp" && return 3
    text="$(bridge_mcp_text "$resp")"
    printf '%s' "$text" | json_test 'type == "object" and (.lines | type == "array") and (.iids | type == "array")' || return 3
    local line iid
    while IFS= read -r line; do
        [ -n "$line" ] && INBOUND_LINES+=$'\n'"$line"
    done < <(printf '%s' "$text" | jq -r '.lines[]' 2>/dev/null)
    while IFS= read -r iid; do
        [ -n "$iid" ] && INBOUND_IIDSET="${INBOUND_IIDSET}${iid} "
    done < <(printf '%s' "$text" | jq -r '.iids[]' 2>/dev/null)
    [ -n "$INBOUND_IIDSET" ] || return 1
    return 0
}

# inbound_issues_marker_key <iidset> -> a stable filesystem-safe key for the SET of inbound iids (so a
# marker-once reminder re-arms only when the set changes). Shared so the Stop reminder and any future
# marker-once caller key identically.
inbound_issues_marker_key() {
    printf '%s' "$1" | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/[^0-9: ]//g' | tr -s ' ' | tr ' :' '_-'
}
