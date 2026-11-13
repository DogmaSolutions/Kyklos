#!/usr/bin/env bash
# story-lib.sh — the backend-AGNOSTIC pure/format + read-only parse helpers for the `story` CLI.
# Sourced (transitively, via a backend impl) by the `story` tool AND directly by the test harness.
# No side effects on source: it only defines functions + a few readonly constants, and every helper here
# only READS (never mutates) — the mutating/orchestration logic lives in a backend impl (story-backend-fs.sh or
# story-backend-gitlab.sh), selected by the dispatcher (story-backend.sh). bash, coreutils/grep/sed/awk/sort/diff only.
#
# What lives here: the pure format helpers (emoji map, status normalize/rank, trim, escaping, one-lining,
# table-row/header/footer rendering) and the requirements.md field parsing — the building blocks both backends
# compose.
#
# Under the FS backend a story's state lives in its own requirements.md; the gitlab backend materializes the issue
# into the same requirements.md shape. This library parses that field block robustly (tolerant of real-world drift)
# so the index can be regenerated deterministically.

# --- Canonical vocabulary -----------------------------------------------------------------------

# Canonical field order for the requirements.md metadata block (written in THIS order).
_SL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=../../../hooks/lib/control-switch.sh
. "$_SL_DIR/../../../hooks/lib/control-switch.sh" 2>/dev/null || true   # kyklos_control_off: the one control-switch reader

STORY_FIELDS=(Status Story-Type Epic "Target repo" Branch Summary)

# Canonical status values, and their table emoji.
story_status_emoji() {
  # Normalizes case, then maps to the glyph. Unknown → the value verbatim (never crash).
  case "$(story_normalize_status "$1")" in
    Todo)        printf '⬜' ;;
    In-progress) printf '🔵' ;;
    Blocked)     printf '⛔' ;;
    Done)        printf '✅' ;;
    Parked)      printf '⏸' ;;                          # unified status:: scope
    Wontfix|Duplicate|Invalid) printf '🚫' ;;
    Archived)    printf '📦' ;;
    *)           printf '%s' "$1" ;;
  esac
}

# story_sanitize_inline VALUE -> VALUE with CR/LF collapsed to single spaces and trimmed.
# The NEWLINE is the metadata/table injection vector (a title or set-value with an embedded newline can forge
# BACKLOG rows and `- **Key:**` metadata lines). Pipes are handled at the CELL-emit seam
# (story_escape_cell), so legitimate '|' in prose still renders; only line structure is normalized here.
story_sanitize_inline() { printf '%s' "$1" | tr '\r\n' '  ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'; }

# Normalize a status value to its canonical capitalization, case-insensitively. Unknown → verbatim (trimmed).
story_normalize_status() {
  local v; v="$(story_trim "$1")"
  case "$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')" in
    todo)        printf 'Todo' ;;
    in-progress|doing) printf 'In-progress' ;;
    blocked)     printf 'Blocked' ;;
    done)        printf 'Done' ;;
    dropped)     printf 'Dropped' ;;
    parked)      printf 'Parked' ;;                    # open, user-deferred (unified status:: scope)
    wontfix|wont-fix) printf 'Wontfix' ;;              # terminal: closed as won't-fix
    duplicate)   printf 'Duplicate' ;;                 # terminal: closed as duplicate
    invalid)     printf 'Invalid' ;;                   # terminal: closed as invalid
    archived)    printf 'Archived' ;;                  # terminal: closed-story history retained
    *)           printf '%s' "$v" ;;
  esac
}

# story_status_valid STATUS -> rc 0 iff STATUS is a canonical lifecycle value. A set path that stores ANY value
# verbatim (e.g. 'Bananas') silently breaks every status-counting invariant. The set covers the open states, Parked
# (open, deferred) and the terminal reasons Wontfix/Duplicate/Invalid/Archived. (Dropped stays valid HERE for normalize/display of historical values; the
# SET path separately rejects it as ambiguous and points at the concrete reasons.)
story_status_valid() {
  case "$1" in Todo|In-progress|Blocked|Done|Dropped|Parked|Wontfix|Duplicate|Invalid|Archived) return 0 ;; *) return 1 ;; esac
}

# story_status_is_open_work STATUS -> rc 0 for a status that keeps the story's issue OPEN (work not finished).
story_status_is_open_work() {
  case "$1" in Todo|In-progress|Blocked|Parked) return 0 ;; *) return 1 ;; esac
}

# story_status_is_closed STATUS -> rc 0 for a status read from a CLOSED story (completed or dropped).
story_status_is_closed() {
  case "$1" in Done|Dropped|Wontfix|Duplicate|Invalid|Archived) return 0 ;; *) return 1 ;; esac
}

# The marker that records why a closed story was reopened; the re-close gate looks for it in a note posted after the
# last reopen. Written only by `story reopen-root-cause` (and `story set ... --reopen --reason`, which calls it).
STORY_REOPEN_ROOT_CAUSE_MARKER='Reopen-Root-Cause:'

# The open-before-done sort rank within an epic (lower sorts first).
story_status_rank() {
  case "$(story_normalize_status "$1")" in
    In-progress) printf '0' ;;
    Blocked)     printf '1' ;;
    Todo)        printf '2' ;;
    Done)        printf '3' ;;
    *)           printf '2' ;;  # unknown open-ish → with Todo
  esac
}

# --- String helpers -----------------------------------------------------------------------------

# Trim leading/trailing whitespace.
story_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Strip a trailing HTML comment ( <!-- ... --> ) from a value, then trim.
story_strip_comment() {
  local s="$1"
  s="$(printf '%s' "$s" | sed 's/<!--.*-->[[:space:]]*$//')"
  story_trim "$s"
}

# Collapse any newlines/CRs to single spaces and squeeze runs of whitespace (for a one-cell table value).
story_oneline() {
  printf '%s' "$1" | tr '\r\n' '  ' | sed 's/[[:space:]]\{1,\}/ /g; s/^ //; s/ $//'
}

# Escape a pipe so a value stays inside one Markdown table cell.
story_escape_cell() {
  local v; v="$(story_oneline "$1")"
  printf '%s' "${v//|/\\|}"
}

# --- requirements.md parsing --------------------------------------------------------------------

# Read one canonical field's value from a requirements.md file.
# $1 = file, $2 = field name (exact canonical label, e.g. "Target repo").
# Order-independent, tolerant of extra spaces and a trailing <!-- comment -->. Absent → empty string.
story_get_field() {
  local file="$1" field="$2" line raw
  [ -f "$file" ] || { printf ''; return 0; }
  # Match a bullet line: optional spaces, '-', spaces, '**Field:**', value. Field label match is exact.
  line="$(grep -m1 -iE "^[[:space:]]*[-*][[:space:]]+\*\*${field}:\*\*" "$file" 2>/dev/null || true)"
  [ -n "$line" ] || { printf ''; return 0; }
  # Cut everything up to and including the first '**...**' bold marker (the '**Field:**' label), then trim.
  raw="$(printf '%s' "$line" | sed -E 's/^[^*]*\*\*[^*]*\*\*[[:space:]]*//')"
  printf '%s' "$(story_strip_comment "$raw")"
}

# --- Parent-child stories ----------------------------------------------------------------
# A child story records its parent as a single canonical, tool-managed bullet in its metadata header:
#   - **Parent:** #<N>
# This bullet is the SOLE source of truth for the relationship. GitLab CE has no typed issue-parent link (the
# work-item hierarchy rejects an issue as the parent of an issue; Epics are Premium), and a `relates_to` link is
# symmetric/untyped so it cannot express direction. `story close` reads this bullet to auto-close
# a parent once ALL its children are closed. The field is written ONLY by the tool (story new --parent /
# story parent), never by hand (the mirror-edit guard forbids hand edits), and set/cycle-validated on write.

