#!/usr/bin/env bash
# story-backend-fs.sh — the FILESYSTEM implementation of the story-backend contract.
#
# Every story is a directory under a Stories dir, its state lives in that dir's requirements.md (the single source
# of truth for this backend), and BACKLOG.md is a GENERATED index. The other backend, story-backend-gitlab.sh
# (issue=story, milestone=epic, labels=status, a note=proof), implements the SAME contract; the dispatcher
# story-backend.sh selects one via STORY_BACKEND.
#
# THE BACKEND CONTRACT — the core subset (the `story` CLI calls only backend_* functions; both backends define
# further ones for phase, kind, risk assessment, body, notes and adoption, and the gitlab backend adds GitLab-only
# helpers the CLI probes with `command -v`):
#   backend_max_num <dir>                      -> highest existing story number (0 if none)
#   backend_resolve <dir> <ref>                -> resolve an id|NNN|N to a backend-native story handle; rc!=0 if none
#   backend_new <dir> <id> <title> <type> <epic> [kind]  -> create a new story (requirements + tasks) for a resolved id
#   backend_get_field <dir> <handle> <field>   -> read a canonical field value (empty if absent)
#   backend_set_field <dir> <handle> <field> <val>  -> set/insert a canonical bullet field (atomic)
#   backend_set_title <dir> <handle> <val>     -> rewrite the story's H1 title text
#   backend_get_type  <dir> <handle>           -> the Story-Type (drives the proof profile)
#   backend_tasks_path <dir> <handle>          -> path/handle of the tasks doc (for `proof --write`)
#   backend_proof_write <dir> <handle> <table> -> replace/append the tasks doc's `## Proof` section
#   backend_proof_read <dir> <handle>          -> read back the `## Proof` section text (empty if none)
#   backend_done_handles <dir>                 -> handles of the Done stories, ascending (for the proof gate)
#   backend_generate_index <dir>               -> emit the full BACKLOG index to stdout (deterministic)
#   backend_epic_records <dir>                 -> every epic as a JSON array {epic,id,title,goal,active,start,due}
#   backend_epic_issues <dir> <epic> <id>      -> the epic's issues as a JSON array {iid,title,open,story}
#   backend_epic_create <dir> <epic> <title> <goal> <start> <due> -> create an epic; prints its id
#   backend_epic_update <dir> <epic> <id> <changes-json> / backend_epic_delete <dir> <epic> <id>
#   backend_epic_members <dir> <epic>          -> list resolved handles of an epic's stories (one per line)
#   backend_find_by_title <dir> <title>        -> rc 0 iff a story with EXACTLY this title exists (SSoT dedup);
#                                                rc 1 none, rc 2 SSoT unreadable (caller MUST fail hard on rc 2)
#   backend_is_done <dir> <handle>             -> rc 0 iff the story's status is Done
#   backend_archive_story <dir> <epic> <handle>   -> record one story into the epic's archive + mark it Archived
#   backend_archive_row <dir> <handle>         -> emit the archived BACKLOG row for a story (for the archive file)
#   backend_add_labels <dir> <handle> <labels> -> add free labels (gitlab: e.g. severity::*, ai-review; FS: no-op)
#   backend_import_issue <dir> <iid> <title> <type> <epic> <desc-file> -> migration import with an EXPLICIT id
#                                                and the FULL body from <desc-file> (gitlab: iid==story#); prints the id
#
# For the FS backend a "handle" IS the story directory path, so backend_resolve returns that path and the
# other verbs take it directly. A different backend may return an opaque handle (e.g. an issue iid) instead.
#
# Sources story-lib.sh for the backend-AGNOSTIC pure/format + parse helpers (emoji map, escaping, ordering,
# table rendering, requirements.md field parsing). bash + coreutils/grep/sed/awk/sort/diff only.

