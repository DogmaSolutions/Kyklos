#!/usr/bin/env bash
# kyklos-zero-failures-gate.sh (Kyklos) — TIER-0: blocks the agent immediately after any test run that
# reports failures (or whose result cannot be confirmed). How a failure is handled — fixed, or root-caused and
# surfaced to its owner — is the "No unexplained failures" rule of the managed policy and the running-tests skill;
# this gate never lets a failure be silently waved through.
#
# Wired (see hooks.json):
#   after-bash-test : PostToolUse matcher Bash                          -> blocks if `dotnet test` had failures
#   after-mcp-test  : PostToolUse matcher mcp__KyklosBridge__(run_tests|get_job_result) -> same, from the MCP tool
#                     result. A run_tests call answers `pending` when its run is queued or still going (the result is
#                     collected later with get_job_result), so: a PENDING answer is judged by nobody (the failure log
#                     is kept), and only an answer that carries a test result (`exitCode=` text) is judged.
#
# Config (optional .claude/standards.env): KYKLOS_STATE_DIR (default /tmp/kyklos-state).
set -euo pipefail

# --- Kyklos: load optional per-project config ---
_cfg="${CLAUDE_PROJECT_DIR:-$(pwd)}/.claude/standards.env"
. "$(dirname "${BASH_SOURCE[0]}")/lib/standards-env.sh"; load_standards_env "$_cfg"   # PARSE, never source (CWE-829)
STATE_DIR="${KYKLOS_STATE_DIR:-/tmp/kyklos-state}"
mkdir -p "$STATE_DIR"

MODE="${1:-}"
FAILURE_LOG="$STATE_DIR/last-test-failures"
INPUT="$(cat || true)"

