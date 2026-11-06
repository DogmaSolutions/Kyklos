#!/usr/bin/env bash
# record-slnx-green.sh (Kyklos) — the ONLY sanctioned way to record a GREEN full-solution (.slnx) build.
#
# WHY this exists: a single-project `dotnet test`/`dotnet build <one.csproj>` does NOT evaluate the StyleCop
# SOLUTION-ruleset rules (SA1117 et al.) — those fire only in a FULL-solution `dotnet build <*.slnx>` where
# SolutionDir is set. So an agent can pass every local single-project check and STILL fail the CI `build`. The
# kyklos-slnx-green-guard blocks pushing a feature/hotfix branch whose HEAD has no recorded green .slnx build;
# THIS script is what produces that record — it runs the same full-solution build the CI runs, and ONLY on a
# green result writes a marker naming the exact commit it proved.
#
# Usage:  record-slnx-green.sh [<repo-dir>]                (a repo holding exactly ONE *.slnx; default: the cwd's repo)
#         record-slnx-green.sh <path/to/Solution.slnx>     (one solution of a repo that holds several)
#
# On success (dotnet build of that *.slnx exits 0) it writes ONE record for THAT solution:
#     ${KYKLOS_STATE_DIR:-/tmp/kyklos-state}/slnx-green-<repo-key>-<solution-key>
# containing the repo's current `git rev-parse HEAD` and a UTC timestamp. The keys are stable hashes of the repo
# TOPLEVEL path and of the solution path inside it (lib/slnx-solutions.sh, shared with the guard), so repos never
# collide and two solutions of one repo never overwrite or satisfy each other's record. A later commit moves HEAD,
# the record no longer matches, and the guard blocks again — exactly the intended staleness behaviour.
#
# Exits NON-ZERO (and writes nothing) when it cannot prove a green full-solution build: no *.slnx in the repo,
# `dotnet` absent, not a git repo / HEAD unresolvable, a repo folder holding several *.slnx (name the solution),
# a path that is not one of the repo's solutions, or the build fails.
#
# MODE-AWARE (BUILD_EXECUTION knob, read from $CLAUDE_PROJECT_DIR/.claude/standards.env — no default):
#   local  = today's behaviour: run a local `dotnet build <*.slnx>` and, on green, write the marker.
#   bridge = do NOT run local dotnet (forbidden — the build runs on the real host). Instead call the bridge's
#            `build` verb through lib/bridge-mcp.sh (bridge_mcp_call; it owns the endpoint resolution), and
#            on a SUCCESS result (exitCode==0) write the green marker for HEAD. A failed/unreachable bridge =>
#            write nothing, exit non-zero (the slnx-green guard then blocks, correctly).
#            A build that outlasts the bridge's bounded wait is answered pending=true + jobId; the recorder then collects it
#            with the `get_job_result` verb (same client), at most one call per RECORD_SLNX_GREEN_POLL_SECONDS (default 60),
#            for at most RECORD_SLNX_GREEN_WAIT_SECONDS (default 3600) overall. A wait that runs out, a pending reply without
#            a job id, an isError reply, or any reply without result.exitCode records nothing and exits non-zero with a named
#            reason. The two settings are checked BEFORE any arithmetic: the wait is a whole number >= 1, the poll a
#            non-negative number (fractions allowed); anything else is refused. A long build outlasts a foreground tool call
#            (cut at 120-600 s): run the recorder in the background or with the tool's maximum time limit.
#            The marker is written ONLY after an explicit success flag (GREEN) set by the build path, so an error that
#            abandons the build path can never record a build as green.
#   unset  = refuse: exit non-zero telling the caller to set BUILD_EXECUTION first (no default).
# shellcheck source=lib/json-answer.sh
. "$(dirname "${BASH_SOURCE[0]}")/json-answer.sh"   # json_test / json_read: an empty or cut answer is never valid
set +e -uo pipefail

# shellcheck source=bridge-mcp.sh
. "$(dirname "${BASH_SOURCE[0]}")/bridge-mcp.sh"
# shellcheck source=slnx-solutions.sh
. "$(dirname "${BASH_SOURCE[0]}")/slnx-solutions.sh"   # slnx_list/slnx_marker_path: the key the guard reads