# story_parent_iid_from_body TEXT -> the parent issue number (bare digits) from the `- **Parent:** #<N>` line,
# or empty if none. Tolerant of an optional '#'. Reads the FIRST such line only.
story_parent_iid_from_body() {
  printf '%s\n' "$1" \
    | grep -m1 -iE '^[[:space:]]*[-*][[:space:]]+\*\*Parent:\*\*[[:space:]]*#?[0-9]+' \
    | grep -oE '#?[0-9]+' | head -1 | tr -d '#'
}

# story_parent_ref_normalize REF -> a bare positive integer from a parent ref given as `#N` or `N`; empty if
# REF is not a well-formed issue number, so a caller can FAIL-HARD on an invalid parent (never silently accept).
story_parent_ref_normalize() {
  local r; r="$(story_trim "$1")"; r="${r#\#}"
  case "$r" in ''|*[!0-9]*) printf '' ;; *) printf '%s' "$((10#$r))" ;; esac
}

# --- SSDLC phase order ------------------------------------------------------------------
# The canonical, ORDERED phase sequence a story advances through. The FIRST phase (the pre-Design
# structuring/authoring stage) is **Requirements**; **Prerequisites** is kept
# as a recognised LEGACY ALIAS for it (rank 0) so pre-rename stories/labels still resolve. Single source of truth
# for validation + the monotonic advance; backend_set_phase's mutual-exclusion remove-set derives from this too.
STORY_PHASE_ORDER="Requirements Design Implementation Testing Deployment Review"

# story_phase_canon PHASE -> canonical-cased phase name (case-insensitive match against STORY_PHASE_ORDER, plus
# the Prerequisites->Requirements legacy alias); empty if unknown.
story_phase_canon() {
  local want p; want="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  [ "$want" = prerequisites ] && { printf 'Requirements'; return 0; }
  for p in $STORY_PHASE_ORDER; do
    [ "$(printf '%s' "$p" | tr '[:upper:]' '[:lower:]')" = "$want" ] && { printf '%s' "$p"; return 0; }
  done
  printf ''
}

# story_phase_rank PHASE -> 0-based position in STORY_PHASE_ORDER (Requirements aliases to rank 0); empty if
# unknown. Used by the monotonic-advance guard (a forward-only advance never regresses the phase silently).
story_phase_rank() {
  local canon i=0 p; canon="$(story_phase_canon "$1")"; [ -n "$canon" ] || { printf ''; return 0; }
  for p in $STORY_PHASE_ORDER; do [ "$p" = "$canon" ] && { printf '%s' "$i"; return 0; }; i=$((i+1)); done
  printf ''
}

# story_phase_advance CURRENT TARGET -> the phase to set under a MONOTONIC (forward-only) advance: the LATER
# of CURRENT and TARGET by STORY_PHASE_ORDER rank, so an advance never regresses the phase. Rules:
#   - TARGET unknown            -> empty output + rc 2 (caller fails hard; never silently pick a phase).
#   - CURRENT unknown/empty     -> TARGET (a story with no phase yet simply enters TARGET).
#   - rank(TARGET) >= rank(CUR) -> TARGET (a real forward move, or a no-op if equal).
#   - rank(TARGET) <  rank(CUR) -> CURRENT (refuse to go backward; the caller treats "result == current" as a no-op).
# Canonical-cases the output. This is the pure decision; the tool/guard seam reads the current phase + writes the result.
story_phase_advance() {
  local cur tgt rc rt; tgt="$(story_phase_canon "$2")"
  [ -n "$tgt" ] || return 2
  cur="$(story_phase_canon "$1")"
  [ -n "$cur" ] || { printf '%s' "$tgt"; return 0; }
  rc="$(story_phase_rank "$cur")"; rt="$(story_phase_rank "$tgt")"
  if [ "$rt" -ge "$rc" ]; then printf '%s' "$tgt"; else printf '%s' "$cur"; fi
}

# The story id = folder basename. $1 = story dir.
story_id_from_dir() { basename "$1"; }

# Extract the numeric NNN from a story id/dir/basename (the FIRST STORY-<digits> run). Empty if none.
# Must anchor to the FIRST occurrence: a `.*STORY-...` sed is GREEDY and captures the LAST run, so a slug that
# references another story (STORY-NNN-fix-for-STORY-MMM) would resolve to MMM — poisoning sort keys, max_num
# (duplicate `new` numbers), resolve (wrong story), and the migrate map. grep|head isolates the first run;
# 10# forces base-10 so a leading-zero id (007) is not misread as octal.
story_num_from_id() {
  local m; m="$(printf '%s' "$1" | grep -oE 'STORY-[0-9]+' | head -n1)"
  [ -n "$m" ] || { printf ''; return 0; }
  printf '%s' "$((10#${m#STORY-}))"
}

# The zero-padded 3-digit number as it appears in the id (e.g. 007). Empty if none. Derived from the
# first-occurrence-safe story_num_from_id so it can never disagree with it (both anchor to the FIRST run).
story_num3_from_id() {
  local n; n="$(story_num_from_id "$1")"
  [ -n "$n" ] || { printf ''; return 0; }
  printf '%03d' "$n"
}

# --- SSDLC-story MINIMUM STRUCTURE --------------------------------------------------------
# Every SSDLC story (local OR GitLab) must contain these 7 items. Checked MECHANICALLY (no AI tokens): an item is
# PRESENT iff its canonical section marker appears in the story's combined text. The check runs on ONE combined
# string, so it is backend-agnostic: the caller passes the story body (backend_body_read) followed by its risk
# assessment (backend_ra_read), whichever backend serves them.
# [Poka-yoke] `story new`/materialize emits the _TEMPLATE carrying all 7 headers, so a tool-created story cannot
# lack them by construction; this checker catches a hand-authored or drifted story before it is worked/closed.
_story_has_section() { printf '%s\n' "$1" | LC_ALL=C grep -ciE "$2" >/dev/null; }

# story_min_structure_problem TEXT -> print each MISSING required-item name, one per line; empty output = conforms.
story_min_structure_problem() {
  local text="$1" items
  items="$(
    _story_has_section "$text" '^##[[:space:]]+Requirements([[:space:]]|$)'           || printf '%s\n' "Requirements"
    _story_has_section "$text" '^##[[:space:]]+Use cases'                             || printf '%s\n' "Use cases to test"
    _story_has_section "$text" '^##[[:space:]]+Failure modes'                         || printf '%s\n' "Failure modes handled"
    _story_has_section "$text" '^##[[:space:]]+Fail-open'                             || printf '%s\n' "Fail-open vs fail-hard"
    _story_has_section "$text" '^##[[:space:]]+Poka-?yoke'                            || printf '%s\n' "Poka-yoke"
    _story_has_section "$text" '^##[[:space:]]+Acceptance criteria'                   || printf '%s\n' "Acceptance criteria"
    _story_has_section "$text" '^#{1,3}[[:space:]].*[Rr]isk[[:space:]]+[Aa]ssessment' || printf '%s\n' "Risk assessment"
  )"
  [ -n "$items" ] && printf '%s\n' "$items"
  # [Poka-yoke] A story that carries a 2a-2f spec is also judged by the close gate's own rule (story_spec_unfilled
  # over story_spec_dims), so this work-time check can never pass a body the close later refuses. Only a line the
  # 7-item check above already printed is dropped (never a section it accepted under its looser heading match); a
  # legacy body without any spec header is grandfathered, exactly as at close.
  story_spec_unfilled "$text" \
    | sed -n -e 's/^MISSING dimension: //p' -e 's/^EMPTY dimension: \([^(]*[^ (]\) (.*/\1 (section has no content)/p' \
    | awk -v printed="$items" 'BEGIN{n=split(printed,k,"\n"); for(i=1;i<=n;i++) seen[k[i]]=1} !seen[$0]++'
}

