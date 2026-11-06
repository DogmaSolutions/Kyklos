#!/usr/bin/env bash
# kyklos-phase-advance.sh — PostToolUse(Bash | bridge coverage/test). Phase choreography, the GUARD-owned lifecycle
# events: advance a story's ssdlc:phase MONOTONICALLY as the real work happens:
#     git commit on a story branch   -> Implementation
#     git push  on a story branch    -> Testing
#     a STORY-BOUND coverage/test run (bridge get_coverage / run_tests with a `story`) -> Testing
# (The tool-owned transitions live in the `story` tool.)
#
# WHY the coverage/test trigger: a project that pushes its feature branch only just before merge would otherwise sit
# in Implementation through its whole test/coverage/mutation stage. A story-bound coverage or test
# run IS the Testing stage, so it advances the phase even without a push.
#
# WHY it PARSES the event repo's .claude/standards.env: STORY_BACKEND/STORY_GITLAB_PROJECT are per-project settings
# that live in that file, not in the hook's process environment. Reading them straight from the environment made the
# backend gate below fail on every real call, so the phase never advanced. Like the sibling guards, this hook now
# loads those settings from the repo the git/bridge event actually happened in (PARSED as data, never sourced -
# CWE-829) BEFORE the gate, so the gate sees the real configuration and targets the right project.
#
# WHY it resolves the repo with the SHARED git_target_repo_dir: a session's commands all start in its own directory and
# reach a story repo with `cd <repo> && git ...` or `git -C <repo> ...`. Reading the branch of the starting directory
# skipped every such commit silently; the shared resolver (the one every git guard uses) finds the repo the operation
# actually ran in, so committing into another project's worktree advances THAT project's story.
#
# WHY it also reads the STORY_* settings written in the OBSERVED COMMAND: the hook runs in the harness process, not in
# the agent's shell, so a `STORY_GITLAB_PROJECT=7 git commit` or an `export STORY_BACKEND=gitlab; ...` reaches the story
# tool but never this hook's environment. A worktree outside the session folder usually has no standards.env of its
# own, so without this the hook resolved NOTHING for exactly the commits the story tool handled fine - and the story
# silently skipped its phases. The command's own assignments are read the way the story tool sees them (they win over
# a standards.env value), as literal values only, and validated before use.
#
# LOUD, NEVER SILENT: this is PostToolUse — it runs AFTER the tool call, so it can never undo or prevent the commit or
# push. It uses the tool's MONOTONIC `story phase --advance`, so an out-of-order event can never regress the phase.
# When a lifecycle event IS detected on a story branch but the advance cannot proceed (no backend resolvable, the story
# tool missing, the advance call failing), it answers `decision: block` with the reason and the exact fix: the agent
# must deal with it before it goes on, so a story cannot drift out of its phases unnoticed. A deliberate non-gitlab
# backend, a non-story branch and a repository on another GitLab instance stay quiet or informational.
# Wired: PostToolUse, matcher "Bash|mcp__KyklosBridge__(get_coverage|run_tests)".
# [json-answer-required] Every answer this hook reads goes through the JSON reader; without it a check would exit 127
# and fall into a fail-open path, so the hook refuses by name instead (a broken install). [CySec] CWE-636
. "$(dirname "${BASH_SOURCE[0]}")/lib/json-answer.sh" 2>/dev/null
if ! command -v json_test >/dev/null 2>&1; then
    printf '{"decision":"block","reason":"BLOCKED (%s): the JSON reader hooks/lib/json-answer.sh did not load (broken install), so this check cannot run. Reinstall or repin the kyklos plugin."}\n' "$(basename "$0")"
    exit 0
fi
set +e -uo pipefail
_PA_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_PA_HERE/lib/git-cmd-detect.sh" 2>/dev/null || exit 0
command -v jq >/dev/null 2>&1 || exit 0

INPUT="$(cat || true)"
_tool="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)"
cmd="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"