# How often a pending bridge build is polled, and how long the recorder waits for it overall (seconds). Overridable
# (the tests shrink them); the defaults keep it to one call per minute for up to an hour.
POLL_SECONDS="${RECORD_SLNX_GREEN_POLL_SECONDS:-60}"
WAIT_SECONDS="${RECORD_SLNX_GREEN_WAIT_SECONDS:-3600}"

STATE_DIR="${KYKLOS_STATE_DIR:-/tmp/kyklos-state}"

# read_build_execution — the interviewed BUILD_EXECUTION knob (bridge|local; NO default), from
# $CLAUDE_PROJECT_DIR/.claude/standards.env. Prints the normalised value (or empty when unset/blank/invalid).
read_build_execution() {
    local dir="${CLAUDE_PROJECT_DIR:-$(pwd)}" cfg v
    cfg="$dir/.claude/standards.env"
    [ -f "$cfg" ] || return 0
    v="$(grep -E "^[[:space:]]*BUILD_EXECUTION=" "$cfg" 2>/dev/null | grep -vE "^[[:space:]]*#" | tail -1 | sed -E 's/^[[:space:]]*BUILD_EXECUTION=//')"
    v="${v%%#*}"
    v="$(printf '%s' "$v" | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//')"
    case "$v" in bridge|local) printf '%s' "$v" ;; *) return 0 ;; esac
}

