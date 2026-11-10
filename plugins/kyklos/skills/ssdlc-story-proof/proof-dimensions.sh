#!/usr/bin/env bash
# proof-dimensions.sh — the SINGLE mechanical source of truth for the `## Proof` table's ROW SET.
#
# The canonical Quality-Dimension list (the base rows, in canonical order; Adversarial Review is appended by
# proof_canonical_dimensions while its gate is on, the default) lives in exactly ONE place:
# the `ALL=` line of `story-type-profile.sh` (sibling file). This library reads THAT value safely — it
# greps the literal `ALL="..."` assignment out of the profile script rather than SOURCING it (sourcing the
# profile executes an `echo`/`case` side-effect block), so there is one authoritative definition and no DRY
# drift. Both the `story proof` subcommand (which GENERATES the table) and kyklos-story-proof-guard.sh (which
# ENFORCES that a story's rows ARE that set) consume this library — a row the agent invents, merges, renames,
# or omits then cannot pass the gate.
#
# Sourced (never executed); defines functions + reads one constant. bash + grep/sed/awk only, so it runs in
# any ephemeral container. Fail-CLOSED for the generator (a missing profile is a build error worth surfacing),
# fail-OPEN for the guard (the guard checks `proof_dimensions_available` and simply skips its set-check when
# the list cannot be resolved — a broken deploy must never wedge the Stop loop).
# shell options: inherited from the caller (a sourced-only library; it never runs on its own).

# Directory of THIS file (so the profile sibling is found regardless of the caller's cwd).
_PROOF_DIM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROOF_PROFILE_SCRIPT="${PROOF_PROFILE_SCRIPT:-$_PROOF_DIM_DIR/story-type-profile.sh}"

# kyklos_control_enabled / kyklos_control_off: the ONE reader every Kyklos control shares (an unset, blank or
# unrecognized value ENFORCES; only an explicit off value disables). It lives in hooks/lib/control-switch.sh, the
# lowest level the hooks and the skills share; a per-gate hand-rolled parser is the defect class it replaces.
# shellcheck source=../../hooks/lib/control-switch.sh
. "$_PROOF_DIM_DIR/../../hooks/lib/control-switch.sh" 2>/dev/null || true   # kyklos_control_off: the one control-switch reader

# Operative-proof gate — a story whose change touches a CONTROL surface (Kyklos
# hooks, ssdlc skills, CI rules) must cite an END-TO-END RUN in its Proof: an own-CI suite tally
# ("<suite>: N passed, 0 failed") or a pipeline reference ("pipeline <id>" / a /-/pipelines/<id> URL). "Unit
# tests exist" is necessary but not sufficient for a control — a control can ship green
# on unit mocks while INERT in the real close path. DEFAULT-ON via the shared parser; fail-OPEN when the diff
# cannot be read or no control surface changed (an innocent story is never gated).
_proof_control_changed() {   # PROJECT_DIR -> rc 0 iff the working tree/last commit touches a control surface
  local proj="$1" changed
  command -v git >/dev/null 2>&1 || return 1
  git -C "$proj" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  changed="$( { git -C "$proj" diff --name-only HEAD 2>/dev/null
                git -C "$proj" diff --name-only HEAD~1 HEAD 2>/dev/null; } || true )"
  printf '%s\n' "$changed" | grep -cE '(^|/)hooks/[^/]+\.sh$|(^|/)skills/ssdlc-[^/]+/.*\.sh$|(^|/)\.gitlab-ci[^/]*\.yml$' >/dev/null
}
proof_operative_finding() {  # PROOF_TEXT PROJECT_DIR [STORY_ID] -> print a BLOCK reason, rc 0, iff the gate refuses
  local proof="$1" proj="$2" story="${3:-}"
  kyklos_control_off "${PROOF_OPERATIVE_GATE:-}" && return 1
  # ATTRIBUTION: this gate reads the LIVE repo diff, which only represents the
  # story whose change IS that diff. A story that shipped no code, closing right after a SIBLING story's
  # control-surface merge, was demanded a pipeline citation for a diff it never made (the exact false block the
  # close hit — the same class fixed on the tool-gates). Route through the SAME seam: only
  # gate while the diff is attributable to THIS story. Seam unavailable (partial install) or no story id ->
  # legacy behaviour (backward-compatible, like the tool-gates).
  if [ -n "$story" ]; then
    command -v _proof_tool_diff_attributable >/dev/null 2>&1 || {
      local _ptg="${KYKLOS_PROOF_TOOL_GATE_LIB:-$_PROOF_DIM_DIR/../../hooks/lib/proof-tool-gate.sh}"
      # A broken file is said, not swallowed; without the seam the change is judged as this story's (the strict side).
      [ -f "$_ptg" ] && { . "$_ptg" || printf 'proof-dimensions: cannot load %s; every change is judged as this story'"'"'s\n' "$_ptg" >&2; }
    }
    if command -v _proof_tool_diff_attributable >/dev/null 2>&1; then
      _proof_tool_diff_attributable "$proj" "$story" || return 1
    fi
  fi
  _proof_control_changed "$proj" || return 1
  printf '%s' "$proof" | grep -cE '[0-9]+ passed[,· ]+ *0 failed|pipeline ?#?[0-9]{2,}|/-/pipelines/[0-9]+' >/dev/null && return 1
  printf 'this story changes a CONTROL surface (Kyklos hooks / ssdlc skills / CI rules) but its Proof cites NO end-to-end run — cite the own-CI suite tally ("<suite>: N passed, 0 failed") or the pipeline ("pipeline <id>") that exercised the control in the REAL path\n'
  return 0
}

# The canonical verdict tokens. The story-proof gate blocks a Done story iff any row's VERDICT column contains
# the literal `UNPROVEN`; PROVEN and NOT_PERTINENT both pass.
PROOF_VERDICT_UNPROVEN='❌ UNPROVEN'
PROOF_VERDICT_NOT_PERTINENT='∅ NOT_PERTINENT'
PROOF_VERDICT_PROVEN='✅ PROVEN'

# proof_verdict_class <verdict-cell> -> PROVEN | UNPROVEN | NOT_PERTINENT on stdout (rc 0), or nothing (rc 1) for an
# unknown cell. The ONE shell classifier of a Verdict cell, with the same rules as classify() in proof-scan-table.awk:
# UNPROVEN is tested BEFORE PROVEN, because the word UNPROVEN contains PROVEN, so a substring test for PROVEN alone
# would count an UNPROVEN row as PROVEN.
# [RiskMitigation RA-01] UNPROVEN is tested first and an unknown cell is never classified, so no gate reads a non-PROVEN cell as PROVEN.
proof_verdict_class() {
  local u; u="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr -cd 'A-Z_')"
  case "$u" in
    *UNPROVEN*)                        printf 'UNPROVEN' ;;
    *NOT_PERTINENT*|*NOTPERTINENT*|NA|NP) printf 'NOT_PERTINENT' ;;
    *PROVEN*)                          printf 'PROVEN' ;;
    *) return 1 ;;
  esac
}

# proof_verdict_is_proven <verdict-cell> -> rc 0 iff the cell's verdict is exactly PROVEN (never UNPROVEN).
proof_verdict_is_proven() {
  [ "$(proof_verdict_class "$1")" = PROVEN ]
}

# The Story-KIND taxonomy: a story's `kind::` scoped label (gitlab) / `Kind` bullet (FS)
# selects WHICH canonical dimension set its Proof table carries. Unlike a story-TYPE profile (advisory pre-seeding
# of NOT_PERTINENT on the fixed row set), the KIND changes the ROW SET itself: an analysis/documentation story's
# table contains ONLY its kind's dimensions. The lighter sets are reachable ONLY through an explicit, verified
# kind value — every error/absence path resolves to `development` (the FULL set), so a fault can only RAISE rigor.
# [RiskMitigation RA-01] [CySec] Enforces CWE-693 "Protection Mechanism Failure": strictest-on-error kind
# resolution — an unreadable/ambiguous story kind can never select a lighter proof gate.
PROOF_KIND_DEFAULT='development'
PROOF_KIND_SET_ANALYSIS='Completeness|Adversarial Review'
PROOF_KIND_SET_DOCUMENTATION='Completeness|Documentation|Adversarial Review'
# The dimensions ONLY a development story carries: an ops story proves the full set minus these (an ops deliverable
# is bash/config/deployment, and script files are outside the i18n scan by definition).
PROOF_KIND_DEVELOPMENT_ONLY='i18n'

