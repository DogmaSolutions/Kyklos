#!/usr/bin/env bash
# kyklos-mutation-timing.sh (Kyklos) -- advisory only: tells an agent that starts a mutation run whether the run is
# required or due. Whether it is (including the suspension switch) is decided by mutation-due.sh (below); the policy
# itself is the mutation section of the managed policy and the measuring-test-coverage skill.
#
#   before (PreToolUse on Bash and on the bridge get_mutation): when an agent starts a mutation run (the bridge
#          get_mutation, or `dotnet stryker` / `dotnet-stryker` in Bash) that is not required (no security-sensitive
#          code changed: the run is optional), or whose last recorded run already measured exactly the branch's
#          current source, tell it so and why (hookSpecificOutput.additionalContext).
#          Also, for a Bash Stryker run that names no --mutation-level, says that development runs use the lowest
#          level (Basic). Silent when the run is due and names a level, or anything is uncertain. Never blocks.
#   after  (PostToolUse on Bash and on the bridge get_mutation / get_job_result): record what a SUCCESSFUL run
#          measured -- a Bash Stryker run whose output carries Stryker's final score line, or a bridge result with
#          kind=mutation and produced=true. A failed or not-produced run is never recorded.
#
# Due-ness is decided in ONE place: skills/measuring-test-coverage/mutation-due.sh. Default on; the only off
# switch is KYKLOS_MUTATION_TIMING=off. Any parse error -> silent exit 0 (an advisory must never stop work).
set +e -uo pipefail

# shellcheck source=lib/control-switch.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/control-switch.sh" 2>/dev/null || true   # kyklos_control_off: the one control-switch reader
kyklos_control_off "${KYKLOS_MUTATION_TIMING:-}" && exit 0
command -v jq >/dev/null 2>&1 || exit 0

MODE="${1:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DUE="$HERE/../skills/measuring-test-coverage/mutation-due.sh"
[ -f "$DUE" ] || exit 0

INPUT="$(cat 2>/dev/null || true)"
[ -n "$INPUT" ] || exit 0

tool="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)"
cwd="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"
[ -n "$cwd" ] || cwd="${CLAUDE_PROJECT_DIR:-$PWD}"

# The directory a mutation run measures: for a Bash command that starts with `cd <dir> &&` / `cd <dir>;`, that dir
# (relative to cwd); otherwise cwd. For the bridge, the named `tree` when given, else the project root.
# The scope is the one project the run mutates: the bridge `filter`, or Stryker's --project / -p; empty when none.
run_dir=""
scope=""
case "$tool" in
    Bash)
        cmd="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
        # A Stryker invocation at a command position (start, or after ; & | ( ), not a word inside a longer text.
        printf '%s' "$cmd" | grep -cE '(^|[;&|(]\s*)(dotnet\s+stryker|dotnet-stryker)(\s|$)' >/dev/null || exit 0
        run_dir="$cwd"
        _cd="$(printf '%s' "$cmd" | sed -nE 's/^\s*cd\s+([^;&| ]+)\s*(&&|;).*/\1/p' | head -1)"
        if [ -n "$_cd" ]; then
            case "$_cd" in /*) run_dir="$_cd" ;; *) run_dir="$cwd/$_cd" ;; esac
        fi
        scope="$(printf '%s' "$cmd" | sed -nE 's/.*\s(--project|-p)(\s+|=)([^;&| ]+).*/\3/p' | head -1)"
        ;;
    mcp__KyklosBridge__get_mutation|mcp__KyklosBridge__get_job_result)
        _tree="$(printf '%s' "$INPUT" | jq -r '.tool_input.tree // empty | tostring' 2>/dev/null || true)"
        run_dir="${_tree:-${CLAUDE_PROJECT_DIR:-$cwd}}"
        scope="$(printf '%s' "$INPUT" | jq -r '.tool_input.filter // empty | tostring' 2>/dev/null || true)"
        ;;
    *) exit 0 ;;
esac
[ -d "$run_dir" ] || exit 0