# bridge_build <arguments-json> — run the full-solution build ON THE HOST via the KyklosBridge, NOT local dotnet.
# Calls the bridge's `build` verb through lib/bridge-mcp.sh (the same tools/call mcp__KyklosBridge__build issues)
# and returns 0 iff the bridge reports a
# green build (result.exitCode == 0). Any missing tooling / unresolvable endpoint / transport error / non-zero
# build exit => return non-zero (nothing recorded; the slnx-green guard then blocks, correctly).
# <arguments-json> is the `build` tool's arguments: `{}` builds the bridge's configured solution; `{"tree":...}`
# builds the solution in that folder (the way one solution of a multi-solution repo is addressed).
bridge_build() {
    local args="${1:-}"
    [ -n "$args" ] || args='{}'
    command -v curl >/dev/null 2>&1 || { echo "record-slnx-green: BUILD_EXECUTION=bridge but 'curl' is absent — cannot reach the bridge; nothing recorded." >&2; return 2; }
    command -v jq   >/dev/null 2>&1 || { echo "record-slnx-green: BUILD_EXECUTION=bridge but 'jq' is absent — cannot parse .mcp.json / the bridge reply; nothing recorded." >&2; return 2; }

    local mcp endpoint
    mcp="$(bridge_mcp_json_path)"
    [ -f "$mcp" ] || { echo "record-slnx-green: BUILD_EXECUTION=bridge but no .mcp.json at '$mcp' — cannot resolve the bridge endpoint; nothing recorded." >&2; return 2; }
    endpoint="$(bridge_mcp_endpoint)" || { echo "record-slnx-green: BUILD_EXECUTION=bridge but no KyklosBridge http(s)://.../mcp endpoint in '$mcp'; nothing recorded." >&2; return 2; }

    echo "record-slnx-green: BUILD_EXECUTION=bridge — building on the host via the KyklosBridge ($endpoint)..." >&2
    local resp
    resp="$(bridge_mcp_call build "$args" 1800)" || {
        echo "record-slnx-green: bridge request failed (transport error or empty reply); nothing recorded." >&2; return 3; }

    # A build longer than the bridge's bounded wait is answered pending=true + jobId: collect it with get_job_result.
    # [CySec] Mitigates CWE-20 / CWE-95: the env values reach shell arithmetic only after a strict numeric check, so an
    # odd value is refused instead of aborting the build path or being evaluated.
    [[ "$WAIT_SECONDS" =~ ^[1-9][0-9]*$ ]] || { echo "record-slnx-green: RECORD_SLNX_GREEN_WAIT_SECONDS='$WAIT_SECONDS' is not a whole number of seconds >= 1; nothing recorded." >&2; return 2; }
    [[ "$POLL_SECONDS" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "record-slnx-green: RECORD_SLNX_GREEN_POLL_SECONDS='$POLL_SECONDS' is not a non-negative number of seconds; nothing recorded." >&2; return 2; }
    local deadline=$((SECONDS + WAIT_SECONDS)) job
    while :; do
        # A JSON-RPC error envelope (e.g. -32001 unauthorized) => not a green build.
        if ! printf '%s' "$resp" | json_test '.error | not'; then
            echo "record-slnx-green: bridge returned an error: $(printf '%s' "$resp" | jq -r '.error.message // "unknown"'); nothing recorded." >&2
            return 3
        fi
        printf '%s' "$resp" | json_test '.result.pending == true' || break
        job="$(printf '%s' "$resp" | jq -r '.result.jobId // empty' 2>/dev/null)"
        [ -n "$job" ] || { echo "record-slnx-green: bridge answered pending without a jobId; nothing recorded." >&2; return 3; }
        if [ "$SECONDS" -ge "$deadline" ]; then
            echo "record-slnx-green: host build (job $job) still not finished after ${WAIT_SECONDS}s (RECORD_SLNX_GREEN_WAIT_SECONDS); nothing recorded. Collect it with get_job_result and re-run." >&2
            return 4
        fi
        echo "record-slnx-green: host build (job $job) still running; polling again in ${POLL_SECONDS}s..." >&2
        sleep "$POLL_SECONDS" || { echo "record-slnx-green: waiting between polls failed (RECORD_SLNX_GREEN_POLL_SECONDS='$POLL_SECONDS'); nothing recorded." >&2; return 4; }
        resp="$(bridge_mcp_call get_job_result "$(jq -cn --arg jobId "$job" '{jobId: $jobId}')" 120)" || {
            echo "record-slnx-green: get_job_result request for job $job failed (transport error or empty reply); nothing recorded." >&2; return 3; }
    done
    if bridge_mcp_is_error "$resp"; then
        echo "record-slnx-green: bridge reply is an error result (isError); nothing recorded." >&2; return 3
    fi
    # SUCCESS detection mirrors mcp__KyklosBridge__build's result shape: result.exitCode == 0.
    local bexit
    bexit="$(printf '%s' "$resp" | jq -r '.result.exitCode // empty' 2>/dev/null)"
    [ -n "$bexit" ] || { echo "record-slnx-green: bridge reply missing result.exitCode; nothing recorded." >&2; return 3; }
    if [ "$bexit" != "0" ]; then
        echo "record-slnx-green: host build via the bridge FAILED (exitCode=$bexit) — nothing recorded. Fix the build (incl. solution-ruleset StyleCop rules like SA1117) then re-run." >&2
        return 1
    fi
    return 0
}

# bridge_tree_args <solution-abs> — the bridge `build` arguments that address that solution's folder, relative to the
# project dir the bridge serves. Fails (rc 2, nothing printed) when the solution lies outside it: the bridge could
# not reach it, and building its default solution instead would record a build of the WRONG solution.
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

ARG="${1:-.}"
SOL_ARG=""
case "$ARG" in
    *.slnx)
        [ -f "$ARG" ] || { echo "record-slnx-green: '$ARG' is not a solution file; nothing recorded." >&2; exit 3; }
        SOL_ARG="$(cd "$(dirname "$ARG")" && pwd -P)/$(basename "$ARG")"
        REPO_ARG="${SOL_ARG%/*}" ;;
    *) REPO_ARG="$ARG" ;;
esac

command -v git >/dev/null 2>&1 || { echo "record-slnx-green: git not found on PATH; nothing recorded." >&2; exit 3; }

TOP="$(git -C "$REPO_ARG" rev-parse --show-toplevel 2>/dev/null || echo "")"
[ -n "$TOP" ] || { echo "record-slnx-green: '$REPO_ARG' is not inside a git repository; nothing recorded." >&2; exit 3; }

HEAD_SHA="$(git -C "$TOP" rev-parse HEAD 2>/dev/null || echo "")"
[ -n "$HEAD_SHA" ] || { echo "record-slnx-green: cannot resolve HEAD in '$TOP'; nothing recorded." >&2; exit 3; }

