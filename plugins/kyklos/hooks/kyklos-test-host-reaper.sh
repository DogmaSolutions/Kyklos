#!/usr/bin/env bash
# kyklos-test-host-reaper.sh (Kyklos) - Stop. At every end of turn, ends by process id the test hosts in this container
# that have run longer than the limit, and reports each one with its command and its starter.
#
# Why: the bounded test-run guard refuses a test run started without a time limit, but a run can still escape it (the
# guard switched off, a run started by a tool rather than a shell command). Three such runs once hung for about 20
# hours at 98 % CPU each and slowed every agent on the machine. This reaper is the backstop behind the guard.
#
# Test hosts (lib/run-bound.sh, test_runner_kind, kind "host"): dotnet test / vstest, the .NET test host
# (testhost), vstest.console, npm test, vitest, pytest, Pester, bun test, cargo test and go test. A test host with a
# `timeout <duration>` ancestor of at most 2 hours, younger than that duration, is bounded by it and left alone: only
# unbounded test hosts are ended (a longer or spent timeout is no bound). Shell batteries are not test hosts and are never
# ended here. Only this user's processes are read (from /proc); a process that is not a test host is
# never touched, whatever its age. A reaped host's descendants (the processes its run started) end with it.
# The process list is one snapshot read from /proc (parent, state, start time, command line per process).
#
# How a host is ended: TERM by its process id, then KILL for one still running after a short grace. Before each signal
# its start time is compared with the snapshot's, so a reused id is never hit; a zombie counts as gone. The report
# goes to the session as a system message and to stderr.
#
# Settings: KYKLOS_TEST_RUN_LIMIT ("<n>s", "<n>m" or "<n>h"; default 60m), the same limit the guard proposes.
# Default ON. The only off switch: KYKLOS_TEST_HOST_REAPER=off (environment or .claude/standards.env).
# Test seam: KYKLOS_TEST_HOST_REAPER_ROOT_PID limits the reaper to the descendants of one process, so a test never
# reaches a real run on the same machine; KYKLOS_TEST_HOST_REAPER_STALE_PIDS makes the listed ids look reused since the
# snapshot. Both act only in a sealed test shell (lib/seal-rule.sh, kyklos_test_seam); elsewhere they are ignored, said
# on stderr, so a value left in a live session can never narrow or skew what the reaper ends. Wired: Stop.
set +e -uo pipefail

_TR_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_TR_HERE/lib/run-bound.sh"
. "$_TR_HERE/lib/standards-env.sh"
. "$_TR_HERE/lib/seal-rule.sh"   # kyklos_test_seam: test-only settings act only in a sealed test shell
# shellcheck source=lib/control-switch.sh
. "$_TR_HERE/lib/control-switch.sh" 2>/dev/null || true   # kyklos_control_off: the one control-switch reader

INPUT="$(cat || true)"
HOOK_CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-${HOOK_CWD:-$PWD}}"
CFG="$PROJECT_DIR/.claude/standards.env"

_setting() { local v="${!1:-}"; [ -n "$v" ] || v="$(standards_env_value "$CFG" "$1" 2>/dev/null)"; printf '%s' "$v"; }
log() { printf '[kyklos] test-host reaper: %s\n' "$1" >&2; }

# [RiskMitigation RA-02] Default on (CWE-1188, insecure default); the only off switch is explicit.
kyklos_control_off "$(_setting KYKLOS_TEST_HOST_REAPER)" && exit 0
declare -F test_runner_kind >/dev/null || { log "its library hooks/lib/run-bound.sh did not load (broken install): test hosts are NOT checked this turn"; exit 0; }

_limit="$(_setting KYKLOS_TEST_RUN_LIMIT)"
if ! _limit_s="$(test_run_limit_parse "$_limit")"; then
    [ -n "$_limit" ] && log "KYKLOS_TEST_RUN_LIMIT='$_limit' is not <n>s, <n>m or <n>h: using $TRB_DEFAULT_LIMIT"
    _limit="$TRB_DEFAULT_LIMIT"; _limit_s="$(test_run_limit_parse "$_limit")"
