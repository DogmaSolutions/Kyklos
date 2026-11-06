#!/usr/bin/env bash
# kyklos-scenario-gate.sh — PreToolUse. In a **scenario-enabled** project (one that has a `scenarios/` dir),
# BLOCK build/test until an ACTIVE, VALID working scenario is selected — so multi-SLNX tooling never guesses
# which solutions to target. Covers the bridge's build/test MCP tools AND raw `dotnet test|build|run`.
# No-op in any project without `scenarios/` (single-repo / non-.NET are unaffected). See the scenario schema
# (the working-scenario model) + validate-scenario.sh.
set -e +u -o pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
SCEN_DIR="$PROJECT_DIR/scenarios"
MARKER="${KYKLOS_STATE_DIR:-/tmp/kyklos-state}/active-scenario"
PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LINT="$PLUGIN_ROOT/scenario/validate-scenario.sh"

INPUT="$(cat || true)"
[ -d "$SCEN_DIR" ] || exit 0     # opt-in: not a scenario project

tool="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)"
cmd="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"

# Is this a build/test invocation? Detect a raw `dotnet <verb>` via the SHARED command-position detector
# (lib/dotnet-cmd-detect.sh) — the same one the build-execution + zero-failures guards use — so this gate cannot
# drift from them and (the bug this fixes) cannot false-block a `dotnet test` that is only MENTIONED inside a
# heredoc body or a quoted argument. The inline regex here had neither strip, so it over-matched a mention.
. "$(dirname "${BASH_SOURCE[0]}")/lib/dotnet-cmd-detect.sh"
is_bt=0
case "$tool" in
    *KyklosBridge__run_tests|*KyklosBridge__build) is_bt=1 ;;
    Bash) dotnet_cmd_invokes "$cmd" 'test|build|run' && is_bt=1 ;;
esac
[ "$is_bt" -eq 1 ] || exit 0

block() {
    # 3-step JSON escape: backslash, then double-quote, then FLATTEN newlines. The reason embeds a
    # multi-line `ls` of scenario paths; a raw newline would make the emitted JSON invalid and the block
    # would be silently dropped. Matches the other guards' escape.
    local reason="$1"
    reason="${reason//\\/\\\\}"; reason="${reason//\"/\\\"}"; reason="$(printf '%s' "$reason" | tr '\n' ' ')"
    printf '{"decision":"block","reason":"%s"}' "$reason"
    exit 0
}

# Backend-aware record instruction. Under the GITLAB backend the story's requirements.md is a DERIVED mirror that
# kyklos-story-mirror-edit-guard FORBIDS editing, so the gate must NOT tell the agent to hand-edit its 'Scenario:'
# field (a direct contradiction). The active-scenario MARKER (a state file, not a mirror) is the real signal the
# gate reads and is written on BOTH backends; the requirements.md 'Scenario:' field is a secondary, FS-only record.
# PARSE standards.env (never source — CWE-829) to learn the declared backend, exactly as the sibling guards do.
. "$(dirname "${BASH_SOURCE[0]}")/lib/standards-env.sh" 2>/dev/null && load_standards_env "$PROJECT_DIR/.claude/standards.env" 2>/dev/null || true
if [ "${STORY_BACKEND:-local}" = gitlab ]; then
    _scen_record="write its path to ${MARKER} (the active-scenario marker the gate reads)"
else
    _scen_record="write its path to ${MARKER} and record it in the active story's 'Scenario:' field"
fi

scen=""
[ -f "$MARKER" ] && scen="$(cat "$MARKER" 2>/dev/null || true)"

if [ -z "$scen" ] || [ ! -f "$scen" ]; then
    avail="$(ls "$SCEN_DIR"/*-scenario.md 2>/dev/null | sed "s#^#    #" || true)"
    block "SCENARIO GATE: no active working scenario, so multi-SLNX build/test is blocked. Ask the user \"what are we working on today?\", pick one of the scenarios below (or author one WITH them — never invent modules/edges), then ${_scen_record}.$([ -n "$avail" ] && printf ' Available:\n%s' "$avail")"
fi

# Re-lint the active scenario: a fabricated/malformed one must not be honoured just because it is selected.
if ! bash "$LINT" "$scen" "$PROJECT_DIR" >/dev/null 2>&1; then   # invoke via bash: a fresh clone has no +x bit
    block "SCENARIO GATE: the active scenario '$scen' FAILS validation (e.g. a declared .slnx does not exist, a dangling edge, or a cycle). Run: bash '$LINT' '$scen' '$PROJECT_DIR' — fix it or re-select before build/test."
fi

exit 0
