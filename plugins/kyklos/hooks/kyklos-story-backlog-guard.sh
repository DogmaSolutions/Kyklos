#!/usr/bin/env bash
# kyklos-story-backlog-guard.sh — Stop hook that keeps the Stories/ backlog CONSISTENT, so the story workflow is a real
# constraint (rung-3 guard) rather than documentation only. Blocks a session from ending while any of these hold:
#   - a STORY-*/ folder is missing requirements.md or tasks.md   (an incomplete story)
#   - a STORY-*/ folder has no row/link in BACKLOG.md             (an orphan not in the index)
#   - a BACKLOG.md link points to a non-existent STORY-*/ folder  (a dangling index row)
#   - more than one In-progress (🔵) story without its own branch (parallel work needs a story-named branch each),
#     or more In-progress stories than KYKLOS_MAX_IN_PROGRESS (default 8)
# No-op when Stories/ does not exist (legacy PLAN.md repos). Safety valve prevents a wedged Stop loop.
# [json-answer-required] Every answer this hook reads goes through the JSON reader; without it a check would exit 127
# and fall into a fail-open path, so the hook refuses by name instead (a broken install). [CySec] CWE-636
. "$(dirname "${BASH_SOURCE[0]}")/lib/json-answer.sh" 2>/dev/null
if ! command -v json_test >/dev/null 2>&1; then
    printf '{"decision":"block","reason":"BLOCKED (%s): the JSON reader hooks/lib/json-answer.sh did not load (broken install), so this check cannot run. Reinstall or repin the kyklos plugin."}\n' "$(basename "$0")"
    exit 0
fi
set -e +u -o pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
# A project directory inside a companion's nested source (CLAUDE_PROJECT_DIR or the session working directory) is
# resolved to the companion root, where Stories/ and .claude/ live.
. "$(dirname "${BASH_SOURCE[0]}")/lib/repo-role.sh" 2>/dev/null && PROJECT_DIR="$(repo_companion_root "$PROJECT_DIR")"
# Load per-project config so this guard sees the SAME story-backend selection (STORY_BACKEND + STORY_GITLAB_*)
# the story tool and the other guards do — without it the gitlab backend is invisible here and the backlog is
# read only from the (absent) on-disk file, silently no-opping the In-progress invariant.
_cfg="$PROJECT_DIR/.claude/standards.env"
# PARSE, never source (CWE-829): a malformed line can't execute (would mis-resolve the story backend + spam the TUI).
. "$(dirname "${BASH_SOURCE[0]}")/lib/standards-env.sh"; load_standards_env "$_cfg"
STORIES_DIR="$PROJECT_DIR/Stories"

INPUT="$(cat || true)"
if printf '%s' "$INPUT" | grep -cE '"stop_hook_active"[[:space:]]*:[[:space:]]*true' >/dev/null; then
    exit 0
fi

# Column-position-independent Status reading + the story-backend seam. Sourced FIRST (the backlog to judge now
# depends on the backend). Fail-open if the shared lib is somehow absent (a broken deploy must never wedge Stop).
_bl="$(dirname "${BASH_SOURCE[0]}")/lib/backlog-lib.sh"
# [no-fail-open] a missing lib is a broken install — surface it LOUDLY (still exit 0 so Stop never wedges).
if [ -f "$_bl" ]; then . "$_bl"; else echo "[kyklos] WARNING: story-backlog guard INERT this Stop — backlog-lib.sh missing ($_bl), a broken plugin install; the In-progress invariant is NOT enforced. Reinstall kyklos." >&2; exit 0; fi