# story_fix_class_problem <body> <story-type> -> print a REFUSAL when a fix-type story lacks a
# usable "## Fix the class" record, else nothing. A fix scoped to the single reproduction it saw is how the same
# defect recurs on the next call site (one path fixed, a sibling path missed) — so a
# fix story must record the INVARIANT that was violated and the call-site SWEEP (where else the same mistake could
# live + the chokepoint chosen so the whole class is closed). DEFAULT-ON: unset/blank/
# garbage PROOF_FIX_CLASS enforces; only an explicit off|0|false|no opts out. Non-fix story types are never gated.
story_fix_class_problem() {
  local text="$1" type="$2" verdict
  kyklos_control_off "${PROOF_FIX_CLASS:-}" && return 0
  case "$(printf '%s' "$type" | tr '[:upper:]' '[:lower:]')" in fix|hotfix) : ;; *) return 0 ;; esac
  # One reading of the section (fences and comments hidden, real text, a label with nothing after it records nothing),
  # the same as the bridge's FixTheClassGate: tests/fixtures/fix-class-cases.txt is read by both suites.
  verdict="$(printf '%s\n' "$text" | LC_ALL=C awk -f "$_SL_DIR/../../ssdlc-story-proof/real-text.awk" -f "$_SL_DIR/sl-fix-class.awk")"
  case "$verdict" in
    OK) return 0 ;;
    PLACEHOLDER) printf 'the "## Fix the class" section still holds unfilled <FILL: ...> placeholders: record the INVARIANT violated, the call-site SWEEP and the chokepoint' ;;
    BOTH) printf 'the "## Fix the class" section must name BOTH the INVARIANT violated AND the call-site SWEEP / chokepoint chosen, each with text written after its label' ;;
    *) printf 'a fix-type story must carry a "## Fix the class" section recording the INVARIANT violated and the call-site SWEEP (where else the same mistake could recur + the chokepoint that closes the whole class) — fix the class, not the instance' ;;
  esac
}