BACKEND_FS_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Each library below must load completely. A failure is RECORDED in STORY_LIB_LOAD_FAILED and loading goes on as
# before, so the hooks that source this seam keep their behaviour; the story tool refuses to run when it is set.
# shellcheck source=../../../hooks/lib/require-lib.sh
. "$BACKEND_FS_HERE/../../../hooks/lib/require-lib.sh" \
  || { require_lib() { . "$1"; }; STORY_LIB_LOAD_FAILED="${STORY_LIB_LOAD_FAILED:+$STORY_LIB_LOAD_FAILED, }require-lib.sh"; }
# shellcheck source=story-lib.sh
require_lib "$BACKEND_FS_HERE/story-lib.sh" || STORY_LIB_LOAD_FAILED="${STORY_LIB_LOAD_FAILED:+$STORY_LIB_LOAD_FAILED, }story-lib.sh"
# shellcheck source=../../../hooks/lib/json-answer.sh
require_lib "$BACKEND_FS_HERE/../../../hooks/lib/json-answer.sh" json_test json_read || STORY_LIB_LOAD_FAILED="${STORY_LIB_LOAD_FAILED:+$STORY_LIB_LOAD_FAILED, }json-answer.sh"

# --- template bodies (embedded so the tool ships self-contained) --------------------------------

backend_fs_emit_requirements_template() { # $1=id $2=title $3=type $4=epic $5=kind
  cat <<EOF
# $1: $2

- **Status:** Todo
- **Story-Type:** $3
- **Epic:** ${4:--}
- **Kind:** ${5:-development}
- **Target repo:** -
- **Branch:** -
- **Summary:** $2

EOF
  story_emit_spec_skeleton "$3"   # the shared 2a-2f skeleton (DRY with the gitlab backend)
}

backend_fs_emit_tasks_template() { story_emit_tasks_template "$1"; }   # shared with the gitlab backend (DRY)
backend_body_read() { cat "$2/requirements.md" 2>/dev/null; }          # full body (for the story-quality gate)
# backend_set_body <dir> <handle> <full-body> -> replace the story's WHOLE body (requirements.md). The
# sanctioned write path behind `story requirements` (author the spec via the tool, not a raw PUT).
backend_set_body() { printf '%s\n' "$3" > "$2/requirements.md"; }

# --- requirements.md mutation (atomic) ----------------------------------------------------------

# Set a canonical bullet field in a requirements.md, inserting in canonical position if absent.
# $1=file $2=canonical-field $3=value. Writes to a temp in the same dir then mv (atomic).
backend_fs_set_field_in_file() {
  local file="$1" field="$2" value="$3" dir tmp
  dir="$(dirname "$file")"
  tmp="$(mktemp "$dir/.story.XXXXXX")" || { printf 'story: cannot create temp file in %s\n' "$dir" >&2; return 2; }
  story_tmp_register "$tmp"

  if [ "$field" = "title" ]; then
    # Rewrite the H1's title text (after the first ": "). Keep the "# STORY-...: " prefix.
    awk -v val="$value" -f "$BACKEND_FS_HERE/fs-set-title-field.awk" "$file" > "$tmp"
    mv -f "$tmp" "$file"
    return 0
  fi

  # If the field bullet already exists, replace its line in place.
  if grep -qiE "^[[:space:]]*[-*][[:space:]]+\*\*${field}:\*\*" "$file"; then
    awk -v f="$field" -v val="$value" -f "$BACKEND_FS_HERE/fs-set-field-bullet.awk" "$file" > "$tmp"
    mv -f "$tmp" "$file"
    return 0
  fi

  # Field absent → insert in canonical position, after the last preceding canonical field that IS present,
  # else immediately after the H1.
  local pos="" fprev
  local -a order=("Status" "Story-Type" "Epic" "Kind" "Target repo" "Branch" "Summary")
  local i target_index=-1 j
  for i in "${!order[@]}"; do [ "${order[$i]}" = "$field" ] && target_index="$i" && break; done
  # Walk backwards from the target position to find an anchor field present in the file.
  if [ "$target_index" -ge 0 ]; then
    for (( j=target_index-1; j>=0; j-- )); do
      fprev="${order[$j]}"
      if grep -qiE "^[[:space:]]*[-*][[:space:]]+\*\*${fprev}:\*\*" "$file"; then pos="$fprev"; break; fi
    done
  fi

  if [ -n "$pos" ]; then
    awk -v anchor="$pos" -v f="$field" -v val="$value" -f "$BACKEND_FS_HERE/fs-insert-after-anchor.awk" "$file" > "$tmp"
  else
    # Insert right after the first H1 line (or at top if no H1).
    awk -v f="$field" -v val="$value" -f "$BACKEND_FS_HERE/fs-insert-header-field.awk" "$file" > "$tmp"
  fi
  mv -f "$tmp" "$file"
}