# Which story backend is active, and the BACKLOG.md to judge: the on-disk index (local) or a projection
# materialized from the GitLab issues (gitlab). Empty => nothing to enforce (no Stories/, or GitLab unreachable)
# — fail-open, no-op. The folder-structural checks below are LOCAL-only (with the GitLab backend the stories ARE
# issues: there are no folders, so only the backend-meaningful In-progress invariant applies).
MODE="$(story_backend_mode)"
BACKLOG="$(resolve_backlog "$PROJECT_DIR")"
# The gitlab backend materializes the index into a per-Stop temp file whose PATH is returned here; clean it
# on exit so a long-lived container does not accumulate one backlog-gl.* temp per Stop. Pattern-guarded to the gitlab
# temp so the real on-disk Stories/BACKLOG.md (local mode) is NEVER deleted.
case "$BACKLOG" in */backlog-gl.*) trap 'rm -f "$BACKLOG" 2>/dev/null' EXIT ;; esac
[ "$MODE" = local ] && { [ -d "$STORIES_DIR" ] || exit 0; }
# [no-fail-open] resolve_backlog returns the __BACKLOG_UNREACHABLE__ sentinel when the gitlab backend is
# CONFIGURED but the index could not be built (API error/unreachable). The In-progress invariant is
# then UNVERIFIABLE — fail CLOSED (block) with a one-shot LOGGED override (spend-first, mirroring
# kyklos-merge-green-guard), never a silent no-op. A genuinely-empty backlog (empty string) and the local/
# unconfigured paths still no-op below.
if [ "$BACKLOG" = "__BACKLOG_UNREACHABLE__" ]; then
    . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/override-marker.sh"   # override_take: the scoped, expiring one-shot override
    override_take backlog-ok "$(override_hook_scope "$INPUT")" "$INPUT" && { echo "[kyklos] backlog gate: OVERRIDDEN once (backlog-ok spent) — the In-progress invariant was NOT verified (GitLab unreachable)." >&2; exit 0; }
    _r="BLOCKED: the GitLab story backend is CONFIGURED but UNREACHABLE, so the In-progress invariant (a story-named branch per parallel story, at most KYKLOS_MAX_IN_PROGRESS, see lib/backlog-lib.sh) cannot be verified — a session must not end in an unverifiable workflow state. Wait for GitLab and re-run; or if you have INDEPENDENTLY confirmed the In-progress stories respect that invariant, override once: bash $OVERRIDE_MARKER_CLI set backlog-ok <your-working-folder>"
    _r="${_r//\\/\\\\}"; _r="${_r//\"/\\\"}"; _r="$(printf '%s' "$_r" | tr '\n' ' ')"
    printf '{"decision":"block","reason":"%s"}' "$_r"
    exit 0
fi
{ [ -n "$BACKLOG" ] && [ -f "$BACKLOG" ]; } || exit 0

problems=""
add() { problems="${problems}; $1"; }