case "$MODE" in
  after-bash-test)
    # Gate ONLY a real `dotnet test`/`vstest` INVOCATION in COMMAND POSITION — never a MENTION. The OLD raw-INPUT
    # grep matched `dotnet\s+(vs)?test` anywhere in the payload INCLUDING the tool OUTPUT, so a `grep`/`cat` of a file
    # that merely CONTAINS runner-summary strings false-fired this Tier-0 gate (observed live). Detect on the ACTUAL
    # command via the shared lib (strips heredoc bodies + quoted args first). Without jq we cannot extract the command
    # precisely -> fail-open (the CI backstop still catches a real failing run).
    command -v jq >/dev/null 2>&1 || exit 0
    _cmd="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
    [ -n "$_cmd" ] || exit 0
    . "$(dirname "${BASH_SOURCE[0]}")/lib/dotnet-cmd-detect.sh"
    dotnet_cmd_invokes "$_cmd" 'test|vstest' || exit 0

    # Extract the run OUTPUT from the tool response (jq never truncates at an escaped quote inside the output).
    COMBINED="$(printf '%s' "$INPUT" | jq -r '[.tool_response.stdout?, .tool_response.stderr?, .stdout?, .stderr?] | map(select(type=="string")) | join("\n")' 2>/dev/null || true)"

    # "Failed:  N" (sum across assemblies) — the VSTest console summary is authoritative when present.
    # '|| true' so a no-match under `set -euo pipefail` CANNOT abort the gate. [RiskMitigation] the OLD line
    # aborted here (pipefail propagated grep's exit-1) on a build error / crashed testhost that emits no
    # summary -> the Tier-0 gate FAILED OPEN on exactly the catastrophic case. awk always prints a number.
    FAIL_COUNT="$( { printf '%s' "$COMBINED" | grep -oE 'Failed:[[:space:]]+[0-9]+' | grep -oE '[0-9]+' || true; } | awk '{s+=$1} END {print s+0}')"

    # A `dotnet test` that never reached a VSTest summary but shows a build/compile/run failure is NOT
    # "zero failures" — it is an unfinished, FAILED run and MUST block. Only when NO summary is present at all
    # (so a mixed solution where one project "has no tests" but others "Passed!" is not falsely blocked).
    HAS_SUMMARY=0
    printf '%s' "$COMBINED" | grep -cE 'Passed!|Failed!|Failed:[[:space:]]+[0-9]' >/dev/null && HAS_SUMMARY=1
    RUN_BROKEN=0
    printf '%s' "$COMBINED" | grep -ciE 'Build FAILED|error [A-Z]{2,}[0-9]{3,}|MSBUILD : error|the build failed|no test is available|could not execute because|test run was aborted' >/dev/null && RUN_BROKEN=1
    # A real BUILD/COMPILE/ABORT failure must block EVEN WHEN a sibling project in the same run printed a summary:
    # `Build FAILED` + another project's `Passed!` sets HAS_SUMMARY=1 and would slip through the (HAS_SUMMARY==0 &&
    # RUN_BROKEN) clause. Only the benign "no test is available" (a project genuinely without tests) stays soft-
    # exempt. [CySec] Prevents a green-wash bypass (a compile failure reported as zero-failures).
    HARD_BROKEN=0
    printf '%s' "$COMBINED" | grep -ciE 'Build FAILED|error [A-Z]{2,}[0-9]{3,}|MSBUILD : error|the build failed|could not execute because|test run was aborted' >/dev/null && HARD_BROKEN=1

    # A REAL `dotnet test`/`vstest` invocation ALWAYS emits a recognizable signal — a VSTest summary, a
    # build result, a restore/discovery line, or an abort. If the captured output carries NONE of them, the run's
    # output was NOT captured (killed before printing, output routed off-payload, empty tool_response) — so we CANNOT
    # confirm zero failures. Reading that as green is the classic fail-OPEN. Block LOUD instead. [CySec] Enforces
    # CWE-393 "Return of Wrong Status Code": treat unconfirmable as failing, never silently pass. (no-fail-open directive)
    NO_SIGNAL=0
    printf '%s' "$COMBINED" | grep -ciE 'Passed!|Failed!|Passed:[[:space:]]|Failed:[[:space:]]+[0-9]|Skipped:[[:space:]]|no test is available|Build (FAILED|succeeded)|error [A-Z]{2,}[0-9]{3,}|MSBUILD|Restore|Determining projects|test run was aborted|could not execute|A total of [0-9]+ test|Starting test execution' >/dev/null || NO_SIGNAL=1

    if [ "${FAIL_COUNT:-0}" -gt 0 ] || [ "$HARD_BROKEN" -eq 1 ] || [ "$NO_SIGNAL" -eq 1 ] || { [ "$HAS_SUMMARY" -eq 0 ] && [ "$RUN_BROKEN" -eq 1 ]; }; then
      printf '%s' "$COMBINED" | grep -oE 'Failed[[:space:]]+[^[:space:]]+' 2>/dev/null | head -20 > "$FAILURE_LOG" 2>/dev/null || true
      if [ "${FAIL_COUNT:-0}" -gt 0 ]; then
        reason="TEST RUN REPORTED ${FAIL_COUNT} FAILURE(S). Investigate every failure and root-cause it, then re-run until green; never dismiss, skip or silently suppress one. A failure in code you do not own is root-caused and surfaced to its owner (the 'No unexplained failures' rule of the managed policy; procedure: the running-tests skill). git-stash is for diagnosis only, not exemption."
      elif [ "${NO_SIGNAL:-0}" -eq 1 ]; then
        reason="TEST RUN OUTPUT WAS NOT CAPTURED — a real \`dotnet test\`/\`vstest\` invocation produced NO recognizable output (no summary, no build result, no restore/discovery line). Zero-failures CANNOT be confirmed from an empty run, so this is NOT a pass. Re-run the tests so their full output is captured, then verify the suite is actually green before proceeding."
      else
        reason="TEST RUN DID NOT COMPLETE — the output shows a build/compile error or an aborted run and NO test summary. A broken build is NOT 'zero failures'; it is an unfinished, failed run. Fix the build/root cause and re-run until the suite is actually green. Do NOT proceed on an unfinished test run."
      fi
      printf '{"decision":"block","reason":"%s"}' "$reason"
      exit 0
    fi
    # A run of part of the suite (a project file or folder, an assembly, a filter, the last build's binaries, ...) is
    # green only for what it ran: it never clears the failures an earlier run recorded. The shell reading is of the
    # command line (lib/dotnet-test-scope.sh); the bridge's structured partial marker is the authoritative one.
    . "$(dirname "${BASH_SOURCE[0]}")/lib/dotnet-test-scope.sh"
    dotnet_test_is_partial "$_cmd" && exit 0
    rm -f "$FAILURE_LOG"
    exit 0
    ;;

  after-mcp-test)
    [ -z "$INPUT" ] && exit 0
    # Not a test result yet (a pending/queued answer) or not a test result at all (a coverage/build/mutation job
    # collected through get_job_result): judge nothing and keep the failure log - never read "no failed field" as green.
    printf '%s' "$INPUT" | grep -cE '"pending"[[:space:]]*:[[:space:]]*true' >/dev/null && exit 0
    printf '%s' "$INPUT" | grep -cE 'exitCode=-?[0-9]+' >/dev/null || exit 0
    # The failure count arrives as a JSON field ("failed": N) and/or in the bridge's result text (failed=N); the text is
    # the only one a plain run_tests answer carries. Read both and take the larger, so a completed run with failures is
    # never mistaken for a run that did not complete (and a disagreement never under-reports failures).
    FAILED_JSON="$( { printf '%s' "$INPUT" | grep -oE '"failed"[[:space:]]*:[[:space:]]*[0-9]+' | grep -oE '[0-9]+' || true; } | head -1)"
    FAILED_TEXT="$( { printf '%s' "$INPUT" | grep -oE '(^|[^A-Za-z_])failed=[0-9]+' | grep -oE '[0-9]+' || true; } | head -1)"
    FAILED="${FAILED_JSON:-0}"; [ "${FAILED_TEXT:-0}" -gt "$FAILED" ] && FAILED="$FAILED_TEXT"
    # The bridge run_tests result carries `exitCode=N failed=N`. A build/run failure returns exitCode!=0 with
    # failed=0 (no tests ran) — that is NOT "zero failures" and must block, mirroring the after-bash-test path.
    EXITCODE="$( { printf '%s' "$INPUT" | grep -oE 'exitCode=-?[0-9]+' | grep -oE -- '-?[0-9]+' || true; } | head -1)"; EXITCODE="${EXITCODE:-0}"
    # A run whose test summary could not be read (ran=False / "ran": false / failed=unknown) has UNKNOWN failures, even
    # with exit code 0: it is never green. [CySec] Prevents CWE-393 "Return of Wrong Status Code". [RiskMitigation RA-05]
    UNREAD=0
    printf '%s' "$INPUT" | grep -cE '(^|[^A-Za-z_])ran=False|"ran"[[:space:]]*:[[:space:]]*false|(^|[^A-Za-z_])failed=unknown' >/dev/null && UNREAD=1
    # A run the bridge STOPPED (its time limit, its idle limit, or a cancel) never finished: its failures are unknown
    # and the cause is the stop, not whatever its partial output says. Name it. [CySec] Prevents CWE-393. [RiskMitigation RA-05]
    STOPPED="$( { printf '%s' "$INPUT" | grep -oE '(^|[^A-Za-z_])stopped=(timed-out|idle-timeout|cancelled)' | sed 's/.*stopped=//' || true; } | head -1)"
    if [ "$FAILED" -gt 0 ] || [ "$EXITCODE" != "0" ] || [ "$UNREAD" = 1 ] || [ -n "$STOPPED" ]; then
      if [ -n "$STOPPED" ]; then
        reason="TEST RUN WAS STOPPED BY THE BRIDGE (${STOPPED}) before it finished - its failures are UNKNOWN, not zero. The answer names the test assemblies the stop cut off. Narrow the run (a filter or a framework), or, after a time-limit stop, ask for a longer limit with timeoutMinutes (up to the bridge's maximum) if the suite legitimately needs longer, then re-run until the suite reports a green summary."
      elif [ "$FAILED" -gt 0 ]; then
        reason="TEST RUN REPORTED ${FAILED} FAILURE(S). Use the runner's get_failures/get_logs to investigate every failure, root-cause it, and re-run until green; never dismiss, skip or silently suppress one. A failure in code you do not own is root-caused and surfaced to its owner (the 'No unexplained failures' rule of the managed policy; procedure: the running-tests skill)."
      elif [ "$EXITCODE" = "0" ]; then
        reason="TEST RUN PRODUCED NO READABLE TEST SUMMARY (run_tests exitCode=0, failures unknown) - nothing proves the tests ran or passed. Use get_logs and the saved test output to see what happened, fix it, and re-run until the suite reports a green summary."
      else
        reason="TEST RUN DID NOT COMPLETE (run_tests exitCode=${EXITCODE}, failed=0) — a build/compile error or aborted run, NOT zero failures. Use get_logs to find the root cause, fix it, and re-run until the suite is green."
      fi
      printf '{"decision":"block","reason":"%s"}' "$reason"
      exit 0
    fi
    # A partial run (named test projects, or the last build's binaries) is green only for what it covered: it says
    # nothing about the rest of the suite, so it never clears the failures recorded by an earlier run.
    # The marker is the key `partial=true` on the FIRST line of the result text, or the result's top-level `partial`
    # field, read as structure: free text elsewhere in the answer can never stop failures from clearing. Without jq the
    # answer cannot be read as structure, so the log is kept (never cleared on a guess).
    command -v jq >/dev/null 2>&1 || exit 0
    _first="$(printf '%s' "$INPUT" | jq -r '(.tool_response // .) | (if type == "string" then . elif type == "array" then (map(select(.type? == "text"))[0].text // "") else ((.content // []) | map(select(.type? == "text"))[0].text // "") end) | split("\n")[0]' 2>/dev/null || true)"
    _field="$(printf '%s' "$INPUT" | jq -r '(.tool_response // .) | if type == "object" and (.partial | type) == "string" then "partial" else "" end' 2>/dev/null || true)"
    if [ -n "$_field" ] || printf '%s\n' "$_first" | tr ' ' '\n' | grep -cx 'partial=true' >/dev/null; then exit 0; fi
    rm -f "$FAILURE_LOG"
    exit 0
    ;;

  *)
    echo "zero-failures-gate.sh: unknown mode '$MODE'" >&2
    exit 0
    ;;
esac
