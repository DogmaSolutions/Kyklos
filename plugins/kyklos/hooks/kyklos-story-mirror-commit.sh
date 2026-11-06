#!/usr/bin/env bash
# kyklos-story-mirror-commit.sh — PostToolUse(Bash). Keep the committed Stories/ MIRROR tracking the GitLab SSoT as a
# story changes state, not only at close. After a state-changing `story` op (set / phase / requirements / ra / adopt)
# in a COMPANION/TRUNK-model repo (where Stories/ is trunk bookkeeping), regenerate the mirror from GitLab and COMMIT
# it if it changed — so the companion repo the developer reads never misrepresents in-progress work for hours
# (observed failure: a story showed Todo / no branch through its whole implementation).
#
# DEFAULT-ON; opt out with KYKLOS_MIRROR_AUTOCOMMIT=off (greppable). FAIL-SOFT: PostToolUse, best-effort, never
# blocks. It commits ONLY at a declared root (a repository toplevel holding .claude/standards.env, resolved from the
# working directory or the session project through the shared repository-role resolver) and never inside a companion's
# nested source or a linked worktree of it; when that cannot be proven it commits nothing and says so. Only the gitlab backend (the mirror is a projection of GitLab) and only a companion/trunk-model repo (an
# internal single-repo commits its own Stories/ on its own cadence). Commits ONLY the Stories/ pathspec, so it never
# disturbs the agent's other staged work.
set +e -uo pipefail
_MC_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v jq >/dev/null 2>&1 || exit 0

# shellcheck source=lib/control-switch.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/control-switch.sh" 2>/dev/null || true   # kyklos_control_off: the one control-switch reader
kyklos_control_off "${KYKLOS_MIRROR_AUTOCOMMIT:-}" && exit 0

INPUT="$(cat || true)"
cmd="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
[ -n "$cmd" ] || exit 0
# A `story` invocation whose subcommand changes state. (A read op — show/structure/proof/refresh/check — is skipped.)
printf '%s' "$cmd" | grep -cE '(^|[/[:space:]"'"'"'])story([[:space:]])' >/dev/null || exit 0
printf '%s' "$cmd" | grep -cE '([[:space:]])(set|phase|requirements|ra|adopt)([[:space:]])' >/dev/null || exit 0

# The hook's PostToolUse notice: shown to the agent as context and logged on stderr. It NEVER blocks (exit stays 0).
_mc_notice() {
  local msg="[mirror-commit] $1"
  jq -cn --arg m "$msg" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$m}}' 2>/dev/null || true
  printf '%s\n' "$msg" >&2
}

_cwd="$(printf '%s' "$INPUT" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
[ -n "$_cwd" ] || _cwd="${CLAUDE_PROJECT_DIR:-$(pwd)}"
# The repository-role resolver maps a directory inside a companion's nested source - or inside a LINKED WORKTREE of it,
# wherever that worktree lives - to the companion root, where Stories/ and .claude/ live.
. "$_MC_HERE/lib/repo-role.sh" 2>/dev/null || { _mc_notice "skipped: the repository-role resolver is missing, so the companion cannot be proven; nothing was committed."; exit 0; }

# _mc_declared_root <dir> -> the companion/trunk root that owns the mirror for <dir>: the resolved root, which must hold
# the declared model (.claude/standards.env) and BE its own git toplevel. rc 1 when that cannot be proven.
_mc_declared_root() {
  local root top
  [ -n "$1" ] || return 1
  root="$(repo_companion_root "$1")"
  [ -f "$root/.claude/standards.env" ] || return 1
  top="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)" || return 1
  [ "$(realpath -- "$top" 2>/dev/null)" = "$(realpath -- "$root" 2>/dev/null)" ] || return 1
  printf '%s' "$top"
}
# The working directory first, then the session's own project: the root must be a DECLARED one, never a guess. A
# nested source, or a worktree of it, always resolves to its companion here, so the mirror is never committed inside
# it. [CySec] Prevents CWE-538 (internal story files committed into a public source). [RiskMitigation RA-01]
PROJECT_DIR="$(_mc_declared_root "$_cwd")" || PROJECT_DIR="$(_mc_declared_root "${CLAUDE_PROJECT_DIR:-}")" || PROJECT_DIR=""

# Load the project model (STORY_BACKEND) the same way the other hooks do — PARSE, never source.
[ -n "$PROJECT_DIR" ] && { . "$_MC_HERE/lib/standards-env.sh" 2>/dev/null && load_standards_env "$PROJECT_DIR/.claude/standards.env" 2>/dev/null || true; }
[ "${STORY_BACKEND:-local}" = gitlab ] || exit 0
if [ -z "$PROJECT_DIR" ]; then
  _mc_notice "not committed: no declared companion owns the working directory $_cwd (no .claude/standards.env at a repository root). Run the story command from the companion root."
  exit 0
fi
# Only a companion/trunk-model repo auto-commits its mirror as bookkeeping; the model is read from the root's own file.
{ [ "$(repo_role "$PROJECT_DIR")" = companion ] || [ "$(repo_workflow "$PROJECT_DIR")" = trunk ]; } || exit 0
[ -d "$PROJECT_DIR/Stories" ] || exit 0

STORY="${KYKLOS_MIRROR_COMMIT_STORY:-$_MC_HERE/../skills/ssdlc-story/story}"
[ -f "$STORY" ] || exit 0

# Regenerate the mirror from the SSoT, then commit ONLY Stories/ when it actually changed. All best-effort.
CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$STORY" refresh --dir "$PROJECT_DIR/Stories" >/dev/null 2>&1 || true
git -C "$PROJECT_DIR" add -- Stories >/dev/null 2>&1 || exit 0
git -C "$PROJECT_DIR" diff --cached --quiet -- Stories 2>/dev/null && exit 0   # nothing changed -> done
_id="$(printf '%s' "$cmd" | grep -oE '(set|phase|requirements|ra|adopt)[[:space:]]+#?0*[0-9]+' | grep -oE '[0-9]+' | head -1)"
_refs=""; [ -n "$_id" ] && _refs="$(printf '\n\nRefs: #%s' "$_id")"
# The commit is the repository user's own: git's configured identity. Only a repository with no identity at all gets the
# neutral mirror identity below, so no product or organisation name is ever written into another project's history.
_ident=()
if [ -z "$(git -C "$PROJECT_DIR" config user.name 2>/dev/null)" ] || [ -z "$(git -C "$PROJECT_DIR" config user.email 2>/dev/null)" ]; then
  _ident=(-c "user.name=Story mirror" -c "user.email=story-mirror@localhost.invalid")
fi
git -C "$PROJECT_DIR" ${_ident[@]+"${_ident[@]}"} \
  commit -q -m "chore(stories): sync the Stories mirror to GitLab after a state change${_refs}" -- Stories >/dev/null 2>&1 || true
exit 0
