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
# a path that is not one of the repo's solutions, the build fails, or the record cannot be written. Exit 0 means a
# green record of HEAD exists (written now, or kept when a poll failed), and nothing else: an EXIT trap turns any other ending into a non-zero exit.
#
# MODE-AWARE (BUILD_EXECUTION knob, no default; lib/build-execution.sh reads the session's environment first, then
# the workspace root's .claude/standards.env; for a solution in a companion's nested source, <workspace>/Repo, that
# root is the companion root, build_execution_root):
#   local  = today's behaviour: run a local `dotnet build <*.slnx>` and, on green, write the marker.
#   bridge = do NOT run local dotnet (forbidden — the build runs on the real host). Instead call the bridge's
#            `build` verb through lib/bridge-mcp.sh (bridge_mcp_call; it owns the endpoint resolution), and
#            on a SUCCESS result (exitCode==0) write the green marker for HEAD. A failed/unreachable bridge =>
#            write nothing, exit non-zero (the slnx-green guard then blocks, correctly).
#            A build that outlasts the bridge's bounded wait is answered pending=true + jobId; the recorder then collects it
#            with the `get_job_result` verb (same client), at most one call per RECORD_SLNX_GREEN_POLL_SECONDS (default 60),
#            for at most RECORD_SLNX_GREEN_WAIT_SECONDS (default 3600) overall. A poll that fails on a transport error or an
#            empty reply is not a failed build: it is retried within that same overall wait. A poll ANSWERED with an error
#            (a JSON-RPC error, an isError result, an unreadable reply) is not a failed build either: it is retried up to
#            RECORD_SLNX_GREEN_POLL_ERRORS (default 3) times in a row. When the build's result cannot be collected (those
#            retries used up, a client failure on a poll, or the wait ending right after a failed poll), a green record
#            already written for the same commit is kept (exit 0); without one, nothing is recorded and the exit is non-zero,
#            naming the failed poll and the next step (check the job with get_job_result, then re-run). A wait that runs out,
#            a pending reply without a job id, an isError build reply, or any reply without result.exitCode records nothing
#            and exits non-zero with a named reason. The settings are checked BEFORE any arithmetic: the wait and the error
#            bound are whole numbers >= 1, the poll a non-negative number (fractions allowed); anything else is refused. A long build outlasts a foreground tool call
#            (cut at 120-600 s): run the recorder in the background or with the tool's maximum time limit.
#            The marker is written ONLY after an explicit success flag (GREEN) set by the build path, so an error that
#            abandons the build path can never record a build as green.
#   unset  = refuse: exit non-zero telling the caller to set BUILD_EXECUTION first (no default).
# shellcheck source=lib/json-answer.sh
. "$(dirname "${BASH_SOURCE[0]}")/json-escape.sh" 2>/dev/null || true   # kyklos_json_escape: the one escaper for text inside a JSON answer
. "$(dirname "${BASH_SOURCE[0]}")/json-answer.sh"   # json_test / json_read: an empty or cut answer is never valid
set +e -uo pipefail

# Exit status contract: 0 ONLY when a green record of HEAD exists (written, or kept). [CySec] Mitigates CWE-636 "Not Failing Securely": every
# path that ends without a written record exits non-zero, including one that forgot to say so (a future bare `exit 0`,
# an unchecked step), so a caller can never read "nothing recorded" as success.
RECORDED=0
_record_slnx_green_on_exit() {
    local rc=$?
    if [ "$RECORDED" != 1 ] && [ "$rc" -eq 0 ]; then
        echo "record-slnx-green: ended without writing a record; nothing recorded (exit 8)." >&2
        exit 8
    fi
}
trap _record_slnx_green_on_exit EXIT

# shellcheck source=bridge-mcp.sh
. "$(dirname "${BASH_SOURCE[0]}")/bridge-mcp.sh"
# shellcheck source=bridge-build-state.sh
. "$(dirname "${BASH_SOURCE[0]}")/bridge-build-state.sh"   # bridge_tree_args: the folder argument of one solution (shared with the push check)
# shellcheck source=slnx-solutions.sh
. "$(dirname "${BASH_SOURCE[0]}")/slnx-solutions.sh"   # slnx_list/slnx_marker_path: the key the guard reads