# ================================================================================================
# CONTRACT IMPLEMENTATION
# ================================================================================================

# backend_max_num <dir> -> highest existing story number (0 if none).
backend_max_num() { story_max_num "$1"; }

# backend_resolve <dir> <ref> -> the story dir path (the FS handle); rc 1 if not found/ambiguous.
backend_resolve() { story_resolve "$1" "$2"; }

# FS backend has no GitLab-issue / milestone concept — these exist only so the backend contract is complete (the
# CLI/guard call them ONLY under the gitlab backend, so in FS mode they are never reached):
#   - epic_has_milestone: rc 0 (FS stories have no milestone to require — never block on it).
#   - is_adopted_story:   rc 3 (indeterminate — the raw-issue branch-guard is a gitlab concern).
#   - adopt:              refuse (adoption is a gitlab-issue operation; FS stories are created with `story new`).
backend_epic_has_milestone() { return 0; }
backend_is_adopted_story()   { return 3; }
backend_adopt() { echo "story adopt: only the gitlab backend adopts existing issues; in FS mode create a story with 'story new'." >&2; return 2; }

# backend_new <dir> <id> <title> <type> <epic> [kind] -> create the story dir + requirements.md + tasks.md.
# rc 2 if the story id already exists. kind defaults to development (strictest) at the template.
backend_new() {
  local dir="$1" id="$2" title="$3" type="$4" epic="$5" kind="${6:-development}"
  [ -e "$dir/$id" ] && { printf 'story: new: %s already exists\n' "$id" >&2; return 2; }
  mkdir -p "$dir/$id"
  backend_fs_emit_requirements_template "$id" "$title" "$type" "$epic" "$kind" > "$dir/$id/requirements.md"
  backend_fs_emit_tasks_template "$id" > "$dir/$id/tasks.md"
  # Print the created handle (the story dir path — the FS handle-space) so callers use the AUTHORITATIVE
  # handle for follow-up mutations rather than re-resolving by a pre-computed number (uniform with gitlab).
  printf '%s' "$dir/$id"
}

# backend_id_from_handle <dir> <handle=story-dir> -> the canonical STORY id (the dir basename).
backend_id_from_handle() { printf '%s' "$(basename "$2")"; }

# backend_materialize / backend_materialize_all -> NO-OP for the FS backend: the on-disk folder IS the source of
# truth (already written by backend_new). These exist so the tool can call them uniformly for BOTH backends.
backend_materialize()     { :; }
backend_materialize_all() { :; }

# backend_get_field <dir> <handle> <field> -> a canonical field value (empty if absent).
backend_get_field() { story_get_field "$2/requirements.md" "$3"; }

# backend_set_field <dir> <handle> <field> <val> -> set/insert a canonical bullet field.
backend_set_field() { backend_fs_set_field_in_file "$2/requirements.md" "$3" "$4"; }

# backend_set_title <dir> <handle> <val> -> rewrite the story's H1 title text.
backend_set_title() { backend_fs_set_field_in_file "$2/requirements.md" "title" "$3"; }

