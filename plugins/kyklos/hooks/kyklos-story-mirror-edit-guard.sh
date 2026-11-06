#!/usr/bin/env bash
# kyklos-story-mirror-edit-guard.sh - PreToolUse(Write|Edit|MultiEdit). When the story source-of-truth is GitLab
# (STORY_BACKEND=gitlab), the on-disk Stories/ files are GENERATED PROJECTIONS of the GitLab issues (each carries a
# "GENERATED MIRROR - DO NOT EDIT" banner). Block a hand Write/Edit of those files so an agent cannot bypass the
# `story` commands and hand-author a backlog that silently diverges from the source of truth - the exact failure a
# fleet agent hit (it wrote BACKLOG.md / requirements.md by hand instead of using the SSDLC commands).
#
# WHY this catches only the mistake, never the tool: the `story` tool writes these files through Bash redirection
# (`_gl_write_requirements`, backlog regeneration), NOT through the Claude Write/Edit tool - so it is UNAFFECTED.
# Only a DIRECT agent Write/Edit of a mirror file is caught. tasks.md is agent-editable working notes (the tool seeds
# it once and never clobbers agent edits), so it is deliberately NOT blocked.
#
# Scope: BACKLOG.md and each STORY-*/requirements.md under a Stories/ directory (by path shape), PLUS any existing
# file whose head carries the literal '<!-- GENERATED MIRROR' banner at any path (defense-in-depth / future mirror
# types). Local-backend repos are untouched: there requirements.md IS the durable record and the agent legitimately
# authors the spec there.
#
# FAIL-OPEN (allow): jq missing, no file_path, not the gitlab backend, or the target is not a mirror file.
# One-shot override (a deliberate, rare manual fix): bash hooks/lib/override-marker.sh set mirror-edit-ok <repo-dir> in a SEPARATE prior
# step (a PreToolUse hook evaluates before the tool runs), then retry; the marker is consumed after one allow.
#
# Wired: PreToolUse, matcher Edit|Write|MultiEdit.
# [json-answer-required] Every answer this hook reads goes through the JSON reader; without it a check would exit 127
# and fall into a fail-open path, so the hook refuses by name instead (a broken install). [CySec] CWE-636
. "$(dirname "${BASH_SOURCE[0]}")/lib/json-answer.sh" 2>/dev/null
if ! command -v json_test >/dev/null 2>&1; then
    printf '{"decision":"block","reason":"BLOCKED (%s): the JSON reader hooks/lib/json-answer.sh did not load (broken install), so this check cannot run. Reinstall or repin the kyklos plugin."}\n' "$(basename "$0")"
    exit 0
fi
set +e -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/override-marker.sh"   # override_take: the scoped, expiring one-shot override
OK_NAME=mirror-edit-ok
OK_SCOPE_HINT="<repo-dir>"

INPUT="$(cat || true)"

command -v jq >/dev/null 2>&1 || { echo "[kyklos] WARNING: story-mirror-edit guard INERT - jq is missing; hand-edit protection of the generated story mirror is NOT enforced. Install jq." >&2; exit 0; }

fp="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)"
[ -n "$fp" ] || exit 0

# Is the target a GENERATED mirror file? TWO detection paths (defense-in-depth):
#  (1) PATH SHAPE - the canonical mirror locations, matched even for a not-yet-existing file the agent is about to
#      hand-create (BACKLOG.md / STORY-*/requirements.md under a Stories/ dir).
#  (2) BANNER - an EXISTING file whose head carries the literal '<!-- GENERATED MIRROR' banner, at ANY path. This
#      future-proofs the guard: a new mirror TYPE (or a mirror at a non-standard path) is protected the moment it
#      carries the banner, with no change to this matcher. Matched PRECISELY (the HTML-comment banner at line start)
#      so a file that merely MENTIONS the phrase in prose or a code comment is never false-blocked.
# tasks.md is intentionally excluded from (1) (agent working notes) and never carries the (2) banner either.
is_mirror=0
case "$fp" in
    */Stories/BACKLOG.md|Stories/BACKLOG.md)                 is_mirror=1 ;;
    */Stories/STORY-*/requirements.md|Stories/STORY-*/requirements.md) is_mirror=1 ;;
esac
# The banner test is the story tool's single definition (its opening lines only, here the first 3).
_mirror_lib="$(dirname "${BASH_SOURCE[0]}")/../skills/ssdlc-story/lib/story-mirror-git.sh"
# shellcheck source=../skills/ssdlc-story/lib/story-mirror-git.sh
[ -f "$_mirror_lib" ] && . "$_mirror_lib"
if [ "$is_mirror" = 0 ] && [ -f "$fp" ] && command -v _story_generated_files >/dev/null 2>&1 \
    && [ -n "$(STORY_MIRROR_BANNER_LINES=3 _story_generated_files "$fp")" ]; then
    is_mirror=1
fi
[ "$is_mirror" = 1 ] || exit 0

# Only enforce when the story SSoT is GitLab (the FS files are a projection). Load the project's declared backend the
# SAME way the story tool + sibling guards do. PARSE, never source (CWE-829): a malformed line must not execute.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
# A project directory inside a companion's nested source (CLAUDE_PROJECT_DIR or the session working directory) is
# resolved to the companion root, where Stories/ and .claude/ live.
. "$(dirname "${BASH_SOURCE[0]}")/lib/repo-role.sh" 2>/dev/null && PROJECT_DIR="$(repo_companion_root "$PROJECT_DIR")"
_se="$(dirname "${BASH_SOURCE[0]}")/lib/standards-env.sh"
if [ -z "${STORY_BACKEND:-}" ] && [ -f "$_se" ]; then
    # shellcheck source=lib/standards-env.sh
    . "$_se" 2>/dev/null && load_standards_env "$PROJECT_DIR/.claude/standards.env" 2>/dev/null || true
fi
[ "${STORY_BACKEND:-local}" = gitlab ] || exit 0

# One-shot override: a deliberate manual fix. Consume it and allow.
if override_take "$OK_NAME" "$(override_scope_of "$(dirname "$fp")")" "$INPUT"; then
    echo "[kyklos] story-mirror-edit override consumed for '$(basename "$fp")' - allowing this one hand-edit of the generated mirror." >&2
    exit 0
fi

base="$(basename "$fp")"
reason="BLOCKED: '$base' is a GENERATED MIRROR of the GitLab story source-of-truth (STORY_BACKEND=gitlab). Hand-editing it makes the on-disk backlog diverge from the issues and is silently overwritten on the next refresh - so a hand-authored backlog is NOT real work and gets lost. Do NOT author it by hand; use the story commands (story --help, or the SessionStart tool catalog, lists them with their flags): story new to open a story, story requirements <id> --file <f> to author its spec, story set for a field, story proof for the proof, story close to close it. Re-project the on-disk mirror from GitLab with: story refresh (or story materialize <id>). Tool-first norm (GOVERNANCE F10): look before you leap -- use the story tool, do not hand-craft. Deliberate one-off exception: bash $OVERRIDE_MARKER_CLI set $OK_NAME $OK_SCOPE_HINT in a SEPARATE prior step, then retry."
reason="${reason//\\/\\\\}"; reason="${reason//\"/\\\"}"; reason="$(printf '%s' "$reason" | tr '\n' ' ')"
printf '{"decision":"block","reason":"%s"}' "$reason"
exit 0
