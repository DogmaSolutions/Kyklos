#!/usr/bin/env bash
# backlog-lib.sh — shared BACKLOG.md Status-column reading for the story guards.
#
# The Status cell can be in ANY column: the infra repo uses narrow `| id | Status | branch | summary |`
# tables where Status is field 3, but the companion uses WIDE `| Story | Project | Epic | Branch | Status |
# Notes |` tables where Status is field 5. A hardcoded awk `$3` therefore reads the wrong column in wide
# tables and every Status check silently no-ops (fail-open) — this is how the Tier-0 proof gate + the backlog
# consistency checks were bypassed on the companion. Three guards each had their own copy of the parse; two
# were fixed and one was not, so the bug recurred. This is the SINGLE source of truth.
#
# The Status cell also STARTS WITH a status glyph (✅/🔵/⬜/⛔/🟡). We identify it as the cell that, after
# stripping the leading non-letter glyph+spaces, is EXACTLY the status word (only trailing whitespace after it):
# `^(Done)[[:space:]]*$`. This (a) never depends on a fixed field index, (b) never matches a multibyte glyph by
# bytes (the locale byte-vs-char trap), and (c) is PROSE-SAFE where a mere "starts-with" is not — a Notes cell
# that begins "DONE <a date> ..." or "In-progress spike ..." has non-space content after the word, so it is
# NOT mistaken for the Status cell (the earlier bug: hardcoded $3, and a loose starts-with, both misfired). This
# relies on the convention that a BACKLOG Status cell holds ONLY the status word (+ its glyph), not free prose.
#
# Status EREs to pass: '[Dd]one' | '[Ii]n[- ]?[Pp]rogress' | '[Tt]odo' | '[Bb]locked' (or an alternation).

# backlog_row_has_status ROW STATUS_ERE -> exit 0 iff a cell of ROW, after stripping the leading glyph, is
# exactly STATUS_ERE (+ trailing whitespace). Column-position independent + prose-safe.
backlog_row_has_status() {
    printf '%s\n' "$1" | awk -F'|' -v re="$2" '
        { for (i=1;i<=NF;i++){ s=$i; sub(/^[^A-Za-z]+/,"",s); if (s ~ ("^(" re ")[[:space:]]*$")) { f=1 } } }
        END { exit(f?0:1) }'
}

# backlog_count_status FILE STATUS_ERE -> count table rows whose Status cell is exactly STATUS_ERE.
backlog_count_status() {
    grep -E '^\|' "$1" 2>/dev/null | awk -F'|' -v re="$2" '
        { for (i=1;i<=NF;i++){ s=$i; sub(/^[^A-Za-z]+/,"",s); if (s ~ ("^(" re ")[[:space:]]*$")) { c++; break } } }
        END { print c+0 }'
}

# backlog_story_row FILE NUM -> the table row whose FIRST cell names story NUM (a `[STORY-<nnn>](...)` or `[<n>](...)` link,
# compared NUMERICALLY so zero-padding never matters). Empty when the story has no row. Used by the guards that must
# judge the story a branch NAMES (feature/story-<N>-...), not merely "some story is active".
backlog_story_row() {
    grep -E '^\|' "$1" 2>/dev/null | awk -F'|' -v n="$2" '
        { c=$2; if (match(c, /\[[^]0-9]*[0-9]+/)) { id=substr(c, RSTART, RLENGTH); gsub(/[^0-9]/, "", id);
          if (id+0 == n+0) { print; exit } } }'
}

# backlog_story_in_progress FILE NUM -> exit 0 iff story NUM has a row whose Status cell is In-progress.
backlog_story_in_progress() {
    local row; row="$(backlog_story_row "$1" "$2")"
    [ -n "$row" ] && backlog_row_has_status "$row" '[Ii]n[- ]?[Pp]rogress'
}