# backend_get_type <dir> <handle> -> the Story-Type field.
backend_get_type() { story_get_field "$2/requirements.md" 'Story-Type'; }

# backend_get_kind <dir> <handle> -> the Kind field (raw; empty when absent — the caller normalizes, and an
# empty/unknown read resolves to development, the strictest set).
backend_get_kind() { story_get_field "$2/requirements.md" 'Kind'; }

# backend_tasks_path <dir> <handle> -> the tasks doc path (for `proof --write`); empty if absent.
backend_tasks_path() {
  local tasks="$2/tasks.md"
  [ -f "$tasks" ] || { printf ''; return 1; }
  printf '%s' "$tasks"
}

# backend_proof_write <dir> <handle> <table> -> replace (idempotently) or append the `## Proof` section.
backend_proof_write() {
  local sdir="$2" table="$3" tasks="$2/tasks.md" tmp
  [ -f "$tasks" ] || { printf 'story: proof: no tasks.md in %s\n' "$sdir" >&2; return 2; }
  tmp="$(mktemp "$sdir/.story.XXXXXX")" || { printf 'story: proof: cannot create temp file in %s\n' "$sdir" >&2; return 2; }
  story_tmp_register "$tmp"
  if grep -qE '^##[[:space:]]+Proof([[:space:]]|$)' "$tasks"; then
    # Emit everything BEFORE the `## Proof` heading, then the fresh table, then everything from the NEXT `## `.
    awk -v tbl="$table" -f "$BACKEND_FS_HERE/fs-replace-proof.awk" "$tasks" > "$tmp"
  else
    { cat "$tasks"; printf '\n%s\n' "$table"; } > "$tmp"
  fi
  mv -f "$tmp" "$tasks"
}

# backend_proof_read <dir> <handle> -> the `## Proof` section text of the tasks doc (heading + body up to the
# next `## `); empty if there is no tasks.md or no Proof section. The story-proof gate reads it.
backend_proof_read() {
  local tasks="$2/tasks.md"
  [ -f "$tasks" ] || { printf ''; return 0; }
  awk '/^##[[:space:]]+Proof([[:space:]]|$)/{f=1;print;next} /^##[[:space:]]/{f=0} f{print}' "$tasks"
}

# --- Risk Assessment register seam -----------------------------------------------------------------------------
# The per-story numbered Risk Assessment register (RA-## items + an optional user `Risk-Assessment-Waived:` line).
# On the FS backend it IS the durable record: risk-assessment.md in the story dir. The story-proof gate reads it
# via backend_ra_read so the SAME RA checks run on both backends (the gitlab impl stores it in the issue instead).
# backend_ra_read <dir> <handle> -> the register text (empty if none).
backend_ra_read() {
  local ra="$2/risk-assessment.md"
  [ -f "$ra" ] && cat "$ra" 2>/dev/null || printf ''
}
# backend_ra_write <dir> <handle> <text> -> create/replace the register file atomically.
backend_ra_write() {
  local sdir="$2" text="$3" tmp
  [ -d "$sdir" ] || { printf 'story: ra: no story dir %s\n' "$sdir" >&2; return 2; }
  tmp="$(mktemp "$sdir/.ra.XXXXXX")" || { printf 'story: ra: cannot create temp file in %s\n' "$sdir" >&2; return 2; }
  story_tmp_register "$tmp"
  printf '%s\n' "$text" > "$tmp" && mv -f "$tmp" "$sdir/risk-assessment.md"
}

# backend_done_handles <dir> -> the handles (story dirs) of the Done stories, ascending. Used by the proof gate.
backend_done_handles() {
  local dir="$1" d
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    [ "$(story_normalize_status "$(story_get_field "$d/requirements.md" Status)")" = "Done" ] && printf '%s\n' "$d"
  done < <(story_list_dirs "$dir")
}

