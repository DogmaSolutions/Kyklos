#!/usr/bin/env bash
# kyklos-story-mirror-refresh.sh — SessionStart. Under the GITLAB story backend the local Stories/ tree is a DERIVED,
# portable, offline MIRROR of GitLab (the source of truth) — it must NEVER silently drift. So ONCE per container, at
# session start, refresh the mirror from the SoT via `story refresh`:
#   - GitLab REACHABLE   -> re-render every requirements.md + rebuild BACKLOG.md from the live issues (fresh Status).
#   - GitLab UNREACHABLE -> keep the last-good mirror but SAY SO on stderr (never a silent stale pass), drop a marker.
# No-op under the LOCAL backend (there the files ARE the record) and when there is no Stories/ dir. FAIL-OPEN: any
# error is swallowed so a transient can never block SessionStart. Wired: SessionStart.
set +e -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
# A project directory inside a companion's nested source (CLAUDE_PROJECT_DIR or the session working directory) is
# resolved to the companion root, where Stories/ and .claude/ live.
. "$(dirname "${BASH_SOURCE[0]}")/lib/repo-role.sh" 2>/dev/null && PROJECT_DIR="$(repo_companion_root "$PROJECT_DIR")"

# Load per-project config (STORY_BACKEND, STORY_GITLAB_PROJECT, token env) — PARSE, never source (CWE-829). The loader
# EXPORTs, so the `story` child below inherits the backend + credentials it needs to reach GitLab.
. "$HERE/lib/standards-env.sh" 2>/dev/null && load_standards_env "$PROJECT_DIR/.claude/standards.env" 2>/dev/null || true

[ "${STORY_BACKEND:-local}" = gitlab ] || exit 0     # local backend: nothing to mirror
[ -d "$PROJECT_DIR/Stories" ] || exit 0              # no story tree: nothing to refresh

STATE="${KYKLOS_STATE_DIR:-/tmp/kyklos-state}"; mkdir -p "$STATE" 2>/dev/null || true
marker="$STATE/story-mirror-refreshed"
[ -f "$marker" ] && exit 0                            # once per container lifetime
touch "$marker" 2>/dev/null || true

STORY="$HERE/../skills/ssdlc-story/story"
[ -f "$STORY" ] || exit 0

# `story refresh` prints its own STALE warning when GitLab is unreachable; swallow rc so SessionStart never wedges.
CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$STORY" refresh --dir "$PROJECT_DIR/Stories" 2>&1 || true
exit 0
