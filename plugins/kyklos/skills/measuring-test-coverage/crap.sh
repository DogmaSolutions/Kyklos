#!/usr/bin/env bash
# crap.sh — the C.R.A.P. score (Change Risk Anti-Patterns) per method of a cobertura coverage report, gated on a
# ceiling. The score is computed by the KyklosBridge (its `crap_score` verb, the same code that `get_coverage` uses to
# report CRAP for the run it measures); this script only sends the report there and relays the verdict, so the number
# a story cites cannot be changed by editing anything in the container.
#
#   CRAP(m) = complexity(m)^2 * (1 - coverage(m))^3 + complexity(m)
#
# Usage: crap.sh <cobertura.xml> [threshold] [--triage <ledger>]
#   threshold: max CRAP any single method may score. Falls back to $CRAP_THRESHOLD; without either the bridge answers
#              "cannot gate" (the threshold is interviewed + persisted by measuring-test-coverage, never invented).
#   --triage <ledger>: OPTIONAL cover-vs-refactor-vs-accept triage ledger (falls back to $CRAP_TRIAGE). Each
#              over-threshold method may carry a recorded decision COVER | REFACTOR | ACCEPT; a justified ACCEPT (with
#              its rationale) passes, COVER / REFACTOR stay open debt. Ledger line grammar (blank lines + `#` ignored):
#                <ClassName>.<Method>[(sig)] = ACCEPT: <rationale>
#                <ClassName>.<Method>[(sig)] = COVER | REFACTOR
# Prints the bridge's report (worst offenders + the max). Exit 0 = every method passes, 1 = a method exceeds the
# threshold without a justified ACCEPT, 2 = cannot gate (no threshold, no complexity in the report, a malformed ledger,
# a missing file, or no bridge to compute it — it never falls back to computing on its own).
set +e -uo pipefail

REPORT=""; THRESH=""; TRIAGE="${CRAP_TRIAGE:-}"
# Parse args: first bare token = report, second bare token = threshold, `--triage <file>` anywhere.
while [ "$#" -gt 0 ]; do
  case "$1" in
    --triage) shift; TRIAGE="${1:?--triage needs a <ledger> path}";;
    --triage=*) TRIAGE="${1#--triage=}";;
    *) if [ -z "$REPORT" ]; then REPORT="$1"; elif [ -z "$THRESH" ]; then THRESH="$1"; else echo "crap: unexpected argument: $1" >&2; exit 2; fi;;
  esac
  shift
done
[ -n "$REPORT" ] || { echo "usage: crap.sh <cobertura.xml> [threshold] [--triage <ledger>]" >&2; exit 2; }
THRESH="${THRESH:-${CRAP_THRESHOLD:-}}"
[ -f "$REPORT" ] || { echo "crap: report not found: $REPORT" >&2; exit 2; }
# A triage path that is set but does not exist is a MISTAKE, not "no triage" — fail loud rather than silently drop a
# ledger the operator meant to apply (which would re-fail an ACCEPTED method and read as a regression).
[ -z "$TRIAGE" ] || [ -f "$TRIAGE" ] || { echo "crap: triage ledger not found: $TRIAGE" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "crap: jq is required to talk to the bridge" >&2; exit 2; }

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../hooks/lib/bridge-mcp.sh"

args="$(jq -cn --rawfile report "$REPORT" --arg threshold "$THRESH" --rawfile triage "${TRIAGE:-/dev/null}" \
    '{report: $report, threshold: $threshold} + (if $triage == "" then {} else {triage: $triage} end)')" \
    || { echo "crap: could not read the report or the ledger" >&2; exit 2; }
reply="$(bridge_mcp_call crap_score "$args" 300)"; rc=$?
case "$rc" in
  0) : ;;
  2) echo "crap: no KyklosBridge is configured for this workspace (.mcp.json) — the C.R.A.P. score is computed by the bridge; start the session through its launcher" >&2; exit 2 ;;
  *) echo "crap: the KyklosBridge did not answer (rc $rc) — the C.R.A.P. score is computed by the bridge, never in the container" >&2; exit 2 ;;
esac
code="$(printf '%s' "$reply" | jq -r '.result.exitCode // empty' 2>/dev/null)"
text="$(bridge_mcp_text "$reply")"
case "$code" in
  0|1) printf '%s\n' "$text"; exit "$code" ;;
  2) printf '%s\n' "$text" >&2; exit 2 ;;
  *) echo "crap: the KyklosBridge did not score the report (an older bridge has no crap_score verb — relaunch the session to update it): ${text:0:300}" >&2; exit 2 ;;
esac