# --- Remote Truth: a close may only cite a deliverable the REMOTE actually has ---------------------------------
# A story closed as PROVEN while its commits existed only in a local checkout records "done" for work that had no
# effect. story_remote_truth_problem <repo_root> <cited> prints ONE refusal line when a deliverable cited in the
# story's Branch field (commits, branches, merge requests) is local-only or cannot be found, else nothing.
#
# A deliverable "exists on the remote" is NOT enough: it must be ON THE TRUNK (merged), never merely pushed to its
# own feature branch — a story closed while its merge request was still open records "done" for work that never
# shipped. The invariant for EVERY citation form is therefore "reachable from an integration trunk" (merged), not
# "the ref/MR exists".
#
# Recognised citation tokens (anything else is prose and ignored):
#   <sha>                7-40 hex chars (digit+letter, or any commit that resolves locally) -> must be reachable from an
#                        integration-trunk ref (main/master/develop) of <repo_root>, or merged on the story project's
#                        remote trunk (backend_commit_on_trunk)
#   <group/project>@<sha>                                         -> must be merged onto THAT project's trunk
#   <branch>             an existing LOCAL branch of <repo_root>  -> must be MERGED into an integration trunk, not just
#                        pushed (its tip is reachable from a remote trunk ref, OR a merged MR used it as source)
#                        (a trunk name next to a cited commit/MR is only its location, not separate evidence)
#   !<n> | <group/project>!<n>                                    -> that merge request must be MERGED
# Remote lookups are optional backend helpers (gitlab); without them only the local git evidence decides.
# Always on (no switch); the only exception is the shared Done-gate exception. Fail-CLOSED: evidence that cannot
# be verified is refused with the reason, never assumed good.
# _rt_is_sha <token> [<repo>] -> a commit id. Mixed digits+letters (7-40 hex) always count; an all-digit or all-letter
# hex token (a commit prefix can be all digits) counts only when it resolves to a commit in <repo>, so prose numbers
# and words stay prose.
_rt_is_sha() {
  printf '%s' "$1" | grep -ciE '^[0-9a-f]{7,40}$' >/dev/null || return 1
  if printf '%s' "$1" | grep -ciE '[a-f]' >/dev/null && printf '%s' "$1" | grep -cE '[0-9]' >/dev/null; then return 0; fi
  [ -n "${2:-}" ] && git -C "$2" cat-file -e "$1^{commit}" 2>/dev/null
}
_rt_is_project() { printf '%s' "$1" | grep -cE '^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$' >/dev/null; }   # group/[sub/]project, nothing else
# _rt_project_problem <kind> <project> <ref> -> why a cited project path is not usable, with the exact form to write.
# A bare project name (no group) is the common slip: it is named as such, with an example, because the same project
# name can exist in several groups and only the full path identifies one.
_rt_project_problem() {
  local kind="$1" proj="$2" ref="$3" sep='!'; [ "$kind" = commit ] && sep='@'
  if printf '%s' "$proj" | grep -cE '^[A-Za-z0-9._-]+$' >/dev/null; then
    printf 'cited %s %s%s%s names the project "%s" without its group: write the full project path, group/[subgroup/]project%s%s (for example my-group/%s%s%s)' \
      "$kind" "$proj" "$sep" "$ref" "$proj" "$sep" "$ref" "$proj" "$sep" "$ref"
  else
    printf 'cited %s %s%s%s names an invalid project path: use group/[subgroup/]project%s%s' "$kind" "$proj" "$sep" "$ref" "$sep" "$ref"
  fi
}
_rt_tokens() {  # <text> -> one citation token per line; split WITHOUT pathname expansion (read -a never globs)
  local -a toks; local t
  read -r -a toks <<< "$(printf '%s' "$1" | tr ',;()[]"`\n' '         ')"
  for t in ${toks[@]+"${toks[@]}"}; do t="${t%.}"; t="${t%:}"; printf '%s\n' "$t"; done
}
_rt_has_remote_refs() { [ -n "$(git -C "$1" for-each-ref --count=1 refs/remotes 2>/dev/null)" ]; }
_rt_local_only() {  # <repo> <rev> -> print the first commit of <rev> that no remote-tracking ref contains
  # A git error must never read as "nothing local-only" (that would pass unverified work): report <rev> itself.
  local out; out="$(git -C "$1" rev-list -1 "$2" --not --remotes 2>/dev/null)" || { printf '%s' "$2"; return 0; }
  printf '%s' "$out"
}
_rt_fetch() {  # <repo> -> one bounded, prompt-free fetch with prune from origin; its status is the fetch's
  GIT_TERMINAL_PROMPT=0 timeout 30 git -C "$1" fetch --quiet --no-tags --prune origin >/dev/null 2>&1
}
_rt_refresh_once() {  # best-effort fetch so stale remote-tracking refs do not cause a false refusal
  [ "${_RT_FETCHED:-0}" = 1 ] && return 0
  _RT_FETCHED=1
  _rt_fetch "$1" || true
}
# _story_item_lib_loaded -> rc 0 when the plugin's item-project.sh (the bridge's one repository resolver, from the
# container) is loaded, loading it once on first use.
_story_item_lib_loaded() {
  command -v item_trunk_refs_of >/dev/null 2>&1 && return 0
  local lib; lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../hooks/lib/item-project.sh"
  # shellcheck source=../../../hooks/lib/item-project.sh
  [ -f "$lib" ] && . "$lib" && command -v item_trunk_refs_of >/dev/null 2>&1
}

# _rt_trunk_refs <repo> -> the remote-tracking refs that count as an integration TRUNK (one per line): the trunks the
# bridge names from GitLab for the repository (item_trunk_refs_of: develop when GitLab has it, and the default branch);
# only when no bridge can say, origin/HEAD's target when set, plus origin/{main,master,develop}. A deliverable is
# "shipped" only when it is reachable from one of these, never merely from its own pushed feature branch.
_rt_trunk_refs() {
  local repo="$1" def ref named
  _story_item_lib_loaded && named="$(item_trunk_refs_of "$repo")" && { printf '%s\n' "$named" | sed '/^$/d'; return 0; }
  def="$(git -C "$repo" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)"   # e.g. origin/main
  [ -n "$def" ] && printf 'refs/remotes/%s\n' "$def"
  for ref in main master develop; do
    git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$ref" && printf 'refs/remotes/origin/%s\n' "$ref"
  done
}
# _rt_on_remote_trunk <repo> <rev> -> 0 when <rev> is an ancestor of (i.e. merged into) at least one remote trunk ref.
# This is the local-git proof of "merged", distinct from "pushed to some branch". A rev that resolves to no commit, or
# that no trunk ref reaches, returns non-zero (the caller then tries the backend, else refuses: fail-closed).
# [RiskMitigation RA-3] CI/supply-chain integrity: requiring a cited deliverable to be reachable from the trunk stops
# a story being recorded Done on work that never shipped, so a consumer can never adopt an "approved" change that was
# only pushed to an abandoned feature branch.
_rt_on_remote_trunk() {
  local repo="$1" rev="$2" tref
  git -C "$repo" rev-parse --verify -q "${rev}^{commit}" >/dev/null 2>&1 || return 1
  while IFS= read -r tref; do
    [ -n "$tref" ] || continue
    git -C "$repo" merge-base --is-ancestor "$rev" "$tref" 2>/dev/null && return 0
  done < <(_rt_trunk_refs "$repo" | sort -u)
  return 1
}
# _rt_on_remote_trunk_fresh <repo> <rev> -> as _rt_on_remote_trunk, but a NEGATIVE first answer triggers one
# best-effort fetch and a re-check, so a merely-stale remote trunk ref never causes a false "not merged" (the
# single seam both the commit and branch paths share, so the check/refresh/re-check idiom lives in one place).
_rt_on_remote_trunk_fresh() {
  _rt_on_remote_trunk "$1" "$2" && return 0
  _rt_refresh_once "$1"
  _rt_on_remote_trunk "$1" "$2"
}
story_remote_truth_problem() {
  local repo="$1" cited="$2" tok sha proj n br first isrepo=0
  case "$(story_trim "${cited:-}")" in ""|"-") return 0 ;; esac
  _RT_FETCHED=0
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 && isrepo=1
  # A trunk name next to a cited commit or MR ("main 3693dea", "MR !5 -> develop") only says WHERE the deliverable
  # landed; the commit/MR is the evidence. Checking the trunk too would refuse a pushed deliverable because of
  # unrelated local commits. A trunk cited ALONE is still the evidence and is checked.
  local specific=0 t
  while IFS= read -r t; do
    case "$t" in *?@*) _rt_is_sha "${t##*@}" "$repo" && specific=1 ;; *!*) printf '%s' "${t##*!}" | grep -cE '^[0-9]+$' >/dev/null && specific=1 ;; esac
    _rt_is_sha "$t" "$repo" && specific=1
  done < <(_rt_tokens "$cited")
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    case "$tok" in
      *?@*)   # <group/project>@<sha>
        proj="${tok%@*}"; sha="${tok##*@}"
        printf '%s' "$sha" | grep -ciE '^[0-9a-f]{7,40}$' >/dev/null || continue
        _rt_is_project "$proj" || { _rt_project_problem commit "$proj" "$sha"; return 0; }
        if ! command -v backend_commit_on_trunk >/dev/null 2>&1; then
          printf 'cited commit %s in %s cannot be verified: no remote lookup is available for another project' "$sha" "$proj"; return 0
        fi
        backend_commit_on_trunk "$sha" "$proj" || { printf 'cited commit %s is not merged onto the trunk of %s on the remote: its merge request must merge first (armed when it was created, it merges itself once its pipeline succeeds; never merge it by hand), then close' "$sha" "$proj"; return 0; }
        continue ;;
      *?!*|!*)   # [<group/project>]!<n>
        n="${tok##*!}"; proj="${tok%!*}"
        printf '%s' "$n" | grep -cE '^[0-9]+$' >/dev/null || continue
        [ -z "$proj" ] || _rt_is_project "$proj" || { _rt_project_problem "merge request" "$proj" "$n"; return 0; }
        if ! command -v backend_mr_merged >/dev/null 2>&1; then
          printf 'cited merge request !%s cannot be verified: no remote lookup is available' "$n"; return 0
        fi
        if ! backend_mr_merged "$n" "$proj"; then
          local _stall=""
          command -v backend_mr_stall_reason >/dev/null 2>&1 && _stall="$(backend_mr_stall_reason "$n" "$proj" 2>/dev/null)"
          if [ -n "$_stall" ]; then
            printf 'cited merge request %s!%s is not merged on the remote and is stalled. %s' "$proj" "$n" "$_stall"
          else
            printf 'cited merge request %s!%s is not merged on the remote yet: wait until it merges (an armed merge request merges itself once its pipeline succeeds; arm it if it is not armed, never merge it by hand), then close' "$proj" "$n"
          fi
          return 0
        fi
        continue ;;
    esac
    if _rt_is_sha "$tok" "$repo"; then
      sha="$tok"
      if [ "$isrepo" = 1 ] && git -C "$repo" cat-file -e "${sha}^{commit}" 2>/dev/null; then
        # Merged onto a local remote-trunk ref (one stale-ref refresh retried inside) => shipped.
        if _rt_on_remote_trunk_fresh "$repo" "$sha"; then continue; fi
        # Not reachable from a local trunk ref: let the backend say whether it is merged on the remote trunk.
        if command -v backend_commit_on_trunk >/dev/null 2>&1 && backend_commit_on_trunk "$sha" ""; then continue; fi
        # Still not on a trunk. Name whether it is wholly unpushed or pushed-but-unmerged, so the fix is obvious.
        first="$(_rt_local_only "$repo" "$sha")"
        if [ -n "$first" ]; then
          printf 'cited commit %s exists only locally in %s (no remote branch contains it): push it, with its merge request created armed, and close once that request has merged' "$sha" "$repo"; return 0
        fi
        printf 'cited commit %s is on the remote but not merged into the trunk (main/master/develop) of %s: its merge request must merge first (armed when it was created, it merges itself once its pipeline succeeds; never merge it by hand), then close' "$sha" "$repo"; return 0
      fi
      if command -v backend_commit_on_trunk >/dev/null 2>&1 && backend_commit_on_trunk "$sha" ""; then continue; fi
      printf 'cited commit %s is not in %s and not on the story project'"'"'s remote trunk; if it lives in another repo, cite it as <group/project>@%s' "$sha" "$repo" "$sha"; return 0
    fi
    # a branch name is only evidence when it is a real LOCAL branch of the story's repo
    [ "$isrepo" = 1 ] || continue
    printf '%s' "$tok" | grep -cE '^[A-Za-z0-9._/-]+$' >/dev/null || continue
    git -C "$repo" show-ref --verify --quiet "refs/heads/$tok" || continue
    case "$tok" in main|master|develop|trunk) [ "$specific" = 1 ] && continue ;; esac
    br="$tok"
    # A cited branch is "shipped" only when it is MERGED into an integration trunk, not merely pushed to its own ref.
    # Tip reachable from a remote trunk (fast-forward / merge-commit) => merged (one stale-ref refresh retried inside).
    if _rt_on_remote_trunk_fresh "$repo" "refs/heads/$br"; then continue; fi
    # Squash-merge leaves the tip off every trunk ref; a merged MR that used this branch as source still proves shipped.
    if command -v backend_branch_merged_on_remote >/dev/null 2>&1 && backend_branch_merged_on_remote "$br" ""; then continue; fi
    # Not merged. Separate "never pushed" from "pushed but the merge request is still open" for a precise refusal.
    first="$(_rt_local_only "$repo" "refs/heads/$br")"
    if [ -n "$first" ]; then
      _rt_has_remote_refs "$repo" || { printf 'cited branch %s cannot be verified: %s has no remote-tracking refs' "$br" "$repo"; return 0; }
      printf 'cited branch %s has commit %s that no remote branch contains (unpushed local work): push it, with its merge request created armed, and close once that request has merged' "$br" "$(git -C "$repo" rev-parse --short "$first" 2>/dev/null || printf '%s' "$first")"; return 0
    fi
    printf 'cited branch %s is pushed but not merged into the trunk (main/master/develop) on the remote: its merge request must merge first (armed when it was created, it merges itself once its pipeline succeeds; never merge it by hand), then close' "$br"; return 0
  done < <(_rt_tokens "$cited")
  return 0
}

# The H1 title text (after ": ") from a requirements.md. Empty if no H1 or no ": ".
story_title_from_file() {
  local file="$1" h1
  [ -f "$file" ] || { printf ''; return 0; }
  h1="$(grep -m1 -E '^#[[:space:]]' "$file" 2>/dev/null | sed -E 's/^#[[:space:]]+//')"
  case "$h1" in
    *": "*) printf '%s' "$(story_trim "${h1#*": "}")" ;;
    *)      printf '' ;;
  esac
}

# The slug portion of a story id (everything after STORY-NNN-). Empty if none.
story_slug_from_id() {
  printf '%s' "$1" | sed -nE 's/^STORY-[0-9]+-(.*)$/\1/p'
}

# The longest slug a story folder name carries. The mirror truncates a title-derived slug to this length, so a
# caller-chosen slug is held to the same bound and the two never disagree on shape.
STORY_SLUG_MAX_LENGTH=40

# story_slugify <text> -> the ONE slug rule for every folder name derived from text: lowercase ASCII, every run of
# non-alphanumerics becomes a single '-', no leading/trailing '-', truncated to STORY_SLUG_MAX_LENGTH and never
# ending in '-' after the cut. LC_ALL=C keeps the ranges byte-wise, so a non-ASCII letter never reaches a path.
story_slugify() {
  printf '%s' "$1" | tr '\r\n' '  ' | LC_ALL=C tr '[:upper:]' '[:lower:]' \
    | LC_ALL=C sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
    | cut -c1-"$STORY_SLUG_MAX_LENGTH" | LC_ALL=C sed -E 's/-+$//'
}

# story_slug_is_kebab <slug> -> rc 0 iff the slug is kebab-case (lowercase ASCII words joined by single dashes) and
# no longer than STORY_SLUG_MAX_LENGTH. The allow-list a NEW slug must pass before it becomes a folder name.
# [CySec] Allow-list validation of a value that becomes a filesystem path component (CWE-20, CWE-22).
story_slug_is_kebab() {
  [ "${#1}" -le "$STORY_SLUG_MAX_LENGTH" ] && story_slug_has_kebab_shape "$1"
}

# story_slug_has_kebab_shape <slug> -> rc 0 iff the slug is kebab-case, whatever its length. The mirror uses the
# shape alone to tell a legacy folder (to heal) from a curated one: a long curated kebab slug is left as it is.
story_slug_has_kebab_shape() {
  # No subprocess (the mirror calls this per folder on every sync). The allowed characters are spelled out rather
  # than given as ranges, so no locale can widen them; a newline or any other byte is outside the set.
  case "$1" in
    ''|-*|*-|*--*|*[!abcdefghijklmnopqrstuvwxyz0123456789-]*) return 1 ;;
  esac
  return 0
}

# Is a story archived? ("- **Archived:** true" present, case-insensitive on true). $1 = requirements file.
story_is_archived() {
  local v; v="$(story_get_field "$1" "Archived")"
  case "$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')" in
    true|yes|1) return 0 ;;
    *) return 1 ;;
  esac
}

# List story directories under a Stories dir, sorted by NNN ascending. $1 = Stories dir.
# Prints one absolute dir path per line. A "story dir" = a dir named STORY-<num>-* containing requirements.md.
story_list_dirs() {
  local dir="$1" d id num
  [ -d "$dir" ] || return 0
  for d in "$dir"/STORY-*/; do
    [ -d "$d" ] || continue
    d="${d%/}"
    id="$(basename "$d")"
    num="$(story_num_from_id "$id")"
    [ -n "$num" ] || continue
    printf '%s\t%s\n' "$num" "$d"
  done | sort -n -k1,1 | cut -f2-
}

# The maximum existing STORY number under a Stories dir (0 if none). $1 = Stories dir.
story_max_num() {
  local dir="$1" d id num max=0
  [ -d "$dir" ] || { printf '0'; return 0; }
  for d in "$dir"/STORY-*/; do
    [ -d "$d" ] || continue
    id="$(basename "${d%/}")"
    num="$(story_num_from_id "$id")"
    [ -n "$num" ] || continue
    [ "$num" -gt "$max" ] && max="$num"
  done
  printf '%s' "$max"
}

# Resolve an id-or-number argument to a story dir. $1 = Stories dir, $2 = "id" or "NNN" or "N".
# Prints the dir path on success; empty + return 1 if not found or ambiguous.
story_resolve() {
  local dir="$1" ref="$2" want d id num matches=()
  [ -d "$dir" ] || return 1
  # Exact folder match first.
  if [ -d "$dir/$ref" ]; then printf '%s' "$dir/$ref"; return 0; fi
  # Otherwise treat as a number: the FIRST-occurrence-safe parser for a STORY-<n> ref, else a bare number.
  want="$(story_num_from_id "$ref")"
  [ -n "$want" ] || want="$(printf '%s' "$ref" | sed -nE 's/^0*([0-9]+)$/\1/p')"
  [ -n "$want" ] || return 1
  for d in "$dir"/STORY-*/; do
    [ -d "$d" ] || continue
    id="$(basename "${d%/}")"
    num="$(story_num_from_id "$id")"
    [ "$num" = "$want" ] && matches+=("${d%/}")
  done
  [ "${#matches[@]}" -eq 1 ] || return 1
  printf '%s' "${matches[0]}"
}

# --- Epic registry ------------------------------------------------------------------------------

# Locate the registry file for an epic id (E0N) under <Stories>/_epics/. Prints path or empty.
story_epic_file() {
  local dir="$1" epic="$2" f
  [ -n "$epic" ] || { printf ''; return 0; }
  for f in "$dir"/_epics/"$epic"-*.md "$dir"/_epics/"$epic".md; do
    [ -f "$f" ] && { printf '%s' "$f"; return 0; }
  done
  printf ''
}

# The epic title from its registry file's H1 "# E0N — <title>" (text after the em/en dash or hyphen).
story_epic_title() {
  local f="$1" h1
  [ -f "$f" ] || { printf ''; return 0; }
  h1="$(grep -m1 -E '^#[[:space:]]' "$f" 2>/dev/null | sed -E 's/^#[[:space:]]+//')"
  # Title = text after the first " — " / " – " / " - " separator; else the whole H1.
  printf '%s' "$h1" | sed -E 's/^[^—–-]*[—–-][[:space:]]*//'
}

# The epic goal: the text of the "> **Goal:** ..." blockquote (joins continuation '>' lines with spaces).
story_epic_goal() {
  local f="$1"
  [ -f "$f" ] || { printf ''; return 0; }
  awk -f "$_SL_DIR/sl-extract-goal.awk" "$f" | sed 's/[[:space:]]\{1,\}/ /g; s/^ //; s/ $//' | head -n1
}

# --- BACKLOG.md generation ----------------------------------------------------------------------

# Print the verbatim header (<Stories>/_backlog-header.md) if present, else a minimal default H1.
story_emit_header() {
  local dir="$1" hf="$1/_backlog-header.md"
  if [ -f "$hf" ]; then
    cat "$hf"
  else
    printf '# Backlog\n'
  fi
}

# Print the verbatim footer (<Stories>/_backlog-footer.md) if present (e.g. usage conventions). Optional.
story_emit_footer() {
  local ff="$1/_backlog-footer.md"
  [ -f "$ff" ] && cat "$ff"
}

# Emit one table row for a story dir. $1 = story dir.
story_emit_row() {
  local d="$1" id req status branch summary slug emoji
  id="$(basename "$d")"
  req="$d/requirements.md"
  slug="$id"  # the link uses the full folder name
  status="$(story_normalize_status "$(story_get_field "$req" Status)")"
  [ -n "$status" ] || status="Todo"
  emoji="$(story_status_emoji "$status")"
  branch="$(story_get_field "$req" Branch)"
  [ -n "$branch" ] && [ "$branch" != "-" ] || branch="—"
  summary="$(story_get_field "$req" Summary)"
  # Short id label for the link text: STORY-NNN
  local label; label="$(printf '%s' "$id" | sed -nE 's/^(STORY-[0-9]+).*/\1/p')"
  [ -n "$label" ] || label="$id"
  # belt to the intake sanitizer: a hostile FOLDER name (newline/pipe) must not forge row cells either
  # (the label/link sit outside the story_escape_cell-covered cells).
  label="$(story_sanitize_inline "$label" | tr '|' '-')"
  slug="$(story_sanitize_inline "$slug" | tr '|' '-')"
  printf '| [%s](%s/requirements.md) | %s %s | %s | %s |\n' \
    "$label" "$slug" "$emoji" "$status" \
    "$(story_escape_cell "$branch")" "$(story_escape_cell "$summary")"
}

# story_emit_tasks_template <id> -> the tasks.md scaffold (shared by BOTH backends: the FS backend writes it on
# `new`, and the GitLab backend materializes it beside the issue-derived requirements.md so a story's on-disk
# folder is complete and BACKLOG links resolve).
story_emit_tasks_template() { # $1=id
  cat <<EOF
# $1 — Tasks

> Living checklist — keep in sync with the story Status. Legend: \`[ ]\` todo · \`[~]\` in progress · \`[x]\` done · \`[!]\` blocked.

## Work
- [ ] **T1** — <task> _(→ R1 / AC1)_

## Proof
<!-- ssdlc-story-proof gate. Fill this before closing. A story may be closed only when NO row is UNPROVEN. -->
EOF
}

# Emit the full BACKLOG.md to stdout, deterministically. $1 = Stories dir.
# Warnings (missing epic registry) go to stderr.
story_generate_backlog() {
  local dir="$1"
  story_emit_header "$dir"
  printf '\n'

  # Gather stories with their epic + status + number into a sortable index.
  # Fields: epicnum \t epic \t statusrank \t num \t dir \t archived
  local index d id req epic num rank arch
  index=""
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    id="$(basename "$d")"
    req="$d/requirements.md"
    epic="$(story_get_field "$req" Epic)"
    case "$epic" in ""|"-") epic="-" ;; esac
    num="$(story_num_from_id "$id")"
    rank="$(story_status_rank "$(story_get_field "$req" Status)")"
    if story_is_archived "$req"; then arch=1; else arch=0; fi
    local epicnum
    if [ "$epic" = "-" ]; then
      epicnum=999999   # Ungrouped sorts last
    else
      epicnum="$(printf '%s' "$epic" | sed -nE 's/^E0*([0-9]+)$/\1/p')"
      [ -n "$epicnum" ] || epicnum=999998   # malformed epic id → before Ungrouped, stable
    fi
    index+="$epicnum"$'\t'"$epic"$'\t'"$rank"$'\t'"$num"$'\t'"$d"$'\t'"$arch"$'\n'
  done < <(story_list_dirs "$dir")

  [ -n "$index" ] || return 0

  # Distinct epics in ascending epicnum order (Ungrouped's 999999 sorts last).
  local epics_sorted
  epics_sorted="$(printf '%s' "$index" | awk -F'\t' 'NF{print $1"\t"$2}' | sort -n -u -k1,1)"

  local epicnum epic
  while IFS=$'\t' read -r epicnum epic || [ -n "$epicnum" ]; do
    [ -n "$epic" ] || continue
    # All rows for this epic.
    local rows; rows="$(printf '%s' "$index" | awk -F'\t' -v e="$epic" '$2==e')"
    [ -n "$rows" ] || continue

    if [ "$epic" = "-" ]; then
      printf '## Ungrouped\n\n'
    else
      local ef title goal
      ef="$(story_epic_file "$dir" "$epic")"
      if [ -n "$ef" ]; then
        title="$(story_epic_title "$ef")"
        goal="$(story_epic_goal "$ef")"
      else
        title=""; goal=""
        printf '[story] warning: no registry for %s\n' "$epic" >&2
      fi
      if [ -n "$title" ]; then
        printf '## Epic %s — %s\n' "$epic" "$title"
      else
        printf '## Epic %s\n' "$epic"
      fi
      [ -n "$goal" ] && printf '> **Goal:** %s\n' "$goal"
      printf '\n'
    fi

    # Fully-archived epic (>=1 story, all archived) → emit the archived line, no table.
    local total archived_count
    total="$(printf '%s' "$rows" | grep -c . )"
    archived_count="$(printf '%s' "$rows" | awk -F'\t' '$6==1' | grep -c . )"
    if [ "$epic" != "-" ] && [ "$total" -gt 0 ] && [ "$total" -eq "$archived_count" ]; then
      printf '> _Archived: %s stories (see _archive/BACKLOG-archive.md)._\n\n' "$total"
      continue
    fi

    printf '| Story | Status | Ref | Summary |\n'
    printf '|-------|--------|-----|---------|\n'
    # Non-archived rows, ordered by statusrank asc then num asc.
    printf '%s' "$rows" | awk -F'\t' '$6==0' | sort -n -k3,3 -k4,4 | cut -f5 \
      | while IFS= read -r d; do [ -n "$d" ] && story_emit_row "$d"; done
    printf '\n'
  done < <(printf '%s' "$epics_sorted")

  story_emit_footer "$dir"
}

# --- story-quality (2a-2f) spec skeleton + close gate ------------------------
# The SINGLE canonical spec skeleton every NEW story is born with (both backends emit it via
# story_emit_spec_skeleton — DRY). A story carrying STORY_SPEC_MARKER is GATED at close: every 2a-2f dimension
# header must be present AND no <placeholder> token may remain. Legacy stories (no marker) are grandfathered.
# The sections themselves are described in the ssdlc-story SKILL.md.
STORY_SPEC_MARKER='<!-- spec:2a-2f -->'

# story_emit_spec_skeleton [<story-type>] — a fix-type story (fix|hotfix) also gets the "## Fix the class" section the
# close requires (the bridge's StoryBodyTemplate.SkeletonFor emits the same text), after the 2f section.
story_emit_spec_skeleton() {
  local type
  type="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  cat <<EOF
$STORY_SPEC_MARKER
## User story
As a **<FILL: role>**, I want **<FILL: capability>**, so that **<FILL: benefit>**.

## Requirements
- **R1** — <FILL: requirement>

## Use cases to test — and how (2a)
- **UC1** — <FILL: case> -> <FILL: how it is tested>

## Failure modes handled — and how (2b)
- **FM1** — <FILL: failure mode> -> <FILL: how it is handled>

## Fail-open vs fail-hard (2c)
- **FAIL-HARD:** <FILL: cases that must block>
- **FAIL-OPEN:** <FILL: cases that degrade safely, and why that is safe>

## Poka-yoke — prevent agent misuse (2d)
- <FILL: mechanism that makes the wrong thing impossible or fail-loud, and which rung>

## Enforcement — the agent MUST use it (2e)
- <FILL: the hook/gate that makes this the only path>

## Anti-circumvention / anti-reinvention (2f)
- <FILL: what stops an agent bypassing it or re-building the wheel>

EOF
  case "$type" in
    fix|hotfix)
      cat <<EOF
## Fix the class
- **Invariant violated:** <FILL: the rule that was broken, stated so it holds for the whole class>
- **Sweep:** <FILL: the other call sites where the same mistake could recur, and how each was checked>
- **Chokepoint:** <FILL: the one place that now closes the whole class, and the test that locks it>

EOF
      ;;
  esac
  cat <<EOF
## Acceptance criteria (Given / When / Then)
- **AC1** — Given <FILL: context>, when <FILL: action>, then <FILL: observable outcome>.

## Out of scope / non-goals
- <FILL: what this story deliberately does NOT do>
EOF
}

# OFF-MODE REMAINDER. The spec-completeness rule lives in the bridge (StorySpecCompleteness: every section of the
# story skeleton filled before a story leaves Requirements, and at close). story_spec_dims and story_spec_unfilled
# below are the older 2a-2f close check, kept unchanged ONLY for projects whose bridge serves no story stack (mode
# 'off'), where the bash mechanics still decide. Where the stack is on, the bridge decides; in shadow mode its spec
# refusal stops the bash path (ssdlc_spec_gate_shadow). Delete both once every project runs the bridge's story stack.
# story_spec_dims -> the 2a-2f dimension headers a spec'd story MUST carry (one per line).
story_spec_dims() {
  printf '%s\n' 'Use cases to test' 'Failure modes handled' 'Fail-open vs fail-hard' \
                'Poka-yoke' 'Enforcement' 'Anti-circumvention'
}

# _story_dim_has_content <body> <dim> -> 0 iff the '## <dim>…' section has a non-blank, non-heading line before the
# next '## ' (the dimension isn't header-only).
_story_dim_has_content() {
  printf '%s\n' "$1" | LC_ALL=C awk -v h="## $2" -f "$_SL_DIR/sl-section-has-content.awk"
}

# story_spec_unfilled <body> -> print each unmet condition (one per line); EMPTY = OK. hardening
# A body carrying the 2a-2f SPEC (the marker OR ANY dimension header — so deleting the marker cannot disarm it) is
# GATED: it must carry EVERY dimension header, each with real CONTENT (not header-only), and NO unfilled <FILL: …>
# sentinel. A body with neither the marker nor any dimension header is legacy -> grandfathered. Keying the
# placeholder check on the distinctive `<FILL:` sentinel (not a generic `<…>`) means a legitimately-authored token
# like `<slug>`/`<file>`/`<div>` in prose is NOT false-flagged (the review's false-positive).
# story_has_unfilled_placeholder <text> -> rc 0 iff an UNFILLED `<FILL:` template placeholder remains, IGNORING any
# `<FILL:` that appears inside a markdown code span (backtick `...`) or a fenced code block (triple-backtick), so a
# story whose CONTENT merely MENTIONS the sentinel (e.g. a story ABOUT the template/placeholder gate) is not
# false-flagged. A real skeleton placeholder is a bare template value on a
# bullet/field line, never inside a code span. The ONE discriminator both the close gate (story_spec_unfilled) and
# the work-time structure check (_story_missing_items) call, so they can never disagree on "is this authored".
story_has_unfilled_placeholder() {
  local stripped
  # 1) drop fenced code blocks (``` … ```); 2) drop inline code spans (`…`); 3) look for the bare sentinel.
  stripped="$(printf '%s\n' "$1" | awk 'BEGIN{f=0} /^[[:space:]]*```/{f=!f; next} !f{print}')"
  stripped="$(printf '%s' "$stripped" | sed 's/`[^`]*`//g')"
  printf '%s' "$stripped" | grep -cF '<FILL:' >/dev/null
}

