#!/usr/bin/env bash
# kyklos-build-execution-guard.sh (Kyklos) — PreToolUse Bash. Enforces HOW this project builds/tests,
# per the BUILD_EXECUTION knob (values bridge|local, NO default), read by hooks/lib/build-execution.sh: the session's
# environment first (the KyklosLauncher passes the project's setting), then .claude/standards.env.
#
# WHY: some projects MUST build/test on the real host via the KyklosBridge, never locally in the sealed
# Linux dev container — a local `dotnet build`/`test` there does not see the host SDK and outright fails on
# host-only target frameworks (e.g. a *-windows TFM). The agent kept violating that Tier-0 rule, so this
# guard makes the mistake fail EARLY (the moment the local build is attempted) instead of late (a wasted CI
# round trip or a confusing local failure). The knob is INTERVIEWED once (running-tests skill) and persisted.
#
# ENGAGE / BLOCK / ALLOW / FAIL-SAFE matrix:
#   * Engages ONLY when the Bash command invokes a LOCAL .NET build/test:
#       `dotnet build|test|run|msbuild|vstest`, or `dotnet <*.slnx|*.sln|*.csproj>`.
#     It deliberately does NOT match `dotnet tool`, `dotnet nuget`, `dotnet --version`/`--info`, `dotnet new`,
#     etc. — those are not builds. No such invocation in the command => exit 0 (never wedge an unrelated cmd).
#   * BUILD_EXECUTION=bridge  => BLOCK, pointing at mcp__KyklosBridge__{build,run_tests} (builds go through
#     the bridge). EXEMPTION: the mode-aware `record-slnx-green.sh` is allowed — in bridge mode it self-routes
#     to the bridge over HTTP (it does NOT run local dotnet), so it is the sanctioned recorder, not a local build.
#   * BUILD_EXECUTION=local   => ALLOW (exit 0): local dotnet is the declared mode.
#   * BUILD_EXECUTION unset/blank/invalid => BLOCK with the interview message (no default; ENFORCE, not fail-open).
#     That includes a project with no standards.env and no value in the environment (a brand-new project): a
#     missing declaration is "not set", never "local".
#   * FAIL-SAFE: a command that is clearly not a local dotnet build exits 0 — the guard enforces the build channel,
#     it must not brick unrelated commands.
#
# One-shot LOGGED override (consumed on the block path only, mirroring push-ok/slnx-ok/gitflow-ok):
#   bash hooks/lib/override-marker.sh set build-execution-ok <your-working-folder>
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

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
CFG="$PROJECT_DIR/.claude/standards.env"
STATE_DIR="${KYKLOS_STATE_DIR:-/tmp/kyklos-state}"; mkdir -p "$STATE_DIR" 2>/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/override-marker.sh"   # override_take: the scoped, expiring one-shot override
OK_NAME=build-execution-ok
OK_SCOPE_HINT="<your-working-folder>"

INPUT="$(cat || true)"
# Match the ACTUAL command being run, not the whole hook payload. The build channel gates a `dotnet build|test`
# INVOCATION — never a MENTION of the phrase in a description field or inside a quoted argument (a `grep
# 'x|dotnet test|y'` / `echo "dotnet run"` must not be wedged). Extract .tool_input.command via jq; fall back to
# the raw (unescaped) payload only if jq is unavailable (fail-safe — never brick the command).
CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
[ -n "$CMD" ] || CMD="${INPUT//\\\"/\"}"
# ---- Does the command invoke a LOCAL .NET build/test? (precise: never match tool/nuget/--version) ----
# Heredoc-body + quoted-substring stripping and the anchored `dotnet <verb>` match are the SHARED mention-vs-
# invocation detector (lib/dotnet-cmd-detect.sh) — the same one the zero-failures gate uses, so the two guards
# can never drift on what counts as a real invocation. This guard adds ONE guard-specific form on the same
# stripped command: a direct solution/project build `dotnet <file>.slnx|.sln|.csproj` (a full-solution build).
. "$(dirname "${BASH_SOURCE[0]}")/lib/dotnet-cmd-detect.sh"
CMD_MATCH="$(dotnet_cmd_strip "$CMD")"
if ! dotnet_cmd_invokes "$CMD" 'build|test|run|msbuild|vstest' \
   && ! printf '%s' "$CMD_MATCH" | grep -ciE '(^|[^[:alnum:]_./-])dotnet[[:space:]]+[^[:space:]]*\.(slnx|sln|csproj)([[:space:]"'"'"']|$)' >/dev/null; then
    exit 0   # not a local dotnet build => FAIL-SAFE exit 0 (never wedge an unrelated command).