# How often a pending bridge build is polled, and how long the recorder waits for it overall (seconds). Overridable
# (the tests shrink them); the defaults keep it to one call per minute for up to an hour.
POLL_SECONDS="${RECORD_SLNX_GREEN_POLL_SECONDS:-60}"
WAIT_SECONDS="${RECORD_SLNX_GREEN_WAIT_SECONDS:-3600}"
# How many error ANSWERS to a poll in a row (a JSON-RPC error, an isError result, an unreadable reply) are retried
# before the recorder stops with the next step named. Transport errors are retried for the whole wait, as before.
POLL_ERRORS="${RECORD_SLNX_GREEN_POLL_ERRORS:-3}"

STATE_DIR="${KYKLOS_STATE_DIR:-/tmp/kyklos-state}"

# shellcheck source=build-execution.sh
. "$(dirname "${BASH_SOURCE[0]}")/build-execution.sh"

# read_build_execution — the BUILD_EXECUTION knob (bridge|local; NO default), read by the shared reader: the session's
# environment first, then $CLAUDE_PROJECT_DIR/.claude/standards.env. Prints the normalised value (or empty when
# unset/blank/invalid).
read_build_execution() { build_execution_mode; }

# _poll_next_step <job> — what the caller does when the build's result could not be collected.
_poll_next_step() {
    printf 'The build may still be green on the host: check it with get_job_result {"jobId":"%s"}, then re-run this recorder.' "$(kyklos_json_escape "$1")"
}

# _poll_error_text <reply> — a short reason from an error answer: the JSON-RPC message, the result's text, or "unreadable reply".
_poll_error_text() {
    local why
    why="$(printf '%s' "$1" | jq -r '.error.message // ([(.result.content // [])[] | select(.type == "text") | .text] | join(" ")) // empty' 2>/dev/null | head -c 300)"
    printf '%s' "${why:-unreadable reply}"
}

# _poll_job <job> — one get_job_result poll. rc 0: a usable reply, in POLL_REPLY; rc 11: a failed poll to retry within
# the overall wait (a transport error or an empty reply, or an error ANSWER - a JSON-RPC error, an isError result, an
# unreadable reply - fewer than POLL_ERRORS times in a row); rc 10: the poll failed for good (POLL_ERRORS error answers
# in a row, or a client failure: no tooling, no endpoint, a wrong bridge identity). A failed poll says nothing about the
# build, so rc 10 names the next step and never reads as a failed build.
_poll_job() {
    local job="$1" prc
    POLL_REPLY="$(bridge_mcp_call get_job_result "$(jq -cn --arg jobId "$job" '{jobId: $jobId}')" 120)"; prc=$?
    if [ "$prc" -eq 0 ] && ! bridge_mcp_is_error "$POLL_REPLY"; then
        POLL_ERRORS_SEEN=0; return 0
    fi
    if [ "$prc" -eq 3 ]; then
        echo "record-slnx-green: get_job_result poll for job $job failed (transport error or empty reply); the build is still running on the host, polling again within the ${WAIT_SECONDS}s wait." >&2
        return 11
    fi
    if [ "$prc" -ne 0 ]; then
        echo "record-slnx-green: get_job_result poll for job $job failed (client error $prc). $(_poll_next_step "$job")" >&2
        return 10
    fi
    POLL_ERRORS_SEEN=$((POLL_ERRORS_SEEN + 1))
    echo "record-slnx-green: get_job_result poll for job $job answered an error ($(_poll_error_text "$POLL_REPLY")); attempt $POLL_ERRORS_SEEN of $POLL_ERRORS." >&2
    [ "$POLL_ERRORS_SEEN" -lt "$POLL_ERRORS" ] && return 11
    echo "record-slnx-green: get_job_result poll for job $job failed $POLL_ERRORS_SEEN times in a row; the build's result is unknown. $(_poll_next_step "$job")" >&2
    return 10
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
    [[ "$POLL_ERRORS" =~ ^[1-9][0-9]*$ ]] || { echo "record-slnx-green: RECORD_SLNX_GREEN_POLL_ERRORS='$POLL_ERRORS' is not a whole number >= 1; nothing recorded." >&2; return 2; }
    local deadline=$((SECONDS + WAIT_SECONDS)) job _failed_poll=0 _prc
    POLL_ERRORS_SEEN=0
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
            echo "record-slnx-green: host build (job $job) still not finished after ${WAIT_SECONDS}s (RECORD_SLNX_GREEN_WAIT_SECONDS); nothing recorded. $(_poll_next_step "$job")" >&2
            # Ended right after a failed poll: the build's result is unknown (10), so a green record of HEAD is kept.
            [ "$_failed_poll" = 1 ] && return 10
            return 4
        fi
        # After a failed poll the pause is at least 1 s, whatever the poll setting, so a bridge that fails at once is
        # not asked in a tight loop until the deadline.
        local nap="$POLL_SECONDS"
        if [ "$_failed_poll" = 1 ] && ! [[ "$POLL_SECONDS" =~ ^0*[1-9][0-9]*(\.[0-9]+)?$ ]]; then nap=1; fi
        echo "record-slnx-green: host build (job $job) still running; polling again in ${nap}s..." >&2
        sleep "$nap" || { echo "record-slnx-green: waiting between polls failed (RECORD_SLNX_GREEN_POLL_SECONDS='$POLL_SECONDS'); nothing recorded." >&2; return 4; }
        # A failed POLL is not a failed build: the job keeps running on the host (_poll_job decides retry or stop).
        _poll_job "$job"; _prc=$?
        case "$_prc" in
            0) resp="$POLL_REPLY"; _failed_poll=0 ;;
            11) _failed_poll=1 ;;
            *) return "$_prc" ;;
        esac
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