# Off-mode remainder (see story_spec_dims): tests/fixtures/spec-parity.json locks its verdicts.
story_spec_unfilled() {
  local body="$1" d gated=0
  if printf '%s' "$body" | grep -cF "$STORY_SPEC_MARKER" >/dev/null; then gated=1; fi
  while IFS= read -r d; do
    if printf '%s' "$body" | LC_ALL=C grep -ciF "## $d" >/dev/null; then gated=1; fi
  done <<DIMS
$(story_spec_dims)
DIMS
  [ "$gated" -eq 1 ] || return 0   # legacy / not a spec'd story -> grandfathered
  while IFS= read -r d; do
    if ! printf '%s' "$body" | LC_ALL=C grep -ciF "## $d" >/dev/null; then printf 'MISSING dimension: %s\n' "$d"
    elif ! _story_dim_has_content "$body" "$d"; then printf 'EMPTY dimension: %s (header present, no content)\n' "$d"
    fi
  done <<DIMS
$(story_spec_dims)
DIMS
  if story_has_unfilled_placeholder "$body"; then printf 'PLACEHOLDER: unfilled <FILL: …> token(s) remain\n'; fi
  return 0
}

# story_proof_has_proven <proof-table> -> rc 0 iff the table has ≥1 PROVEN (not UNPROVEN/NOT_PERTINENT)
# verdict row. The verdict is column 2 (| Dim | Verdict | Evidence | …), read by the shared classifier
# (proof_verdict_is_proven: any case, bold, emoji, UNPROVEN never PROVEN) when proof-dimensions.sh is loaded. Used by
# the close gate: a story that PROVES anything MUST carry a real spec — it cannot be a grandfathered "specless legacy"
# story (the green-wash).
story_proof_has_proven() {
  local _v
  if command -v proof_verdict_is_proven >/dev/null 2>&1; then
    while IFS= read -r _v; do
      proof_verdict_is_proven "$_v" && return 0
    done < <(printf '%s\n' "$1" | awk -F'|' 'NF>=3 { print $3 }')
    return 1
  fi
  printf '%s\n' "$1" | awk -F'|' 'NF>=3 { v=toupper($3); gsub(/[^A-Z_]/,"",v); if (v=="PROVEN") found=1 } END{ exit(found?0:1) }'
}