# Resolve the lifecycle event, the story NUMBER it applies to, and the REPO the event happened in (_cwd). The event
# repo is needed up front: its .claude/standards.env carries the story backend config, and it is the project the
# phase advance must target.
_phase=""; _num=""; _cwd=""; _pa_on_story_branch=""
# A real commit appends to the branch's HEAD reflog, and a real push records "update by push" on the remote-tracking
# ref it moved; a dry run or a no-op writes neither. The age is the file's own modification time on this machine (a
# commit date the committer sets plays no part), and a window covers commit hooks that run after the write.
_PA_RECORD_WINDOW_SECONDS=600
# _pa_recorded <commit|push>: rc 0 when the repository _cwd shows the operation just recorded work.
_pa_recorded() {
  local now f age; now="$(date +%s)"
  if [ "$1" = commit ]; then
    f="$(git -C "$_cwd" rev-parse --path-format=absolute --git-path logs/HEAD 2>/dev/null)" || return 1
    [ -f "$f" ] || return 1
    age=$(( now - $(stat -c %Y "$f" 2>/dev/null || echo 0) ))
    [ "$age" -le "$_PA_RECORD_WINDOW_SECONDS" ] && tail -n 1 "$f" | cut -f2- | grep -cE '^commit' >/dev/null
    return
  fi
  local common refs ref; common="$(git -C "$_cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  refs="$(git -C "$_cwd" for-each-ref --format='%(refname)' refs/remotes 2>/dev/null)" || return 1
  while IFS= read -r ref; do
    f="$common/logs/$ref"
    [ -n "$ref" ] && [ -f "$f" ] || continue
    age=$(( now - $(stat -c %Y "$f" 2>/dev/null || echo 0) ))
    [ "$age" -le "$_PA_RECORD_WINDOW_SECONDS" ] && tail -n 1 "$f" | grep -c 'update by push' >/dev/null && return 0
  done <<REFS
$refs
REFS
  return 1
}
case "$_tool" in
  mcp__KyklosBridge__get_coverage|mcp__KyklosBridge__run_tests)
    # A coverage/test run is the Testing stage — but ONLY when bound to a story (the `story` argument); an unbound
    # ad-hoc run must not advance anything.
    _sp="$(printf '%s' "$INPUT" | jq -r '.tool_input.story // empty' 2>/dev/null || true)"
    [ -n "$_sp" ] || exit 0
    _num="$(printf '%s' "$_sp" | grep -oE '[0-9]+' | head -1 | sed 's/^0*//')"
    _num="${_num:-0}"
    _phase="Testing"
    # A bridge call carries no git cwd. Without a `tree` the run measured the session's own solution root, so the
    # event repo is the active project. With a `tree` it measured that repository: a relative tree lies inside the
    # solution root (the same project); a host path (R:\<Repo>\sub) is the repository mounted beside the workspace
    # under the same folder name (/mnt/<Repo>), and that repository's own story settings decide the project. A tree
    # that is not visible here cannot be attributed, so nothing is advanced - never the session's project instead.
    _cwd="${CLAUDE_PROJECT_DIR:-$(pwd)}"
    _tree="$(printf '%s' "$INPUT" | jq -r '.tool_input.tree // empty' 2>/dev/null || true)"
    if [ -n "$_tree" ]; then
      _t="$(printf '%s' "$_tree" | tr '\\' '/')"; _cand=""
      case "$_t" in
        [A-Za-z]:/*) _first="${_t#?:/}"; _first="${_first%%/*}"
                     [ -n "$_first" ] && _cand="${KYKLOS_PHASE_ADVANCE_MOUNT_ROOT:-/mnt}/$_first" ;;
        /*) _cand="$_t" ;;
      esac
      if [ -n "$_cand" ]; then
        _top="$(git -C "$_cand" rev-parse --show-toplevel 2>/dev/null || echo "")"
        [ -n "$_top" ] || exit 0
        _cwd="$_top"
      fi
    fi
    # Starting a not-started story is left to work on ITS branch: a test run bound to story N starts it only when the
    # measured repository is on story N's branch.
    _branch="$(git -C "$_cwd" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
    [ "$(story_num_from_branch "$_branch" | sed 's/^0*//')" = "$_num" ] && _pa_on_story_branch=1
    ;;
  *)
    # A Bash git command: push -> Testing, else commit -> Implementation.
    [ -n "$cmd" ] || exit 0
    if git_cmd_invokes "$cmd" push 2>/dev/null; then _phase="Testing"
    elif git_cmd_invokes "$cmd" commit 2>/dev/null; then _phase="Implementation"
    fi
    [ -n "$_phase" ] || exit 0
    # Resolve the repo the git operation ACTUALLY ran in with the SHARED resolver every git guard uses
    # (`git -C <dir>`, a `cd <dir>` before the git token, --work-tree, GIT_DIR, else the hook cwd). The hook-input
    # .cwd alone is not enough: a session's commands all start in its own directory, so `cd <story-repo> && git
    # commit` or `git -C <story-repo> commit` would otherwise be read against the wrong repo and silently skipped.
    _op=commit; [ "$_phase" = Testing ] && _op=push
    _hook_cwd="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"
    _cwd="$(git_target_repo_dir "$cmd" "$_hook_cwd" "${CLAUDE_PROJECT_DIR:-${_hook_cwd:-$(pwd)}}" "$_op")"
    # A command-substitution target cannot be resolved statically: never guess a repo.
    [ "$_cwd" = "__UNDECIDABLE__" ] && exit 0
    _top="$(git -C "$_cwd" rev-parse --show-toplevel 2>/dev/null || echo "")"
    [ -n "$_top" ] && _cwd="$_top"
    _branch="$(git -C "$_cwd" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
    # The story number via the SHARED branch parser (the same one the gitflow and commit-message guards use).
    _num="$(story_num_from_branch "$_branch" | sed 's/^0*//')"
    [ -n "$_num" ] || exit 0
    _pa_on_story_branch=1
    # Only a git command that really recorded work moves the story: a dry run, an up-to-date push or a commit that
    # wrote nothing changes nothing.
    _pa_args="$(cmd_strip "$cmd" | sed -nE "s/.*(^|[[:space:]])$_op([[:space:]][^;&|]*)?([;&|].*)?\$/\2/p")"
    # git accepts any unambiguous prefix of a long option, so --dry, --dry-, --dry-r and --dry-ru are dry runs too.
    printf '%s' "$_pa_args" | grep -cE '(^|[[:space:]])--dry(-(r(u(n)?)?)?)?([[:space:]=]|$)' >/dev/null && exit 0
    [ "$_op" = push ] && printf '%s' "$_pa_args" | grep -cE '(^|[[:space:]])-[A-Za-z]*n[A-Za-z]*([[:space:]]|$)' >/dev/null && exit 0
    _pa_recorded "$_op" || exit 0
    ;;