# proof_kind_normalize <raw> -> the canonical kind on stdout. `development` for empty/unknown/garbage input —
# the STRICTEST interpretation is the only default (poka-yoke: no input can accidentally select a lighter set).
proof_kind_normalize() {
  # TRIM surrounding whitespace only (matching the write-side sed), then exact-match.
  # An earlier `tr -d ' '` stripped INTERNAL spaces too, so a corrupted `analy sis` collapsed to the lighter
  # `analysis` — a fault LOWERING the gate. Trimming keeps only clean case/space variations recognisable; any
  # internal corruption falls through to development (the strictest set): a fault can only RAISE rigor.
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')" in
    analysis)      printf 'analysis' ;;
    documentation) printf 'documentation' ;;
    ops)           printf 'ops' ;;
    *)             printf '%s' "$PROOF_KIND_DEFAULT" ;;
  esac
}

# proof_kind_is_valid <raw> -> rc 0 iff <raw> is EXACTLY one of the three canonical kinds (case-insensitive).
# The WRITE-side validator (story new/adopt/set): unlike proof_kind_normalize (which coerces reads to the strict
# default), a write of an unknown kind must be REFUSED loudly, never silently coerced.
proof_kind_is_valid() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d ' ')" in
    development|analysis|documentation|ops) return 0 ;; *) return 1 ;;
  esac
}

# proof_kind_from_requirements <requirements.md> -> the raw `- **Kind:**` bullet value (empty if absent/unreadable).
# The FS-side kind reader shared by the CLI and the close guard (one implementation, no drift).
proof_kind_from_requirements() {
  [ -f "${1:-}" ] || return 0
  sed -nE 's/^[[:space:]]*[-*][[:space:]]+\*\*Kind:\*\*[[:space:]]*(.*)$/\1/p' "$1" | head -1
}

# Print the canonical dimension list FOR A KIND, one dimension per line, in canonical order.
# $1 (optional) = the story kind; empty/unknown -> development (the full set — today's exact behaviour).
# Reads the literal `ALL="..."` assignment from the profile script (NOT by sourcing it). Empty output +
# return 1 if the profile script or its ALL= line cannot be found (caller decides fail-open vs fail-closed).
proof_canonical_dimensions() {
  [ -f "$PROOF_PROFILE_SCRIPT" ] || return 1
  local kind all full keep dim
  kind="$(proof_kind_normalize "${1:-}")"
  # Grab the first `ALL="..."` assignment's quoted value, then split on the '|' separator.
  all="$(grep -m1 -E '^[[:space:]]*ALL=' "$PROOF_PROFILE_SCRIPT" 2>/dev/null \
         | sed -E 's/^[[:space:]]*ALL=//; s/^"//; s/"[[:space:]]*$//')"
  [ -n "$all" ] || return 1
  full="$(printf '%s\n' "$all" | tr '|' '\n')"
  # Append the "Adversarial Review" dimension while its gate (KYKLOS_ADVREVIEW_GATE) is on. It is kept OUT of the
  # static ALL= line so this one place decides it. It is on unless the switch holds an explicit off value
  # (off/0/false/no): unset, blank and any other value (a typo included) keep the row.
  kyklos_control_off "${KYKLOS_ADVREVIEW_GATE:-}" || full="$(printf '%s\n%s' "$full" 'Adversarial Review')"
  # A non-development kind FILTERS the full list down to its own set — filtering (never a literal
  # emit) preserves the canonical ORDER and the Adversarial-Review gate semantics in one place.
  case "$kind" in
    analysis)      keep="$PROOF_KIND_SET_ANALYSIS" ;;
    documentation) keep="$PROOF_KIND_SET_DOCUMENTATION" ;;
    ops)           keep="$(printf '%s\n' "$full" | grep -vxE "$PROOF_KIND_DEVELOPMENT_ONLY" | paste -sd'|' -)" ;;
    *)             printf '%s\n' "$full"; return 0 ;;
  esac
  while IFS= read -r dim; do
    [ -n "$dim" ] || continue
    case "|$keep|" in *"|$dim|"*) printf '%s\n' "$dim" ;; esac
  done <<PROOF_KIND_FULL
$full
PROOF_KIND_FULL
}

# True (exit 0) iff the canonical dimension list can be resolved. Used by the guard to decide whether to run
# its set-check at all (fail-open: skip when unavailable).
proof_dimensions_available() {
  proof_canonical_dimensions >/dev/null 2>&1
}

# Print the pipe-delimited PERTINENT list for a story type by delegating to the profile script (the ONE place
# that maps type -> pertinence). Empty + return 1 if the profile cannot be run.
proof_pertinent_for_type() {
  local type="$1"
  [ -f "$PROOF_PROFILE_SCRIPT" ] || return 1
  bash "$PROOF_PROFILE_SCRIPT" "$type" 2>/dev/null | sed -n 's/^PERTINENT: //p' | head -1
}

# Emit the full canonical `## Proof` section for a story TYPE (and KIND) to stdout.
# $1 = story type (may be empty/unknown -> the profile falls back to the full set: the ALL= rows plus Adversarial
# Review while its gate is on).
# $2 = story kind (optional; empty/unknown -> development). A non-development kind REDUCES the row set
# to its own canonical dimensions, and every row in that set is LIVE (the type profile's NOT_PERTINENT pre-seeding
# applies only to development — a kind row must never be pre-waived by an unrelated type profile, e.g. type=docs
# whose PERTINENT set lacks Completeness).
# A dimension that is N/A per the profile is pre-filled NOT_PERTINENT with a stock reason; a pertinent
# dimension is left UNPROVEN with empty evidence (the agent fills evidence/verdict only). Ends with a Tally
# PLACEHOLDER line (both counts left as `_` — the agent flips verdicts as it proves rows, which changes the
# counts, so pre-filling a number would only go stale). Returns 1 (prints nothing) if the canonical list
# cannot be resolved.
proof_emit_table() {
  local type="${1:-}" kind pert dim
  kind="$(proof_kind_normalize "${2:-}")"
  proof_dimensions_available || return 1
  if [ "$kind" = "$PROOF_KIND_DEFAULT" ] || [ "$kind" = "ops" ]; then
    pert="|$(proof_pertinent_for_type "$type")|"
  else
    pert="|$(proof_canonical_dimensions "$kind" | paste -sd'|' -)|"
  fi

  # The 4th "Metrics" column cites the TOOLS + OUTPUT metrics that back a tool-computable dimension
  # (greppable `<kbd>{Metric} ({Tool}):</kbd> {Value}<br>` groups). Additive: proof_scan_table width-baselines from
  # the header and reads the Verdict at the 2nd content cell regardless of column count, so an OLD 3-column note
  # still validates. Default cell is an em-dash (nothing measured yet / NOT_PERTINENT).
  printf '## Proof\n\n'
  printf '| Quality Dimension | Verdict | Evidence | Metrics |\n'
  printf '|-------------------|---------|----------|---------|\n'
  while IFS= read -r dim; do
    [ -n "$dim" ] || continue
    case "$pert" in
      *"|$dim|"*)
        printf '| %s | %s |  | — |\n' "$dim" "$PROOF_VERDICT_UNPROVEN" ;;
      *)
        printf '| %s | %s | (not pertinent for a %s story) | — |\n' "$dim" "$PROOF_VERDICT_NOT_PERTINENT" "${type:-untyped}" ;;
    esac
  done < <(proof_canonical_dimensions "$kind")
  printf '\n**Tally: _ PROVEN · _ NOT_PERTINENT_**\n'
}

# proof_table_row_index <table> -> one line per DATA row: <line-number><TAB><dimension> (emphasis/backticks stripped,
# trimmed; the header and the |---| separator are not data rows). The ONE reader of the Dimension column: the
# canonical set-check and the missing-row upgrade both use it, so they can never disagree on what a row is.
proof_table_row_index() {
  printf '%s\n' "$1" | awk -F'|' -f "$_PROOF_DIM_DIR/proof-row-index.awk"
}