# backend_generate_index <dir> -> emit the full BACKLOG index to stdout, deterministically.
backend_generate_index() { story_generate_backlog "$1"; }

# backend_find_by_title <dir> <title> -> rc 0 if a story with EXACTLY this title exists, rc 1 if none, rc 2 if the
# corpus is unreadable. On the FS backend the disk IS the SSoT, so it never reports "unreachable" (rc 2): an
# absent/empty Stories dir simply yields "not found" (rc 1). The single sanctioned dedup enumeration for
# track-finding — never scan the folder mirror directly (a divergent scan is a contract violation).
backend_find_by_title() {
  local dir="$1" want="$2" d
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    [ "$(story_title_from_file "$d/requirements.md" 2>/dev/null)" = "$want" ] && return 0
  done < <(story_list_dirs "$dir" 2>/dev/null)
  return 1
}

# --- epics (registry files) ---------------------------------------------------------------------------------------
# An epic here is a registry file _epics/<epic>-<slug>.md: a "# <epic> — <title>" line and an optional "> **Goal:**"
# line. A file has no state and no dates: every epic is active, and a write of a state or a date is refused.

# _fs_epic_no_state <what> -> the refusal for a state or date write (rc 2).
_fs_epic_no_state() {
  printf 'story: the filesystem story backend keeps an epic as a registry file, which has no %s; that exists only for GitLab milestones (STORY_BACKEND=gitlab). Nothing was changed.\n' "$1" >&2
  return 2
}

# backend_epic_records <dir> -> every epic registry file as one JSON array of {epic, id, title, goal, active, start,
# due}; id is the file name, active is always true, start and due are null. The title is read by the same rule as a
# GitLab milestone's (epic-records.jq).
backend_epic_records() {
  local dir="$1" f head goal
  for f in "$dir"/_epics/E*.md; do
    [ -f "$f" ] || continue
    head="$(grep -m1 -E '^#[[:space:]]' "$f" | sed -E 's/^#[[:space:]]+//')"
    goal="$(story_epic_goal "$f")"
    jq -cn --arg t "$head" --arg g "$goal" --arg id "$(basename "$f")" '{id:$id, title:$t, description:$g, state:"active"}'
  done | jq -cs '.' | jq -c -f "$(dirname "${BASH_SOURCE[0]}")/epic-records.jq"
}

# _fs_epic_file <dir> <epic> -> the epic's registry file(s), one per line.
_fs_epic_file() {
  local f
  for f in "$1"/_epics/"$2"-*.md "$1/_epics/$2.md"; do [ -f "$f" ] && printf '%s\n' "$f"; done
  return 0
}

# _fs_epic_write <dir> <epic> <title> <goal> -> (re)write the epic's registry file; a title change renames it, so the
# epic keeps exactly one file. Prints the file name.
_fs_epic_write() {
  local dir="$1" epic="$2" title="$3" goal="$4" slug f old
  mkdir -p "$dir/_epics"
  slug="$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]\{1,\}/-/g; s/^-//; s/-$//')"
  [ -n "$slug" ] || slug="epic"
  f="$dir/_epics/$epic-$slug.md"
  {
    printf '# %s — %s\n' "$epic" "$title"
    [ -z "$goal" ] || printf '> **Goal:** %s\n' "$goal"
  } > "$f.tmp" && mv -f "$f.tmp" "$f"
  while IFS= read -r old; do [ "$old" = "$f" ] || rm -f -- "$old"; done < <(_fs_epic_file "$dir" "$epic")
  printf '%s' "$(basename "$f")"
}

