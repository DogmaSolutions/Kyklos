#!/usr/bin/env bash
# api-scope-check.sh -- print which GitLab tokens the agent in this container can read and which of them can call the
# API, with the project's verdict. Values are never printed: only names and scopes.
#
#   api-scope-check.sh            -> report lines, then "verdict: fine|warning|error (<state>)"
#   api-scope-check.sh --ledger   -> how often each hook still fell back to a direct token ("<count> <caller>"), from
#                                    ${KYKLOS_STATE_DIR}/direct-token-fallback.log; exit 0 when none, 1 when any.
# Exit codes: 0 fine, 1 warning (api-capable token readable while the project still serves or is in transition),
# 2 error (api-capable token readable while the project is host-only), 3 cannot check (no API base configured).
set -uo pipefail
if [ "${1:-}" = "--ledger" ]; then
    ledger="${KYKLOS_STATE_DIR:-/tmp/kyklos-state}/direct-token-fallback.log"
    counts="$(cut -f2 "$ledger" 2>/dev/null | sort | uniq -c | sort -rn | sed 's/^ *//')"
    [ -n "$counts" ] || { echo "ledger: no direct-token fallback recorded"; exit 0; }
    printf '%s\n' "$counts"
    echo "ledger: $(cut -f2 "$ledger" | wc -l | tr -d ' ') direct-token fallback(s) recorded"
    exit 1
fi
. "$(dirname "${BASH_SOURCE[0]}")/api-scope.sh"
. "$(dirname "${BASH_SOURCE[0]}")/gitlab-api-base.sh"
state="$(api_scope_state)" || exit 2
api="$(gitlab_api_base 2>/dev/null)" || { echo "verdict: cannot check (no GitLab API base is configured)"; exit 3; }
report="$(api_scope_report "$api")"
[ -n "$report" ] && printf '%s\n' "$report"
api_scope_verdict "$state" "$report"; rc=$?
case "$rc" in
    0) echo "verdict: fine ($state)" ;;
    1) echo "verdict: warning ($state): the agent can read a token that can call the GitLab API" ;;
    2) echo "verdict: error ($state): the project is host-only, yet the agent can read a token that can call the GitLab API" ;;
esac
exit "$rc"