# proof_add_missing_rows <table> <type> <kind> -> the stored table with every canonical dimension it lacks INSERTED
# at its canonical position, pre-seeded exactly as a fresh scaffold would be (UNPROVEN, or the profile's
# NOT_PERTINENT). Existing rows, verdicts, evidence and every non-row line are kept byte-for-byte; an unchanged
# table is returned as-is. This is the upgrade path when the canonical set grows (a story whose proof was written
# before a new dimension existed): `story proof --set` can then fill the new row instead of failing with
# "unknown dimension". A 3-column table gets 3-column rows so its width stays consistent.
proof_add_missing_rows() {
  local table="$1" type="${2:-}" kind="${3:-}" canon scaffold index present missing="" line d idx n=0 last_row width
  canon="$(proof_canonical_dimensions "$kind")" || { printf '%s' "$table"; return 0; }
  index="$(proof_table_row_index "$table")"
  [ -n "$index" ] || { printf '%s' "$table"; return 0; }
  present="|$(printf '%s\n' "$index" | cut -f2 | paste -sd'|' -)|"
  while IFS= read -r d; do
    case "$present" in *"|$d|"*) : ;; *) missing="$missing|$d|" ;; esac
  done <<<"$canon"
  [ -n "$missing" ] || { printf '%s' "$table"; return 0; }
  scaffold="$(proof_emit_table "$type" "$kind")" || { printf '%s' "$table"; return 0; }
  width="$(printf '%s\n' "$table" | grep -m1 '| Quality Dimension |' | tr -cd '|' | wc -c)"
  # emit the missing canonical rows whose canonical index is below $1, in order (each at most once).
  _proof_emit_missing_before() {
    local limit="$1" i=0 c r
    while IFS= read -r c; do
      i=$((i + 1))
      [ "$i" -lt "$limit" ] || break
      case "$missing" in *"|$c|"*) : ;; *) continue ;; esac
      missing="${missing/"|$c|"/}"
      r="$(printf '%s\n' "$scaffold" | grep -m1 -F "| $c | ")"
      [ "$width" = 4 ] && r="${r% — |}" && r="${r% |}" && r="$r |"
      printf '%s\n' "$r"
    done <<<"$canon"
  }
  last_row="$(printf '%s\n' "$index" | tail -1 | cut -f1)"
  while IFS= read -r line; do
    n=$((n + 1))
    d="$(printf '%s\n' "$index" | awk -F'\t' -v n="$n" '$1 == n { print $2; exit }')"
    if [ -n "$d" ]; then
      idx="$(printf '%s\n' "$canon" | grep -nxF "$d" | head -1 | cut -d: -f1)"
      [ -n "$idx" ] && _proof_emit_missing_before "$idx"
    fi
    printf '%s\n' "$line"
    [ "$n" -eq "$last_row" ] && _proof_emit_missing_before 100000
  done <<<"$table"
}

# proof_normalize_verdict <word> -> the canonical verdict string on stdout; rc 1 if the word is unknown.
# Accepts case-insensitive PROVEN | NOT_PERTINENT (aliases N/A, NA, NP, NOT-PERTINENT) | UNPROVEN.
proof_normalize_verdict() {
  case "$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr -d ' ')" in
    PROVEN)                               printf '%s' "$PROOF_VERDICT_PROVEN" ;;
    NOT_PERTINENT|NOT-PERTINENT|N/A|NA|NP) printf '%s' "$PROOF_VERDICT_NOT_PERTINENT" ;;
    UNPROVEN)                             printf '%s' "$PROOF_VERDICT_UNPROVEN" ;;
    *) return 1 ;;
  esac
}

# proof_apply_verdict <table> <dimension> <verdict-word> [evidence] [metrics] -> the table with that dimension's
# row's Verdict (and, if given, Evidence and — on a 4-column table — Metrics) columns replaced. Case-insensitive
# dimension match on the trimmed name. rc 1 if the verdict word is unknown or the dimension row is not found (so a
# typo fails loud, never silently). The Metrics cell is written only when the row actually HAS one (a 4-column
# table); on an old 3-column table a metrics arg is ignored (regenerate the table to get the column).
proof_apply_verdict() {
  local table="$1" dim="$2" vword="$3" evidence="${4:-}" metrics="${5:-}" verdict
  verdict="$(proof_normalize_verdict "$vword")" || return 1
  # [Poka-Yoke] A literal '|' in a cell is the CELL DELIMITER: left raw it splits the row into extra cells, which
  # shifts the verdict out of its column and makes the awk tally MISCOUNT (a silent corruption). Escape it to the
  # HTML entity '&#124;' — GitLab/GitHub render it as '|' in the cell, but it contains no literal pipe, so the row
  # stays clean and the tally is correct. (A markdown '\|' would render but still break the awk split.)
  evidence="${evidence//|/"&#124;"}"   # quote the replacement: bash 5.x treats a bare & as the matched text
  metrics="${metrics//|/"&#124;"}"
  printf '%s' "$table" | awk -v dim="$dim" -v verdict="$verdict" -v ev="$evidence" -v haveev="${4+1}" \
                             -v mx="$metrics" -v havemx="${5+1}" \
                             -f "$_PROOF_DIM_DIR/proof-apply-verdict.awk" 2>/dev/null
  local rc=$?
  [ "$rc" -eq 3 ] && return 1 || return 0
}

# The tool-gated dimensions whose PROVEN verdict MUST cite a Metrics group when the metrics gate is armed.
PROOF_METRICS_MANDATORY_DIMS='Test Discipline|Non-Duplication|Documentation|Risk Assessment'

# proof_metrics_gate_on -> rc 0 iff the Metrics enforcement is armed. DEFAULT-ON: an opt-in gate is inert in every
# repo that never sets the flag, so a story could close with a PROVEN cell that cites no metric. It enforces
# everywhere by default; a repo that genuinely cannot comply must EXPLICITLY opt OUT (PROOF_METRICS_GATE=off|0|false|no).
# An unset/blank/garbage value ENFORCES (fail-safe: the safe default is to enforce, never to silently fail open).
proof_metrics_gate_on() {
  ! kyklos_control_off "${PROOF_METRICS_GATE:-}"   # the shared deterministic parser
}

# proof_metrics_cell_empty <cell> -> rc 0 iff the Metrics cell carries no real metric (blank, an em/hyphen dash, or
# 'n/a'). Used to require a non-empty Metrics cell for a mandatory dimension's PROVEN row.
proof_metrics_cell_empty() {
  local c; c="$(printf '%s' "$1" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
  case "$c" in ''|'-'|'—'|'–'|'n/a'|'na'|'none') return 0 ;; *) return 1 ;; esac
}

# proof_metrics_set_problem <dimension> <verdict> <metrics-cell> -> print a REFUSAL reason when the metrics gate is
# armed (DEFAULT-ON) and this (dimension, PROVEN, metrics) combination violates it, else nothing. The ONE place the CLI
# (--set) and the close guard both consult, so the rule can never diverge between them. Only fires for a PROVEN
# verdict on a MANDATORY dimension; NOT_PERTINENT / UNPROVEN and non-mandatory dimensions are never gated.
proof_metrics_set_problem() {   # <dimension> <verdict> <metrics-cell> [src-root — stack detection] [kind]
  local dim="$1" verdict="$2" metrics="$3" src_root="${4:-}" kind="${5:-}"
  proof_metrics_gate_on || return 0
  # i18n is checked for EVERY verdict, not only PROVEN: its NOT_PERTINENT is itself a refusal on a development story.
  if [ "$(printf '%s' "$dim" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')" = "$PROOF_I18N_DIMENSION" ]; then
    proof_i18n_problem "$verdict" "$metrics" "$kind"
    return 0
  fi
  proof_verdict_is_proven "$verdict" || return 0   # only PROVEN is gated; UNPROVEN and NOT_PERTINENT never are
  local d; d="$(printf '%s' "$dim" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
  # The ops kind exempts the Test Discipline METRICS (coverage %) — an ops deliverable (bash/config/deployment)
  # may be PROVEN without a coverage number when the technology cannot be tested or testing is destructive. ONLY
  # Test Discipline, ONLY for a genuine ops kind (normalised — any corruption resolves to development); every
  # OTHER dimension and every other kind keeps full rigor.
  case "$(proof_kind_normalize "$kind")|$d" in "ops|Test Discipline") return 0 ;; esac
  case "|$PROOF_METRICS_MANDATORY_DIMS|" in *"|$d|"*) : ;; *) return 0 ;; esac
  if proof_metrics_cell_empty "$metrics"; then
    printf "dimension '%s' is PROVEN but its Metrics cell cites no tool/metric — a tool-gated dimension must cite the tool(s) + output value(s) as '<kbd>{Metric} ({Tool}):</kbd> {Value}<br>' (PROOF_METRICS_GATE is on)" "$d"
    return 0
  fi
  # Per-dimension numeric thresholds (Test Discipline max-CRAP / min-coverage) are layered on through
  # proof_metrics_dimension_threshold_problem, kept as a separate seam so they extend this check without touching
  # the mandatory-cell rule above.
  if command -v proof_metrics_dimension_threshold_problem >/dev/null 2>&1; then
    proof_metrics_dimension_threshold_problem "$d" "$metrics" "$src_root"
  fi
}