# --- parallel work: several In-progress stories, each bound to its own branch -------------------------------------
# "In-progress" means somebody is actually working on the story. Several stories may be In-progress at once when each
# extra one is worked on its own story-named branch (a sub-agent per story); a story without such a branch is the one
# a session forgot. These helpers are shared by the backlog guard and its tests.

# backlog_inprogress_ids FILE -> the story number (zero padding removed) of every In-progress row, one per line.
backlog_inprogress_ids() {
    local row
    grep -E '^\|' "$1" 2>/dev/null | while IFS= read -r row; do
        backlog_row_has_status "$row" '[Ii]n[- ]?[Pp]rogress' || continue
        printf '%s\n' "$row" | awk -F'|' '{ c=$2; if (match(c, /\[[^]0-9]*[0-9]+/) || match(c, /STORY-[0-9]+/)) {
            id=substr(c, RSTART, RLENGTH); gsub(/[^0-9]/, "", id); if (id != "") print id+0 } }'
    done
}

# story_branch_bound NUM DIR... -> exit 0 iff a branch named after story NUM (feature/story-<NUM>[-...] or
# hotfix/story-<NUM>[-...], zero padding ignored) exists in one of the git repositories DIR...: a local branch (which
# every worktree of that repository shares) or a remote-tracking branch. A repository that cannot be read adds nothing,
# so the story stays unbound (fail-closed: a doubt never lets an extra In-progress story pass).
story_branch_bound() {
    local n="${1:-}" d
    shift || true
    [[ "$n" =~ ^[0-9]+$ ]] || return 1
    n=$((10#$n))
    for d in "$@"; do
        [ -n "$d" ] || continue
        git -C "$d" for-each-ref --format='%(refname:short)' refs/heads refs/remotes 2>/dev/null \
            | sed -E 's#^[^/]+/((feature|hotfix)/)#\1#' \
            | grep -cE "^(feature|hotfix)/story-0*${n}(-|$)" >/dev/null && return 0
    done
    return 1
}

# backlog_max_in_progress -> the ceiling on In-progress stories: KYKLOS_MAX_IN_PROGRESS when it is a positive whole
# number, otherwise 8 (a value that is not a positive whole number is reported once on stderr).
backlog_max_in_progress() {
    local v="${KYKLOS_MAX_IN_PROGRESS:-}"
    if [ -z "$v" ]; then printf '8'; return 0; fi
    if [[ "$v" =~ ^[1-9][0-9]*$ ]]; then printf '%s' "$v"; return 0; fi
    printf '[kyklos] KYKLOS_MAX_IN_PROGRESS=%s is not a positive whole number; using 8.\n' "$v" >&2
    printf '8'
}

# --- backend seam (story workflow: filesystem OR GitLab issues) --------------------------------------
# The story guards must judge the SAME backlog the story tool writes. When a project keeps its stories as
# GitLab issues (STORY_BACKEND=gitlab, sourced from .claude/standards.env) there is no on-disk BACKLOG.md, so
# the guards would silently no-op and STOP enforcing the In-progress invariant (backlog_max_in_progress above).
# These helpers let every guard that sources this lib read the active backend uniformly.

BACKLOG_LIB_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# story_backend_mode -> 'gitlab' | 'local'. The selector the story tool uses (STORY_BACKEND), defaulting local.
story_backend_mode() { case "${STORY_BACKEND:-local}" in gitlab) printf 'gitlab' ;; *) printf 'local' ;; esac; }

