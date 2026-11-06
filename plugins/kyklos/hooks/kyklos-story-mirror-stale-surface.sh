#!/usr/bin/env bash
# kyklos-story-mirror-stale-surface.sh — PostToolUse(Read). When the agent reads a Stories/ MIRROR file while that
# mirror is known STALE (a `.mirror-stale` marker is present, dropped by `story refresh` on an unreachable SoT or by
# `story check` on drift), surface a loud warning so a stale Status/phase/branch read is never silent (an
# observed failure: a mid-session read returned "Todo" for an In-progress story). Advisory only — PostToolUse never blocks.
set +e -uo pipefail
command -v jq >/dev/null 2>&1 || exit 0
INPUT="$(cat || true)"
fp="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)"
[ -n "$fp" ] || exit 0
case "$fp" in */Stories/*) ;; *) exit 0 ;; esac
sdir="${fp%%/Stories/*}/Stories"
[ -f "$sdir/.mirror-stale" ] || exit 0
printf '[kyklos] STORY MIRROR MAY BE STALE — you just read %s, but the Stories/ mirror is flagged out of sync with GitLab (the source of truth). Re-run `story refresh` before trusting its Status/phase/branch. Detail: %s\n' \
  "$fp" "$(head -c 300 "$sdir/.mirror-stale" 2>/dev/null | tr '\n' ' ')" >&2
exit 0
