#!/usr/bin/env bash
# kyklos-doctor-surface.sh (Kyklos, SessionStart) -- the one place a session starts with its health: it runs the health
# checks itself, synchronously, inside its own bounded time, asks the bridge's `doctor` verb for its checks, and puts every
# finding into the session's starting context, with the instruction that the agent's FIRST message to the person reports each
# one, so a wrong setting is never met silently.
#
# The checks it runs itself (lib/session-health.sh), which used to print their own warnings from other hooks:
#   - the token scopes the agent can read (the same check as kyklos-api-scope-surface.sh, limited to 30 seconds; a check that
#     runs out of time gives the same "CHECK failed" line that hook gave, never silence);
#   - the story mirror marked stale (the marker is read directly at the start; nothing waits on the refresh).
# Nothing passes between separately started hooks, so there is nothing to lose and nothing cached across firings: every
# SessionStart (start, resume, compact) runs the checks afresh.
#
# A bridge that is absent, that does not know the verb (an older bridge) or that does not answer within the bound gives ONE
# short neutral line, never a failure and never a long wait: the call is bounded by KYKLOS_DOCTOR_TIMEOUT_SECONDS (default
# 15, never more than 15); a run that outlasts the bound goes on in the bridge, for its page. A healthy answer adds nothing.
# Total time: the token check at most 30 seconds plus the bridge call at most 15 (hooks.json gives the hook 60). If the hook
# itself fails part-way, an exit trap still prints the findings gathered so far (as plain text when jq is missing).
#
# SessionStart can add context but cannot block. CONFIG: KYKLOS_DOCTOR_SURFACE=on|off (default on; off brings back the own
# warnings of kyklos-api-scope-surface.sh and kyklos-story-mirror-refresh.sh). FAIL-OPEN by design for the session: a doctor
# that cannot run says so in one line and never stops the start.
# [json-answer-required] Every answer this hook reads goes through the JSON reader; without it a check would exit 127
# and fall into a fail-open path, so the hook refuses by name instead (a broken install). [CySec] CWE-636
. "$(dirname "${BASH_SOURCE[0]}")/lib/json-answer.sh" 2>/dev/null
if ! command -v json_test >/dev/null 2>&1; then
    echo "[kyklos] $(basename "$0"): the JSON reader hooks/lib/json-answer.sh did not load (broken install); the Kyklos's guards refuse until the kyklos plugin is reinstalled or repinned."
    echo "$(. "$(dirname "${BASH_SOURCE[0]}")/lib/help-link.sh" 2>/dev/null && kyklos_help_line broken-install)"
    # The health findings still reach the agent: they need no JSON reader.
    . "$(dirname "${BASH_SOURCE[0]}")/lib/session-health.sh" 2>/dev/null
    if command -v kyklos_health_api_scope >/dev/null 2>&1 && kyklos_doctor_on; then
        kyklos_health_api_scope
        kyklos_health_story_mirror "$(kyklos_health_project_dir)"
    fi
    exit 0
fi
set +e -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/control-switch.sh
. "$HERE/lib/control-switch.sh" 2>/dev/null || true   # kyklos_control_off: the one control-switch reader
# shellcheck source=lib/session-health.sh
. "$HERE/lib/session-health.sh" 2>/dev/null || true
# shellcheck source=lib/help-link.sh
. "$HERE/lib/help-link.sh" 2>/dev/null   # kyklos_help_line: the neutral line names the guide's section
kyklos_doctor_on || exit 0   # the one decision shared with the two hooks that speak for themselves when it is off
session_id="$(jq -r '.session_id // empty' 2>/dev/null)"   # the SessionStart payload names the session (the red record is keyed by it)

health=""       # the findings of the checks this hook runs itself, one per line
lines=""        # one line per finding of the bridge's doctor
neutral=""      # the one neutral line when the bridge gave no report

# emit: prints what was gathered; runs on every exit, so a failure part-way still prints the health lines.
emit() {
    local msg=""
    if [ -n "$health$lines" ]; then
        msg="[kyklos] DOCTOR at session start found problems. Your FIRST message to the person reports each of them and its fix, before any other work; never reorient silently."
        [ -n "$health" ] && msg="$msg
$health"
        [ -n "$lines" ] && msg="$msg
$lines"
    fi
    if [ -n "$neutral" ]; then
        msg="${msg:+$msg
}[kyklos] Doctor: no health report from the bridge at session start (${neutral}); /kyklos:health asks again.
$(kyklos_help_line bridge-unreachable)"
    fi
    [ -n "$msg" ] || return 0
    if command -v jq >/dev/null 2>&1; then
        jq -nc --arg m "$msg" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$m}}'
    else
        printf '%s\n' "$msg"
    fi
}
trap emit EXIT

# The checks of this hook, before anything that could fail: each finding is one line.
tokens="$(kyklos_health_api_scope)"
[ -n "$tokens" ] && health="- $tokens"
mirror="$(kyklos_health_story_mirror "$(kyklos_health_project_dir)")"
[ -n "$mirror" ] && health="${health:+$health$'\n'}- $mirror"

# shellcheck source=lib/bridge-mcp.sh
. "$HERE/lib/bridge-mcp.sh" 2>/dev/null || true
bound="${KYKLOS_DOCTOR_TIMEOUT_SECONDS:-15}"
case "$bound" in ''|*[!0-9]*) bound=15 ;; esac
[ "$bound" -gt 15 ] && bound=15
[ "$bound" -lt 1 ] && bound=1

reply="$(bridge_mcp_call doctor '{}' "$bound" 2>/dev/null)"; rc=$?
if [ "$rc" -ne 0 ]; then
    case "$rc" in
        2) neutral="the bridge is not configured for this session" ;;
        3) neutral="the bridge did not answer within ${bound} seconds" ;;
        6) neutral="the bridge that answered is not this session's bridge" ;;
        *) neutral="the bridge could not be asked" ;;
    esac
elif bridge_mcp_is_error "$reply"; then
    neutral="this bridge does not know the doctor verb (an older bridge)"
elif ! printf '%s' "$reply" | json_test '.result.findings | type == "array"'; then
    # An answer that is a plain text (a bridge with no doctor) or unreadable gives no findings: never read as healthy.
    neutral="the bridge gave no doctor report"
else
    lines="$(printf '%s' "$reply" | json_read '[.result.findings[] | select(.verdict == "No")
        | "- " + .check + ": " + .found + (if (.fix // "") != "" then " Fix: " + .fix else "" end)] | join("\n")')"
    unknown="$(printf '%s' "$reply" | json_read '[.result.findings[] | select(.verdict == "CannotTell")] | length')"
    if [ "${unknown:-0}" -gt 0 ] 2>/dev/null; then
        lines="${lines:+$lines$'\n'}- ${unknown} check(s) could not tell (never a pass): ask /kyklos:health for the full report."
    fi
    # The red record for the continue guard: the checks that answered "no" (only a real answer; see below).
    red="$(printf '%s' "$reply" | json_read '[.result.findings[] | select(.verdict == "No") | .check] | join("\n")')"
    if [ -n "$red" ]; then kyklos_doctor_record_write "$session_id" "$red"; else kyklos_doctor_record_clear "$session_id"; fi
fi
# A doctor that could not run is not a red result: it leaves no record, and clears any earlier one of this session.
[ -n "$neutral" ] && kyklos_doctor_record_clear "$session_id"
exit 0