esac
# No story number => not a story lifecycle event (e.g. a commit on a non-story branch). Silent, by design.
[ -n "$_num" ] || exit 0

# From here a lifecycle event IS bound to story #_num. A PostToolUse hook reaches the agent ONLY through its stdout JSON
# (plain stderr on exit 0 is not shown to it); every message is also kept on stderr for logs. The hook exits 0 either
# way: the tool call already happened.
# _phase_advance_notice: informational (a deliberate situation the agent cannot fix from here).
_phase_advance_notice() {
  local msg; msg="[phase-advance] could not advance story ${_num} to ${_phase}: $1"
  jq -cn --arg m "$msg" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$m}}' 2>/dev/null || true
  printf '%s\n' "$msg" >&2
}
# _phase_advance_fail: the story is drifting out of its phases. `decision: block` makes the agent read the reason and
# act before it continues (POKA-YOKE: a silent mis-configuration becomes a stop the agent cannot scroll past).
_phase_advance_fail() {
  local msg; msg="[phase-advance] could not advance story ${_num} to ${_phase}: $1 The story's phase did NOT move. Advance it now with: story phase ${_num} ${_phase} --advance (with the story settings the story tool uses for this repository)."
  jq -cn --arg m "$msg" '{decision:"block",reason:$m,hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$m}}' 2>/dev/null || true
  printf '%s\n' "$msg" >&2
}

# [RiskMitigation RA-02] Shell-rule scope, so a setting written for another command never steers this advance.
# _pa_command_setting <command> <NAME>: the literal value NAME has for the command's first git invocation, by shell
# rules: an `export NAME=v` earlier in the command, overridden by a `NAME=v` written directly in front of the git
# command itself. A `NAME=v other-tool` prefix belongs to that other tool only and is ignored, so a setting meant for a
# different command can never steer this advance. Only literal values: a value that expands anything ($, a back-quote)
# is ignored, never evaluated (CWE-78).
_pa_command_setting() {
  local before value="" segment
  before="$(printf '%s' "$1" | sed -E 's/(^|[;&|[:space:]])git[[:space:]].*$//')"
  while IFS= read -r segment; do
    case "$segment" in
      export[[:space:]]*) value="$(_pa_literal_assignment "$segment" "$2")" ;;
    esac
  done <<SEGMENTS