# The i18n dimension: every user-facing string a development story adds or changes is found and promoted into
# centralized, deduplicated i18n resources (the ssdlc-i18n skill is the doer). Its three metrics are MANDATORY and
# must add up, so the row cannot be hand-waved: Candidates = Promoted + Ignored.
PROOF_I18N_DIMENSION='i18n'
PROOF_I18N_METRICS='Candidates Promoted Ignored'

# proof_i18n_metric_value <metrics-cell> <metric> -> the integer value of '<kbd>{metric} ({tool}):</kbd> {N}' on
# stdout (rc 0), or nothing (rc 1) when the group is absent, cites no tool, or its value is not a whole number.
proof_i18n_metric_value() {
  printf '%s' "$1" | grep -oiE "<kbd>[[:space:]]*$2[[:space:]]*\\([^)<]*[^[:space:])<][^)<]*\\)[[:space:]]*:?[[:space:]]*</kbd>[[:space:]]*[0-9]+([^0-9.]|$)" \
    | head -1 | sed -E 's/.*<\/kbd>[[:space:]]*([0-9]+).*/\1/' | grep -E '^[0-9]+$'
}

# proof_i18n_problem <verdict> <metrics-cell> [kind] -> print a REFUSAL for the i18n row, else nothing. Only a
# development story carries the row (other kinds are filtered out of the set, so a row there is reported by the
# set-check). On development: NOT_PERTINENT is refused (a change without user-facing strings proves it with zero
# candidates instead); PROVEN needs all three metrics, each citing its tool, and Promoted + Ignored == Candidates.
# UNPROVEN is left to the normal UNPROVEN gate.
proof_i18n_problem() {
  local verdict="$1" metrics="$2" kind m v missing="" c p i
  kind="$(proof_kind_normalize "${3:-}")"
  [ "$kind" = "$PROOF_KIND_DEFAULT" ] || return 0
  case "$(proof_verdict_class "$verdict")" in
    NOT_PERTINENT)
      printf "dimension 'i18n' cannot be NOT_PERTINENT on a development story — run the ssdlc-i18n skill; a change with no user-facing strings proves it as '<kbd>Candidates (<scanner>):</kbd> 0<br><kbd>Promoted (<scanner>):</kbd> 0<br><kbd>Ignored (<scanner>):</kbd> 0'"
      return 0 ;;
    PROVEN) : ;;
    *) return 0 ;;
  esac
  for m in $PROOF_I18N_METRICS; do
    v="$(proof_i18n_metric_value "$metrics" "$m")" || { missing="${missing:+$missing, }$m"; continue; }
    case "$m" in Candidates) c="$v" ;; Promoted) p="$v" ;; Ignored) i="$v" ;; esac
  done
  if [ -n "$missing" ]; then
    printf "dimension 'i18n' is PROVEN but its Metrics cell lacks %s — each must be a whole number citing the tool that produced it, as '<kbd>{Metric} ({Tool}):</kbd> {N}<br>'" "$missing"
    return 0
  fi
  if [ $((p + i)) -ne "$c" ]; then
    printf "dimension 'i18n' metrics do not add up: Promoted %s + Ignored %s = %s, but Candidates is %s — every candidate must be either promoted or ignored with a reason" "$p" "$i" "$((p + i))" "$c"
  fi
  return 0
}

# proof_metrics_dimension_threshold_problem <dimension> <metrics-cell> -> per-dimension NUMERIC threshold checks,
# print a refusal (or nothing) for the gated dimension (today: Test Discipline max-CRAP and min-coverage).
proof_metrics_dimension_threshold_problem() {   # <dimension> <metrics-cell> [src-root]
  local dim="$1" metrics="$2" src_root="${3:-}" out="" cov
  case "$dim" in
    "Test Discipline")
      # max-CRAP + min-coverage — a PROVEN failing BOTH reports both (joined with '; ').
      # The CRAP ceiling follows the same one-source-of-truth rule as the coverage floor below: an explicit
      # PROOF_TD_MAX_CRAP wins; else the repository's own declared CRAP_THRESHOLD (the bar its CI crap-gate
      # enforces); else 30. The refusal names the setting that produced the ceiling.
      local _crap_max _crap_src
      if [ -n "${PROOF_TD_MAX_CRAP:-}" ]; then _crap_max="$PROOF_TD_MAX_CRAP"; _crap_src="PROOF_TD_MAX_CRAP"
      elif [ -n "${CRAP_THRESHOLD:-}" ]; then _crap_max="$CRAP_THRESHOLD"; _crap_src="CRAP_THRESHOLD"
      else _crap_max=30; _crap_src="the default"; fi
      # name WHERE the setting came from (the story's repository, this workspace, or neither) so a refusal is traceable
      [ -n "${STORY_THRESHOLD_SOURCE:-}" ] && _crap_src="$_crap_src, from $STORY_THRESHOLD_SOURCE"
      out="$(proof_td_crap_problem "$metrics" "$_crap_max" "$src_root" "$_crap_src")"
      # The coverage FLOOR is not decided here: the bridge decides it (the project floor, the project minimum and the
      # story's own Coverage-Floor line) and judges it at the proof write and at the close. This plugin only checks that
      # the cell DECLARES a coverage figure, so a row without one is refused before it reaches the bridge.
      cov="$(proof_td_coverage_missing_problem "$metrics")"
      [ -n "$cov" ] && out="${out:+$out; }$cov"
      ;;
    "Non-Duplication")
      # the dedup-scan report is too large for the cell, so it must be ATTACHED to the issue and LINKED.
      out="$(proof_nondup_link_problem "$metrics")"
      ;;
    "Documentation")
      # "docs updated" must LINK the changed doc file(s) in the source repo, not just assert it.
      out="$(proof_doc_link_problem "$metrics")"
      ;;
  esac
  [ -n "$out" ] && printf '%s' "$out"
  return 0
}

# proof_metrics_has_link <metrics-cell> -> 0 when the cell carries a LINK (a markdown link "[text](url)", a GitLab
# "/uploads/" attachment reference, or an "http(s)://" URL), else 1. The ONE shared link detector for every dimension
# whose Metrics cell must cite an artifact by link — (Non-Duplication report) and (changed doc files) both
# call it, so their link rule can never drift apart.
proof_metrics_has_link() {
  printf '%s' "$1" | grep -cE '\[[^]]+\]\([^)]+\)|/uploads/|https?://' >/dev/null
}

# proof_nondup_link_problem <metrics-cell> -> print a REFUSAL when the Non-Duplication Metrics cell carries no LINK to
# the duplication-report attachment; else nothing. The full dedup report is too large for the cell, so a
# PROVEN must LINK the attached report (a markdown link, a GitLab /uploads/ reference, or an http(s) URL) — asserting
# "no duplications" without the attached tool output is refused. (proof_metrics_set_problem already requires a
# non-empty Metrics cell; this additionally requires a link.)
proof_nondup_link_problem() {
  proof_metrics_has_link "$1" && return 0
  printf 'Non-Duplication PROVEN requires the Metrics cell to LINK the duplication-report attachment (e.g. "[jscpd report](/uploads/...)") — attach the scan output with "story attach <report-file>" and cite the link it prints, not just summarise it (PROOF_METRICS_GATE is on)'
}

