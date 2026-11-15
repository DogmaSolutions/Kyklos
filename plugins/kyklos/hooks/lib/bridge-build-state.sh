#!/usr/bin/env bash
# bridge-build-state.sh -- ask the KyklosBridge whether it built a solution green on exactly the commit being pushed, so the
# push check (kyklos-slnx-green-guard.sh) accepts the bridge's own build besides the record record-slnx-green.sh writes.
# Source it; it defines functions only.
#
#   bridge_tree_args <solution-abs>
#       -> the bridge `build` / `build_state` arguments that address that solution's folder, relative to the project dir the
#          bridge serves (rc 2, nothing printed, when the solution lies outside it: the bridge could not reach it, and the
#          default solution would be the WRONG one). Shared with the recorder.
#   bridge_build_is_current <repo-top> <solution-rel> <solution-count> <sha>
#       -> rc 0 only when ALL hold: <sha> is the repo's HEAD and its tracked files carry no change, and the bridge's
#          read-only `build_state` verb answers, for that solution's folder, that its last successful full build is exactly
#          the tree as it stands (current true) at HEAD <sha>. Anything else is rc 1: no bridge reachable, an older bridge
#          without the verb, an error or cut answer, no build recorded, another commit, a changed tree, a red build (a red
#          build is never recorded by the bridge). The caller then judges by the recorder's record alone: this answer can
#          only ADD an accepted push, never remove one, and a failure to ask is never read as a green build.
# [CySec] CWE-636 "Not Failing Securely": every doubt answers "not current". [RiskMitigation RA-03]

# shellcheck source=json-answer.sh
. "$(dirname "${BASH_SOURCE[0]}")/json-answer.sh"
# shellcheck source=bridge-mcp.sh
. "$(dirname "${BASH_SOURCE[0]}")/bridge-mcp.sh"

bridge_tree_args() {
    local proj soldir tree
    proj="$(cd "${CLAUDE_PROJECT_DIR:-$(pwd)}" 2>/dev/null && pwd -P)" || return 2
    soldir="${1%/*}"
    case "$soldir/" in
        "$proj/"*) tree="${soldir#"$proj"}"; tree="${tree#/}"; [ -n "$tree" ] || tree="." ;;
        *) return 2 ;;
    esac
    # [CySec] Mitigates CWE-78/CWE-88: the folder is a JSON argument built by jq, never interpolated into a shell or
    # a JSON string by hand. [RiskMitigation RA-05]
    jq -cn --arg tree "$tree" '{tree: $tree}'
}

bridge_build_is_current() {
    local top="$1" sol="$2" count="$3" sha="$4" head args="{}" reply
    [ -n "$sha" ] || return 1
    command -v git >/dev/null 2>&1 || return 1
    head="$(git -C "$top" rev-parse HEAD 2>/dev/null)" || return 1
    [ "$head" = "$sha" ] || return 1
    # Tracked changes in this folder would be a build of other content than the commit; the bridge sees them too, this
    # is the second look from the side that pushes.
    git -C "$top" diff --quiet HEAD -- 2>/dev/null || return 1
    if [ "$count" -gt 1 ]; then
        args="$(bridge_tree_args "$top/$sol")" || return 1
    fi
    reply="$(bridge_mcp_call build_state "$args" 60)" || return 1
    bridge_mcp_is_error "$reply" && return 1
    printf '%s' "$reply" | json_test '.result.current == true and .result.head == $sha' --arg sha "$sha"
}
