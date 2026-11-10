#!/usr/bin/env bash
# kyklos-script-lint-guard.sh (Kyklos) - PreToolUse Bash. Before a `git push`, runs the script formal check
# (hooks/lib/script-lint/Invoke-ScriptLint.ps1: encoding, line endings, quoting and parse errors in shell,
# PowerShell and batch files) over the scripts the pushed branch changes, and blocks the push on a finding.
#
# WHY: these mistakes keep recurring and most of these scripts cannot be tested before a real host launch; the CI
# job script-lint catches them too, but only after a push and a pipeline. This guard stops them at the source.
#
# The checker is a byte-identical copy of the CI script-lint checker, scripts/Invoke-ScriptLint.ps1 (+ lib/); the CI job
# script-lint-copy fails if the two ever differ, so there is one implementation.
#
# Scope: the scripts added, copied, modified or renamed between the merge base with the remote default branch and
# HEAD. Default-ON; explicit opt-out: SCRIPT_LINT=off (environment or .claude/standards.env).
# pwsh missing: a loud warning and the push goes on (the CI job still blocks); shellcheck missing: the checker
# reports SL005 as "not checked".
#
# One-shot LOGGED override (consumed on the block path only): bash hooks/lib/override-marker.sh set script-lint-ok <repo-dir>
#
# Wired: PreToolUse, matcher Bash.
# [json-answer-required] Every answer this hook reads goes through the JSON reader; without it a check would exit 127
# and fall into a fail-open path, so the hook refuses by name instead (a broken install). [CySec] CWE-636
. "$(dirname "${BASH_SOURCE[0]}")/lib/json-answer.sh" 2>/dev/null
if ! command -v json_test >/dev/null 2>&1; then
    printf '{"decision":"block","reason":"BLOCKED (%s): the JSON reader hooks/lib/json-answer.sh did not load (broken install), so this check cannot run. Reinstall or repin the kyklos plugin."}\n' "$(basename "$0")"
    exit 0
fi
set +e -uo pipefail
_GD_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_GD_HERE/lib/git-cmd-detect.sh"   # git_cmd_invokes / git_target_repo_dir: command-position detection (shared)
. "$_GD_HERE/lib/push-refspec.sh"     # push_is_delete (a delete pushes no content) + push_base (the shared push base)

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
. "$_GD_HERE/lib/standards-env.sh"; load_standards_env "$PROJECT_DIR/.claude/standards.env"
STATE_DIR="${KYKLOS_STATE_DIR:-/tmp/kyklos-state}"; mkdir -p "$STATE_DIR" 2>/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/override-marker.sh"   # override_take: the scoped, expiring one-shot override
OK_NAME=script-lint-ok
OK_SCOPE_HINT="<repo-dir>"
LINTER="${SCRIPT_LINT_CHECKER:-$_GD_HERE/lib/script-lint/Invoke-ScriptLint.ps1}"
INPUT="$(cat || true)"
CMD_REAL="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
[ -n "$CMD_REAL" ] || CMD_REAL="${INPUT//\\\"/\"}"
HOOK_CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"

git_cmd_invokes "$CMD_REAL" push || exit 0
push_is_delete "$CMD_REAL" && exit 0
[ "${SCRIPT_LINT:-on}" = "off" ] && { echo "[kyklos] script-lint: skipped (SCRIPT_LINT=off)." >&2; exit 0; }
command -v git >/dev/null 2>&1 || exit 0

TOP="$(git -C "$(git_target_repo_dir "$CMD_REAL" "$HOOK_CWD" "$PROJECT_DIR" push)" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$TOP" ] || exit 0

if ! command -v pwsh >/dev/null 2>&1; then
    echo "[kyklos] WARNING: script-lint pre-push check NOT run: pwsh is not installed. The CI job script-lint still blocks a bad script." >&2
    exit 0
fi
[ -f "$LINTER" ] || { echo "[kyklos] WARNING: script-lint pre-push check NOT run: checker missing at $LINTER." >&2; exit 0; }

# The base the branch is judged against: the merge base with the remote default branch (origin/HEAD, then the
# usual trunks). No base -> check every tracked script (a new repository).
BASE="$(push_base "$TOP" origin "" HEAD)" || BASE=""

args=(-NoProfile -NonInteractive -File "$LINTER" -Repo "$TOP")
[ -n "$BASE" ] && args+=(-ChangedSince "$BASE")
out="$(pwsh "${args[@]}" 2>&1)"; rc=$?

[ "$rc" -eq 0 ] && exit 0
if [ "$rc" -ne 1 ]; then
    echo "[kyklos] WARNING: script-lint could not run (exit $rc): $(printf '%s' "$out" | tail -1)" >&2
    exit 0
fi

override_take "$OK_NAME" "$(override_scope_of "${TOP:-$PROJECT_DIR}")" "$INPUT" && { echo "[kyklos] script-lint: OVERRIDDEN once ($OK_NAME spent) - a push was allowed with script findings." >&2; exit 0; }

findings="$(printf '%s\n' "$out" | grep -E ': SL[0-9]{3}: ' | grep -v '(allowed: ' | head -20)"
reason="Push BLOCKED - the script formal check found problems in the scripts this branch changes (fix them, or add a reviewed entry <path>|<RULE>|<reason> to .script-lint-allow): $(printf '%s' "$findings" | tr '\n' ';' | sed 's/;/; /g') For a single deliberate exception: bash $OVERRIDE_MARKER_CLI set $OK_NAME $OK_SCOPE_HINT"
reason="${reason//\\/\\\\}"; reason="${reason//\"/\\\"}"; reason="$(printf '%s' "$reason" | tr '\n\t' '  ')"
printf '{"decision":"block","reason":"%s"}' "$reason"
exit 0
