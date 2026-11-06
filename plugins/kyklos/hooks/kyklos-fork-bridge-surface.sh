#!/usr/bin/env bash
# kyklos-fork-bridge-surface.sh (Kyklos, PreToolUse on the KyklosBridge run/admin verbs) -- advisory, with ONE refusal.
#
# The bridge is ONE host process per project with ONE solution root. It cannot see a git worktree the container
# created elsewhere, so a build/test/coverage call made while working in such a worktree silently checks the SHARED
# tree instead of the caller's change. And cleanup / kill_process / restart / stop act on every session that shares
# the bridge, so a forked session calling them can wreck another session's run.
#
# This hook surfaces both situations to the model (via hookSpecificOutput.additionalContext -- a PreToolUse hook's
# stderr is not delivered) so it can switch to CI or leave the operation to the parent session:
#   1. the call is made from a working directory OUTSIDE the project root, or from a linked git worktree;
#   2. a run verb is called from a subagent (its shell may sit at the root while it edits a separate worktree);
#   3. a shared-state verb (cleanup / kill_process / restart / stop) is called from a subagent, or from such a tree.
# The ONE refusal: a run verb called from INSIDE a different git working tree (a linked worktree, or a git repo
# outside the project root) without a `tree` argument. That call is provably about the wrong code, so it is refused
# (the caller passes `tree` naming a tree the bridge can reach, or verifies through CI). Everything else only warns:
# a subagent call alone, or a cwd outside any repo, does not prove the caller means another tree, and a mis-detected
# cwd must never stop legitimate work. KYKLOS_RIGHT_TREE=off turns the refusal back into the warning;
# KYKLOS_FORK_ETIQUETTE=off silences the hook entirely. Any parse error -> silent exit 0.
set +e -uo pipefail

# shellcheck source=lib/control-switch.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/control-switch.sh" 2>/dev/null || true   # kyklos_control_off: the one control-switch reader
kyklos_control_off "${KYKLOS_FORK_ETIQUETTE:-}" && exit 0
command -v jq >/dev/null 2>&1 || exit 0

INPUT="$(cat 2>/dev/null || true)"
[ -n "$INPUT" ] || exit 0

tool="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)"
cwd="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"
agent="$(printf '%s' "$INPUT" | jq -r '(.agent_id // .agent_type // empty) | tostring' 2>/dev/null || true)"
named_tree="$(printf '%s' "$INPUT" | jq -r '.tool_input.tree // empty | tostring' 2>/dev/null || true)"
verb="${tool##*__}"
[ -n "$verb" ] || exit 0

case "$verb" in
    build|run_tests|get_coverage|get_mutation) shared_state=0 ;;
    cleanup|kill_process|restart|stop)          shared_state=1 ;;
    *) exit 0 ;;
esac

root="${CLAUDE_PROJECT_DIR:-}"
[ -z "$cwd" ] && cwd="$PWD"

# Is the caller working outside the tree the bridge can see?
foreign_tree=0
# ...and is that PROVEN by git (the cwd sits in a different git working tree), not just a cwd outside the root?
foreign_git_tree=0
if [ -n "$root" ]; then
    _r="$(cd "$root" 2>/dev/null && pwd -P || printf '%s' "$root")"
    _c="$(cd "$cwd" 2>/dev/null && pwd -P || printf '%s' "$cwd")"
    case "$_c/" in
        "$_r"/*) ;;
        *) foreign_tree=1
           [ -d "$cwd" ] && git -C "$cwd" rev-parse --show-toplevel >/dev/null 2>&1 && foreign_git_tree=1 ;;
    esac
fi
# A linked worktree (its git dir differs from the common dir) is a separate tree even when it sits inside the root.
if [ -d "$cwd" ]; then
    _gd="$(git -C "$cwd" rev-parse --absolute-git-dir 2>/dev/null || true)"
    _cd="$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    if [ -n "$_gd" ] && [ -n "$_cd" ] && [ "$_gd" != "$_cd" ]; then foreign_tree=1; foreign_git_tree=1; fi
fi

# The refusal: a run verb from a proven foreign git tree, with no `tree` saying which tree the caller means.
if [ "$shared_state" -eq 0 ] && [ "$foreign_git_tree" -eq 1 ] && [ -z "$named_tree" ] && ! kyklos_control_off "${KYKLOS_RIGHT_TREE:-}"; then
    reason="[kyklos] right-tree: mcp__KyklosBridge__${verb} REFUSED. You are working in a different git tree (${cwd}) than the bridge's solution root, and the bridge would silently ${verb} the SHARED code, not your change. Either pass tree=<a path the bridge can reach: a folder under the solution root, relative to it> or verify this change through CI on its own branch (see the using-the-bridge skill, 'Forks and parallel sessions'). Opt-out (not recommended): KYKLOS_RIGHT_TREE=off."
    jq -nc --arg r "$reason" '{decision:"block", reason:$r}'
    exit 0
fi

msg=""
if [ "$foreign_tree" -eq 1 ] && [ "$shared_state" -eq 0 ]; then
    msg="[kyklos] fork-etiquette: mcp__KyklosBridge__${verb} acts on the bridge's own solution root, NOT on your current tree (${cwd}). The bridge cannot see a separate worktree, so this result would describe the shared code, not your change. Verify a worktree's change through CI on its own branch instead (see the using-the-bridge skill, 'Forks and parallel sessions')."
elif [ "$shared_state" -eq 0 ] && [ -n "$agent" ]; then
    # A subagent's shell often resets to the project root between commands even while it edits a separate worktree
    # through absolute paths, so the cwd alone cannot prove which tree it means. Remind it which tree the bridge sees.
    msg="[kyklos] fork-etiquette: mcp__KyklosBridge__${verb} is being called from a subagent. The bridge acts on its own solution root only. If your change lives in a separate worktree, this result will not include it: verify that change through CI on its own branch instead (see the using-the-bridge skill, 'Forks and parallel sessions')."
elif [ "$shared_state" -eq 1 ] && { [ "$foreign_tree" -eq 1 ] || [ -n "$agent" ]; }; then
    msg="[kyklos] fork-etiquette: mcp__KyklosBridge__${verb} affects EVERY session sharing this bridge and can break another session's run in progress. Leave cleanup, kill_process, restart and stop to the parent session (see the using-the-bridge skill, 'Forks and parallel sessions')."
fi

[ -n "$msg" ] || exit 0
jq -nc --arg ctx "$msg" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$ctx}}'
exit 0