# The workspace root that owns this solution's settings (.claude/standards.env) and bridge connection (.mcp.json): the
# session's project folder when set, else the working folder, kept as they are, except that a companion's nested
# source (<workspace>/Repo, which holds no .claude/ by design; with the project folder unset, also the solution's own
# repository) resolves UP to the companion root (build_execution_root). Exported so the channel reader, the bridge
# client and the bridge `tree` all start from the same root, whatever folder the recorder was started from.
CLAUDE_PROJECT_DIR="$(build_execution_root "$TOP")"; export CLAUDE_PROJECT_DIR

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
    if [ "$_brc" -eq 10 ]; then
        # The build's result could not be collected (its poll failed): a green record already written for this very
        # commit stays valid and is kept; without one, nothing is recorded and the exit is non-zero.
        _kept="$(slnx_marker_path "$STATE_DIR" "$TOP" "$SOL_REL")"
        if [ -f "$_kept" ] && [ "$(head -n1 "$_kept" 2>/dev/null)" = "$HEAD_SHA" ]; then
            RECORDED=1
            echo "record-slnx-green: the green record already written for HEAD $HEAD_SHA is kept ($_kept); nothing new recorded." >&2
            exit 0
        fi
        echo "record-slnx-green: nothing recorded (no earlier green record of HEAD $HEAD_SHA to keep)." >&2
        exit 3
    fi
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
if ! printf '%s\ntimestamp=%s\nrepo=%s\nsolution=%s\n' "$HEAD_SHA" "$STAMP" "$TOP" "$SOLUTION" > "$MARKER" 2>/dev/null \
   || [ "$(head -n1 "$MARKER" 2>/dev/null)" != "$HEAD_SHA" ]; then
    echo "record-slnx-green: the build was green, but the record '$MARKER' could not be written (KYKLOS_STATE_DIR='$STATE_DIR'); nothing recorded. Fix the folder and re-run." >&2
    exit 8
fi
RECORDED=1

echo "record-slnx-green: GREEN full-solution build of '$SOL_REL' recorded for HEAD $HEAD_SHA -> $MARKER" >&2
exit 0