# proof_doc_link_problem <metrics-cell> -> print a REFUSAL when the Documentation Metrics cell carries no LINK to a
# changed documentation file; else nothing. "docs updated" must be demonstrated by a clickable GitLab link to
# the actual changed doc file(s) in the source repo (a markdown link, a GitLab /-/blob//uploads/ reference, or an
# http(s) URL) — asserting the docs changed without a link the reader can open is refused. (proof_metrics_set_problem
# already requires a non-empty Metrics cell; this additionally requires it to be a LINK.)
# [RiskMitigation RA-01] CI-integrity: this gate is DEFAULT-ON (explicit PROOF_METRICS_GATE=off to opt a repo
# out) and a pure, unit-tested text predicate — it can only refuse a PROVEN Documentation, never mutate state or
# block a repo that opted out, so it cannot wrongly wedge other projects.
proof_doc_link_problem() {
  proof_metrics_has_link "$1" && return 0
  printf 'Documentation PROVEN requires the Metrics cell to LINK the changed documentation file(s) in the source repo (e.g. "[docs/topic.md](https://.../-/blob/<sha>/docs/topic.md)") — cite the actual changed doc file(s) so the reader can open them, not just assert the docs were updated (PROOF_METRICS_GATE is on)'
}

# proof_td_coverage_value <metrics-cell> -> the line-coverage percentage the cell declares (without the %), or
# nothing. Read per <br> segment, the same way as the CRAP score: a percentage is taken only from the text AFTER a
# segment's </kbd>, never from its label, so a floor, a job id or a run number named in the label is never the
# coverage. Preference: (1) the first segment whose label names coverage; (2) an unlabelled segment, by the first
# percentage after the word 'cover'; (3) the first percentage after the label of any other segment. A segment that
# names mutation is skipped in (2) and (3), so a mutation score is never read as coverage. HTML-escaped tags read the
# same.
# [RiskMitigation RA-03] CI integrity: only the declared coverage can pass the story-close coverage floor.
proof_td_coverage_value() {
  printf '%s' "$1" | sed -e 's/&lt;/</g' -e 's/&gt;/>/g' | awk '
    function pct(s,   t) {
      if (!match(s, /[0-9]+(\.[0-9]+)?[ \t]*%/)) return ""
      t = substr(s, RSTART, RLENGTH); sub(/[ \t]*%$/, "", t); return t
    }
    { text = text (NR > 1 ? "<br>" : "") $0 }
    END {
      n = split(text, seg, /<br *\/?>/)
      labelled = ""; plain = ""; other = ""
      for (i = 1; i <= n; i++) {
        k = index(seg[i], "</kbd>")
        if (k > 0) {
          label = tolower(substr(seg[i], 1, k - 1)); v = pct(substr(seg[i], k + 6))
          if (v == "") continue
          if (label ~ /cover/) { if (labelled == "") labelled = v }
          else if (label !~ /mutat|mutant/ && other == "") other = v
        } else {
          s = tolower(seg[i])
          if (s ~ /mutat|mutant/) continue
          if (plain == "" && match(s, /cover[^%]*[0-9]+(\.[0-9]+)?[ \t]*%/)) plain = pct(substr(s, RSTART + 5, RLENGTH - 5))
          else if (other == "") other = pct(s)
        }
      }
      if (labelled != "") print labelled; else if (plain != "") print plain; else if (other != "") print other
    }'
}

# proof_td_coverage_missing_problem <metrics-cell> -> print a REFUSAL when the Metrics cell declares no coverage
# percentage; else nothing. Fail-CLOSED: a Test Discipline PROVEN must carry a real coverage number. It never compares
# the number with a floor: the floor is the bridge's alone (project floor, project minimum, the story's Coverage-Floor).
proof_td_coverage_missing_problem() {   # <metrics>
  [ -n "$(proof_td_coverage_value "$1")" ] && return 0
  printf 'Test Discipline PROVEN requires a coverage percentage in the Metrics cell (e.g. "<kbd>Line coverage (cobertura):</kbd>98%%"), but none was found'
}

# proof_source_root <project-dir> -> the SOURCE root the stack-detection (and any diff-scoped gate)
# should look at: the nested $KYKLOS_SOURCE_DIR under a companion-shaped project, else the project dir itself.
# The ONE resolver both the CLI and the close guard use (the guard's _tool_gate_source_root delegates here).
proof_source_root() {
  local proj="${1:-}"
  [ -n "$proj" ] || { printf ''; return 0; }
  local sub="${KYKLOS_SOURCE_DIR:-Repo}"
  # Explicit companion shape wins (declared env).
  if [ "${KYKLOS_REPO_SHAPE:-}" = companion ] && [ -d "$proj/$sub" ]; then
    printf '%s' "$proj/$sub"; return 0
  fi
  # Poka-yoke AUTO-DETECT of the nested source, so stack-detection (CRAP applicability) can NEVER
  # silently miss a companion's .NET source just because KYKLOS_REPO_SHAPE was not set in that project's env
  # (the opt-in-inert class — a companion .NET story otherwise closes CRAP-less because the companion's OWN git
  # diff never contains the .cs files, which live in the nested, git-ignored <sub>/). Trigger ONLY when <sub>/
  # positively looks like a nested SOURCE root — its own `.git` (companion-nested clone) OR a .NET project/solution
  # file near its top — so a normal single-repo project (with no such subdir) is completely unaffected.
  if [ -d "$proj/$sub" ] && { [ -e "$proj/$sub/.git" ] || \
       [ -n "$(find "$proj/$sub" -maxdepth 2 \( -name '*.csproj' -o -name '*.sln' -o -name '*.slnx' \) -not -path '*/node_modules/*' -print -quit 2>/dev/null)" ]; }; then
    printf '%s' "$proj/$sub"; return 0
  fi
  printf '%s' "$proj"
}

# proof_td_crap_applicable <src-root> -> rc 0 iff CRAP applies. Explicit env wins BOTH ways
# (`PROOF_TD_CRAP_APPLICABLE=off|0|false|no` = the greppable opt-out; an explicit on-value forces it); UNSET
# AUTO-DETECTS: a source root that POSITIVELY contains .NET project/solution files is CRAP-capable (cobertura
# complexity exists for .NET), because an opt-IN flag would let a .NET repo that never set it silently skip
# CRAP. An unknown/empty
# root with the flag unset stays NOT applicable (a context that cannot see the stack must never false-block).
proof_td_crap_applicable() {
  local root="${1:-}"
  kyklos_switch_explicit_on "${PROOF_TD_CRAP_APPLICABLE:-}" && return 0
  kyklos_control_off "${PROOF_TD_CRAP_APPLICABLE:-}" && return 1
  [ -n "$root" ] && [ -d "$root" ] || return 1
  # STORY-FIRST: when the story is known (PROOF_TD_STORY, set by the story tool), CRAP applies iff the story's own change
  # (the proof CLI's change window: its merge against the first parent, its own commits, or its branch) holds a .NET
  # file; a shell-only story is judged by its shell receipt, whatever stack the source root holds and whatever else
  # merged since. A window that cannot be read falls through to the checks below, which never relax.
  local _story_window
  if [ -n "${PROOF_TD_STORY:-}" ] && [ -f "$_PROOF_DIM_DIR/../../hooks/lib/proof-tool-gate.sh" ] \
    && _story_window="$(bash "$_PROOF_DIM_DIR/../../hooks/lib/proof-tool-gate.sh" changed-files "$root" --story "$PROOF_TD_STORY" 2>/dev/null)" \
    && [ -n "$(printf '%s' "$_story_window" | tr -d '[:space:]')" ]; then
    printf '%s\n' "$_story_window" | grep -cE '\.(cs|csproj|sln|slnx|fs|fsproj|vb|vbproj|props|targets|razor|cshtml)$' >/dev/null
    return $?
  fi
  # DIFF-FIRST (precise for a MIXED bash+.NET repo): when the story's own recent change (working tree + last
  # commit — the same window the other diff-scoped gates read) is readable, CRAP is applicable iff that change
  # touches .NET files; a bash-only story in a mixed repo is then never asked for a metric it cannot compute.
  if command -v git >/dev/null 2>&1 && git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    local _changed
    _changed="$( { git -C "$root" diff --name-only HEAD 2>/dev/null
                   git -C "$root" diff --name-only HEAD~1 HEAD 2>/dev/null; } || true )"
    if [ -n "$(printf '%s' "$_changed" | tr -d '[:space:]')" ]; then
      printf '%s\n' "$_changed" | grep -cE '\.(cs|csproj|sln|slnx|fs|fsproj|vb|vbproj)$' >/dev/null
      return $?
    fi
  fi
  # TREE-PRESENCE fallback (no git / empty diff): a source root that positively contains .NET project/solution
  # files is CRAP-capable — covers a pure-.NET repo whose story diff is already merged away. Bounded find
  # (depth-capped, first hit wins) so a Stop-hook path stays fast on a large tree.
  [ -n "$(find "$root" -maxdepth 4 \( -name '*.csproj' -o -name '*.slnx' -o -name '*.sln' \) -not -path '*/node_modules/*' -not -path '*/.git/*' -print -quit 2>/dev/null)" ]
}

