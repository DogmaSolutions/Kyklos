#!/usr/bin/env bash
# kyklos-api-scope-surface.sh (Kyklos, SessionStart) -- tell the agent, at every launch, which GitLab tokens it can
# read and which of them can call the GitLab API, judged against the project's declared token state.
#
# A project moving its api-scoped token to host-only (the bridge keeps it, the agent's secret_read is refused) must
# not quietly get an API-capable token back. This hook runs lib/api-scope-check.sh and puts the result in the
# session's starting context: a warning while the project still serves or is in transition, an ERROR when it is
# declared host-only and a readable token can still call the API. Values are never printed, only names and scopes.
#
# SessionStart can add context but cannot block. CONFIG: KYKLOS_API_SCOPE_SURFACE=on|off (default on);
# KYKLOS_API_TOKEN_STATE=serve|transition|host-only (default serve). FAIL-OPEN: no API base or an unreachable
# GitLab yields a "cannot check" line, never "no API-capable token".
set +e -uo pipefail
# shellcheck source=lib/control-switch.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/control-switch.sh" 2>/dev/null || true   # kyklos_control_off: the one control-switch reader
kyklos_control_off "${KYKLOS_API_SCOPE_SURFACE:-}" && exit 0
cat >/dev/null 2>&1   # drain the SessionStart payload (unused)
out="$(timeout 60 bash "$(dirname "${BASH_SOURCE[0]}")/lib/api-scope-check.sh" 2>&1)"; rc=$?
case "$rc" in
    0) exit 0 ;;
    1) head="[kyklos] API TOKEN NOTICE at session start: the agent can read a GitLab token that can call the API." ;;
    2) head="[kyklos] API TOKEN ERROR at session start: either this project is declared host-only (KYKLOS_API_TOKEN_STATE) yet the agent can read a GitLab token that can call the API, or KYKLOS_API_TOKEN_STATE holds an invalid value (the details follow). Tell the owner of this project's launcher configuration; do not use the token." ;;
    3) head="[kyklos] API TOKEN CHECK could not run at session start." ;;
    *) head="[kyklos] API TOKEN CHECK failed at session start (exit $rc)." ;;
esac
msg="$head $(printf '%s' "$out" | tr '\n' ';' | sed 's/;$//')"
if command -v jq >/dev/null 2>&1; then
    jq -nc --arg m "$msg" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$m}}'
fi
exit 0