$(printf '%s' "$before" | tr ';&|' '\n\n\n' | sed -E 's/^[[:space:]]+//')
SEGMENTS
  # The words directly in front of the git command, when they are all assignments.
  segment="$(printf '%s' "$before" | sed -E 's/^.*[;&|]//; s/^[[:space:]]+//')"
  if printf '%s' "$segment" | grep -cE '^([A-Za-z_][A-Za-z0-9_]*=("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:]"'"'"']*)([[:space:]]+|$))+$' >/dev/null; then
    local prefixed; prefixed="$(_pa_literal_assignment " $segment" "$2")"
    [ -n "$prefixed" ] && value="$prefixed"
  fi
  printf '%s' "$value"
}
# _pa_literal_assignment <text> <NAME>: the last literal value assigned to NAME in <text>, else nothing.
# [RiskMitigation RA-01] Text only: the value is never evaluated, and one that would expand ($, a back-quote) is skipped.
_pa_literal_assignment() {
  printf '%s' "$1" | grep -oE "(^|[[:space:]])$2=(\"[^\"\$\`]*\"|'[^']*'|[^[:space:]\"'\$\`]+)" \
    | tail -1 | sed -E "s/^.*$2=//; s/^[\"']//; s/[\"']\$//"
}

# Per-project story config (STORY_BACKEND/STORY_GITLAB_PROJECT) lives in the EVENT repo's .claude/standards.env, not
# in this hook's process environment. PARSE it as data (never source - CWE-829) BEFORE the backend gate so the gate
# sees the real configuration. Best-effort: a missing lib or file leaves the environment untouched.
# [CySec] A repo OUTSIDE the session's workspace (another project's checkout or worktree) is not under the session's
# control: its file contributes ONLY its story identity (STANDARDS_ENV_FOREIGN_KEYS); everything else - API endpoint,
# token variable, PATH, proxies - comes from the session's own project settings (CWE-426 / CWE-829 / CWE-522).
. "$_PA_HERE/lib/standards-env.sh" 2>/dev/null || true
_pa_own="$(cd "${CLAUDE_PROJECT_DIR:-$_cwd}" 2>/dev/null && pwd -P)"; _pa_evt="$(cd "$_cwd" 2>/dev/null && pwd -P)"
# An unresolvable project folder must not make every repository "the session's own" (fail closed: treat as foreign).
[ -n "$_pa_own" ] || _pa_own="/nonexistent-session-project"
case "$_pa_evt/" in
  "$_pa_own"/*) load_standards_env "$_cwd/.claude/standards.env" 2>/dev/null || true ;;
  *) load_standards_env "${CLAUDE_PROJECT_DIR}/.claude/standards.env" 2>/dev/null || true
     # Never let this session's own project identity stand in for the foreign repo's (a wrong-project advance).
     unset STORY_BACKEND STORY_GITLAB_PROJECT STORY_GITLAB_LABEL
     if [ -f "$_cwd/.claude/standards.env" ] && command -v load_standards_env_keys >/dev/null 2>&1; then
       if ! standards_env_same_instance "$_cwd/.claude/standards.env"; then
         # Its stories live on another GitLab instance: its project number means nothing on this one.
         _phase_advance_notice "the repository's stories live on another GitLab instance; its phase is not advanced from this session"
         exit 0
       fi
       # shellcheck disable=SC2086  # the key list is a space-separated constant, split on purpose
       load_standards_env_keys "$_cwd/.claude/standards.env" $STANDARDS_ENV_FOREIGN_KEYS 2>/dev/null || true
     fi ;;
esac

# The story settings written in the observed command itself, as the story tool sees them (a command's assignment wins
# over a standards.env value). [CySec] Only the story identity is taken from the command, and only when it has the
# shape of one: a backend word and a project id or path (CWE-20 Improper Input Validation).
if [ -n "${cmd:-}" ]; then
  _pa_cmd_backend="$(_pa_command_setting "$cmd" STORY_BACKEND)"
  _pa_cmd_project="$(_pa_command_setting "$cmd" STORY_GITLAB_PROJECT)"
  case "$_pa_cmd_backend" in gitlab|fs|filesystem) export STORY_BACKEND="$_pa_cmd_backend" ;; esac
  if printf '%s' "$_pa_cmd_project" | grep -cE '^[A-Za-z0-9][A-Za-z0-9._/-]{0,254}$' >/dev/null; then
    export STORY_GITLAB_PROJECT="$_pa_cmd_project"
  fi
fi

# Tell the bridge GUI who committed or pushed on which story, in which project (display only, fail-open). Placed after
# the event repository's settings are loaded, so the project reported is that repository's, not the session's.
if [ -n "${_op:-}" ] && [ -f "$_PA_HERE/lib/fyi.sh" ]; then
  # shellcheck source=lib/fyi.sh
  { . "$_PA_HERE/lib/fyi.sh" && fyi_emit "$_op" "$_num" "$_op on ${_branch:-?}" "" "$_cwd"; } 2>/dev/null || true
fi

# Only when the story tooling is configured for the gitlab backend (phase labels are a gitlab concept). Best-effort.
if ! { [ "${STORY_BACKEND:-}" = gitlab ] || [ -n "${STORY_GITLAB_PROJECT:-}" ]; }; then
  # Notify ONLY when the backend is genuinely UNRESOLVED (nothing selected) - that is the mis-config this guards
  # against. A project that DELIBERATELY runs a non-gitlab backend (e.g. STORY_BACKEND=fs) has no phase labels to
  # advance, so stay silent there instead of warning on every commit.
  if [ -z "${STORY_BACKEND:-}" ] && [ -z "${STORY_GITLAB_PROJECT:-}" ]; then
    _phase_advance_fail "no story backend resolves for $_cwd (checked the hook's environment, the command's own STORY_* settings and $_cwd/.claude/standards.env). Give the git command the settings the story tool uses, e.g. STORY_BACKEND=gitlab STORY_GITLAB_PROJECT=<id> git ..., or declare them in that repository's .claude/standards.env."
  fi
  exit 0
fi
# The story tool; KYKLOS_PHASE_ADVANCE_STORY is a TEST seam (unset in production).
_story="${KYKLOS_PHASE_ADVANCE_STORY:-$_PA_HERE/../skills/ssdlc-story/story}"
if [ ! -f "$_story" ]; then
  _phase_advance_fail "story tool not found at $_story."
  exit 0
fi

# MONOTONIC advance (forward-only; a backward target is a no-op). A FAILURE of the advance itself stops the agent
# with the reason (the git command already happened and stays). Target the EVENT repo so a cross-project session advances the right project.
_pa_out="$(CLAUDE_PROJECT_DIR="$_cwd" bash "$_story" phase "$_num" "$_phase" --advance 2>&1)"; _pa_rc=$?
# A story nobody started may not move past Design, so the story tool leaves it where it is (a no-op in the bash
# mechanics, a refusal from the bridge); both answers name the story's state. A commit, a push or a story-bound test
# run on the story's OWN branch IS the work starting, so a Todo story is started, then advanced, and its history
# records the phases as they happen instead of jumping at the close. A Parked or Blocked story was set aside on
# purpose: work never un-parks or unblocks it; the agent is told instead.
_pa_state="$(printf '%s' "$_pa_out" | sed -nE 's/.*\(unchanged — story is ([A-Za-z -]+); .*/\1/p; s/.*Story [0-9]+ is ([A-Za-z -]+), so it cannot enter .*/\1/p' | head -1)"
case "$_pa_state" in
  Todo|ToDo)
    if [ -z "$_pa_on_story_branch" ]; then
      _phase_advance_notice "the story is ${_pa_state} and the work is not on its branch, so it was not started."
      exit 0
    fi
    if ! CLAUDE_PROJECT_DIR="$_cwd" bash "$_story" set "$_num" status=In-progress >/dev/null 2>&1; then
      _phase_advance_fail "the story is not started and starting it (story set ${_num} status=In-progress) failed."
      exit 0
    fi
    _pa_out="$(CLAUDE_PROJECT_DIR="$_cwd" bash "$_story" phase "$_num" "$_phase" --advance 2>&1)"; _pa_rc=$?
    if [ "$_pa_rc" -eq 0 ]; then
      _pa_msg="[phase-advance] story ${_num} was not started; this work on its branch started it (status In-progress) and moved it to ${_phase}."
      jq -cn --arg m "$_pa_msg" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$m}}' 2>/dev/null || true
    fi ;;
  ?*)
    _phase_advance_notice "the story is ${_pa_state}; work on its branch does not resume it. Resume it deliberately (story set ${_num} status=In-progress) if this work belongs to it."
    exit 0 ;;
esac
if [ "$_pa_rc" -ne 0 ]; then
  _phase_advance_fail "the 'story phase --advance' call failed."
fi
exit 0
