#!/usr/bin/env bash
# pre-commit-story-gate.sh (Kyklos) — Coding Chokepoint, Q3 the COMMIT-WAIST hard gate. Installed as a git
# `pre-commit` hook (via core.hooksPath, so it fires on EVERY `git commit` regardless of who invokes it — the agent, a
# subagent, a tool that shells git, or a human at the terminal). It is the PERSIST waist that complements the bridge
# build/test (validate) waist: even if code were somehow produced un-gated, it cannot be COMMITTED without a ready
# in-progress story. This is a HARD block (exit non-zero aborts the commit) — user-authorised, so it is not an
# unsanctioned new fleet gate.
#
# READINESS = the SAME oracle every other layer uses (R4 SSoT, no drift): `story structure` (no id -> the single
# in-progress story) exits 0 iff there is exactly one, fully-authored, conforming in-progress story. This hook NEVER
# re-derives readiness from anything else.
#
# FAIL-OPEN (allow the commit) on EVERY uncertainty (RA-2) — a mis-firing commit gate must never wedge a repo:
#   * KYKLOS_COMMIT_GATE=off / 0 / false / no        -> disabled (H4: bootstrap/infra repos, a repo-owner decision)
#   * no Stories/ machinery, no `story` tool, no jq/bash oracle, or an AMBIGUOUS oracle result
#   * `git commit --no-verify` bypasses ALL pre-commit hooks (a git built-in; the documented H3 hole)
# It BLOCKS (exit 1) only when readiness is CONFIDENTLY not-ready: no in-progress story, or an unfilled/incomplete one.
set +e -uo pipefail

# shellcheck source=../lib/control-switch.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/control-switch.sh" 2>/dev/null || true   # kyklos_control_off: the one control-switch reader
kyklos_control_off "${KYKLOS_COMMIT_GATE:-}" && exit 0
command -v jq  >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

# Resolve the repo + project dir. A git hook runs at the repo root; CLAUDE_PROJECT_DIR (when set) wins.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/standards-env.sh
. "$HERE/../lib/standards-env.sh" 2>/dev/null || true
command -v load_standards_env >/dev/null 2>&1 && load_standards_env "$PROJECT_DIR/.claude/standards.env" 2>/dev/null || true
kyklos_control_off "${KYKLOS_COMMIT_GATE:-}" && exit 0   # re-check after standards.env

[ -d "$PROJECT_DIR/Stories" ] || exit 0                         # no story machinery here -> fail-open (allow)
STORY="${KYKLOS_STORY_BIN:-$HERE/../../skills/ssdlc-story/story}"   # KYKLOS_STORY_BIN = test seam (mock the oracle)
[ -f "$STORY" ] || exit 0

# --- readiness oracle (identical to the story-before-coding guard, R4) ---------------------------------------------
# exit 0 = a conforming READY in-progress story -> allow the commit.
# exit 1 = an in-progress story that is INCOMPLETE (missing section / unfilled <FILL:>) -> BLOCK.
# any other exit = no single in-progress story / ambiguous -> confirm against the BACKLOG count, else fail-open.
if out="$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$STORY" structure 2>&1)"; then
  exit 0
else
  rc=$?
fi

block() {
  printf '\n[kyklos] COMMIT BLOCKED (coding-chokepoint, commit waist): %s\n' "$1" >&2
  printf 'SSDLC requires an authored, in-progress story BEFORE code is committed. Open/adopt + fully author a story\n' >&2
  printf '(story new <kebab-slug> --title "<title>" --type <t> --kind <k> --severity <critical|high|medium|low> --epic <E0N>  |  story adopt <id>  -> In-progress), then commit.\n' >&2
  printf 'Deliberate exceptions (documented): KYKLOS_COMMIT_GATE=off for a bootstrap/infra repo, or `git commit --no-verify`.\n' >&2
  exit 1
}

if [ "$rc" -eq 1 ]; then
  block "the in-progress story is NOT ready yet — $(printf '%s' "$out" | tr '\n' ' ' | head -c 240)"
fi

# rc != 0/1: no single in-progress story or ambiguous. Confirm with the BACKLOG row count (table rows only, never the
# prose that explains the marker), so we block the CONFIDENT "no story" case and fail-open on genuine ambiguity.
_bl="$PROJECT_DIR/Stories/BACKLOG.md"
[ -f "$_bl" ] || exit 0
_ip="$(grep -cE '^[[:space:]]*\|.*In-progress' "$_bl" 2>/dev/null || true)"; _ip="${_ip:-0}"
[ "$_ip" = "0" ] && block "there is NO in-progress story."
exit 0   # a story is in progress but the oracle was ambiguous -> fail-open (never wedge on uncertainty)
