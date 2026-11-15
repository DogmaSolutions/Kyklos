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

# Whether the doctor surface is on: the same decision, from the same source (the environment the hook was started with),
# as the doctor and the token hook make, taken BEFORE standards.env is loaded (which overrides the environment).
# shellcheck source=lib/session-health.sh
. "$HERE/lib/session-health.sh" 2>/dev/null || true
doctor_reports=0; kyklos_doctor_on 2>/dev/null && doctor_reports=1

# Load per-project config (STORY_BACKEND, STORY_GITLAB_PROJECT, token env) — PARSE, never source (CWE-829). The loader
# EXPORTs, so the `story` child below inherits the backend + credentials it needs to reach GitLab.
. "$HERE/lib/standards-env.sh" 2>/dev/null && load_standards_env "$PROJECT_DIR/.claude/standards.env" 2>/dev/null || true

# The stale-store warning is a health finding the doctor surface (kyklos-doctor-surface.sh) reports itself, reading the stale
# marker at its start; with the doctor on (the default) this hook keeps refreshing but leaves that line out of its output.
# One case it still says itself: a refresh that marks the mirror stale NOW, since the doctor may have read the marker before
# this refresh ran, so that warning is never lost. KYKLOS_DOCTOR_SURFACE=off prints everything as before.

[ "${STORY_BACKEND:-local}" = gitlab ] || exit 0     # local backend: nothing to mirror
[ -d "$PROJECT_DIR/Stories" ] || exit 0              # no story tree: nothing to refresh

STATE="${KYKLOS_STATE_DIR:-/tmp/kyklos-state}"; mkdir -p "$STATE" 2>/dev/null || true
marker="$STATE/story-mirror-refreshed"
[ -f "$marker" ] && exit 0                            # once per container lifetime
touch "$marker" 2>/dev/null || true

STORY="$HERE/../skills/ssdlc-story/story"
[ -f "$STORY" ] || exit 0

# `story refresh` prints its own STALE warning when GitLab is unreachable; swallow rc so SessionStart never wedges.
if [ "$doctor_reports" -eq 1 ]; then
    was_stale=0; [ -f "$PROJECT_DIR/Stories/.mirror-stale" ] && was_stale=1
    refresh_out="$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$STORY" refresh --dir "$PROJECT_DIR/Stories" 2>&1)"
    printf '%s\n' "$refresh_out" | grep -v -e 'may be STALE' -e 'GitLab unreachable at refresh' | grep -v '^$' || true
    if [ "$was_stale" -eq 0 ] && [ -f "$PROJECT_DIR/Stories/.mirror-stale" ]; then
        printf '%s\n' "$(kyklos_mirror_stale_text)"
    fi
else
    CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$STORY" refresh --dir "$PROJECT_DIR/Stories" 2>&1 || true
fi
exit 0
