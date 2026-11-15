#!/usr/bin/env bash
# kyklos-api-scope-surface.sh (Kyklos, SessionStart) -- tell the agent, at every launch, which GitLab tokens it can
# read and which of them can call the GitLab API, judged against the project's declared token state.
#
# A project moving its api-scoped token to host-only (the bridge keeps it, the agent's secret_read is refused) must
# not quietly get an API-capable token back. This hook runs lib/api-scope-check.sh and puts the result in the
# session's starting context: a warning while the project still serves or is in transition, an ERROR when it is
# declared host-only and a readable token can still call the API. Values are never printed, only names and scopes.
#
# When the doctor surface is on (the default) the doctor hook (kyklos-doctor-surface.sh) runs this same check itself, inside
# its own time limit, and reports it in its one block, so this hook does nothing then; KYKLOS_DOCTOR_SURFACE=off is the path
# on which this hook speaks for itself.
# SessionStart can add context but cannot block. CONFIG: KYKLOS_API_SCOPE_SURFACE=on|off (default on);
# KYKLOS_API_TOKEN_STATE=serve|transition|host-only (default serve). FAIL-OPEN: no API base or an unreachable
# GitLab yields a "cannot check" line, never "no API-capable token".
set +e -uo pipefail
# shellcheck source=lib/control-switch.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/control-switch.sh" 2>/dev/null || true   # kyklos_control_off: the one control-switch reader
kyklos_control_off "${KYKLOS_API_SCOPE_SURFACE:-}" && exit 0
# shellcheck source=lib/session-health.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/session-health.sh" 2>/dev/null || true
kyklos_doctor_on 2>/dev/null && exit 0   # the doctor surface runs the check itself
cat >/dev/null 2>&1   # drain the SessionStart payload (unused)
out="$(timeout 60 bash "$(dirname "${BASH_SOURCE[0]}")/lib/api-scope-check.sh" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && exit 0
msg="$(kyklos_api_scope_message "$rc" "$out")"
if command -v jq >/dev/null 2>&1; then
    jq -nc --arg m "$msg" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$m}}'
fi
exit 0