# story_body_has_spec <body> -> rc 0 iff the body carries a real 2a-2f spec: the marker, OR any 2a-2f
# dimension header, OR a `## Requirements` / `## Acceptance criteria` section. A body with NONE of these is a
# bare/unstructured story (metadata + free prose only) whose Proof table would correlate to nothing.
story_body_has_spec() {
  local body="$1" d
  printf '%s' "$body" | grep -cF "$STORY_SPEC_MARKER" >/dev/null && return 0
  printf '%s' "$body" | grep -cE '^##[[:space:]]+(Requirements|Acceptance criteria)([[:space:]]|$)' >/dev/null && return 0
  while IFS= read -r d; do
    printf '%s' "$body" | LC_ALL=C grep -ciF "## $d" >/dev/null && return 0
  done <<DIMS
$(story_spec_dims)
DIMS
  return 1
}

# story_phase_needs_start <status> <target-phase> -> rc 0 iff entering <target-phase> is NOT allowed for a story in <status>:
# a phase later than Design means the story is being worked, so a story nobody started (Todo, Parked or no status) may be
# specified (Requirements, Design) but not worked. The one rule every phase writer asks (the manual phase command and the
# automatic move to Review on a complete proof), so no path can skip it.
story_phase_needs_start() {
  local st="$1" rt rd; rt="$(story_phase_rank "$2")"; rd="$(story_phase_rank Design)"
  [ -n "$rt" ] && [ -n "$rd" ] && [ "$rt" -gt "$rd" ] || return 1
  case "$st" in Todo|Parked|"") return 0 ;; *) return 1 ;; esac
}