fi

root="$(kyklos_test_seam "test-host reaper" KYKLOS_TEST_HOST_REAPER_ROOT_PID)"

# One snapshot of this user's processes, read from /proc: for each, its parent, state, start time (clock ticks since
# boot) and command line. The start time read here is the identity every later signal is checked against, so an id
# the system gave to another process after this read is never signalled.
[ -r /proc/uptime ] || { log "the process table (/proc) cannot be read: test hosts are NOT checked this turn"; exit 0; }
_hz="$(getconf CLK_TCK 2>/dev/null)"; [[ "$_hz" =~ ^[1-9][0-9]*$ ]] || _hz=100
declare -A PARENT=() AGE=() ARGS=() STATE=() TICKS=()
# _proc_stat <pid> -> "<state> <ppid> <start ticks>" from /proc/<pid>/stat (the command name may hold blanks and
# parentheses, so the fields are read after its last ")").
_proc_stat() {
    local s; s="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
    s="${s##*) }"; read -r -a f <<< "$s"
    printf '%s %s %s' "${f[0]}" "${f[1]}" "${f[19]}"
}
read -r _up _ < /proc/uptime; _up_ticks=$(( ${_up%%.*} * _hz + 10#${_up#*.} * _hz / 100 ))
for _d in /proc/[0-9]*; do
    [ -O "$_d" ] || continue
    pid="${_d#/proc/}"
    read -r _st _pp _tk <<< "$(_proc_stat "$pid")" || continue
    [[ "$_tk" =~ ^[0-9]+$ ]] || continue
    PARENT[$pid]="$_pp"; STATE[$pid]="$_st"; TICKS[$pid]="$_tk"
    AGE[$pid]=$(( (_up_ticks - _tk) / _hz ))
    ARGS[$pid]="$(tr '\0' ' ' < "$_d/cmdline" 2>/dev/null)"; ARGS[$pid]="${ARGS[$pid]% }"
done
# Test seam: pretend these ids were recorded with another start time (their id now belongs to another process).
for pid in $(kyklos_test_seam "test-host reaper" KYKLOS_TEST_HOST_REAPER_STALE_PIDS); do [ -n "${TICKS[$pid]:-}" ] && TICKS[$pid]=$(( TICKS[$pid] + 1 )); done

# _descends <pid> <ancestor> -> rc 0 when <ancestor> is <pid> or one of its ancestors in the snapshot.
_descends() {
    local p="$1" hops=0
    while [ -n "$p" ] && [ "$p" != 0 ] && [ "$hops" -lt 200 ]; do
        [ "$p" = "$2" ] && return 0
        p="${PARENT[$p]:-}"; hops=$((hops + 1))
    done
    return 1
}
# _same <pid> -> rc 0 when the process is still the one of the snapshot (same start time) and still running: a zombie
# (state Z or X) has ended and only waits for its parent to collect it.
_same() {
    local st tk
    read -r st _ tk <<< "$(_proc_stat "$1")" || return 1
    [ "$tk" = "${TICKS[$1]}" ] && [[ "$st" != [ZX] ]]
}

# _bounded <pid> -> rc 0 when an ancestor of the process is `timeout <duration>` that still bounds it: the duration is at
# most TRB_BOUND_CEILING_SECONDS (2 hours) and the host is younger than it, so the run ends at its own limit and the
# reaper leaves it alone. A longer timeout, or one already spent without ending the host, is no bound (owner decisions
# on the reaper's scope: only unbounded hosts are ended; a bound is a timeout of at most 2 hours still running).
_bounded() {
    local p="${PARENT[$1]:-}" hops=0 words
    # With the test seam set, the ancestors above its root are outside the reaper's scope and are not read.
    while [ -n "$p" ] && [ "$p" != 0 ] && [ "$p" != "$root" ] && [ "$hops" -lt 200 ]; do
        read -r -a words <<< "${ARGS[$p]:-}"
        if test_run_timeout_bounds "${words[@]}" && [ "$TRB_TIMEOUT_SECONDS" -le "$TRB_BOUND_CEILING_SECONDS" ] \
            && [ "${AGE[$1]:-0}" -lt "$TRB_TIMEOUT_SECONDS" ]; then
            return 0
        fi
        p="${PARENT[$p]:-}"; hops=$((hops + 1))
    done
    return 1
}

declare -A REAP=()
for pid in "${!ARGS[@]}"; do
    [ "$pid" = "$$" ] && continue
    _descends "$$" "$pid" && continue                  # never this hook or a process it runs under
    [ -n "$root" ] && { [ "$pid" != "$root" ] && _descends "$pid" "$root" || continue; }
    [[ "${STATE[$pid]}" == [ZX] ]] && continue
    [ "${AGE[$pid]:-0}" -gt "$_limit_s" ] 2>/dev/null || continue
    read -r -a words <<< "${ARGS[$pid]}"
    kind="$(test_runner_kind "${words[@]}" | cut -f1)"
    [ "$kind" = host ] || continue
    _bounded "$pid" && continue
    REAP[$pid]=1
done
(( ${#REAP[@]} )) || exit 0

# A reaped host's descendants end with it (they are its run).
declare -A ALL=()
for pid in "${!ARGS[@]}"; do
    for host in "${!REAP[@]}"; do _descends "$pid" "$host" && { ALL[$pid]=1; break; }; done
done

# HOW: TERM (ended by it), KILL (still running after the grace), gone (no longer the snapshot's process before any
# signal: ended on its own, a zombie, or its id reused).
# The hosts are signalled before the processes they started: a host often ends by itself once its child ends, and it
# must then read as ended by the reaper, not as gone on its own.
declare -A HOW=()
for pid in $(printf '%s\n' "${!REAP[@]}" | sort -n) $(printf '%s\n' "${!ALL[@]}" | sort -n); do
    [ -n "${HOW[$pid]:-}" ] && continue
    if _same "$pid"; then kill -TERM "$pid" 2>/dev/null && HOW[$pid]=TERM; else HOW[$pid]=gone; fi
done
_alive() { local pid; for pid in "${!ALL[@]}"; do [ "${HOW[$pid]}" = TERM ] && _same "$pid" && return 0; done; return 1; }
for _ in 1 2 3 4 5 6 7 8 9 10; do _alive || break; sleep 0.5; done
for pid in "${!ALL[@]}"; do
    [ "${HOW[$pid]}" = TERM ] && _same "$pid" && kill -KILL "$pid" 2>/dev/null && HOW[$pid]=KILL
done

report=""; ended=0
for pid in $(printf '%s\n' "${!REAP[@]}" | sort -n); do
    ppid="${PARENT[$pid]:-?}"
    extra=0; for d in "${!ALL[@]}"; do [ "$d" != "$pid" ] && _descends "$d" "$pid" && extra=$((extra + 1)); done
    case "${HOW[$pid]}" in
        gone) what="already gone before it could be ended (it ended on its own, is a zombie waiting for its parent, or its id now belongs to another process): nothing was signalled" ;;
        *)    what="ended with ${HOW[$pid]}"; ended=$((ended + 1)) ;;
    esac
    report+="
- process ${pid}, running for $(( ${AGE[$pid]} / 60 )) min ($(( ${AGE[$pid]} )) s), ${what}$([ "$extra" -gt 0 ] && printf ' together with %s process(es) it started' "$extra"): $(printf '%s' "${ARGS[$pid]}" | cut -c1-300)
  started by process ${ppid}: $(printf '%s' "${ARGS[$ppid]:-(no longer running)}" | cut -c1-200)"
done
msg="[kyklos] test-host reaper: ended ${ended} of ${#REAP[@]} test host(s) that ran longer than the limit of ${_limit} (KYKLOS_TEST_RUN_LIMIT):${report}
Start test runs with a bound (timeout ${_limit} <command>) so they end on their own. Opt-out: KYKLOS_TEST_HOST_REAPER=off."
printf '%s\n' "$msg" >&2
jq -nc --arg m "$msg" '{systemMessage:$m}' 2>/dev/null
exit 0