# proof_td_crap_value <metrics-cell> -> the CRAP score the cell declares, or nothing. The cell is read per <br>
# segment, each by its own shape: a labelled segment ("<kbd>Max CRAP (crap gate, run 6697b908):</kbd> 32.6") by its
# label - the text before </kbd> must name CRAP, and the value is the first number AFTER it, so a number inside the
# label (a run id, a pipeline id, a threshold) is never taken for the score; an unlabelled segment ("CRAP 40") by the
# first number that follows the word 'crap'. The first CRAP found wins. HTML-escaped tags (&lt;kbd&gt;) read the same.
proof_td_crap_value() {
  printf '%s' "$1" | sed -e 's/&lt;/</g' -e 's/&gt;/>/g' | awk '
    BEGIN { found = "" }
    {
      n = split($0, seg, /<br *\/?>/)
      for (i = 1; i <= n && found == ""; i++) {
        k = index(seg[i], "</kbd>")
        if (k > 0) {
          label = tolower(substr(seg[i], 1, k - 1)); value = substr(seg[i], k + 6)
          if (label ~ /crap/ && match(value, /[0-9]+(\.[0-9]+)?/)) found = substr(value, RSTART, RLENGTH)
        } else if (match(tolower(seg[i]), /crap[^0-9]*[0-9]+(\.[0-9]+)?/)) {
          m = substr(seg[i], RSTART, RLENGTH)
          if (match(m, /[0-9]+(\.[0-9]+)?$/)) found = substr(m, RSTART, RLENGTH)
        }
      }
    }
    END { if (found != "") print found }'
}

# proof_td_crap_problem <metrics-cell> <max-crap> [src-root] -> print a REFUSAL when the CRAP declared in the Metrics
# cell EXCEEDS <max-crap>; a MISSING CRAP is refused when CRAP is APPLICABLE to this project's stack.
# Applicability = proof_td_crap_applicable: explicit env wins; else AUTO-DETECTED from the source root (.NET files
# present -> applicable — DEFAULT-ON for the stacks that can compute CRAP; bash/PowerShell repos stay N/A and
# COVERAGE carries Test Discipline). A PRESENT CRAP is ALWAYS thresholded (a cited bad score never passes,
# regardless of the flag). Decimal-safe (awk compare).
proof_td_crap_problem() {
  local metrics="$1" max_crap="$2" src_root="${3:-}" max_src="${4:-PROOF_TD_MAX_CRAP}" crap
  # A ceiling that is not a number would make every comparison meaningless; refuse loudly instead of guessing.
  if ! printf '%s' "$max_crap" | grep -c -E '^[0-9]+(\.[0-9]+)?$' >/dev/null; then
    printf 'Test Discipline CRAP ceiling %s from %s is not a number - fix the setting' "$max_crap" "$max_src"
    return 0
  fi
  crap="$(proof_td_crap_value "$metrics")"
  if [ -z "$crap" ]; then
    if proof_td_crap_applicable "$src_root"; then
      printf 'Test Discipline PROVEN requires a CRAP score in the Metrics cell (e.g. "<kbd>Max CRAP (crap-gate):</kbd>27"), but none was found — CRAP is APPLICABLE here (explicit PROOF_TD_CRAP_APPLICABLE, or a .NET stack auto-detected in the source root; a stack that truly cannot compute CRAP opts out with PROOF_TD_CRAP_APPLICABLE=off)'
    fi
  elif awk -v c="$crap" -v m="$max_crap" 'BEGIN{exit !((c+0) > (m+0))}'; then
    printf 'Test Discipline CRAP %s EXCEEDS the configured maximum %s (%s)' "$crap" "$max_crap" "$max_src"
  fi
}

# Correlation map: each mapped dimension's Metrics cell must MENTION every item/criteria identifier declared in
# the LINKED story section, so the Proof Table demonstrably covers what the story declared (not just generic quality).
# One entry per line: "<dimension>|<section-'## ' prefix>|<id-pattern>[|<id-pattern2>]". The ids live ONLY in the
# opaque Metrics cell, so the verdict/row validators are unaffected.
proof_correlation_map() {
  printf '%s\n' \
    'Feature Availability|## Requirements|R[0-9]+' \
    'Completeness|## Acceptance criteria|AC[0-9]+' \
    'Risk Assessment|## Risk assessment|RA-[0-9]+' \
    'Test Discipline|## Use cases|UC[0-9]+' \
    'Robustness|## Failure modes|FM[0-9]+' \
    'Resilience|## Fail-open|FAIL-OPEN|FAIL-HARD'
}

# proof_section_text <body> <section-'## ' prefix> -> the lines of the FIRST '## <prefix>...' section (heading
# excluded) up to the next '## ' heading; empty if absent. Prefix match is a leading-substring on the heading, so
# "## Use cases" matches "## Use cases to test — and how (2a)".
proof_section_text() {
  printf '%s\n' "$1" | awk -v pre="$2" -f "$_PROOF_DIM_DIR/proof-section-text.awk"
}

# proof_section_ids <body> <section prefix> <id-pattern> [<id-pattern2>] -> sorted-unique, UPPER-cased whole-token
# identifiers matching the pattern(s) inside that section (e.g. UC1 UC2; RA-1; FAIL-OPEN FAIL-HARD).
proof_section_ids() {
  local body="$1" prefix="$2"; shift 2
  local pat; pat="$(printf '%s|' "$@" | sed 's/|$//')"
  [ -n "$pat" ] || return 0
  # A fail-open or fail-hard item is the upper-case marker anywhere, or, in any letter case, the label that opens a line
  # after an optional bullet and bold; lower-case prose declares nothing. The bridge's readers share the same rule.
  if [ "$prefix" = "## Fail-open" ]; then
    local failtext; failtext="$(proof_section_text "$body" "$prefix")"
    {
      # Each marker on its own line first, so two markers that share one separating character are both seen.
      printf '%s\n' "$failtext" | sed -E 's/FAIL-(OPEN|HARD)/\n&\n/g' | { grep -E '^FAIL-(OPEN|HARD)$' || true; }
      printf '%s\n' "$failtext" \
        | { grep -iE '^[[:space:]]*([-*+][[:space:]]+)?(\*\*|__)?[[:space:]]*fail-(open|hard)([^A-Za-z0-9_-]|$)' || true; } \
        | sed -E 's/^[[:space:]]*([-*+][[:space:]]+)?(\*\*|__)?[[:space:]]*//' | cut -c1-9 | tr '[:lower:]' '[:upper:]'
    } | sort -u
    return 0
  fi
  proof_section_text "$body" "$prefix" | grep -oiE "($pat)" | tr '[:lower:]' '[:upper:]' | sort -u
}