fi

# EXEMPTION: the sanctioned recorder self-routes to the bridge in bridge mode (it does NOT run local dotnet
# there), so allow it even though its own body may contain a local `dotnet build` for the local-mode path.
printf '%s' "$CMD" | grep -cE 'record-slnx-green\.sh' >/dev/null && exit 0

# ---- Read the declared build channel: the session's environment first, then standards.env. ----
# [CySec] Prevents CWE-636 "Not Failing Securely ('Failing Open')": a project that declares no channel anywhere (no
#         value in the environment and no standards.env, as every brand-new project starts) is "not set" and BLOCKS
#         with the interview message, never an allowed local build.
. "$(dirname "${BASH_SOURCE[0]}")/lib/build-execution.sh"
value="$(build_execution_raw "$CFG")"
source_of="$(build_execution_source "$CFG")"
case "$source_of" in
    environment) from="from the session's environment" ;;
    file)        from="from $CFG" ;;
    *)           from="declared nowhere" ;;
esac

block() {
    local reason="$1"
    # One-shot LOGGED override, spent on the block path only so a benign path cannot silently eat it.
    override_take "$OK_NAME" "$(override_hook_scope "$INPUT" "$PROJECT_DIR")" "$INPUT" && { echo "[kyklos] build-execution gate: OVERRIDDEN once ($OK_NAME spent) — a local .NET build/test was allowed despite the BUILD_EXECUTION policy." >&2; exit 0; }
    reason="${reason//\\/\\\\}"; reason="${reason//\"/\\\"}"; reason="$(printf '%s' "$reason" | tr '\n' ' ')"
    printf '{"decision":"block","reason":"%s"}' "$reason"
    exit 0
}

case "$value" in
    local)
        exit 0 ;;   # ALLOW: local dotnet is the declared mode.
    bridge)
        block "Local .NET build/test BLOCKED — this project's BUILD_EXECUTION=bridge: builds and tests run on the real host via the KyklosBridge, never locally in this container (a local 'dotnet build'/'test' does not see the host SDK and fails on host-only target frameworks). Use the MCP tools mcp__KyklosBridge__build / mcp__KyklosBridge__run_tests instead. To record a green full-solution build for a push, run record-slnx-green.sh (it routes to the bridge in this mode). Tool-first norm (GOVERNANCE F10): consult the SessionStart capability catalog before hand-rolling a build/test. For a single deliberate exception: bash $OVERRIDE_MARKER_CLI set $OK_NAME $OK_SCOPE_HINT" ;;
    *)
        # A value that is set but not bridge|local is named with where it came from, never reported as "not set".
        if [ -n "$value" ]; then
            block "BUILD_EXECUTION='$value' ($from) is not one of bridge|local (lower case) — correct it to bridge or local before building (no default). bridge = all builds/tests via the KyklosBridge (mcp__KyklosBridge__build/run_tests); local = local dotnet. A value in the session's environment (from the project's KyklosLauncher configuration) wins over \${CLAUDE_PROJECT_DIR}/.claude/standards.env. For a single deliberate exception: bash $OVERRIDE_MARKER_CLI set $OK_NAME $OK_SCOPE_HINT"
        fi
        if [ "$source_of" = file ] && [ ! -r "$CFG" ]; then
            block "BUILD_EXECUTION cannot be read: $CFG exists but cannot be read, so the declared build channel cannot be told. Fix the file's permissions, or set BUILD_EXECUTION in the project's KyklosLauncher configuration. For a single deliberate exception: bash $OVERRIDE_MARKER_CLI set $OK_NAME $OK_SCOPE_HINT"
        fi
        block "BUILD_EXECUTION is not set — run the running-tests interview and persist bridge|local before building (no default). bridge = all builds/tests via the KyklosBridge (mcp__KyklosBridge__build/run_tests); local = local dotnet. Set it in the project's KyklosLauncher configuration (BUILD_EXECUTION, passed into the session's environment) or persist your answer to \${CLAUDE_PROJECT_DIR}/.claude/standards.env; a value in the environment wins over the file. For a single deliberate exception: bash $OVERRIDE_MARKER_CLI set $OK_NAME $OK_SCOPE_HINT" ;;
esac