if [ "$MODE" = local ]; then
    # Every real story folder must be complete AND indexed.
    for dir in "$STORIES_DIR"/STORY-*/; do
        [ -d "$dir" ] || continue
        name="$(basename "$dir")"
        [ -f "$dir/requirements.md" ] || add "$name/ is missing requirements.md"
        [ -f "$dir/tasks.md" ]        || add "$name/ is missing tasks.md"
        grep -qF "$name" "$BACKLOG"   || add "$name/ has no row in BACKLOG.md"

        # Poka-yoke — CLOSURE LIMBO: a story with EVERY task checked [x] (>=1) but STILL not Done and with an
        # UNFILLED ## Proof is finished-but-never-closed. The story-proof gate only intercepts the Done-transition,
        # so a story whose work is done but which is left In-progress (or whose "done" was only DECLARED, never
        # closed) slips through invisibly. Flag it so a completed story MUST close through the proof gate.
        # (`grep -c` prints its count AND exits 1 on zero matches — swallow that with `|| true`, never `|| echo 0`
        # which would DOUBLE the value and break the numeric test.)
        if [ -f "$dir/tasks.md" ] && [ -f "$dir/requirements.md" ]; then
            _open="$(grep -cE '^[[:space:]]*- \[ \]' "$dir/tasks.md" 2>/dev/null || true)"; _open="${_open:-0}"
            _chk="$(grep -cE '^[[:space:]]*- \[[xX]\]' "$dir/tasks.md" 2>/dev/null || true)"; _chk="${_chk:-0}"
            _pf="$(grep -cE 'PROVEN|NOT_PERTINENT' "$dir/tasks.md" 2>/dev/null || true)"; _pf="${_pf:-0}"
            if [ "$_open" -eq 0 ] && [ "$_chk" -ge 1 ] && [ "$_pf" -eq 0 ]; then
                _st="$(grep -iE '^[[:space:]]*-[[:space:]]*\*\*Status:\*\*' "$dir/requirements.md" 2>/dev/null | head -1 | sed -E 's/.*Status:\*\*[[:space:]]*//I; s/[[:space:]].*//')"
                case "$_st" in
                    Done|Parked|Blocked|Archived|"") : ;;   # closed / paused / legacy (pre-gate) — not our concern
                    *) add "$name has all $_chk tasks checked but its ## Proof is EMPTY and Status is '$_st' — a finished story MUST close through the proof gate, not be declared done in passing. Run 'story proof $name --write', fill each dimension with change-anchored evidence, SHOW the proof ('story proof $name --format text' in the terminal), then close it with 'story close <id>' (see the ssdlc-story skill), never by setting the Status by hand." ;;
                esac
            fi
        fi
    done

    # Every BACKLOG *markdown link* to a story folder must resolve to a real folder.
    # Match only actual link targets `](STORY-xxx/…)` — NOT bare prose like "STORY-aaa/bbb",
    # which the old greedy pattern mis-parsed as a folder reference (false-positive block).
    while IFS= read -r ref; do
        [ -z "$ref" ] && continue
        [ -d "$STORIES_DIR/$ref" ] || add "BACKLOG.md links to a missing story folder: $ref"
    done < <(grep -oE '\]\(STORY-[A-Za-z0-9-]+/' "$BACKLOG" 2>/dev/null | sed -E 's:^\]\(::; s:/$::' | sort -u)
fi

# In-progress means somebody is working on the story (count only table rows; Status may be any column). Applies to BOTH
# backends. One In-progress story is always fine. Several are allowed only when all of them but one are worked on their
# own story-named branch (parallel sub-agents), and never more than the ceiling KYKLOS_MAX_IN_PROGRESS (default 8).
inprogress="$(backlog_count_status "$BACKLOG" '[Ii]n[- ]?[Pp]rogress')"
if [ "${inprogress:-0}" -gt 1 ]; then
    _ceiling="$(backlog_max_in_progress)"
    if [ "$inprogress" -gt "$_ceiling" ]; then
        add "BACKLOG.md has $inprogress In-progress (🔵) stories, more than the ceiling KYKLOS_MAX_IN_PROGRESS=$_ceiling — finish or pause some, or raise the ceiling in .claude/standards.env"
    else
        _repos=("$PROJECT_DIR")
        [ -n "${KYKLOS_SOURCE_DIR:-}" ] && _repos+=("$PROJECT_DIR/$KYKLOS_SOURCE_DIR")
        _unbound=""; _nunbound=0
        while IFS= read -r _id; do
            [ -n "$_id" ] || continue
            story_branch_bound "$_id" "${_repos[@]}" && continue
            _unbound="${_unbound}${_unbound:+, }STORY-$_id"; _nunbound=$((_nunbound + 1))
        done < <(backlog_inprogress_ids "$BACKLOG")
        if [ "$_nunbound" -gt 1 ]; then
            add "BACKLOG.md has $inprogress In-progress (🔵) stories and $_nunbound of them ($_unbound) have no branch of their own — several stories may be In-progress at once only when all but one are worked on their own story-named branch (feature/story-<n>-<slug>); create that branch for the story being worked, or set the others back to Todo"
        fi
    fi
fi

