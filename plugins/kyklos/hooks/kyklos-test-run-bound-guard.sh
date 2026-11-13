#!/usr/bin/env bash
# kyklos-test-run-bound-guard.sh (Kyklos) - PreToolUse Bash. Refuses a shell command that starts a test runner without
# a `timeout <limit>` bounding it, and shows the corrected command.
#
# Why: three `dotnet test` runs an agent started from its shell without a time limit hung for about 20 hours at 98 % CPU
# each, slowed every agent on the machine and made the end-of-turn bridge check read the bridge as down. A run whose
# end is written in the command that starts it cannot outlive its purpose. The test-host reaper (Stop) is the backstop
# for whatever still escapes.
#
# Test runners (lib/run-bound.sh, test_runner_kind): dotnet test / vstest, the .NET test host, vstest.console,
# npm test, vitest, pytest, Pester (Invoke-Pester), the plugin battery (run-all.sh) and the CI shell suites
# (ci/tests/*.sh). Bounded: `timeout <duration>` with a duration above zero before the runner, past wrappers such as
# sudo, env, nice, nohup, flock or xargs, or around the shell whose -c string starts it. A runner only named as text (an
# echo or grep argument, a commit message, a heredoc body) is not started and passes.
#
# The limit the correction proposes is KYKLOS_TEST_RUN_LIMIT ("<n>s", "<n>m" or "<n>h"; default 60m), the same limit
# the reaper ends test hosts at.
#
# Default ON. The only off switch: KYKLOS_TEST_RUN_BOUND_GUARD=off (environment or .claude/standards.env); every use is
# audited. Wired: PreToolUse, matcher Bash.
set +e -uo pipefail

_TB_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_TB_HERE/lib/run-bound.sh"
. "$_TB_HERE/lib/standards-env.sh"
. "$_TB_HERE/lib/escape-audit.sh" 2>/dev/null || true

INPUT="$(cat || true)"
CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
[ -n "$CMD" ] || exit 0
HOOK_CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-${HOOK_CWD:-$PWD}}"

# [CySec] CWE-636 "Not Failing Securely": a detector that did not load cannot say a command is harmless; one that names a
# test runner is refused, naming the broken install.
if ! declare -F test_run_bound_find >/dev/null || ! declare -F shell_scan >/dev/null; then
    if [[ "$CMD" =~ (dotnet|vstest|testhost|npm|vitest|pytest|py\.test|[Pp]ester|run-all\.sh|ci/tests/) ]]; then
        printf '[kyklos] bounded test-run guard: REFUSED - its library hooks/lib/run-bound.sh did not load (broken install), so this command, which names a test runner, cannot be checked. Reinstall or repin the kyklos plugin.\n' >&2
        exit 2
    fi
    exit 0
fi

# A script fed to a shell from a file (`bash < run.sh`, `cat run.sh | bash`) is read relative to the command's folder.
FOUND="$(TRB_CWD="${HOOK_CWD:-$PWD}" test_run_bound_find "$CMD")"
[ -n "$FOUND" ] || exit 0

# [RiskMitigation RA-02] Default on; the one off switch is audited (CWE-1188, insecure default).
_switch="${KYKLOS_TEST_RUN_BOUND_GUARD:-}"
[ -n "$_switch" ] || _switch="$(standards_env_value "$PROJECT_DIR/.claude/standards.env" KYKLOS_TEST_RUN_BOUND_GUARD 2>/dev/null)"
# shellcheck source=lib/control-switch.sh
. "$_TB_HERE/lib/control-switch.sh" 2>/dev/null || true   # kyklos_control_off: the one control-switch reader
if kyklos_control_off "$_switch"; then
    command -v escape_audit >/dev/null 2>&1 && escape_audit "test-run-bound-guard-off" "runners=$(printf '%s' "$FOUND" | cut -f1 | paste -sd, - | cut -c1-200)" 2>/dev/null
    exit 0
fi

_limit="${KYKLOS_TEST_RUN_LIMIT:-}"
[ -n "$_limit" ] || _limit="$(standards_env_value "$PROJECT_DIR/.claude/standards.env" KYKLOS_TEST_RUN_LIMIT 2>/dev/null)"
test_run_limit_parse "$_limit" >/dev/null || _limit="$TRB_DEFAULT_LIMIT"

_runners="$(printf '%s' "$FOUND" | cut -f1 | awk 'NF && !seen[$0]++' | sed 's/^/  - /')"
_fixed="$(test_run_bound_correct "$CMD" "$_limit" "$FOUND")"
if [ -n "$_fixed" ]; then
    _how="Run it bounded instead:
  ${_fixed}"
else
    _how="Put \`timeout ${_limit}\` right before each runner (or before the shell whose -c string starts it), for example: timeout ${_limit} dotnet test ..."
fi
cat >&2 <<EOF
[kyklos] bounded test-run guard: REFUSED - this command starts a test runner without a time limit:
${_runners}
A test run without a bound can hang for hours at full CPU, slowing every agent on the machine. ${_how}
(The limit is KYKLOS_TEST_RUN_LIMIT, default ${TRB_DEFAULT_LIMIT}; choose a larger one for a run that honestly takes longer.)
Only off switch: KYKLOS_TEST_RUN_BOUND_GUARD=off (audited).
EOF
exit 2