# backend_epic_issues <dir> <epic> <id> -> the epic's stories as one JSON array of {iid, title, open, story}; a story
# is closed when its status is terminal (Done, Archived, Wontfix, Duplicate, Invalid).
backend_epic_issues() {
  local dir="$1" epic="$2" d st
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    st="$(story_normalize_status "$(story_get_field "$d/requirements.md" Status)")"
    jq -cn --arg i "$(basename "$d")" --arg t "$(story_title_from_file "$d/requirements.md")" --arg s "$st" \
      '{iid:$i, title:$t, open:(($s|IN("Done","Archived","Wontfix","Duplicate","Invalid"))|not), story:true}'
  done < <(backend_epic_members "$dir" "$epic") | jq -cs '.'
}

# backend_epic_create <dir> <epic> <title> <goal> <start> <due> -> author the registry file; prints its name. A date is
# refused (a file has none).
backend_epic_create() {
  { [ -z "$5" ] && [ -z "$6" ]; } || { _fs_epic_no_state "start or due date"; return; }
  _fs_epic_write "$1" "$2" "$3" "$4"
}

# backend_epic_update <dir> <epic> <id> <changes-json> -> rewrite the title and goal given (the others are kept) and
# print the registry file's name, which a new title changes; a date or a state change is refused.
backend_epic_update() {
  local dir="$1" epic="$2" id="$3" changes="$4" cur title goal
  # The changes must be one readable JSON object: an empty or unreadable value changes nothing and is refused.
  printf '%s' "$changes" | json_test 'type == "object"' \
    || { printf 'story: epic %s: the requested changes are not a readable JSON object; nothing was changed.\n' "$epic" >&2; return 1; }
  printf '%s' "$changes" | json_test 'has("start_date") or has("due_date")' && { _fs_epic_no_state "start or due date"; return; }
  printf '%s' "$changes" | json_test 'has("active")' && { _fs_epic_no_state "open or closed state"; return; }
  cur="$(backend_epic_records "$dir" | jq -c --arg id "$id" '.[] | select(.id == $id)')"
  [ -n "$cur" ] || { printf 'story: epic %s has no registry file %s; nothing was changed.\n' "$epic" "$id" >&2; return 1; }
  title="$(jq -nr --argjson c "$changes" --argjson r "$cur" '$c.title // $r.title')"
  goal="$(jq -nr --argjson c "$changes" --argjson r "$cur" '$c.goal // $r.goal')"
  _fs_epic_write "$dir" "$epic" "$title" "$goal"
}

# backend_epic_delete <dir> <epic> <id> -> remove the epic's registry file.
backend_epic_delete() { rm -f -- "$1/_epics/$3"; }

# backend_epic_members <dir> <epic> -> the resolved handles (story dirs) belonging to an epic, one per line.
backend_epic_members() {
  local dir="$1" epic="$2" d e
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    e="$(story_get_field "$d/requirements.md" Epic)"
    [ "$e" = "$epic" ] || continue
    printf '%s\n' "$d"
  done < <(story_list_dirs "$dir")
}

# backend_is_done <dir> <handle> -> rc 0 iff the story's normalized status is Done.
backend_is_done() {
  [ "$(story_normalize_status "$(story_get_field "$2/requirements.md" Status)")" = "Done" ]
}

# backend_archive_story <dir> <epic> <handle> -> append a lessons line + an archived BACKLOG row into the
# epic's archive files, then mark the story Archived (idempotent on the Archived flag).
backend_archive_story() {
  local dir="$1" handle="$3" req="$3/requirements.md"
  local lessons="$dir/_archive/lessons.md" backlog_archive="$dir/_archive/BACKLOG-archive.md"
  mkdir -p "$dir/_archive"
  [ -f "$lessons" ] || printf '# Archived lessons\n\n' > "$lessons"
  [ -f "$backlog_archive" ] || printf '# Archived backlog rows\n\n' > "$backlog_archive"
  local id num summary
  id="$(basename "$handle")"
  num="$(printf '%03d' "$(story_num_from_id "$id")")"
  summary="$(story_oneline "$(story_get_field "$req" Summary)")"
  printf -- '- STORY-%s: %s\n' "$num" "$summary" >> "$lessons"
  story_emit_row "$handle" >> "$backlog_archive"
  if ! story_is_archived "$req"; then
    backend_fs_set_field_in_file "$req" "Archived" "true"
  fi
}

