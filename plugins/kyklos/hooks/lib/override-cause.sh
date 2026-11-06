#!/usr/bin/env bash
# override-cause.sh -- the Named Cause question every override path asks the bridge. An override of a story's gates (the
# owner's proof-override label at a close, or the one-shot automerge-coverage-ok override of an arm) admits nothing
# unless the story names the open item that removes the cause of its gap, or the owner accepted the gap with its figure.
# The bridge alone decides it (proof_validate, OwnerOverride.IsGranted / OverrideCause); this library only asks and
# reads the answer, so the close, the Stop hook, the close guard and the arm guard cannot judge an override apart.
# Source it; it defines functions only.
#
#   override_cause_named <project> <iid> [automerge-coverage-ok]
#       -> rc 0 only when the bridge answers that the override holds: without a third argument, that the owner's label
#          waives the story's gates (its label granted AND its cause named); with automerge-coverage-ok, that the story
#          names its cause. rc 1 otherwise, the reason in OVERRIDE_CAUSE_WHY. No bridge, no answer, an older answer:
#          rc 1 (fail closed).
# [CySec] Prevents CWE-863 "Incorrect Authorization": no override admits without the bridge's Named Cause answer.

_OC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The bridge's answers (AgileVerbDispatcher.ProofWaivedByOwner and CauseNamedPrefix).
_OC_WAIVED="waived: the owner's exception label"
_OC_NAMED_PREFIX="cause named: "

# shellcheck disable=SC2034  # OVERRIDE_CAUSE_WHY is read by the guards and the story tool that source this file
override_cause_named() {
    local project="$1" iid="$2" which="${3:-}" args reply text
    OVERRIDE_CAUSE_WHY=""
    if ! command -v bridge_mcp_call >/dev/null 2>&1; then
        # shellcheck source=bridge-mcp.sh
        [ -f "$_OC_DIR/bridge-mcp.sh" ] && . "$_OC_DIR/bridge-mcp.sh"
    fi
    command -v bridge_mcp_call >/dev/null 2>&1 || { OVERRIDE_CAUSE_WHY="the bridge client (hooks/lib/bridge-mcp.sh) is missing"; return 1; }
    [ -n "$iid" ] || { OVERRIDE_CAUSE_WHY="the story number is unknown"; return 1; }
    if [ -n "$which" ]; then
        args="$(jq -cn --arg id "$iid" --arg p "$project" --arg o "$which" '{id:$id, override:$o} + (if $p == "" then {} else {project:$p} end)')"
    else
        args="$(jq -cn --arg id "$iid" --arg p "$project" '{id:$id} + (if $p == "" then {} else {project:$p} end)')"
    fi
    reply="$(bridge_mcp_call proof_validate "$args" 120)" || { OVERRIDE_CAUSE_WHY="the bridge did not answer proof_validate, so the override's cause cannot be checked"; return 1; }
    text="$(bridge_mcp_text "$reply" | tr -d '\r' | tr '\n' ' ' | sed -E 's/[[:space:]]+$//')"
    if bridge_mcp_is_error "$reply"; then
        OVERRIDE_CAUSE_WHY="${text:-the bridge refused proof_validate without a reason}"
        return 1
    fi
    if [ -n "$which" ]; then
        case "$text" in "$_OC_NAMED_PREFIX"*) return 0 ;; esac
    else
        [ "$text" = "$_OC_WAIVED" ] && return 0
    fi
    OVERRIDE_CAUSE_WHY="the bridge did not confirm the override (${text:-no answer}); the story must name its cause: a line 'Override cause: <open item>' in a note or the Test Discipline row, or the owner's 'Override cause: accepted <figure>%'"
    return 1
}
