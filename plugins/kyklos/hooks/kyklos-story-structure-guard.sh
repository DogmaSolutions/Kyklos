#!/usr/bin/env bash
# kyklos-story-structure-guard.sh (Kyklos) - blocks working/closing a structurally INCOMPLETE SSDLC story (missing
# a section `story structure` reports: the 7 required items, plus the 2a-2f spec sections when a spec is present; the
# rule is owned by story_min_structure_problem in skills/ssdlc-story/lib/story-lib.sh).
#
# THREE MODES (arg $1):
#   * edit (PreToolUse: Edit|Write|MultiEdit) - the PRIMARY gate: the story must be
#     RESTRUCTURED to conform IMMEDIATELY after it is read and BEFORE any work starts. So a WORK-file edit is BLOCKED
#     while the current In-progress story is non-conforming - forcing the agent to add the missing section(s) FIRST.
#     An edit UNDER Stories/ IS the restructure and is always allowed (never block the fix itself).
# * bash (PreToolUse: Bash) - the Bash-channel companion ("Adopt-Before-Work"): an agent whose work
#     is done through Bash (version-control commits, heredoc writes) would otherwise bypass the edit-mode gate.
#     This mode gates ONLY a real `git commit` INVOCATION (a work-commit) while the active story is non-conforming -
#     reusing the shared command-position detector (lib/git-cmd-detect.sh) so a MENTION of "git commit" in a heredoc
#     or a quoted message is NEVER gated. Any non-commit Bash -> fail-open. (Work on a bare non-story issue is
#     deliberately NOT inferred here - too false-positive-prone.)
#   * stop (Stop hook, default) - backstop: blocks the Stop while the In-progress story is still non-conforming.
#
# ENABLED by default; KYKLOS_STRUCTURE_GATE=0 disables it. FAIL-OPEN on EVERY uncertainty (no story tool, no
# Stories/, no single In-progress story, ambiguous set, jq missing, not a git-commit invocation, any error) - it can
# ONLY block on a DEFINITELY non-conforming active story (the mechanical, no-AI `story structure` exiting EXACTLY 1).
# Honors stop_hook_active (stop mode), so it can never wedge the Stop loop. Regression-locked by
# test-story-min-structure.sh / test-story-structure-parity.sh (the check) + test-story-structure-guard.sh (block-vs-allow).
# Wired: PreToolUse (Edit|Write|MultiEdit, arg "edit"; Bash, arg "bash") + Stop (arg "stop").
set +e -uo pipefail

MODE="${1:-stop}"
INPUT="$(cat || true)"

# Stop-loop guard applies only in stop mode.
if [ "$MODE" = stop ] && printf '%s' "$INPUT" | grep -cE '"stop_hook_active"[[:space:]]*:[[:space:]]*true' >/dev/null; then exit 0; fi
# shellcheck source=lib/control-switch.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/control-switch.sh" 2>/dev/null || true   # kyklos_control_off: the one control-switch reader
kyklos_control_off "${KYKLOS_STRUCTURE_GATE:-}" && exit 0

# edit mode: an edit to the STORY itself (under Stories/) IS the restructure -> always allow, so the agent can add the
# missing sections. Only a WORK-file edit is gated. (For a GitLab story the restructure is a Bash/story-tool call, not
# an Edit, so the restructure path is never blocked either way.)
if [ "$MODE" = edit ]; then
  command -v jq >/dev/null 2>&1 || exit 0
  _fp="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null || true)"
  case "$_fp" in */Stories/*|Stories/*) exit 0 ;; esac
fi

# bash mode: gate ONLY a real `git commit` INVOCATION. Reuse the shared command-position detector so a
# MENTION of "git commit" (in a heredoc, a quoted arg, a message body) is NEVER gated - only a real invocation. Any
# command that is not a git-commit invocation -> fail-open (never wedge an unrelated command).
if [ "$MODE" = bash ]; then
  command -v jq >/dev/null 2>&1 || exit 0
  _cmd="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
  [ -n "$_cmd" ] || exit 0
  # shellcheck source=lib/git-cmd-detect.sh
  . "$(dirname "${BASH_SOURCE[0]}")/lib/git-cmd-detect.sh" 2>/dev/null || exit 0
  git_cmd_invokes "$_cmd" commit || exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
# A project directory inside a companion's nested source (CLAUDE_PROJECT_DIR or the session working directory) is
# resolved to the companion root, where Stories/ and .claude/ live.
. "$(dirname "${BASH_SOURCE[0]}")/lib/repo-role.sh" 2>/dev/null && PROJECT_DIR="$(repo_companion_root "$PROJECT_DIR")"
[ -d "$PROJECT_DIR/Stories" ] || exit 0                                       # no stories -> nothing to gate
STORY="$(dirname "${BASH_SOURCE[0]}")/../skills/ssdlc-story/story"
[ -f "$STORY" ] || exit 0                                                     # broken install -> fail-open
# [json-answer-required] The story tool loads the JSON reader and exits 1 without it, the same code as a real finding,
# so a broken install would be reported as a story to restructure. Name the missing reader instead. [CySec] CWE-636
if ! bash -c '. "$1" 2>/dev/null && command -v json_test >/dev/null 2>&1' _ "$(dirname "${BASH_SOURCE[0]}")/lib/json-answer.sh"; then
  printf '{"decision":"block","reason":"BLOCKED (%s): the JSON reader hooks/lib/json-answer.sh did not load (broken install), so the story tool cannot check the story structure. Reinstall or repin the kyklos plugin."}\n' "$(basename "$0")"
  exit 0
fi

# Mechanical structure check on the CURRENT story (no id -> the single In-progress one, resolved from BACKLOG.md).
# exit 0 = conforms; exit 1 = a DEFINITE non-conforming finding; any other exit (no active story, ambiguous set, lib
# not loaded, not found) -> fail-open (never block on an uncertain state).
if out="$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$STORY" structure 2>&1)"; then exit 0; else rc=$?; fi
[ "$rc" -eq 1 ] || exit 0

reason="$out"
reason="${reason//\\/\\\\}"; reason="${reason//\"/\\\"}"; reason="$(printf '%s' "$reason" | tr '\n' ' ')"
if [ "$MODE" = edit ]; then
  printf '{"decision":"block","reason":"BLOCKED (structure-gate, RESTRUCTURE-BEFORE-WORK): %s The In-progress story is structurally INCOMPLETE - you must RESTRUCTURE it NOW (add the missing section(s), see the ssdlc-story _TEMPLATE) BEFORE writing any work code. Per the user directive, the refactor happens immediately after reading the story, before working. Disable with KYKLOS_STRUCTURE_GATE=0."}' "$reason"
elif [ "$MODE" = bash ]; then
  printf '{"decision":"block","reason":"BLOCKED (structure-gate, RESTRUCTURE-BEFORE-WORK, Bash channel): %s You are about to COMMIT work while the In-progress story is structurally INCOMPLETE. RESTRUCTURE it FIRST (add the missing section(s), see the ssdlc-story _TEMPLATE; for a GitLab story author the spec with story requirements <id> --file <f>) BEFORE committing - a Bash commit no longer bypasses the restructure-before-work gate. Disable with KYKLOS_STRUCTURE_GATE=0."}' "$reason"
else
  printf '{"decision":"block","reason":"BLOCKED (structure-gate): %s Add the missing section(s) to the story (see the ssdlc-story _TEMPLATE), then continue. Disable with KYKLOS_STRUCTURE_GATE=0."}' "$reason"
fi
exit 0