# backend_add_labels <dir> <handle> <csv-labels> -> add free labels to a story. Labels are a GitLab-native
# concept with no equivalent in a folder story, so the FS backend no-ops (the tracked-finding severity is also
# recorded in the story body, which the FS backend keeps).
backend_add_labels() { :; }

# backend_ensure_labels <dir> — project-label hygiene is a GitLab-native concept; no-op on the FS backend
# (a folder backlog has no project labels to materialize).
backend_ensure_labels() { :; }

# backend_set_phase <dir> <handle> <Phase> — ssdlc:phase is a GitLab label concept; no-op on the FS backend.
backend_set_phase() { :; }
# A local story has no tracker, so no assignee: claiming a created story is a no-op there.
backend_self_assign() { :; }

# backend_get_phase <dir> <handle> -> the FS backend has no phase LABEL; a folder story tracks no phase, so
# this returns empty (the monotonic-advance seam then treats TARGET as the phase to set — harmless under FS).
backend_get_phase() { printf ''; }
# backend_get_status <dir> <handle> -> the normalized Status of the folder story, read from its
# requirements.md Status bullet, so cmd_phase can freeze a BLOCKED story's phase under the FS backend too.
backend_get_status() { story_normalize_status "$(story_get_field "$2/requirements.md" Status)"; }

# backend_children_of <dir> <parent-num> -> the DIR handles of every story whose `- **Parent:**` bullet resolves
# to <parent-num>, in NNN order. Single scan of the story dirs — the child's Parent bullet is the sole
# source of truth. Never returns the parent's own dir.
backend_children_of() {
  local dir="$1" parent d dn p
  parent="$(story_parent_ref_normalize "$2")"; [ -n "$parent" ] || return 0
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    dn="$(story_num_from_id "$(basename "$d")")"
    [ "$dn" = "$parent" ] && continue
    p="$(story_parent_iid_from_body "$(cat "$d/requirements.md" 2>/dev/null)")"
    [ -n "$p" ] && [ "$p" = "$parent" ] && printf '%s\n' "$d"
  done < <(story_list_dirs "$dir")
}

# backend_note <dir> <handle> <text> — a folder story has no notes stream; the auto-close audit lives in the
# body's Status bullet + the transcript, so this is a no-op (parity seam for the gitlab backend).
backend_note() { :; }

# backend_close_umbrella <dir> <handle> — close a PARENT (umbrella) story: set its Status bullet to Done. No proof
# gate (the children are the evidence; see the gitlab backend's note). Parity with the gitlab seam.
backend_close_umbrella() { backend_fs_set_field_in_file "$2/requirements.md" "Status" "Done"; }

# backend_import_issue <dir> <iid> <title> <type> <epic> <desc-file> -> MIGRATION import (symmetry with the
# gitlab backend): materialize a story folder STORY-<iid>-imported whose requirements.md IS <desc-file>. Prints
# the iid. On the FS backend id is already the folder number, so this is a straight copy.
backend_import_issue() {
  local dir="$1" iid="$2" descfile="$6" sdir
  sdir="$dir/STORY-$(printf '%03d' "$iid")-imported"; mkdir -p "$sdir"
  [ -f "$descfile" ] && cp -f "$descfile" "$sdir/requirements.md"
  printf '%s' "$iid"
}

# [phase-walk gate] The FS backend keeps no event history, so the jump check cannot apply — treat the walk as
# satisfied rather than inventing a weaker heuristic (the gitlab backend is where the SSDLC record lives).
backend_phase_walked() { return 0; }
# backend_owner_override: a local story has no tracker and no owner who could apply an exception label.
backend_owner_override() { return 1; }