# The interviewed build channel drives HOW we prove the green build. No default: refuse when unset.
MODE="$(read_build_execution)"
[ -n "$MODE" ] || { echo "record-slnx-green: BUILD_EXECUTION is not set (bridge|local) — set it first (run the running-tests interview); nothing recorded." >&2; exit 7; }

# local mode needs a local SDK; bridge mode must NOT touch local dotnet (the build runs on the host).
if [ "$MODE" = "local" ]; then
    command -v dotnet >/dev/null 2>&1 || { echo "record-slnx-green: 'dotnet' not found on PATH — cannot run the full-solution build; nothing recorded." >&2; exit 4; }
fi

# The repo's solutions (VCS/build output folders excluded). Zero => nothing to record. A repo folder holding
# several => the caller must name the one it built (never guess); a named solution must be one of the repo's.
mapfile -t SLNX < <(slnx_list "$TOP")
if [ "${#SLNX[@]}" -eq 0 ]; then
    echo "record-slnx-green: no *.slnx solution found under '$TOP'; nothing recorded (this repo has no full-solution build to gate)." >&2
    exit 5
fi
if [ -n "$SOL_ARG" ]; then
    SOL_REL="${SOL_ARG#"$TOP"/}"
    _known=0; for _s in "${SLNX[@]}"; do [ "$_s" = "$SOL_REL" ] && _known=1; done
    [ "$_known" -eq 1 ] || {
        echo "record-slnx-green: '$SOL_ARG' is not one of the solutions of '$TOP'; nothing recorded. Its solutions:" >&2
        printf '  %s\n' "${SLNX[@]}" >&2
        exit 5
    }
elif [ "${#SLNX[@]}" -gt 1 ]; then
    echo "record-slnx-green: '$TOP' holds ${#SLNX[@]} solutions — name the one to build and record:" >&2
    for _s in "${SLNX[@]}"; do printf '  bash %s %s\n' "${BASH_SOURCE[0]}" "$TOP/$_s" >&2; done
    echo "record-slnx-green: nothing recorded." >&2
    exit 6
else
    SOL_REL="${SLNX[0]}"
fi
SOLUTION="$TOP/$SOL_REL"

if [ "$MODE" = "bridge" ]; then
    # bridge mode: the host builds the solution; do NOT run local dotnet here. A one-solution repo keeps the bridge's
    # own solution resolution; in a multi-solution repo the solution's folder is named so the bridge builds THAT one.
    KYKLOS_BRIDGE_ARGS='{}'
    if [ "${#SLNX[@]}" -gt 1 ]; then
        KYKLOS_BRIDGE_ARGS="$(bridge_tree_args "$SOLUTION")" || {
            echo "record-slnx-green: BUILD_EXECUTION=bridge but '$SOLUTION' is outside the project folder the bridge serves (${CLAUDE_PROJECT_DIR:-$(pwd)}) — it cannot be built there; nothing recorded." >&2
            exit 2
        }
    fi
    bridge_build "$KYKLOS_BRIDGE_ARGS"; _brc=$?
    [ "$_brc" -eq 0 ] || exit "$_brc"
    GREEN=1
else
    echo "record-slnx-green: building full solution '$SOLUTION' (the same build CI's 'build' job runs)..." >&2
    if ! dotnet build "$SOLUTION"; then
        echo "record-slnx-green: full-solution build FAILED — nothing recorded. Fix the build (incl. solution-ruleset StyleCop rules like SA1117) then re-run." >&2
        exit 1
    fi
    GREEN=1
fi

# Structural guard: only a build path that explicitly reported success reaches the marker write.
[ "${GREEN:-0}" = "1" ] || { echo "record-slnx-green: the build path ended without reporting a green build; nothing recorded." >&2; exit 9; }
mkdir -p "$STATE_DIR" 2>/dev/null
MARKER="$(slnx_marker_path "$STATE_DIR" "$TOP" "$SOL_REL")"
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
printf '%s\ntimestamp=%s\nrepo=%s\nsolution=%s\n' "$HEAD_SHA" "$STAMP" "$TOP" "$SOLUTION" > "$MARKER"

echo "record-slnx-green: GREEN full-solution build of '$SOL_REL' recorded for HEAD $HEAD_SHA -> $MARKER" >&2
exit 0
