#!/usr/bin/env bash
# kyklos-test-quality-guard.sh (Kyklos) — blocks regression-hiding anti-patterns in test source so vacuous
# tests (green while the feature is broken) can't be introduced.
#
# Blocks in edited/added TEST code:
#   - Assert.Ignore  (an unconditional skip; NO escape)
#   - Assert.Pass  (an unconditional pass, the twin of Assert.Ignore) — escape: inline `// transient-ok: <reason>`
#   - attribute skips such as [Fact(Skip=...)], [Ignore], [Explicit] — escape: the same inline
#     `// transient-ok: <reason>` as Assert.Inconclusive (a deliberate, recorded quarantine)
#   - Assert.Inconclusive  (turns a should-fail into a non-failure) — escape: inline `// transient-ok: <reason>`
#     on the same line (non-empty reason) for a live-API test that is Inconclusive ONLY on a transient upstream
#     (429/408/5xx/timeout/socket) while a real regression still fails hard.
#   - Positional/structural locators .Nth(...) / :nth-child (break on layout/order, not behaviour)
#     escape: inline `// nth-ok: <reason>` on the same line for a genuine order-IS-behaviour case.
#
# Wired PreToolUse, matcher Edit|Write|MultiEdit.
set -euo pipefail

INPUT="$(cat || true)"
# A missing jq must not SILENTLY disable the gate (it parses INPUT with jq). Announce the INERT state LOUDLY and
# allow (a broken plugin install must not wedge every Edit/Write) — never a silent no-op.
command -v jq >/dev/null 2>&1 || { echo "[kyklos] WARNING: test-quality-guard is INERT — jq is missing, so regression-hiding-test checks are NOT running. Install jq to restore this gate." >&2; exit 0; }
FILE_PATH="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)"

case "$FILE_PATH" in *.cs) ;; *) exit 0 ;; esac
printf '%s' "$FILE_PATH" | grep -cE '(\.Tests/|\.Tests\.[^/]*\.cs$|Tests\.cs$|Test\.cs$)' >/dev/null || exit 0

CONTENT="$(printf '%s' "$INPUT" | jq -r '
  [ (.tool_input.new_string // empty),
    (.tool_input.content // empty),
    ((.tool_input.edits // []) | map(.new_string // empty) | join("\n")) ]
  | join("\n")' 2>/dev/null || true)"

block() { printf '{"decision":"block","reason":"%s"}' "$1"; exit 0; }

# Assert.Ignore = an unconditional skip; NEVER allowed (no escape).
if printf '%s' "$CONTENT" | grep -cE 'Assert\.Ignore\b' >/dev/null; then
  block "BLOCKED (test-quality-guard): Assert.Ignore turns a should-fail condition into a skip, so a real regression passes silently. Assert the actual observable outcome and let the test FAIL when the behaviour is broken. A genuinely unmet environment precondition should make the fixture fail hard, not the test skip."
fi
# Assert.Pass = the UNCONDITIONAL-PASS twin of Assert.Ignore: it makes the test succeed immediately, so EVERY
# assertion after it is dead code that can never fail — a real regression passes silently. Same auditable escape as
# Inconclusive for the rare deliberate early-pass (a data-driven row that is genuinely N/A here).
if printf '%s' "$CONTENT" | grep -E 'Assert\.Pass\b' | grep -cvE '//[[:space:]]*transient-ok:[[:space:]]*\S' >/dev/null; then
  block "BLOCKED (test-quality-guard): Assert.Pass makes the test pass UNCONDITIONALLY from that point, so every assertion after it is dead code and a real regression passes silently — the same vacuous-green class as Assert.Ignore. Let the test reach its assertions and FAIL when the behaviour is broken. For a genuine deliberate early-pass (e.g. a data-driven case that is truly N/A here) add an auditable inline '// transient-ok: <reason>' (non-empty) on that line."
fi
# Assert.Inconclusive is blocked UNLESS the SAME line carries an auditable '// transient-ok: <non-empty reason>' —
# the one legitimate case: a live-API test that must be Inconclusive ONLY on a transient upstream condition (429/408/
# 5xx/timeout/socket) while a genuine regression still fails hard. Empty reason or a bare Inconclusive stays blocked.
# Mirrors the '// nth-ok:' escape. (grep the Inconclusive lines that LACK the marker; any such line -> block.)
if printf '%s' "$CONTENT" | grep -E 'Assert\.Inconclusive\b' | grep -cvE '//[[:space:]]*transient-ok:[[:space:]]*\S' >/dev/null; then
  block "BLOCKED (test-quality-guard): Assert.Inconclusive turns a should-fail condition into a non-failure, so a real regression passes silently. Assert the observable outcome and let the test FAIL when behaviour is broken. If (and ONLY if) this is a live-API test that must be Inconclusive on a TRANSIENT upstream condition (HTTP 429/408/5xx, timeout, socket) — with a real regression still failing hard — add an auditable inline '// transient-ok: <reason>' (non-empty) on that line. This does NOT relax Assert.Ignore or permit an unconditional Inconclusive."
fi

if printf '%s' "$CONTENT" | grep -E '\.Nth\(|nth-child' | grep -cvE '//[[:space:]]*nth-ok:' >/dev/null; then
  block "BLOCKED (test-quality-guard): positional locator (.Nth(...) / nth-child) breaks when layout or order changes, not when behaviour changes — a fragile, untrustworthy test. Locate by ARIA role + accessible name or by text content (GetByRole/GetByText/GetByLabel), or match a row by its content + column header. If order genuinely IS the behaviour under test, add an inline '// nth-ok: <reason>' on that line."
fi

# ATTRIBUTE-based skips — the MOST common way to silence a failing test — are caught as well as the Assert-call
# forms. One pattern rule covers the attribute idioms across frameworks, honoring the SAME auditable inline escape as
# Assert.Inconclusive: '// transient-ok: <non-empty reason>' on the line permits a deliberate, recorded quarantine.
#   xUnit:        [Fact(Skip="...")] / [Theory(Skip="...")]
#   NUnit/MSTest: [Ignore("...")] / [Ignore]
#   NUnit:        [Explicit] / [Explicit("...")]  — a test/fixture marked Explicit is SKIPPED in a normal CI run
# (it only runs when explicitly selected), so it silences the test in CI exactly like [Ignore].
if printf '%s' "$CONTENT" | grep -E '\[(Fact|Theory)[[:space:]]*\([^)]*Skip[[:space:]]*=|\[Ignore(\]|[[:space:]]*\()|\[Explicit(\]|[[:space:]]*\()' | grep -cvE '//[[:space:]]*transient-ok:[[:space:]]*\S' >/dev/null; then
  block "BLOCKED (test-quality-guard): an attribute skip ([Fact(Skip=...)] / [Theory(Skip=...)] / [Ignore] / [Explicit]) silences a test in a normal run, so a real regression passes silently — the exact vacuous-green class this guard exists to kill. Fix the test or the behaviour and let it FAIL when broken. For a deliberate, temporary quarantine add an auditable inline '// transient-ok: <reason>' (non-empty) on the SAME line."
fi
exit 0