case "$MODE" in
    before)
        # get_job_result is a collection, not a new run: never advise on it.
        [ "$tool" = "mcp__KyklosBridge__get_job_result" ] && exit 0
        msg=""
        verdict="$(bash "$DUE" check "$run_dir" "$scope" 2>/dev/null)"; rc=$?
        if [ "$rc" -eq 1 ]; then          # DUE (0) or error (2): no timing advice, the run proceeds
            case "$verdict" in
                "NOT REQUIRED:"*)
                    msg="[kyklos] Mutation run not required. ${verdict#NOT REQUIRED: } (Policy: the measuring-test-coverage skill.)" ;;
                *)
                    msg="[kyklos] Mutation run not due. ${verdict#NOT DUE: } (When a run is due: the measuring-test-coverage skill.)" ;;
            esac
        fi
        # A local Stryker run that names no level runs at Stryker's own default (Standard); development runs use the
        # lowest level unless a higher one is asked for (the bridge get_mutation already defaults to it).
        if [ "$tool" = "Bash" ] && ! printf '%s' "$cmd" | grep -cE '(\s)(--mutation-level|-l)(\s|=)' >/dev/null; then
            msg="${msg:+$msg }[kyklos] This Stryker run names no --mutation-level, so Stryker would use Standard. Development runs use the lowest level: add --mutation-level Basic (a bridge get_mutation run uses the bridge's KYKLOS_BRIDGE_MUTATION_LEVEL instead)."
        fi
        [ -n "$msg" ] || exit 0
        msg="$msg KYKLOS_MUTATION_TIMING=off silences this advice."
        jq -cn --arg c "$msg" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$c}}'
        exit 0
        ;;
    after)
        jobs_dir="${KYKLOS_STATE_DIR:-/tmp/kyklos-state}/mutation-ledger/jobs"
        # A bridge run that answers pending is collected later by get_job_result, whose input names only the job:
        # remember the run's tree and scope under its job id now, and use them when the result arrives.
        if [ "$tool" = "mcp__KyklosBridge__get_mutation" ]; then
            _job="$(printf '%s' "$INPUT" | grep -oE '\\?"jobId\\?"\s*:\s*\\?"[A-Za-z0-9]+' | grep -oE '[A-Za-z0-9]+$' | head -1)"
            if [ -n "$_job" ] && printf '%s' "$INPUT" | grep -cE '\\?"pending\\?"\s*:\s*true' >/dev/null; then
                mkdir -p "$jobs_dir" && printf '%s\n%s\n' "$run_dir" "$scope" > "$jobs_dir/$_job"
                exit 0
            fi
        elif [ "$tool" = "mcp__KyklosBridge__get_job_result" ]; then
            _job="$(printf '%s' "$INPUT" | jq -r '.tool_input.jobId // empty | tostring' 2>/dev/null || true)"
            case "$_job" in ''|*[!A-Za-z0-9]*) exit 0 ;; esac   # an unknown or odd id: the run cannot be attributed
            [ -f "$jobs_dir/$_job" ] || exit 0                    # not a mutation run this hook saw start
            run_dir="$(sed -n 1p "$jobs_dir/$_job")"; scope="$(sed -n 2p "$jobs_dir/$_job")"
            printf '%s' "$INPUT" | grep -cE '\\?"pending\\?"\s*:\s*true' >/dev/null && exit 0   # still running: keep the note
            rm -f "$jobs_dir/$_job"
        fi
        ok=0
        case "$tool" in
            Bash)
                printf '%s' "$INPUT" | grep -ciE 'final mutation score is\s*[0-9]' >/dev/null && ok=1 ;;
            *)
                printf '%s' "$INPUT" | grep -cE '\\?"kind\\?"\s*:\s*\\?"mutation\\?"' \
 >/dev/null                    && printf '%s' "$INPUT" | grep -cE '\\?"produced\\?"\s*:\s*true' >/dev/null && ok=1 ;;
        esac
        [ "$ok" -eq 1 ] || exit 0
        bash "$DUE" record "$run_dir" "$scope" >/dev/null 2>&1 || true
        exit 0
        ;;
    *) exit 0 ;;
esac