# proof_dimension_metrics_cell <proof-text> <dimension> -> the Metrics cell (4th content cell / awk $5 on a 4-column
# row) of that dimension's row; empty if absent or the table is 3-column.
proof_dimension_metrics_cell() {
  printf '%s' "$1" | awk -F'|' -v d="$2" -f "$_PROOF_DIM_DIR/proof-metrics-cell.awk"
}

# proof_correlation_problems <body> <proof> -> print each MISSING correlation (one per line), else nothing. For every
# mapped dimension that is PROVEN, each identifier declared in its linked section must appear in that dimension's
# Metrics cell. Default on; opt out with PROOF_METRICS_GATE=off or PROOF_METRICS_CORRELATION=off.
proof_correlation_problems() {
  proof_metrics_gate_on || return 0
  kyklos_control_off "${PROOF_METRICS_CORRELATION:-}" && return 0   # shared deterministic parser
  local body="$1" proof="$2"
  proof_correlation_map | while IFS='|' read -r dim prefix pat1 pat2; do
    local verdict; verdict="$(printf '%s' "$proof" | awk -F'|' -v d="$dim" 'NF>=3 {x=$2; gsub(/[`*_]/,"",x); gsub(/^[ \t]+|[ \t]+$/,"",x); if(x==d){print $3; exit}}')"
    proof_verdict_is_proven "$verdict" || continue   # only a PROVEN row is correlated
    local ids cell id kbdlabels; ids="$(proof_section_ids "$body" "$prefix" "$pat1" ${pat2:+"$pat2"})"
    [ -n "$ids" ] || continue
    cell="$(proof_dimension_metrics_cell "$proof" "$dim")"
    # the item must be cited inside a FORMAL <kbd>{Metric} ({Tool}):</kbd> group — a bare token in loose
    # prose (e.g. "corr: R1, R2") is informal + easy to hallucinate. Extract ONLY the <kbd>…</kbd> label text and
    # require the id there, so a citation is anchored to a named, tool-attributed metric group, not free text.
    kbdlabels="$(printf '%s' "$cell" | grep -oiE '<kbd>[^<]*</kbd>' | tr '\n' ' ')"
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      printf '%s' "$kbdlabels" | grep -ciE "(^|[^A-Za-z0-9_-])$id([^A-Za-z0-9_-]|$)" \
 >/dev/null        || printf 'dimension "%s" is PROVEN but story item "%s" (declared in "%s") is not cited inside a FORMAL <kbd>…</kbd> metric group — cite it as "<kbd>%s (<tool>):</kbd> <value>", not loose prose\n' "$dim" "$id" "$prefix" "$id"
    done <<IDS
$ids
IDS
  done
}

# proof_metrics_gate_problems <proof-text> -> print each metrics-gate refusal (one per line) across the table's
# MANDATORY-dimension PROVEN rows, else nothing. The close-guard BACKSTOP for the CLI --set gate (an `--apply` or a
# raw note write bypasses --set, so the gate must also fire at close). Parses each data row's dimension ($2),
# verdict ($3) and Metrics cell ($5 on a 4-column table; empty on an old 3-column one), then routes through the
# SHARED proof_metrics_set_problem. No-op when the gate is off.
proof_metrics_gate_problems() {   # <proof-text> [src-root — stack detection] [kind]
  proof_metrics_gate_on || return 0
  local proof="$1" _mg_root="${2:-}" _mg_kind="${3:-}"
  printf '%s' "$proof" | awk -F'|' '
    NF>=4 {
      d=$2; v=$3; m=(NF>=6 ? $5 : "")
      gsub(/[`*_]/,"",d); gsub(/^[ \t]+|[ \t]+$/,"",d)
      if (d=="" || d=="Quality Dimension" || d ~ /^:?-+:?$/) next
      gsub(/^[ \t]+|[ \t]+$/,"",v); gsub(/^[ \t]+|[ \t]+$/,"",m)
      print d "\t" v "\t" m
    }' | while IFS="$(printf '\t')" read -r _d _v _m; do
      _p="$(proof_metrics_set_problem "$_d" "$_v" "$_m" "$_mg_root" "$_mg_kind")"
      [ -n "$_p" ] && printf '%s\n' "$_p"
    done
}

# proof_advreview_row_problem <proof-text> <story-id> -> when the Adversarial-Review gate is ARMED
# (KYKLOS_ADVREVIEW_GATE on), enforce the mandatory "Adversarial Review" row at close: it can NEVER be
# NOT_PERTINENT, and a PROVEN verdict REQUIRES a Report link + a Token metric that the bridge verifies with its
# host-only key (MCP tool advreview_check). Prints one refusal line (else nothing). The gate is on by default (unset
# means on); it is a no-op only when KYKLOS_ADVREVIEW_GATE holds an explicit off value (off/0/false/no). The PRESENCE
# of the row is already enforced by the canonical set-check; this covers verdict + the unfakeable Report/Token metrics.
proof_advreview_row_problem() {
  kyklos_control_off "${KYKLOS_ADVREVIEW_GATE:-}" && return 0
  local proof="$1" story="$2" row verdict metrics tok
  # the Adversarial Review data row (dimension col $2 == "Adversarial Review", ignoring emphasis/space).
  row="$(printf '%s' "$proof" | awk -F'|' '
    NF>=4 { d=$2; gsub(/[`*_]/,"",d); gsub(/^[ \t]+|[ \t]+$/,"",d); if (d=="Adversarial Review") { print; exit } }')"
  [ -n "$row" ] || return 0            # absent -> the set-check reports it; don't double-report
  verdict="$(printf '%s' "$row" | awk -F'|' '{v=$3; gsub(/^[ \t]+|[ \t]+$/,"",v); print v}')"
  metrics="$(printf '%s' "$row"  | awk -F'|' '{m=$5; print m}')"
  case "$(proof_verdict_class "$verdict")" in
    NOT_PERTINENT) printf 'Adversarial Review can NEVER be NOT_PERTINENT — run the ssdlc-adversarial-review skill; the row must be PROVEN with a Report link + a verifying Token.\n'; return 0 ;;
    PROVEN) : ;;
    *) return 0 ;;                     # UNPROVEN is caught by the normal UNPROVEN gate
  esac
  # PROVEN: require a Report link (a URL) AND a Token that verifies.
  printf '%s' "$metrics" | grep -ciE 'Report:?</kbd>[^<]*https?://|Report[^|]*https?://' \
 >/dev/null    || { printf 'Adversarial Review PROVEN requires a "Report" metric linking the review comment (a URL) — populate it via the ssdlc-adversarial-review skill, do not hand-fill.\n'; return 0; }
  tok="$(printf '%s' "$metrics" | sed -nE 's/.*Token:?<\/kbd>[[:space:]]*`?([A-Za-z0-9]{16,})`?.*/\1/p' | head -1)"
  [ -n "$tok" ] || tok="$(printf '%s' "$metrics" | grep -oE '[a-f0-9]{32,64}' | head -1)"
  [ -n "$tok" ] || { printf 'Adversarial Review PROVEN requires a "Token" metric (the skill-minted token) — populate it via the ssdlc-adversarial-review skill.\n'; return 0; }
  # The token is checked by the BRIDGE (advreview_check): it holds the host-only signing key the token was minted
  # with, the container does not, so only the bridge can tell a real review token from a forged one.
  # FAIL-CLOSED when the token CANNOT be verified - a bad token, an unreachable bridge or a missing helper all refuse
  # the close; a verification that cannot RUN is never a pass.
  local bmcp reply rc verdict
  bmcp="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../hooks/lib/bridge-mcp.sh"
  if [ ! -f "$bmcp" ]; then
    printf 'Adversarial Review Token CANNOT be verified - the bridge helper %s is missing, so this close would accept an UNVERIFIED token. Refusing (fail-closed): repair the plugin install, then re-close.\n' "$bmcp"
    return 0
  fi
  # shellcheck source=../../hooks/lib/bridge-mcp.sh
  . "$bmcp"
  reply="$(bridge_mcp_call advreview_check "$(jq -cn --arg s "$story" --arg t "$tok" '{story:$s, token:$t}' 2>/dev/null)" 60)"; rc=$?
  if [ "$rc" -ne 0 ] || bridge_mcp_is_error "$reply"; then
    printf 'Adversarial Review Token CANNOT be verified for story %s - the KyklosBridge did not answer (rc %s; endpoint file %s, override with KYKLOS_BRIDGE_MCP_JSON). Only the bridge can check a review token; refusing (fail-closed): re-close when the bridge is reachable.\n' "$story" "$rc" "$(bridge_mcp_json_path)"
    return 0
  fi
  verdict="$(bridge_mcp_text "$reply" | tr -d '[:space:]')"
  [ "$verdict" = authentic ] \
    || printf 'Adversarial Review Token does not VERIFY for story %s (the bridge says: %s) - re-run ssdlc-adversarial-review so the bridge mints the token; a hand-computed or stale token cannot pass.\n' "$story" "${verdict:0:80}"
  return 0
}