# resolve_backlog PROJECT_DIR -> one of three answers:
#   a path      : a BACKLOG.md the guards can parse — local: the on-disk Stories/BACKLOG.md; gitlab: the index
#                 materialized from the story backend into a temp file (same table shape via the shared renderer).
#   __BACKLOG_UNREACHABLE__ : the gitlab backend is CONFIGURED but could not be read -> the caller FAILS CLOSED.
#   EMPTY       : nothing to enforce (mktemp failure, or a genuinely empty backlog) -> the guard no-ops. A missing or
#                 broken seam is a broken install: it answers __BACKLOG_UNREACHABLE__ (fail closed), naming the library.
#   The temp file lives for the process; the caller need not clean it.
resolve_backlog() {
    local pdir="$1" fs="$1/Stories/BACKLOG.md"
    if [ "$(story_backend_mode)" != gitlab ]; then printf '%s' "$fs"; return 0; fi
    local seam="$BACKLOG_LIB_HERE/../../skills/ssdlc-story/lib/story-backend.sh"
    local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/backlog-gl.XXXXXX" 2>/dev/null)" || { echo "[kyklos] WARNING: backlog gate — mktemp failed; backlog-consistency is NOT enforced." >&2; printf ''; return 0; }
    # Detect a CONFIGURED-but-UNREACHABLE backend via the explicit backend_reachable probe FIRST (exit 3):
    # backend_generate_index swallows a gl_api failure in its pipeline (returns rc 0 with no rows), which is
    # indistinguishable from a genuinely-empty project — so its rc alone cannot tell "unreachable" from "empty".
    # backend_reachable is the purpose-built signal (a JSON-array probe) both this and the story tool use.
    # A broken install (the seam missing or broken, or a library it RECORDED in STORY_LIB_LOAD_FAILED while still
    # returning success) answers exit 4 with the reason on stdout; require_story_seam reads both the seam's status and
    # the record, so every way the seam can be broken is judged alike.
    local _rc; ( STORY_SEAM_PROBLEM="cannot load $BACKLOG_LIB_HERE/require-lib.sh completely"
                 { . "$BACKLOG_LIB_HERE/require-lib.sh" 2>/dev/null \
                     && require_story_seam "$seam" backend_generate_index 2>/dev/null; } \
                   || { printf '%s' "$STORY_SEAM_PROBLEM"; exit 4; }
                 if command -v backend_reachable >/dev/null 2>&1 && ! backend_reachable "$pdir/Stories"; then exit 3; fi
                 backend_generate_index "$pdir/Stories" ) > "$tmp" 2>/dev/null; _rc=$?
    if [ "$_rc" -eq 4 ]; then
        # [no-fail-open] a broken install: the backlog cannot be read, so the In-progress invariant fails CLOSED as for
        # an unreachable backend, but the warning names the library instead of blaming the network.
        echo "[kyklos] WARNING: backlog gate — the story backend $(cat "$tmp" 2>/dev/null), a broken kyklos install (reinstall it); the In-progress invariant fails CLOSED this Stop (override: bash hooks/lib/override-marker.sh set backlog-ok <your-working-folder>)." >&2
        rm -f "$tmp" 2>/dev/null
        printf '__BACKLOG_UNREACHABLE__'; return 0
    fi
    if [ "$_rc" -eq 0 ] && grep -qE '^\|' "$tmp"; then
        printf '%s' "$tmp"
    elif [ "$_rc" -ne 0 ]; then
        # [no-fail-open] the gitlab backend is CONFIGURED but UNREACHABLE (exit 3), or the index build failed while
        # reachable — either way the In-progress invariant is UNVERIFIABLE. Emit a DISTINCT sentinel
        # (not an empty string, which the caller reads as "genuinely-empty = silent no-op") so the guard FAILS CLOSED
        # (blocks) with a one-shot override, rather than silently skipping the invariant.
        rm -f "$tmp" 2>/dev/null
        echo "[kyklos] WARNING: backlog gate — the GitLab story backend is CONFIGURED but could not be read (API error/unreachable); the In-progress invariant fails CLOSED this Stop (override: bash hooks/lib/override-marker.sh set backlog-ok <your-working-folder>)." >&2
        printf '__BACKLOG_UNREACHABLE__'
    else
        rm -f "$tmp" 2>/dev/null; printf ''   # rc 0 but no rows = genuinely empty backlog (no stories) — legit silent no-op
    fi
}
