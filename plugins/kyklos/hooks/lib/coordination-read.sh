#!/usr/bin/env bash
# coordination-read.sh -- the ONE way a Kyklos hook reads GitLab issue data: through the KyklosBridge coordination
# read verbs (coordination_issues, coordination_show, coordination_notes, ...; the bridge's tool list is the owner),
# so the container needs no GitLab token for these reads. Source it; it defines functions only.
#
#   coordination_read <verb> <arguments-json>
#       -> the verb's answer (JSON text) on stdout.
#          rc 0  answered
#          rc 3  cannot check: the bridge is unreachable, GitLab failed behind it (UNREACHABLE:), or the read was refused.
#                The caller keeps its own "cannot check" posture; it must never read this as "nothing found".
#          rc 4  this bridge has no such verb (an older bridge, or no coordination stack): the caller MAY use its direct
#                token path for the transition, and must announce it with coordination_read_fallback.
#   coordination_read_reason
#       -> why the last coordination_read of this hook process could not answer (the bridge's own refusal text, or
#          "the bridge did not answer"), empty after an answer. A guard that refuses on a failed read prints it, so the
#          refusal names what the bridge said instead of a generic "could not be read". The callers discard stderr
#          (2>/dev/null) and call coordination_read in a command substitution, so the reason is kept in a file keyed
#          by the hook's process id ($$ is the same in the substitution), not in a variable.
#   coordination_read_fallback <caller> <reason>
#       -> one greppable line on stderr, "[kyklos] direct-token fallback: <caller> <reason>", the ledger that shows
#          which hooks still read GitLab with a container token. The same use is appended, as "<utc time>\t<caller>\t
#          <reason>", to ${KYKLOS_STATE_DIR}/direct-token-fallback.log, which api-scope-check.sh --ledger counts so a
#          project is switched to host-only only once no hook needs its token any more.
#
# Test seam: a test sources this file and redefines bridge_mcp_call to answer offline.

# shellcheck source=bridge-mcp.sh
. "$(dirname "${BASH_SOURCE[0]}")/bridge-mcp.sh"

_coordination_reason_file() { printf '%s/coordination-read-reason.%s' "${KYKLOS_STATE_DIR:-/tmp/kyklos-state}" "$$"; }
_coordination_reason_set() {
    local f; f="$(_coordination_reason_file)"
    if [ -n "${1:-}" ]; then
        { mkdir -p "$(dirname "$f")" && printf '%s' "$1" >"$f"; } 2>/dev/null || true
    else
        rm -f "$f" 2>/dev/null || true
    fi
}
coordination_read_reason() { cat "$(_coordination_reason_file)" 2>/dev/null || true; }
# A reason left by an earlier process that had the same id is never read as this hook's: loading the helper clears it.
_coordination_reason_set ""

coordination_read() {
    local verb="$1" args="${2:-}" resp text rc
    [ -n "$args" ] || args='{}'
    resp="$(bridge_mcp_call "$verb" "$args" 30)"; rc=$?
    case "$rc" in
        0) ;;
        2) _coordination_reason_set "no bridge is configured for this session"; return 4 ;;   # the transition path
        *) _coordination_reason_set "the bridge did not answer $verb (exit $rc)"; return 3 ;;  # cannot check
    esac
    text="$(bridge_mcp_text "$resp")"
    case "$text" in
        "unknown tool: "*) _coordination_reason_set "this bridge has no $verb verb"; return 4 ;;
    esac
    if bridge_mcp_is_error "$resp"; then
        [ -n "$text" ] || text="$(printf '%s' "$resp" | jq -r '.error.message // "refused"' 2>/dev/null)"
        printf '[kyklos] %s: %s\n' "$verb" "$text" >&2
        _coordination_reason_set "$verb: $text"
        return 3
    fi
    _coordination_reason_set ""
    printf '%s' "$text"
}

coordination_read_fallback() {
    local dir="${KYKLOS_STATE_DIR:-/tmp/kyklos-state}"
    printf '[kyklos] direct-token fallback: %s %s\n' "${1:-unknown}" "${2:-}" >&2
    # The ledger is evidence, never a gate: a state dir that cannot be written loses the line, not the hook's read.
    { mkdir -p "$dir" && printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${1:-unknown}" "${2:-}" \
        >>"$dir/direct-token-fallback.log"; } 2>/dev/null || true
}
