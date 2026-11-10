#!/usr/bin/env bash
# kyklos-inbound-monitor-init.sh — SessionStart. REPORTS the inbound-issues coordination state ONCE per container
# (no silent non-enforcement), then, when coordination is live, reminds the agent to ARM the idle monitor.
#
# Three states, each SAID OUT LOUD (the old version exited silently when unconfigured — which is exactly how a hub
# container with coordination UNWIRED, or wired with a token that can't reach the project, silently enforced
# NOTHING and cross-agent Issues went unseen):
#   1. configured + REACHABLE  -> arm the ~hourly idle monitor (the conversation-alive tick).
#   2. configured + UNREACHABLE -> LOUD WARNING: the check could not run (bridge down / bad token / cross-project
#      404 / non-200), so the inbound Stop gate cannot see waiting issues. A project-bot token cannot read ANOTHER
#      project's issues — use a group/user token that can.
#   3. UNCONFIGURED on a Kyklos container -> NOTICE: the inbound Stop gate is inert; wire KYKLOS_ISSUES_*.
# What the inbound gate enforces is owned by kyklos-inbound-issues-guard.sh (its header).
#
# Wired: SessionStart.
# [json-answer-required] Every answer this hook reads goes through the JSON reader; without it a check would exit 127
# and fall into a fail-open path, so the hook refuses by name instead (a broken install). [CySec] CWE-636
. "$(dirname "${BASH_SOURCE[0]}")/lib/json-answer.sh" 2>/dev/null
if ! command -v json_test >/dev/null 2>&1; then
    echo "[kyklos] $(basename "$0"): the JSON reader hooks/lib/json-answer.sh did not load (broken install); the Kyklos's guards refuse until the kyklos plugin is reinstalled or repinned."
    exit 0
fi
set +e -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/inbound-issues-fetch.sh
. "$HERE/lib/inbound-issues-fetch.sh" 2>/dev/null || exit 0

STATE="${KYKLOS_STATE_DIR:-/tmp/kyklos-state}"; mkdir -p "$STATE" 2>/dev/null || true
marker="$STATE/inbound-monitor-armed"
[ -f "$marker" ] && exit 0        # report once per container lifetime

# Config completeness (mirror the fetch's required vars exactly: API + a scope; the bridge holds the token, and the
# legacy routing label is no longer read, so neither decides whether coordination is configured).
configured=1
[ -n "${KYKLOS_ISSUES_API:-}" ]       || configured=0
{ [ -n "${KYKLOS_ISSUES_PROJECT:-}" ] || [ -n "${KYKLOS_ISSUES_GROUP:-}" ] || [ -n "${KYKLOS_ISSUES_SCOPES:-}" ]; } || configured=0

if [ "$configured" = 0 ]; then
    # State 3 — unconfigured. Only NOTICE on a Kyklos container (or one with a partial coordination config); a
    # plain shell has nothing to coordinate and stays quiet.
    if [ "${KYKLOS:-0}" = "1" ] || [ -n "${KYKLOS_ISSUES_API:-}${KYKLOS_ISSUES_LABEL:-}${KYKLOS_ISSUES_PROJECT:-}${KYKLOS_ISSUES_GROUP:-}${KYKLOS_ISSUES_TOKEN_ENV:-}" ]; then
        touch "$marker" 2>/dev/null || true
        cat >&2 <<'MSG'
[kyklos] NOTICE: inbound-issues coordination is NOT configured for this container (KYKLOS_ISSUES_* unset). So
cross-agent Issues addressed to you will NOT be surfaced and the inbound Stop gate is INERT. If this
container coordinates with other agents, wire KYKLOS_ISSUES_{API,PROJECT|GROUP|SCOPES} in its launcher
(see standards.env.sample). If it deliberately does not coordinate, ignore this.
MSG
    fi
    exit 0
fi

# Configured — probe REACHABILITY once, so a bridge outage / broken token / cross-project 404 is not a SILENT
# non-enforcement.
touch "$marker" 2>/dev/null || true
inbound_issues_collect; _rc=$?
# rc 3 = CONFIGURED but the check could not run (unreachable/unauthorized). (rc 2 = unconfigured cannot occur here —
# we already confirmed configured above.) The inbound Stop gate cannot see waiting issues then, so warn about the outage.
if [ "$_rc" = "3" ]; then
    # State 2 — configured but the check could not run (the bridge or GitLab could not answer).
    cat >&2 <<MSG
[kyklos] WARNING: inbound-issues coordination IS configured (scope
'${KYKLOS_ISSUES_SCOPES:-${KYKLOS_ISSUES_PROJECT:-${KYKLOS_ISSUES_GROUP:-?}}}') but the check could NOT run: the
KyklosBridge did not answer, has no coordination stack, or could not reach GitLab with its token. Until the check
runs, the inbound Stop gate (kyklos-inbound-issues-guard.sh) cannot confirm whether a cross-agent Issue is waiting on
you, so it only warns. Check the bridge (get_status/diag) and the launcher's coordination settings; the bridge's token
must be able to read the coordination project.
MSG
    exit 0
fi

# State 1 — configured + reachable: arm the idle monitor.
cat <<'MSG'
[kyklos] Inbound-issues idle monitor — coordination Issues are configured + reachable for this session. To keep
the agent-to-agent conversation alive, ARM the idle monitor ONCE now: when you finish all queued work, schedule a
~1-hour self-wake that runs `kyklos-inbound-issues-guard.sh monitor`. If that prints inbound Issues, act on each
(evaluate against pending work, apply corrections, reply on the Issue and/or close it), then re-arm the wake.
This is the counterpart to the inbound Stop gate (kyklos-inbound-issues-guard.sh), which blocks ending a turn while
an Issue awaits you; the monitor covers the IDLE gap so a late reply from another agent doesn't wait for the user to
notice. Recipe + guardrails:
the `ssdlc-inbound-monitor` skill.
MSG
exit 0