# story_phase_is_preimpl <phase-string> -> rc 0 iff the phase is a PRE-implementation phase
# (Requirements or Design). A story still in one at close never advanced to Implementation/Testing (the
# automatic advances are owned by hooks/kyklos-phase-advance.sh), so no work was committed under it — closing it is
# incoherent with the SSDLC lifecycle. An EMPTY phase (FS backend / no label) is NOT pre-impl (fail-open).
story_phase_is_preimpl() {
  case "$1" in
    "") return 1 ;;
    *Requirements*|*Design*) return 0 ;;
    *) return 1 ;;
  esac
}

# story_phase_is_awaiting_ci <phase-string> -> rc 0 iff the phase is one where the branch is already PUSHED and the
# only thing the story is still waiting on is its CI pipeline: Testing or Deployment (the phase advances to Testing on
# push). At such a phase the actively-WORKED slot is free, so the agent should start the NEXT story instead of idling
# on CI (the gap another agent reported: nothing frees the one-story slot while a pipeline runs). An EMPTY phase (the
# FS backend has no phase label) is NOT awaiting-CI -> the strict single-story behaviour is unchanged there. The
# canonical classifier both the active-story resolver and `story check` consume, so the two can never diverge.
story_phase_is_awaiting_ci() {
  case "$1" in
    "") return 1 ;;
    *Testing*|*Deployment*) return 0 ;;
    *) return 1 ;;
  esac
}