# The remaining checks bind a BACKLOG row to on-disk story FOLDERS (folder-per-row, scenario file, projection
# drift) — meaningful for the LOCAL backend only. With the GitLab backend a story is an issue with no folder, so
# the materialized projection is authoritative and these would false-block; skip them.
if [ "$MODE" = local ]; then
    # A story ROW marked ✅ Done or 🔵 In-progress must have a matching STORY-*/ folder (to hold
    # requirements.md + tasks.md + the `## Proof` table) — otherwise a bare BACKLOG row could be "closed"
    # bypassing the proof gate entirely. Rows carrying an inline `<!-- no-folder-ok -->` marker are exempt
    # (historical/trivial stories that legitimately have no folder — a deliberate, reviewable escape).
    while IFS= read -r row; do
        # Enforce on rows whose STATUS is Done or In-progress — column-position independent + prose-safe (a Notes
        # cell mentioning "done"/"in-progress" mid-sentence does not START a cell with the token).
        backlog_row_has_status "$row" '[Dd]one|[Ii]n[- ]?[Pp]rogress' || continue
        printf '%s' "$row" | grep -cF '<!-- no-folder-ok' >/dev/null && continue   # prefix match: allow '<!-- no-folder-ok: <reason> -->'
        id="$(printf '%s' "$row" | grep -oE 'STORY-[0-9]+' | head -1)"
        [ -z "$id" ] && continue
        ls -d "$STORIES_DIR/$id"-*/ >/dev/null 2>&1 || add "$id is ✅/🔵 in BACKLOG.md but has no STORY-*/ folder for its requirements.md + tasks.md + Proof table — create it, or add '<!-- no-folder-ok -->' if it legitimately has none"
    done < <(grep -E '^\|' "$BACKLOG")

    # Scenario declaration (multi-SLNX): in a scenario-enabled project (has scenarios/), the In-progress
    # story MUST name the one working scenario it targets — a `**Scenario:**` field in its requirements.md.
    # No-op for any project without scenarios/ (single-repo / non-.NET are unaffected).
    if [ -d "$PROJECT_DIR/scenarios" ]; then
        while IFS= read -r row; do
            backlog_row_has_status "$row" '[Ii]n[- ]?[Pp]rogress' || continue
            id="$(printf '%s' "$row" | grep -oE 'STORY-[0-9]+' | head -1)"
            [ -z "$id" ] && continue
            req="$(ls -d "$STORIES_DIR/$id"-*/ 2>/dev/null | head -1)requirements.md"
            grep -qiE '\*\*Scenario:\*\*[[:space:]]*[A-Za-z0-9]' "$req" 2>/dev/null \
                || add "$id is In-progress but declares no '**Scenario:**' (this project uses scenarios/) — name the scenarios/<slug>-scenario.md it targets"
        done < <(grep -E '^\|' "$BACKLOG")
    fi

    # When the backlog is a GENERATED projection (it has a _backlog-header.md) and the `story` tool is present,
    # verify the projection still matches the folders. `story check` exits 3 on CONFIRMED drift (2 on a usage
    # error, 0 on match) — treat ONLY 3 as drift so a tool bug / missing dep fails OPEN, never wedging the Stop.
    # The fix is one mechanized command: `story sync`.
    _story="$(dirname "${BASH_SOURCE[0]}")/../skills/ssdlc-story/story"
    if [ -f "$STORIES_DIR/_backlog-header.md" ] && [ -x "$_story" ]; then
        _rc=0; "$_story" check --dir "$STORIES_DIR" >/dev/null 2>&1 || _rc=$?
        [ "$_rc" -eq 3 ] && add "BACKLOG.md has drifted from the story folders — run 'story sync' to regenerate it (the index is generated; never hand-edit the table)"
    fi
fi

if [ -n "$problems" ]; then
    reason="BLOCKED: Stories backlog is inconsistent — fix before finishing:${problems}. (See the 'ssdlc-story' skill.)"
    # Full 3-step JSON escape (backslash, quote, flatten newlines) — a '\' or newline in an agent-edited field
    # would otherwise emit invalid JSON and the block would be dropped.
    reason="${reason//\\/\\\\}"; reason="${reason//\"/\\\"}"; reason="$(printf '%s' "$reason" | tr '\n' ' ')"
    printf '{"decision":"block","reason":"%s"}' "$reason"
    exit 0
fi

exit 0
