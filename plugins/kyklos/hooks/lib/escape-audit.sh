#!/usr/bin/env bash
# escape-audit.sh — a shared AUDIT for a consumed one-shot guard ESCAPE. A one-shot escape
# marker (inbound-ok, AGENT_MSG_RAW_OK, ...) is self-grantable in a single silent bash call, so its use must leave
# a durable trail (not only a transient stderr line that scrolls away). escape_audit
# records EVERY consumption in a structured, greppable form to TWO sinks:
#   (1) a prominent stderr banner — which lands in the session TRANSCRIPT, the durable conversation record an
#       auditor (the user / a later session) reviews;
#   (2) an append-only log under the Kyklos state dir, for in-session `grep`.
# Cross-container, tamper-EVIDENT persistence (e.g. a GitLab audit trail) is NOT provided here; this closes the
# "no trail at all" gap. Auditing MUST NEVER break the guard it runs in, so escape_audit always rc 0
# and every write is best-effort.
#
#   escape_audit <marker-name> [context...] -> always rc 0.

escape_audit() {
    local marker="${1:-?}"; shift 2>/dev/null || true
    local ctx="$*"
    local ts; ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo '?')"
    local who="${KYKLOS_ISSUES_SELF:-${KYKLOS_AGENT_NAME:-?}}"
    local line="[kyklos][escape-audit] ${ts} marker=${marker} agent=${who}${ctx:+ ctx=${ctx}}"
    printf '%s\n' "$line" >&2
    local dir="${KYKLOS_STATE_DIR:-/tmp/kyklos-state}"
    { mkdir -p "$dir" 2>/dev/null && printf '%s\n' "$line" >> "$dir/escape-audit.log" 2>/dev/null; } || true
    return 0
}