# story_active_ref_from <all-inprogress-ids> <awaiting-ci-ids> -> the SINGLE actively-worked story id, or empty.
# PURE decision (newline-separated id lists in, one id or empty out): the actively-worked set is (all In-progress)
# minus (awaiting-CI); a default is returned ONLY when exactly one actively-worked story remains. Zero (every
# In-progress story is awaiting CI) or two-or-more (genuinely ambiguous) -> empty, so a caller keeps its strict
# "no single active story" behaviour. Split out from _story_current_ref so the decision is unit-tested without a
# backend.
story_active_ref_from() {
  local all="$1" awaiting="$2" active="" id n=0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    if [ -n "$awaiting" ] && printf '%s\n' "$awaiting" | grep -Fx -- "$id" >/dev/null 2>&1; then continue; fi
    active="$id"; n=$((n+1))
  done <<EOF
$all
EOF
  [ "$n" -eq 1 ] && printf '%s' "$active"
}

# _story_metadata_header <body-text> -> the leading tool-owned METADATA-BULLET block only: the contiguous run of
# `- **Key:** value` bullet lines and interleaving blank lines at the START of the body, stopping at the first line
# that is neither a metadata bullet nor blank. This is what `cmd_requirements` preserves across a re-author.
# A rule such as "everything before the first `## ` heading" would sweep up an ADOPTED issue's free-form prose (which
# has no `## ` heading) as "header" and re-append it ahead of the new spec, duplicating the original body. Anchoring to
# the `- **Key:** value` shape prevents that.
_story_metadata_header() {
  printf '%s\n' "$1" | awk -f "$_SL_DIR/sl-extract-header.awk"
}

# _story_adopt_body <type> <epic> <title> <original-desc> -> the body `story adopt` writes for a NEWLY-adopted issue:
# the canonical metadata bullet block, then — when the original description is non-empty — a `## Original request
# (verbatim)` section quoting the original as a markdown blockquote (`> ` on every line, blanks included, so it stays
# one contiguous quote). Preserves the user's original request verbatim + clearly cited. Pure + unit-tested (no API).
# _story_extract_original_request <body> -> the `## Original request (verbatim)` section (heading +
# its content up to the NEXT `## ` heading or EOF), or empty if absent. This section is PROVENANCE that `story adopt`
# writes to preserve a user-created issue's original words; it is NOT editable spec, so `cmd_requirements` (which
# replaces everything from the first `## `) must carry it across a spec re-author instead of wiping it, or a
# `requirements --file` that drops this section would destroy the user's original request.
_story_extract_original_request() {
  printf '%s\n' "$1" | awk -f "$_SL_DIR/sl-extract-original-request.awk"
}

# _story_strip_original_request <text> -> TEXT with every `## Original request (verbatim)` section
# removed. The inverse of the extractor, so cmd_requirements can be IDEMPOTENT on the tool-owned provenance
# section: an authored spec file that (reasonably) includes it can never duplicate it against the adoption-written
# canonical copy.
_story_strip_original_request() {
  printf '%s\n' "$1" | awk -f "$_SL_DIR/sl-strip-original-request.awk"
}

# _story_strip_title_h1 <text> -> TEXT with a LEADING `# STORY-<n>: ...` title H1 (and one following
# blank) removed. A backend-agnostic belt so the re-prepended metadata header never carries the title H1 into a
# re-authored body (the GitLab strip only runs on the WRITE, and a later mirror re-sync could re-introduce it — the
# leak). Matches ONLY the auto-generated story-title H1, never a user's own `# Heading`.
_story_strip_title_h1() {
  printf '%s\n' "$1" | awk -f "$_SL_DIR/sl-strip-title-line.awk"
}

_story_adopt_body() {
  local type="$1" epic="$2" title="$3" orig="$4" meta quoted skel
  meta="$(printf -- '- **Status:** In-progress\n- **Story-Type:** %s\n- **Epic:** %s\n- **Branch:** -\n- **Summary:** %s' "$type" "$epic" "$title")"
  # SCAFFOLD the SSDLC section skeleton on ADOPT — the SAME one `story new` emits (story_emit_spec_skeleton),
  # plus a Risk-assessment section — so an adopted user-issue is STRUCTURALLY COMPLETE by construction: the sections can never be
  # MISSING; the agent only fills the <FILL:> placeholders
  # (genuine authoring), and `story structure` flags unfilled placeholders, not absent sections.
  skel="$(story_emit_spec_skeleton "$type"; printf '\n## Risk assessment\n- <FILL: RA-## register per the ssdlc-risk-assessment dimension, or NOT_PERTINENT with a stated reason (e.g. a docs/test story)>\n')"
  if [ -n "$(printf '%s' "$orig" | tr -d '[:space:]')" ]; then
    quoted="$(printf '%s\n' "$orig" | sed 's/^/> /')"
    printf '%s\n\n## Original request (verbatim)\n\n%s\n\n%s' "$meta" "$quoted" "$skel"
  else
    printf '%s\n\n%s' "$meta" "$skel"
  fi
}

# --- temp-file hygiene ------------------------------------------------------------------------------------
# Every temp file the tool creates in a REPO-VISIBLE location must be registered here right after its
# mktemp, so an interrupted or killed run can never strand it (stranded .backlog./.story./.mirror. files
# were observed accumulating across sessions). ONE registry + ONE trap: a new mktemp site cannot invent its
# own cleanup, and the paired-site lint test fails if a site forgets to register. Registration is safe for
# the happy path too - after the atomic rename the registered path no longer exists and cleanup skips it.
_STORY_TMP_REGISTRY=()
story_tmp_register() { _STORY_TMP_REGISTRY+=("$1"); }
story_tmp_cleanup() {
  local f
  for f in ${_STORY_TMP_REGISTRY[@]+"${_STORY_TMP_REGISTRY[@]}"}; do
    [ -n "$f" ] && [ -e "$f" ] && rm -f "$f" 2>/dev/null
  done
  return 0
}
# EXIT covers the normal + die paths; INT/TERM cover an interrupted/killed run (re-raise so the exit status
# stays honest). Installing on source is deliberate: every entry point that loads this lib is covered.
trap story_tmp_cleanup EXIT
trap 'story_tmp_cleanup; trap - INT; kill -INT $$' INT
trap 'story_tmp_cleanup; trap - TERM; kill -TERM $$' TERM