# proof_dimension_set_problem <proof-text> [kind] -> print a one-line description of a REQUIRED-set violation, or print
# NOTHING when the table carries every required dimension exactly once, the table has no parseable data rows, or the
# canonical list can't be resolved (fail-open). rc is always 0; the CALLER wraps the message with the story name and its
# own block prefix. $2 = the story's kind (empty/unknown -> development, the FULL set - so an unreadable kind demands
# MORE rows, never fewer: the check can only get stricter on error).
# The rule is a MINIMUM set, not an exact one: the canonical dimensions for the kind must ALL be present (a missing
# one blocks) and none may appear twice (a duplicate required row blocks - two verdicts for one dimension are
# ambiguous). EXTRA rows are ACCEPTED: a proof written by a newer toolchain (a dimension added after this copy was
# released) must never be refused by an older guard. An extra row is only reported as a note on stderr; it can never
# satisfy or replace a required row, because presence is matched by the exact canonical name. The verdict rules still
# apply to every row (an UNPROVEN verdict is counted wherever it appears).
# The SINGLE implementation both the FS and gitlab close-gate branches call, so the set check can never again be
# "enforced on one backend only".
proof_dimension_set_problem() {
  proof_dimensions_available || return 0                                # canonical list unresolvable -> skip (fail-open)
  local proof="$1" kind="${2:-}" present canon missing duplicated extra
  # Parse the Dimension column of every DATA row (header + separator skipped, emphasis stripped). One name per line.
  present="$(proof_table_row_index "$proof" | cut -f2)"
  [ -n "$(printf '%s' "$present" | tr -d '[:space:]')" ] || return 0   # no parseable rows -> skip (fail-open)
  canon="$(proof_canonical_dimensions "$kind")"
  missing="$(comm -23 <(printf '%s\n' "$canon" | sort -u) <(printf '%s\n' "$present" | sort -u) | paste -sd, - | sed 's/,/, /g')"
  duplicated="$(comm -12 <(printf '%s\n' "$canon" | sort -u) <(printf '%s\n' "$present" | sort | uniq -d) | paste -sd, - | sed 's/,/, /g')"
  # Adversarial Review is never reported as extra: the canonical list includes it only when its gate resolves ON in
  # THIS context, while the proof may have been written where the gate was on.
  extra="$(comm -13 <(printf '%s\n' "$canon" | sort -u) <(printf '%s\n' "$present" | sort -u) | grep -vxF 'Adversarial Review' | paste -sd, - | sed 's/,/, /g')"
  [ -n "$extra" ] && printf '[kyklos] proof: note - extra row(s) accepted beyond the required set: %s\n' "$extra" >&2
  if [ -n "$missing" ] || [ -n "$duplicated" ]; then
    printf 'Proof table does not carry every required Quality Dimension exactly once (missing: %s; duplicated: %s) - regenerate with the story tool and fill evidence only; a missing dimension is added in place by story proof --set' "${missing:-none}" "${duplicated:-none}"
  fi
}

# proof_scan_table <table> -> the SINGLE mechanical validator+counter for a `## Proof` table. It classifies
# EVERY data row (a `|`-led line that is not the header or the `|---|` separator) and:
#   - on success prints one line `UN=<n> PR=<n> NP=<n>` (the verdict-column tally) and returns 0;
#   - on ANY unclassifiable row returns 2, names each offending row on stderr, and prints NO count line.
# A row is unclassifiable if its cell count differs from the table WIDTH (baselined from the header, else the
# first data row) — that is how a stray `|`, which splits the row into extra cells and SHIFTS the Verdict out
# of its column, is caught — OR its Verdict cell (always the 2nd content cell) does not resolve to one of
# {PROVEN, NOT_PERTINENT, UNPROVEN}. Width-baselining (rather than a hardcoded cell count) accepts the canonical
# 4-column table, an older 3-column one and a 2-column `| Dimension | Verdict |` while still rejecting a shifted row. This is
# why a malformed table can NEVER read as "0 UNPROVEN": the counter,
# the tally, the guard (both backends) and `story proof --apply` all route through here. [Poka-Yoke: fail-closed
# on an unclassifiable row — the position-fragile `$3 ~ /UNPROVEN/` awk this replaces let a stray pipe shift the
# verdict out of column 3 so an UNPROVEN story silently counted as clean and closed.] The classify() token set
# MUST stay in agreement with proof_normalize_verdict (a unit test cross-checks them).
proof_scan_table() {
  # LC_ALL=C: real-text.awk reads UTF-8 as bytes, so the verdict never depends on the caller's locale (a POSIX-locale CI runner
  # and a UTF-8 workstation must agree).
  printf '%s' "$1" | LC_ALL=C awk -f "$_PROOF_DIM_DIR/real-text.awk" -f "$_PROOF_DIM_DIR/proof-scan-table.awk"
}

# proof_render_terminal <table> -> the TERMINAL form of a stored Proof table (what an agent shows in its
# reply): a numbered entry per dimension row with its verdict, evidence lines and metric bullets, then the tally, and
# no table or HTML. The stored markdown table stays the canonical record; this is the one bash renderer of it, and the
# bridge's ProofTableTerminalRenderer produces the same text from the same table (a shared fixture checks both).
# rc 1 (nothing printed) when the input holds no proof row.
proof_render_terminal() {
  printf '%s\n' "$1" | awk -f "$_PROOF_DIM_DIR/proof-terminal-render.awk"
}

# proof_recompute_tally <table> -> the table with the `**Tally: N PROVEN . M NOT_PERTINENT**` line recomputed
# from the ACTUAL verdicts (plus ` . K UNPROVEN` whenever K > 0, so a partial proof never reads as complete) (routed through proof_scan_table, the single classifier). If the table is malformed,
# the Tally line is left unchanged (proof_count_unproven / the guard will block the table anyway).
proof_recompute_tally() {
  local table="$1" counts pr np un
  if counts="$(proof_scan_table "$table" 2>/dev/null)"; then
    pr="$(printf '%s' "$counts" | sed -n 's/.*PR=\([0-9]\{1,\}\).*/\1/p')"
    np="$(printf '%s' "$counts" | sed -n 's/.*NP=\([0-9]\{1,\}\).*/\1/p')"
    un="$(printf '%s' "$counts" | sed -n 's/^UN=\([0-9]\{1,\}\).*/\1/p')"
  else
    pr=""; np=""; un=""
  fi
  printf '%s' "$table" | awk -v pr="$pr" -v np="$np" -v un="$un" -f "$_PROOF_DIM_DIR/proof-tally-update.awk"
}

# proof_count_unproven <table> -> prints the number of UNPROVEN rows and returns 0 when EVERY row classifies;
# returns 2 (and prints NO number, naming the offending row on stderr) when any row is malformed/unknown-verdict.
# The callers (`story close` and kyklos-story-proof-guard.sh, both backends) treat a non-zero rc as BLOCK, so an
# unclassifiable Proof table can never be read as clean.
proof_count_unproven() {
  local out rc
  if out="$(proof_scan_table "$1")"; then rc=0; else rc=$?; fi
  if [ "$rc" -ne 0 ]; then
    printf 'proof: refusing to report an UNPROVEN count for an unclassifiable Proof table (fix the row(s) above); a malformed or unknown-verdict row must never read as clean.\n' >&2
    return "$rc"
  fi
  printf '%s' "$out" | sed -n 's/^UN=\([0-9]\{1,\}\).*/\1/p'
}
