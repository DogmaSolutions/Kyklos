#!/usr/bin/env bash
# kyklos-story-proof-guard.sh — Stop hook. The FINAL quality gate for a ssdlc-story (see the
# 'ssdlc-story-proof' skill). A story may not be CLOSED while its Proof table still has any UNPROVEN Quality
# Dimension — because "closed" implies merge, and a story must not merge unproven. Blocks the STOP so the agent
# either proves the dimension (writes the named test) or records a justified NOT_PERTINENT — or the USER authorizes
# an override.
#
# Two backends (STORY_BACKEND):
#   gitlab : a closed story issue must carry the canonical proof NOTE, graded below (UNPROVEN, row format,
#            canonical set, tool gates, metrics/advreview/correlation, RA and Documentation interview, SHOWN in the
#            reply). Override: the USER-applied proof-override label (lib/owner-labels.sh).
#            In story-stack mode 'on' the bridge alone judges the proof (proof_validate, lib/proof-bridge-judge.sh),
#            override label included; the hook keeps only the container-side checks (shown in the reply, the CLAUDE.md
#            interviews) and blocks when the bridge refuses or does not answer, never re-judging in bash.
#   local  : the rules below, on the story folders.
# FS path: a story is "closing" when its BACKLOG.md row is marked Done (✅). For each such story:
#   - its tasks.md must contain a `## Proof` section          (else the gate was never run)
#   - that section must have NO `UNPROVEN` row                (every dimension PROVEN or NOT_PERTINENT)
# And, for a story closed THIS session (grandfathering earlier closes):
#   - the Proof table was SHOWN in the reply                  (transcript-gate)
#   - a PROVEN Risk-Assessment / Documentation dimension is backed by the persisted first-run interview
#     (`## Risk assessment criteria` / `## Documentation conventions` in CLAUDE.md), and Risk Assessment is
#     never self-marked NOT_PERTINENT without a recorded `Risk-Assessment-Waived:` waiver
# Escape (USER-authorized only): a line `Proof-Override:` under the story's `## Proof` heading. The agent
# must never add it without explicit user authorization (that is the whole point of the gate).
#
# No-op when Stories/ does not exist. Honors stop_hook_active so it can never wedge a Stop loop.
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
# Load per-project config so the close-on-green check sees the SAME settings (KYKLOS_MERGE_GREEN, the CI access
# settings of lib/ci-access.sh) the other guards do.
_cfg="$PROJECT_DIR/.claude/standards.env"
# PARSE, never source (CWE-829): a malformed line can't execute (would break the guard + spam the TUI). Robust by construction.
. "$(dirname "${BASH_SOURCE[0]}")/lib/standards-env.sh"; load_standards_env "$_cfg"
STORIES_DIR="$PROJECT_DIR/Stories"
_PSG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/lib" && pwd)"
BACKLOG="$STORIES_DIR/BACKLOG.md"

INPUT="$(cat || true)"
if printf '%s' "$INPUT" | grep -cE '"stop_hook_active"[[:space:]]*:[[:space:]]*true' >/dev/null; then
    exit 0
fi

# _psg_block PROBLEMS -> print the Stop block decision for PROBLEMS (a list of "; <problem>" items). Full 3-step JSON
# escape (backslash, quote, flatten newlines): a '\' or newline in an agent-edited field (e.g. a story's Branch:) would
# otherwise emit invalid JSON and the block would be dropped.
_psg_block() {
    local reason="BLOCKED: story proof gate not satisfied${1}. (See the 'ssdlc-story-proof' skill.)"
    reason="${reason//\\/\\\\}"; reason="${reason//\"/\\\"}"; reason="$(printf '%s' "$reason" | tr '\n' ' ')"
    printf '{"decision":"block","reason":"%s"}' "$reason"
}

# --- SHOWN-in-reply support (the "render the Proof table in the reply" rule), shared by BOTH backends ------------------------------------------------
# The transcript path + the durable proof-shown marker dir + the session window. A closed story's Proof table must
# be RENDERED in the reply (the user may be remote with no FS/GitLab-note access) — enforced PER-STORY, only for
# THIS-session closes, marker-suppressed, FAIL-OPEN.
_TPATH="$(printf '%s' "$INPUT" | sed -nE 's/.*"transcript_path"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -1)"
if [ -n "${KYKLOS_STATE_DIR:-}" ]; then _SHOWN_DIR="$KYKLOS_STATE_DIR/proof-shown"
elif [ -n "${HOME:-}" ] && [ -d "$HOME/.claude" ] && [ -w "$HOME/.claude" ]; then _SHOWN_DIR="$HOME/.claude/kyklos-state/proof-shown"
else _SHOWN_DIR="/tmp/kyklos-state/proof-shown"; fi
mkdir -p "$_SHOWN_DIR" 2>/dev/null || true
_SHOWN_WIN="${KYKLOS_SESSION_WINDOW_SECONDS:-64800}"   # 18h default; overridable
# Canonical-dimension SoT, sourced EARLY (before the gitlab branch's shown-check calls it — the FS branch re-sources
# it later at its own set-check, which is idempotent). The shown-check requires the FULL canonical row set, so it
# needs this list; if it cannot be resolved the helper degrades to the legacy verdict-cell count (fail-open).
_pd0="$(dirname "${BASH_SOURCE[0]}")/../skills/ssdlc-story-proof/proof-dimensions.sh"; [ -f "$_pd0" ] && . "$_pd0" || true
# [RiskMitigation RA-02] A missing classifier never switches the PROVEN-only checks off.
# Degraded install (proof-dimensions.sh missing or broken): keep the strict legacy verdict reading, so a check that
# applies to a PROVEN row is never silently skipped because the shared classifier is absent (a cell containing
# PROVEN, even UNPROVEN, still faces it — the safe direction for a close gate).
if ! command -v proof_verdict_class >/dev/null 2>&1; then
  proof_verdict_class() { printf '%s' "$1" | grep -oE 'NOT_PERTINENT|UNPROVEN|PROVEN' | head -1 | grep .; }
  proof_verdict_is_proven() { printf '%s' "$1" | grep -c 'PROVEN' >/dev/null; }
fi
# Proof-authentication helpers (RA register-empty / traceability), sourced EARLY so the gitlab branch's subshell
# inherits them for the Risk Assessment checks (the FS region re-sources it below — idempotent). Fail-open if absent.
_pa0="$(dirname "${BASH_SOURCE[0]}")/lib/proof-authentication.sh"; [ -f "$_pa0" ] && . "$_pa0" || true
_ptg0="$(dirname "${BASH_SOURCE[0]}")/lib/proof-tool-gate.sh"; [ -f "$_ptg0" ] && . "$_ptg0" || true
# A MIGRATED historical close (a pre-existing already-Done story seeded into GitLab, so its closed_at is NOW)
# must be graded under tolerant HISTORICAL rules, not full this-session rigor. It is recognised by a USER-applied
# grandfather label (shared authorship check; the agent cannot self-exempt). Sourced early so the gitlab subshell sees it.
_ual0="$(dirname "${BASH_SOURCE[0]}")/lib/user-applied-label.sh"; [ -f "$_ual0" ] && . "$_ual0" || true
. "$(dirname "${BASH_SOURCE[0]}")/lib/owner-labels.sh"   # fixed owner-label names (never redirected by a variable)
_GF_LABEL="$OWNER_GRANDFATHER_LABEL"
# The gitlab equivalent of the FS `Proof-Override:` short-circuit. A gitlab proof
# lives as an AGENT-WRITABLE note, so the authorization can't be a note line the agent could self-author — it is a
# USER-APPLIED label (label_user_applied fails CLOSED, so a self-applied or unverifiable label never overrides). An
# issue carrying this label proportionately waives the gitlab UNPROVEN/tool-gate checks for that story (a trivial or
# migrated close), reaching FS parity without opening a self-override green-wash. Always on; the name is fixed.
_PO_LABEL="$OWNER_OVERRIDE_LABEL"

# a story TYPE whose profile lists Risk Assessment in LIKELY_N/A — the no-risk-surface types `docs` and
# `test` — may mark RA NOT_PERTINENT with its stock profile reason WITHOUT a user waiver; the always-assess
# register/waiver rule still binds every OTHER type. Read the split via the sibling profile script (one SoT). An
# empty/unknown type is NOT waivable (fail-closed: a story without an explicit no-risk type still needs the waiver).
_PROFILE_SCRIPT0="$(dirname "${BASH_SOURCE[0]}")/../skills/ssdlc-story-proof/story-type-profile.sh"
_type_waives_ra() {
  local t="$1"; [ -n "$t" ] || return 1
  [ -f "$_PROFILE_SCRIPT0" ] || return 1
  bash "$_PROFILE_SCRIPT0" "$t" 2>/dev/null | grep -E '^LIKELY_N/A:' | grep -c 'Risk Assessment' >/dev/null
}

# the tool-gate's applicability predicate must diff the SOURCE repo, which is NOT always $PROJECT_DIR. Under
# the companion/nested model the code lives in the nested source at $PROJECT_DIR/$KYKLOS_SOURCE_DIR (e.g. Repo/)
# while Stories/ + .claude live in the companion root; under the internal model the source IS $PROJECT_DIR. Resolve
# the right root once so a `dedup/coverage token over the changed source` is checked against the repo that changed.
_tool_gate_source_root() {
  # delegate to the shared resolver in proof-dimensions.sh (one implementation); keep the old inline
  # logic as the fallback for a partial install where the library did not load.
  if command -v proof_source_root >/dev/null 2>&1; then proof_source_root "$PROJECT_DIR"; return 0; fi
  if [ "${KYKLOS_REPO_SHAPE:-}" = companion ]; then
    local sub="${KYKLOS_SOURCE_DIR:-Repo}"
    if [ -d "$PROJECT_DIR/$sub" ]; then printf '%s' "$PROJECT_DIR/$sub"; return 0; fi
  fi
  printf '%s' "$PROJECT_DIR"
}
_SHOWN_TABLE_WIN="${KYKLOS_SHOWN_TABLE_WINDOW_CHARS:-24000}"   # window (chars) after the id that must hold the full table

# _proof_shown_in_transcript <id> <transcript-file> -> rc 0 iff, in the recent transcript, an occurrence of <id> is
# FOLLOWED (within _SHOWN_TABLE_WIN chars) by a rendered Proof table that carries EVERY canonical dimension as its own
# row-leader `| <Dimension> |` (not merely >=4 verdict cells). This blocks a hand-ABRIDGED render — e.g. fusing the
# seven NOT_PERTINENT rows into one `| A / B / C | ... |` cell — from passing: each canonical name must appear alone
# between pipes, exactly as the `story proof` generator emits it. PER-id so ONE table can't satisfy N stories
#If the canonical list can't be resolved, degrade to the legacy `>=4 verdict cells` rule (fail-open,
# consistent with the set-check region). rc 1 = not shown; rc 2 = can't read (caller fail-opens). Shared by BOTH backends.
_proof_shown_in_transcript() {
    local id="$1" tf="$2" kind="${3:-}" recent canon
    [ -n "$id" ] || return 2
    [ -n "$tf" ] && [ -f "$tf" ] || return 2
    recent="$(tail -c 400000 "$tf" 2>/dev/null | tr -d '\r')"
    # the demanded row set is the STORY'S KIND'S canonical set — an analysis/documentation story's
    # (correctly) reduced table must satisfy the shown-check, and a development table is still demanded in full.
    canon="$(proof_canonical_dimensions "$kind" 2>/dev/null || true)"
    printf '%s' "$recent" | awk -v id="$id" -v canon="$canon" -v win_sz="$_SHOWN_TABLE_WIN" -f "$_PSG_LIB_DIR/proof-shown-detect.awk"
}

# Story-backend awareness. The rich checks below read on-disk story FOLDERS (tasks.md `## Proof`, requirements.md
# Branch, risk-assessment.md). With the GitLab backend a story is an ISSUE and its proof is a NOTE, so those
# file-coupled checks do not apply — but the CORE anti-green-wash invariant still must: a Done (closed) issue MUST
# carry a proof note with NO UNPROVEN verdict. Enforce that natively via the backend contract (backend_done_handles
# + backend_proof_read), plus the shown-in-reply, RA and Documentation-interview checks below. Only the cited-test
# check and close-on-green stay FS-only — they depend on local story files gitlab stories do not have. FAIL-OPEN on any backend/API error so a transient never wedges Stop. [RiskMitigation]
if [ "${STORY_BACKEND:-local}" = gitlab ]; then
    _seam="$(dirname "${BASH_SOURCE[0]}")/../skills/ssdlc-story/lib/story-backend.sh"
    _rl="$(dirname "${BASH_SOURCE[0]}")/lib/require-lib.sh"
    # [no-fail-open] A missing or broken seam, or a library the seam could not load completely, is a broken install,
    # NOT a transient: the backend functions this gate reads Done issues with are then missing, and going on would allow
    # every Stop in silence. BLOCK this Stop, naming the library (stop_hook_active lets the next Stop through, so a broken
    # install cannot wedge the loop). The seam only RECORDS a library it failed to load (STORY_LIB_LOAD_FAILED) and
    # returns success, so its exit status alone cannot tell; require_story_seam reads both.
    # (Transient BACKEND/API errors below still fail-open by design.) [RiskMitigation RA-03]
    ( _seam_problem=""
      if ! . "$_rl" 2>/dev/null || ! command -v require_story_seam >/dev/null 2>&1; then
          _seam_problem="cannot load $_rl completely"
      elif ! require_story_seam "$_seam" backend_done_handles backend_proof_read 2>/dev/null; then
          _seam_problem="$STORY_SEAM_PROBLEM"
      fi
      if [ -n "$_seam_problem" ]; then
          echo "[kyklos] WARNING: story-proof close gate cannot read the story backend this Stop: $_seam_problem (a broken plugin install). Reinstall kyklos." >&2
          _psg_block "; the story-proof close gate cannot check Done stories: $_seam_problem, a broken kyklos install (the story tool refuses to run until it is reinstalled). Reinstall kyklos to restore the gate"
          exit 0
      fi
      gl_problems=""
      # rc 0 iff issue $1 was CLOSED THIS SESSION (closed_at within the recent window); rc 1 = an earlier-session or
      # unknown-time close -> GRANDFATHER. Used to scope the strict malformed-FORMAT re-check (below) to THIS-session
      # closes: re-litigating a MERGED historical close whose proof note uses a FORMAT the current stricter validator
      # no longer accepts (emoji verdicts, 4-column tables, N/A grandfather notes) only produces false blocks. A
      # genuine UNPROVEN verdict or a MISSING proof note still blocks at ANY age (those are real signals, not
      # format-compat artifacts). Fail-OPEN (rc 1 = grandfather) on any API/parse error so a transient never wedges
      # the Stop. Called ONLY when the malformed check would otherwise fire, so the API cost is bounded to offenders. [RiskMitigation]
      _gl_close_is_recent() {
          # A USER-applied grandfather label marks this as a MIGRATED historical close -> grade as NOT recent
          # (tolerant historical rules) regardless of a fresh closed_at. label_user_applied fails CLOSED, so a
          # self-applied label or an unverifiable one does NOT grandfather (a mismatch can only cause a false-STRICT
          # block, never a false-lenient pass — the safe direction for a Tier-0 gate). The any-age UNPROVEN and
          # missing-proof checks still apply, so a migrated story STILL needs a clean Proof table.
          if [ -n "$_GF_LABEL" ] && command -v label_user_applied >/dev/null 2>&1 \
             && label_user_applied "${_GL_PID:-}" "$1" "$_GF_LABEL"; then return 1; fi
          local _c _e _n
          _c="$(_gl_issue "$1" 2>/dev/null | jq -r '.closed_at // empty' 2>/dev/null)"
          # An ABSENT/unfetchable closed_at is UNKNOWN, not recent -> grandfather (fail-open). Guard explicitly:
          # GNU `date -d ""` yields midnight-today (a recent epoch, not an error), which would otherwise misread an
          # empty closed_at as a this-session close and BLOCK a historical close whose detail could not be fetched.
          [ -n "$_c" ] || return 1
          _e="$(date -d "$_c" +%s 2>/dev/null || echo 0)"; _n="$(date +%s 2>/dev/null || echo 0)"
          [ "${_e:-0}" -gt 0 ] && [ "${_n:-0}" -gt 0 ] || return 1
          [ $((_n - _e)) -lt "$_SHOWN_WIN" ] || return 1
          # "This session" must mean AT/AFTER this session started, not merely within the
          # KYKLOS_SESSION_WINDOW_SECONDS window: that window spans a /clear or another same-day session, so a PRIOR-session close was
          # mis-graded as this-session and its SHOWN/RA/advreview obligations were re-demanded across the boundary
          # (you cannot re-render a past session's reply, and its point-in-time artifacts are gone).
          # The boundary is resolved from, in order: (1) the recorded session-start stamp (written at every
          # SessionStart — a recorded fact, immune to transcript schema drift), (2) the first transcript line
          # that CARRIES a timestamp (the very first line may be a meta/summary record without one — reading
          # only line 1 silently yielded "unknown", which is how a prior-container close got re-graded), and
          # (3) when both are unavailable, the absolute-window test above stands alone (strict): a close
          # seconds old with no resolvable boundary is still a live close that must be graded. The stamp makes
          # case (3) unreachable in a real session — SessionStart always records it — so the strictness only
          # ever applies where a boundary genuinely cannot exist. A close BEFORE session start =>
          # NOT this-session => grandfathered. [RiskMitigation]
          # [CySec] Prevents CWE-807 "Reliance on Untrusted Inputs in a Security Decision": the stamp file sits in a
          # folder the agent can write (KYKLOS_STATE_DIR can even be redirected from standards.env), so a forged
          # start in the future would grandfather every fresh close and skip its grading, the bridge's judgement
          # included. A start later than now (beyond a small clock skew) is unreadable, from the stamp or from the
          # transcript, and an unreadable start never grandfathers.
          local _ss=0 _sts _skew=60
          _sts="$(cat "${KYKLOS_STATE_DIR:-/tmp/kyklos-state}/session-start-epoch" 2>/dev/null || true)"
          case "$_sts" in ''|*[!0-9]*) _ss=0 ;; *) _ss="$_sts" ;; esac
          [ "${_ss:-0}" -gt $((_n + _skew)) ] && _ss=0
          if [ "${_ss:-0}" -le 0 ] && [ -n "${_TPATH:-}" ] && [ -f "$_TPATH" ]; then
              _sts="$(head -n 50 "$_TPATH" 2>/dev/null | jq -r 'select(.timestamp) | .timestamp' 2>/dev/null | head -1 || true)"
              _ss="$(date -d "$_sts" +%s 2>/dev/null || echo 0)"
              [ "${_ss:-0}" -gt $((_n + _skew)) ] && _ss=0
          fi
          [ "${_ss:-0}" -gt 0 ] && [ "$_e" -lt "$_ss" ] && return 1
          return 0
      }
      # Proof-note regime gate: proof grading APPLIES to a closed issue ONLY if it carries a
      # `kyklos:version::<v>` label with v >= $_PROOF_NOTE_MIN_VER — i.e. it was last touched by a plugin that
      # already required a Proof note. NO such label => the close PREDATES the proof-note regime (or predates
      # version-labelling entirely): retroactively demanding a Proof note/table on it is over-reach, so skip
      # ALL proof checks for it. A genuine recent close is always stamped with the CURRENT (>= min) version, so this
      # never relaxes real work. Fail-CLOSED to enforcement (rc 0) when the issue cannot be fetched or the comparator
      # is unavailable: "absent label" can only be positively confirmed from a real fetch, and the safe Tier-0
      # direction is to keep checking (a transient can only re-check an old close, never green-wash a real one). The
      # any-age UNPROVEN / missing-proof invariants for a LABELLED close still apply below (a real green-wash still
      # blocks). [RiskMitigation]
      _PROOF_NOTE_MIN_VER="${KYKLOS_PROOF_NOTE_MIN_VERSION:-0.0.250}"
      _gl_proof_required() {
          command -v kyklos_version_ge >/dev/null 2>&1 || return 0
          local _iss _max
          _iss="$(_gl_issue "$1" 2>/dev/null)" || return 0
          [ -n "$_iss" ] || return 0
          _max="$(printf '%s' "$_iss" | jq -r '.labels[]? | select(startswith("kyklos:version::")) | sub("^kyklos:version::";"")' 2>/dev/null | kyklos_version_max)"
          [ -n "$_max" ] || return 1
          kyklos_version_ge "$_max" "$_PROOF_NOTE_MIN_VER"
      }
      # [Last Word] Who judges the proof: in story-stack mode 'on' the bridge alone (proof_validate), never a bash
      # re-judgement; in 'off'/'shadow' the bash checks below. Resolved once, on the first story that needs it, so a
      # Stop with no close to grade never calls the bridge. A missing engine library is a broken install: said loudly,
      # and the bash checks stay on (the strict side).
      _judge=""
      # Sets _judge (not printed: a command substitution would load the library and remember the answer in a subshell).
      _gl_judge() {
          if [ -z "$_judge" ]; then
              if . "$_PSG_LIB_DIR/proof-bridge-judge.sh" 2>/dev/null && proof_bridge_judge_load; then
                  _judge="$(proof_bridge_judge_mode)"
              else
                  echo "[kyklos] WARNING: the story-stack engine library failed to load; the proof is judged in bash this Stop. Reinstall kyklos." >&2
                  _judge=bash
              fi
          fi
      }
      for _h in $(backend_done_handles "$STORIES_DIR" 2>/dev/null); do
          [ -n "$_h" ] || continue
          _gl_proof_required "$_h" || continue   # skip a close that predates the proof-note regime
          _proof="$(backend_proof_read "$STORIES_DIR" "$_h" 2>/dev/null)"
          _bridge_judged=0
          _gl_judge
          case "$_judge" in
              bridge|unreachable)
                  # Only a close of THIS session is asked: an earlier close was judged by the bridge's own close, and
                  # the bash path grandfathers it the same way (_gl_close_is_recent: an older or unknown close time).
                  _gl_close_is_recent "$_h" || continue
                  # No marker skips this question: the marker folders are writable by the agent, so a file there
                  # must never stand for the bridge's verdict. The bridge is asked on every Stop that sees the close.
                  if [ "$_judge" = unreachable ]; then
                      gl_problems="${gl_problems}; issue #$_h is Done but its proof cannot be judged: the bridge's story stack was last 'on' and the bridge does not answer now. Start the bridge (relaunch the container) and stop again; the proof is never re-judged in bash"
                      continue
                  fi
                  # Inside an if: under set -e a bare failing assignment would end the hook silently (a fail-open).
                  if _bv="$(proof_bridge_validate "$_h")"; then _brc=0; else _brc=$?; fi
                  case "$_brc" in
                      0) _bridge_judged=1 ;;
                      4) continue ;;   # the owner's label waives it (read by the bridge)
                      1) gl_problems="${gl_problems}; issue #$_h is Done but the bridge refuses its proof (proof_validate): $_bv"; continue ;;
                      *) gl_problems="${gl_problems}; issue #$_h is Done but the bridge did not answer proof_validate ($_bv). Start the bridge (relaunch the container) and stop again; the proof is never re-judged in bash"; continue ;;
                  esac ;;
          esac
          if [ "$_bridge_judged" = 1 ]; then
              :   # the bridge passed the proof; only the container-side facts below (shown in the reply, interviews) remain
          elif [ -z "$(printf '%s' "$_proof" | tr -d '[:space:]')" ]; then
              gl_problems="${gl_problems}; issue #$_h is Done (closed) but has NO proof note — run 'story proof' and attach it before closing"
              continue
          fi
          # A USER-applied proof-override label short-circuits this story's proof gate (the authenticated gitlab
          # equivalent of the FS `Proof-Override:` line). Only skips the UNPROVEN/tool-gate/format checks — a proof
          # note must still EXIST (the empty-note block above still fires), so an override waives HOW-WELL, never the
          # existence of a proof. label_user_applied fails CLOSED, so the agent cannot self-authorize.
          # Named Cause: the label waives only when the story names the cause of its gap (the bridge decides it).
          if [ "$_bridge_judged" = 0 ] && [ -n "$_PO_LABEL" ] && command -v label_user_applied >/dev/null 2>&1 \
             && label_user_applied "${_GL_PID:-}" "$_h" "$_PO_LABEL" \
             && { command -v override_cause_named >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/lib/override-cause.sh"; } \
             && override_cause_named "${_GL_PID:-}" "$_h"; then continue; fi
          # Route the verdict count through the SHARED validator (proof_scan_table via
          # proof_count_unproven) so a MALFORMED row (not the header's column count) or an UNKNOWN verdict FAILS HARD
          # instead of silently reading as 0 UNPROVEN — the position-fragile `$3 ~ /UNPROVEN/` awk this replaces
          # let a stray pipe shift the verdict out of column 3 and close an unproven story green. rc!=0 => a row
          # could not be classified => BLOCK. Fail-OPEN only when the library itself did not load (broken install).
          # [RiskMitigation RA-03] An UNPROVEN row still blocks the close here, whatever the PROVEN-only checks decide.
          if [ "$_bridge_judged" = 1 ]; then
              _n=0; _prc=0
          elif command -v proof_count_unproven >/dev/null 2>&1; then
              if _n="$(proof_count_unproven "$_proof" 2>/dev/null)"; then _prc=0; else _prc=$?; fi
          else
              _n="$(printf '%s' "$_proof" | awk -F'|' 'NF>=3 && $3 ~ /UNPROVEN/ {c++} END{print c+0}')"; _prc=0
              echo "[kyklos] WARNING: proof-dimensions.sh unavailable — story-proof verdict validation degraded to the legacy count (reinstall kyklos)." >&2
          fi
          if [ "$_prc" -ne 0 ]; then
              _gl_close_is_recent "$_h" && gl_problems="${gl_problems}; issue #$_h has a MALFORMED or unknown-verdict Proof row — every row must have the header's column count with the Verdict (one of PROVEN/NOT_PERTINENT/UNPROVEN) in the second column; a malformed table can NOT be read as proven. Fix the row(s) (see the hook stderr), then re-render with 'story proof $_h --set ...'"
              continue
          fi
          if [ "${_n:-0}" -gt 0 ]; then
              gl_problems="${gl_problems}; issue #$_h is Done but its Proof still has $_n UNPROVEN Quality Dimension(s) — fill them mechanically: 'story proof $_h --set \"<Dimension>=PROVEN|evidence\"' (edits the CANONICAL '<!-- dogma:story-proof -->' note the gate reads — a sibling note or a stray Proof-Override does NOT count), or mark NOT_PERTINENT with a reason"
              continue
          fi
          # [SHOWN-in-reply, gitlab] the "render the Proof table in the reply" rule applies here too: a gitlab proof lives as a NOTE the remote user never
          # sees in the TUI, so a THIS-SESSION close must have RENDERED its Proof table in the reply. Per-story,
          # marker-suppressed, fail-open. closed_at within the window => this session (else grandfather).
          _ph="$(printf '%s' "$_proof" | sha1sum 2>/dev/null | cut -c1-16)"
          _mk="$_SHOWN_DIR/gl-${_h}-${_ph}"
          [ -f "$_mk" ] && continue
          if ! _gl_close_is_recent "$_h"; then
              touch "$_mk" 2>/dev/null || true; continue        # earlier-session / unknown-time close -> grandfather
          fi
          # Resolve this story's KIND once (labels are the record; absent/ambiguous/error -> development,
          # the STRICTEST set) — it scopes the shown-check row demand AND the canonical set-check below.
          _kind=""
          command -v backend_get_kind >/dev/null 2>&1 && _kind="$(backend_get_kind "$STORIES_DIR" "$_h" 2>/dev/null || true)"
          command -v proof_kind_normalize >/dev/null 2>&1 && _kind="$(proof_kind_normalize "$_kind")"
          _sid="$(backend_id_from_handle "$STORIES_DIR" "$_h" 2>/dev/null | grep -oE 'STORY-[0-9]+' | head -1)"
          _shown=0; _readfail=0
          if _proof_shown_in_transcript "#$_h" "$_TPATH" "$_kind"; then _shown=1; elif [ "$?" = 2 ]; then _readfail=1; fi
          if [ "$_shown" = 0 ] && [ -n "$_sid" ]; then
              if _proof_shown_in_transcript "$_sid" "$_TPATH" "$_kind"; then _shown=1; elif [ "$?" = 2 ]; then _readfail=1; fi
          fi
          # LATCH the SHOWN obligation. "Shown in the reply" is a one-time-per-session close
          # obligation, but it was re-checked every Stop against a SCROLLING transcript window — so once the reply
          # aged out, it read as not-shown and the render was re-demanded forever (worse: the repo-wide tool-gate
          # kept the story "dirty" across turns, so the single fully-clean marker was never written). Latch it: the
          # moment the table IS shown, record a durable per-(story, proof-hash) marker; thereafter SHOWN is satisfied
          # for this closed story this session. A NEW proof (different hash) re-arms it; every other gate is untouched.
          _shmk="$_SHOWN_DIR/gl-shown-${_h}-${_ph}"
          [ "$_shown" = 1 ] && touch "$_shmk" 2>/dev/null || true
          [ -f "$_shmk" ] && _shown=1
          _probs_before="$gl_problems"
          # SHOWN-in-reply: a this-session close must have rendered its OWN table (a note is invisible to a remote user).
          if [ "$_shown" = 0 ] && [ "$_readfail" = 0 ]; then
              gl_problems="${gl_problems}; issue #$_h is Done but ITS OWN Proof table was NOT shown in the reply — name it '#$_h'${_sid:+ / $_sid} in your reply and show THIS story's proof exactly as \`story proof $_h --format text\` prints it (its terminal form: every dimension + the tally; the stored markdown table is accepted too); a GitLab note alone is invisible to a remote user"
          fi
          # [RA forcing-function on gitlab] SAME rules as the FS path, via the seam: NOT_PERTINENT needs a recorded
          # Risk-Assessment-Waived line (the agent may never self-waive); PROVEN needs the persisted '## Risk assessment
          # criteria' in CLAUDE.md AND a non-empty RA-## register. The register is read via backend_ra_read (the RA note).
          _rav="$(printf '%s' "$_proof" | awk -F'|' 'NF>=3 && $2 ~ /Risk Assessment/ {print $3; exit}')"
          _ratext="$(backend_ra_read "$STORIES_DIR" "$_h" 2>/dev/null || true)"
          # With the bridge judging, the register and the waiver are its call; the CLAUDE.md interview stays a check
          # of this container's files.
          if [ "$_bridge_judged" = 1 ]; then
              if proof_verdict_is_proven "$_rav" && ! grep -qE '^##[[:space:]]+Risk assessment criteria[[:space:]]*$' "$PROJECT_DIR/CLAUDE.md" 2>/dev/null; then
                  gl_problems="${gl_problems}; issue #$_h marks Risk Assessment PROVEN but CLAUDE.md has no '## Risk assessment criteria' — run the ssdlc-risk-assessment interview, persist the section, then re-close"
              fi
          elif [ "$(proof_verdict_class "$_rav" || true)" = NOT_PERTINENT ]; then
              # a no-risk-surface type (docs/test) may self-mark RA NOT_PERTINENT (profile default) — no waiver.
              _stype="$(backend_get_type "$STORIES_DIR" "$_h" 2>/dev/null || true)"
              if _type_waives_ra "$_stype"; then :; else
                printf '%s' "$_ratext" | grep -cE '^[[:space:]]*Risk-Assessment-Waived:[[:space:]]*\S' \
 >/dev/null                  || gl_problems="${gl_problems}; issue #$_h marks Risk Assessment NOT_PERTINENT but the agent may not self-waive it — only the user may (via a 'Risk-Assessment-Waived: <who/why>' line in the register, 'story ra $_h --apply <file>'), OR set the story type to docs/test if it truly has no risk surface"
              fi
          elif proof_verdict_is_proven "$_rav"; then
              if ! grep -qE '^##[[:space:]]+Risk assessment criteria[[:space:]]*$' "$PROJECT_DIR/CLAUDE.md" 2>/dev/null; then
                  gl_problems="${gl_problems}; issue #$_h marks Risk Assessment PROVEN but CLAUDE.md has no '## Risk assessment criteria' — run the ssdlc-risk-assessment interview, persist the section, then re-close"
              elif command -v proof_ra_register_empty >/dev/null 2>&1 && proof_ra_register_empty "$_ratext" 2>/dev/null; then
                  gl_problems="${gl_problems}; issue #$_h marks Risk Assessment PROVEN but its register enumerates no 'RA-##' item — write the numbered register with 'story ra $_h --apply <file>' (a PROVEN Risk Assessment must be backed by it)"
              fi
          fi
          # [TOOL-GATE on gitlab] the SAME fail-hard content-token gate the FS path applies: a PROVEN verdict on a
          # gated dimension (proof_tool_is_gated in lib/proof-tool-gate.sh) must be backed by a fresh tool token over
          # the changed SOURCE (the nested Repo/ under companion, else $PROJECT_DIR). DEFAULT-ON per dimension; opt
          # out with KYKLOS_TOOL_GATE_<DIMENSION>=0. Fail-open applicability (a story that touched no source is never
          # gated). Findings are per-story, appended to gl_problems.
          # ACCEPTED ONCE, NOT RE-GATED: a closed story whose tool tokens one Stop has accepted (this proof hash) is not
          # re-graded on later Stops. Its proof was accepted; a later commit that touches the same files (the next
          # story) would otherwise make its old token stale and block every Stop on a story nobody can reopen. The
          # latch is per proof hash, so a new proof re-arms the gate.
          _tgmk="$_SHOWN_DIR/gl-toolgate-${_h}-${_ph}"
          if [ "$_bridge_judged" = 0 ] && [ ! -f "$_tgmk" ] && command -v proof_tool_gate_finding >/dev/null 2>&1; then
              _gtg_src="$(_tool_gate_source_root)"
              # the diff-dependent tool-gate + mirror read the LIVE source diff, which only
              # represents the story whose change IS that diff. For a story whose deliverable is in a DIFFERENT repo
              # than PROJECT_DIR, or whose HEAD commit belongs to ANOTHER story, that diff is not its own -> re-grading
              # it demands a token/coverage for source it never touched (an unsatisfiable gate on an already-clean
              # close). Run these checks ONLY while the diff is attributable to THIS story (backward-compatible if the
              # helper is absent); the non-diff checks (UNPROVEN, canonical set, correlation, RA, SHOWN) run regardless.
              if ! command -v _proof_tool_diff_attributable >/dev/null 2>&1 || _proof_tool_diff_attributable "$_gtg_src" "$_h"; then
              _probs_tg_before="$gl_problems"
              # ops kind: Test Discipline metrics are optional (an ops deliverable — bash/config/deployment — may
              # not be coverage-testable), so skip the Test-Discipline PROVEN tool-gate for ops; every other kind unchanged.
              # shellcheck source=lib/control-switch.sh
              . "$(dirname "${BASH_SOURCE[0]}")/lib/control-switch.sh" 2>/dev/null || true   # kyklos_control_off: the one control-switch reader
              if ! kyklos_control_off "${KYKLOS_TOOL_GATE_TEST_DISCIPLINE:-}" && [ "$_kind" != "ops" ]; then
                  _gtdv="$(proof_verdict_class "$(printf '%s' "$_proof" | awk -F'|' 'NF>=3 && $2 ~ /Test Discipline/ {print $3; exit}')" || true)"
                  _gtd="$(proof_tool_gate_finding "Test Discipline" "$_gtdv" "$_gtg_src" "$_h" 2>/dev/null | head -1 || true)"
                  [ -n "$_gtd" ] && gl_problems="${gl_problems}; issue #$_h: $_gtd"
              fi
              # MIRROR check — INDEPENDENT of the PROVEN tool-gate flag above (its own default-on control,
              # PROOF_NOTPERTINENT_VERIFY, opt out with =off, checked inside): a NOT_PERTINENT that the diff contradicts
              # (source changed) is refused. Extracts its own verdict; runs even when the PROVEN gate is opted down.
              if command -v proof_tool_notpertinent_finding >/dev/null 2>&1; then
                  for _npdim in "Test Discipline" "Non-Duplication"; do
                      # ops kind: a Test Discipline NOT_PERTINENT is legitimate (metrics optional for ops), so the
                      # source-changed mirror must NOT refuse it; Non-Duplication is still enforced for ops.
                      case "$_kind|$_npdim" in "ops|Test Discipline") continue ;; esac
                      _npv="$(proof_verdict_class "$(printf '%s' "$_proof" | awk -F'|' -v d="$_npdim" 'NF>=3 && $2 ~ d {print $3; exit}')" || true)"
                      _np="$(proof_tool_notpertinent_finding "$_npdim" "$_npv" "$_gtg_src" 2>/dev/null | head -1 || true)"
                      [ -n "$_np" ] && gl_problems="${gl_problems}; issue #$_h: $_np"
                  done
              fi
              if ! kyklos_control_off "${KYKLOS_TOOL_GATE_NON_DUPLICATION:-}"; then
                  _gndv="$(proof_verdict_class "$(printf '%s' "$_proof" | awk -F'|' 'NF>=3 && $2 ~ /Non-Duplication/ {print $3; exit}')" || true)"
                  _gnd="$(proof_tool_gate_finding "Non-Duplication" "$_gndv" "$_gtg_src" "$_h" 2>/dev/null | head -1 || true)"
                  [ -n "$_gnd" ] && gl_problems="${gl_problems}; issue #$_h: $_gnd"
              fi
              if ! kyklos_control_off "${KYKLOS_TOOL_GATE_DOCUMENTATION:-}"; then
                  _gdocv="$(proof_verdict_class "$(printf '%s' "$_proof" | awk -F'|' 'NF>=3 && $2 ~ /Documentation/ {print $3; exit}')" || true)"
                  _gdoc="$(proof_tool_gate_finding "Documentation" "$_gdocv" "$_gtg_src" "$_h" 2>/dev/null | head -1 || true)"
                  [ -n "$_gdoc" ] && gl_problems="${gl_problems}; issue #$_h: $_gdoc"
              fi
              [ "$gl_problems" = "$_probs_tg_before" ] && touch "$_tgmk" 2>/dev/null || true
              fi   # end diff-attributable guard
          fi
          # [canonical dimension SET, gitlab] the Proof note's rows must BE the canonical Quality Dimensions — a
          # hoisted-to-both-backends check via the SHARED helper, so an agent cannot green-wash a gitlab close by
          # renaming/dropping/merging rows. Fail-open when the canonical list can't resolve (broken install, LOUD).
          if [ "$_bridge_judged" = 0 ] && command -v proof_dimension_set_problem >/dev/null 2>&1; then
              if proof_dimensions_available; then
                  # the expected set is the story's KIND'S canonical set (development when unreadable).
                  _sp="$(proof_dimension_set_problem "$_proof" "$_kind" 2>/dev/null || true)"
                  [ -n "$_sp" ] && gl_problems="${gl_problems}; issue #$_h $_sp (regenerate with 'story proof $_h')"
              else
                  echo "[kyklos] WARNING: story-proof set-check SKIPPED (gitlab) — the canonical Quality-Dimension list could not be resolved; reinstall kyklos." >&2
              fi
          fi
          # [metrics gate, gitlab] BACKSTOP for the CLI --set gate (PROOF_METRICS_GATE, default on; opt out with
          # =off): a mandatory-dimension PROVEN whose Metrics cell cites no tool/metric — or a Test Discipline PROVEN
          # whose coverage/CRAP miss the configured thresholds — is refused at close too (a raw note write / --apply
          # bypasses --set).
          if [ "$_bridge_judged" = 0 ] && command -v proof_metrics_gate_problems >/dev/null 2>&1; then
              while IFS= read -r _mgp; do
                  [ -n "$_mgp" ] && gl_problems="${gl_problems}; issue #$_h: $_mgp"
              done < <(proof_metrics_gate_problems "$_proof" "$(_tool_gate_source_root)" "$_kind" 2>/dev/null)
          fi
          # [advreview, gitlab] the Adversarial-Review gate (KYKLOS_ADVREVIEW_GATE, default on; opt out with =off):
          # the mandatory row must be PROVEN (never NOT_PERTINENT) with a Report link + a VERIFYING Token.
          if [ "$_bridge_judged" = 0 ] && command -v proof_advreview_row_problem >/dev/null 2>&1; then
              _arp="$(proof_advreview_row_problem "$_proof" "$_h" 2>/dev/null || true)"
              [ -n "$_arp" ] && gl_problems="${gl_problems}; issue #$_h: $_arp"
          fi
          # [correlation, gitlab] (PROOF_METRICS_CORRELATION, default on; opt out with =off) each PROVEN mapped
          # dimension's Metrics cell must cite every item/criteria id declared in its linked story section
          # (UC/FM/AC/R/RA/FAIL-*). Reads the issue body.
          if [ "$_bridge_judged" = 0 ] && command -v proof_correlation_problems >/dev/null 2>&1; then
              _cbody="$(backend_body_read "$STORIES_DIR" "$_h" 2>/dev/null)"
              while IFS= read -r _cp; do
                  [ -n "$_cp" ] && gl_problems="${gl_problems}; issue #$_h: $_cp"
              done < <(proof_correlation_problems "$_cbody" "$_proof" 2>/dev/null)
          fi
          # [Documentation interview, gitlab] a PROVEN Documentation verdict requires the persisted '## Documentation
          # conventions' section in CLAUDE.md (the first-run interview) — same rule as the FS path.
          _docv="$(printf '%s' "$_proof" | awk -F'|' 'NF>=3 && $2 ~ /Documentation/ {print $3; exit}')"
          if proof_verdict_is_proven "$_docv"; then
              grep -qE '^##[[:space:]]+Documentation conventions[[:space:]]*$' "$PROJECT_DIR/CLAUDE.md" 2>/dev/null \
                || gl_problems="${gl_problems}; issue #$_h marks Documentation PROVEN but CLAUDE.md has no '## Documentation conventions' — run the update-docs interview, persist the section, then re-close"
          fi
          # Suppress re-checking this story+proof for the rest of the session ONLY if it stayed fully clean this
          # iteration (SHOWN fails open on an unreadable transcript, so that alone does not add a problem). A story
          # that added a problem is NOT marked, so it is re-checked next Stop until fixed.
          [ "$gl_problems" = "$_probs_before" ] && touch "$_mk" 2>/dev/null || true
      done
      [ -z "$gl_problems" ] && exit 0
      _psg_block "$gl_problems"
    )
    exit 0
fi

[ -d "$STORIES_DIR" ] || exit 0
[ -f "$BACKLOG" ] || exit 0

# Column-position-independent Status reading (wide companion tables vs narrow infra tables). A missing shared lib is
# a broken install — [no-fail-open] surface it LOUDLY rather than let the whole local proof gate disappear silently
# (still exit 0 so a broken deploy does not wedge the Stop loop).
_bl="$(dirname "${BASH_SOURCE[0]}")/lib/backlog-lib.sh"
if [ -f "$_bl" ]; then . "$_bl"; else echo "[kyklos] WARNING: story-proof (FS) gate INERT this Stop — backlog-lib.sh missing ($_bl), a broken plugin install; the proof gate is NOT enforcing. Reinstall kyklos." >&2; exit 0; fi
# Proof-authentication helpers (cited-test check + RA traceability). Fail-open: if the lib is somehow absent,
# simply skip those heuristics — the string-level gate above still stands, and Stop must never wedge.
_pa="$(dirname "${BASH_SOURCE[0]}")/lib/proof-authentication.sh"; [ -f "$_pa" ] && . "$_pa" || true
_ptg="$(dirname "${BASH_SOURCE[0]}")/lib/proof-tool-gate.sh"; [ -f "$_ptg" ] && . "$_ptg" || true
# Canonical-dimension source of truth (shared with the `story proof` generator). Fail-open: if the lib is
# absent the guard's canonical-SET check is simply skipped (guarded by proof_dimensions_available below).
_pd="$(dirname "${BASH_SOURCE[0]}")/../skills/ssdlc-story-proof/proof-dimensions.sh"; [ -f "$_pd" ] && . "$_pd" || true
# ai-review awareness: surface a failed ai-review job as the likely cause when the close gate blocks on a red
# pipeline, and route to the fix loop. Optional — the guard behaves identically if the lib is absent.
_ar="$(dirname "${BASH_SOURCE[0]}")/lib/ai-review-verdict.sh"; [ -f "$_ar" ] && . "$_ar" || true

problems=""
add() { problems="${problems}; $1"; }

# _close_is_recent <tasks-file> -> rc 0 iff this story was CLOSED THIS SESSION (its tasks.md is uncommitted-modified,
# OR committed AFTER the session's first transcript timestamp AND within the recent absolute window); rc 1 = an OLD or
# unknown-time close (grandfather). Shared by the no-Proof-section gate (below) and the this-session refinements
# region. FAIL-OPEN (rc 1) when git/timestamps are unavailable, so an old close is grandfathered, never a wedge. [RiskMitigation]
_close_is_recent() {
    local _t="$1" _tp _sess _ci _ss _cd _now _win
    [ -n "$_t" ] || return 1
    [ -n "$(git -C "$PROJECT_DIR" status --porcelain -- "$_t" 2>/dev/null)" ] && return 0   # uncommitted this-session close
    _tp="$(printf '%s' "$INPUT" | sed -nE 's/.*"transcript_path"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -1)"
    [ -n "$_tp" ] && [ -f "$_tp" ] || return 1
    _sess="$(head -n 1 "$_tp" 2>/dev/null | jq -r '.timestamp // empty' 2>/dev/null || true)"
    _ci="$(git -C "$PROJECT_DIR" log -1 --format=%cI -- "$_t" 2>/dev/null || true)"
    _ss="$(date -d "$_sess" +%s 2>/dev/null || echo 0)"
    _cd="$(date -d "$_ci" +%s 2>/dev/null || echo 0)"
    _now="$(date +%s 2>/dev/null || echo 0)"
    _win="${KYKLOS_SESSION_WINDOW_SECONDS:-64800}"
    [ "$_ss" -gt 0 ] && [ "$_cd" -gt "$_ss" ] && [ "$_now" -gt 0 ] && [ $((_now - _cd)) -lt "$_win" ] && return 0
    return 1
}

for dir in "$STORIES_DIR"/STORY-*/; do
    [ -d "$dir" ] || continue
    name="$(basename "$dir")"
    tasks="$dir/tasks.md"

    # Only enforce on stories the BACKLOG marks Done — i.e. being/already closed. Column-position independent
    # (the Status cell is field 3 in narrow infra tables but field 5 in the companion's wide tables; a hardcoded
    # $3 read Project there and silently skipped every Done story — bypassing this Tier-0 gate).
    _row="$(grep -E '^\|' "$BACKLOG" 2>/dev/null | grep -F "$name" | head -1)"
    backlog_row_has_status "$_row" '[Dd]one' || continue

    if [ ! -f "$tasks" ]; then
        add "$name is Done but has no tasks.md to hold a Proof table"
        continue
    fi

    # Extract the `## Proof` section (from its heading to the next `## ` or EOF).
    proof="$(awk '/^##[[:space:]]+Proof([[:space:]]|$)/{f=1;next} /^##[[:space:]]/{f=0} f{print}' "$tasks")"

    # No `## Proof` section at all. Two very different cases, and the OLD code grandfathered BOTH — the loophole:
    #   - a genuinely OLD story that predates the Proof gate -> grandfather (do NOT retroactively block).
    #   - a story closed THIS SESSION with no Proof table (edit Status->Done + commit, never ran `story proof`) -> BLOCK.
    # The no-UNPROVEN check below never catches the second case (there is no table to inspect), so a proof-LESS close
    # slipped through un-gated. Gate the grandfather on close-age: a recent close with no Proof table is blocked.
    if [ -z "$(printf '%s' "$proof" | tr -d '[:space:]')" ]; then
        if _close_is_recent "$tasks"; then
            add "$name is Done but has NO \`## Proof\` table — a proof-LESS close. Run 'story proof $name' and fill each Quality Dimension (or record a justified NOT_PERTINENT) BEFORE closing; a Done story must carry a Proof (Test Discipline included)."
        fi
        continue
    fi

    # A user-authorized override short-circuits the block for this story.
    printf '%s' "$proof" | grep -cE '^[[:space:]]*Proof-Override:[[:space:]]*\S' >/dev/null && continue

    # Count UNPROVEN only in the VERDICT column (the second column, i.e. awk field $3 because the leading `|`
    # makes $1 empty) — NOT in the legend comment AND NOT in the Notes
    # column, where a story legitimately describes proof mechanics ("a test asserts an UNPROVEN row blocks").
    # Anything looser false-blocks: the template legend mentions the word, and so does any story about the
    # gate itself.
    # Shared validator (proof_scan_table via proof_count_unproven): a MALFORMED row (not the header's
    # column count) or an UNKNOWN verdict FAILS HARD instead of silently counting as 0 UNPROVEN. Fail-OPEN only on a
    # broken install (library did not load).
    # [RiskMitigation RA-03] An UNPROVEN row still blocks the close here, whatever the PROVEN-only checks decide.
    if command -v proof_count_unproven >/dev/null 2>&1; then
        if n="$(proof_count_unproven "$proof" 2>/dev/null)"; then prc=0; else prc=$?; fi
    else
        n="$(printf '%s' "$proof" | awk -F'|' 'NF>=3 && $3 ~ /UNPROVEN/ {c++} END{print c+0}')"; prc=0
        echo "[kyklos] WARNING: proof-dimensions.sh unavailable — story-proof verdict validation degraded to the legacy count (reinstall kyklos)." >&2
    fi
    # Grandfather earlier-session closes from the strict malformed-FORMAT re-check (mirrors the no-Proof-section
    # grandfather above and the gitlab region): only a THIS-session close is re-validated for a malformed table, so a
    # merged historical close whose proof note uses a format the current stricter validator no longer accepts (emoji
    # verdicts, 4-column tables, N/A grandfather notes) is not retroactively blocked. A genuine UNPROVEN verdict
    # still blocks at ANY age (below) — that is a real "not proven" signal, not a format-compat artifact.
    if [ "$prc" -ne 0 ]; then
        _close_is_recent "$tasks" && add "$name has a MALFORMED or unknown-verdict Proof row — every row must have the header's column count with the Verdict (one of PROVEN/NOT_PERTINENT/UNPROVEN) in the second column; a malformed table can NOT be read as proven. Fix the row(s) (see the hook stderr), then re-render with 'story proof $name --set ...'"
        continue
    fi
    if [ "${n:-0}" -gt 0 ]; then
        add "$name is Done but its Proof table still has $n UNPROVEN Quality Dimension(s) — fill them: 'story proof $name --set \"<Dimension>=PROVEN|evidence\"' (or edit the '## Proof' table in tasks.md); mark NOT_PERTINENT with a reason; only the user may add a 'Proof-Override:'"
        continue
    fi

    # ---- Checks that apply ONLY to a story CLOSED THIS SESSION (grandfather earlier closes) ----
    # (a) the Proof table was SHOWN in the reply (transcript-gate); (b) the first-run INTERVIEW behind
    # a PROVEN Risk-Assessment / Documentation dimension was actually done + persisted, and Risk Assessment is
    # never self-marked NOT_PERTINENT without a recorded user waiver. Marker-based (validate once per
    # story+proof) and FAIL-OPEN when the transcript can't be read, so it can never wedge the Stop loop.
    # proof-shown markers must SURVIVE a container restart, else a close from earlier the same day is re-flagged
    # after a rebuild (and now also re-demands the canonical row set). The `$HOME/.claude` mount is a PERSISTENT
    # named volume; other Kyklos state (gitflow-ok, etc.) is intentionally volatile and stays in /tmp. Honor an
    # explicit KYKLOS_STATE_DIR first (the test harness sets it), then prefer the persistent volume.
    if [ -n "${KYKLOS_STATE_DIR:-}" ]; then
        state_dir="$KYKLOS_STATE_DIR/proof-shown"                   # explicit override (tests) — honor it
        _vol_state_dir="$state_dir"
    elif [ -n "${HOME:-}" ] && [ -d "$HOME/.claude" ] && [ -w "$HOME/.claude" ]; then
        state_dir="$HOME/.claude/kyklos-state/proof-shown"         # persistent named volume — durable
        _vol_state_dir="/tmp/kyklos-state/proof-shown"             # legacy volatile location (transition read)
    else
        state_dir="/tmp/kyklos-state/proof-shown"                  # last-resort volatile
        _vol_state_dir="$state_dir"
    fi
    mkdir -p "$state_dir" 2>/dev/null || true
    proof_hash="$(printf '%s' "$proof" | sha1sum 2>/dev/null | cut -c1-16)"
    marker="$state_dir/${name}-${proof_hash}"
    # A marker in the durable dir OR the legacy volatile dir (a close already validated this session before the
    # durable-marker rollout) suppresses re-checking — so the transition never re-flags a settled close.
    if [ -f "$marker" ] || [ -f "$_vol_state_dir/${name}-${proof_hash}" ]; then continue; fi

    tpath="$(printf '%s' "$INPUT" | sed -nE 's/.*"transcript_path"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -1)"
    if [ -z "$tpath" ] || [ ! -f "$tpath" ]; then
        touch "$marker" 2>/dev/null || true   # fail-open: cannot verify -> do not block
        continue
    fi
    recent="$(tail -c 400000 "$tpath" 2>/dev/null | tr -d '\r')"
    # Grandfather (robust): a story counts as CLOSED THIS SESSION only if its OWN tasks.md (which holds the Proof)
    # was CHANGED this session -- uncommitted in the worktree, OR committed after the session's first transcript
    # timestamp. Merely READING a doc that names it (BACKLOG.md lists every story) or mentioning it in passing does
    # NOT count -- that grep-the-transcript heuristic both OVER-fired (mass false-block on prior stories after a
    # BACKLOG read) and, via fail-open, UNDER-enforced (a real close could slip). Fail-open => grandfather when
    # git/timestamps are unavailable, so the Stop loop can never wedge. [RiskMitigation]
    # THIS-session detection is the SAME close-age logic the no-Proof-table gate uses — via the shared helper (no
    # duplicate copy to drift). Uncommitted OR committed-after-session-start-within-window => this session. [RiskMitigation]
    _changed_this_session=0
    _close_is_recent "$tasks" && _changed_this_session=1
    if [ "$_changed_this_session" -eq 0 ]; then
        touch "$marker" 2>/dev/null || true                      # earlier-session close -> grandfather
        continue
    fi

    session_ok=1

    # (canonical SET) — the Proof table's DIMENSION rows must BE exactly the canonical set for the story's kind
    # (proof_canonical_dimensions):
    # no invented/renamed/merged row PRESENT, none MISSING. The rows are mechanically generated by
    # `story proof <id>` from the ONE canonical source (story-type-profile.sh's ALL, via proof-dimensions.sh);
    # this check rejects a hand-edited row set so an LLM cannot hallucinate/omit dimensions and still pass.
    # Only runs on THIS-session closes (this whole region is grandfathered). FAIL-OPEN: if the canonical list
    # can't be resolved (lib/profile absent) or the table has no parseable data rows, SKIP — never wedge Stop.
    # this story's KIND (the `- **Kind:**` bullet on the FS backend; absent/unreadable -> development,
    # the STRICTEST set) scopes both the canonical set-check and the shown-check row demand below.
    _fs_kind=""
    command -v proof_kind_from_requirements >/dev/null 2>&1 && _fs_kind="$(proof_kind_from_requirements "$dir/requirements.md" 2>/dev/null || true)"
    command -v proof_kind_normalize >/dev/null 2>&1 && _fs_kind="$(proof_kind_normalize "$_fs_kind")"
    if command -v proof_dimension_set_problem >/dev/null 2>&1 && proof_dimensions_available; then
        # The canonical-SET check is now the SHARED proof_dimension_set_problem helper (one implementation for both
        # the FS and gitlab close paths — no per-branch copy to drift). It fail-opens on an unparseable/absent table.
        _setprob="$(proof_dimension_set_problem "$proof" "$_fs_kind" 2>/dev/null || true)"
        if [ -n "$_setprob" ]; then
            add "$name is Done but its $_setprob (regenerate with 'story proof $name')"
            session_ok=0
        fi
    else
        # [no-fail-open] the canonical-dimension list could not be resolved (proof-dimensions.sh / story-type-profile.sh
        # absent or broken) so the SET-membership check is degraded/skipped — announce it LOUDLY rather than silently
        # pass a possibly non-canonical Proof table. (The core UNPROVEN check above still stands; only this refinement
        # is skipped.)
        echo "[kyklos] WARNING: story-proof set-check SKIPPED this Stop — the canonical Quality-Dimension list could not be resolved (proof-dimensions.sh/story-type-profile.sh missing or broken); the Proof rows are NOT verified against the canonical set. Reinstall kyklos." >&2
    fi

    # [metrics gate, FS] BACKSTOP for the CLI --set gate (same rule, both backends; PROOF_METRICS_GATE, default on,
    # opt out with =off): a mandatory-dimension PROVEN whose Metrics cell cites no tool/metric — or a Test Discipline
    # PROVEN whose coverage/CRAP miss the configured thresholds — is refused at close.
    if command -v proof_metrics_gate_problems >/dev/null 2>&1; then
        while IFS= read -r _mgp; do
            if [ -n "$_mgp" ]; then add "$name: $_mgp"; session_ok=0; fi
        done < <(proof_metrics_gate_problems "$proof" "$(_tool_gate_source_root)" "$_fs_kind" 2>/dev/null)
    fi
    # [advreview, FS] same enforcement on the FS path (KYKLOS_ADVREVIEW_GATE, default on; opt out with =off): the
    # mandatory Adversarial Review row must be PROVEN with a verifying Report+Token.
    if command -v proof_advreview_row_problem >/dev/null 2>&1; then
        _arp="$(proof_advreview_row_problem "$proof" "$name" 2>/dev/null || true)"
        if [ -n "$_arp" ]; then add "$name: $_arp"; session_ok=0; fi
    fi
    # [correlation, FS] (PROOF_METRICS_CORRELATION, default on; opt out with =off) each PROVEN mapped dimension's
    # Metrics cell must cite every item/criteria id declared in its linked story section. Reads requirements.md.
    if command -v proof_correlation_problems >/dev/null 2>&1; then
        _cbody="$(cat "$dir/requirements.md" 2>/dev/null)"
        while IFS= read -r _cp; do
            if [ -n "$_cp" ]; then add "$name: $_cp"; session_ok=0; fi
        done < <(proof_correlation_problems "$_cbody" "$proof" 2>/dev/null)
    fi

    # (a) SHOWN — the story's OWN Proof table must appear in the reply. The PRIOR check counted PROVEN/
    # NOT_PERTINENT cells across the WHOLE transcript, so ONE shown table satisfied EVERY story closing that
    # session: close N stories, render one table, and all N passed unshown. Now the
    # check is PER-STORY and STRUCTURAL: the story's id must be FOLLOWED by a table carrying EVERY canonical
    # dimension as its own `| <Dimension> |` row-leader (not merely >=4 verdict cells) — so a hand-ABRIDGED render
    # (e.g. fusing the seven NOT_PERTINENT rows into one cell) no longer passes. Routed through the SHARED
    # _proof_shown_in_transcript helper (one implementation for both backends; no drift). Marker-based fail-open
    # is unchanged, so this can never wedge the Stop loop; an unreadable transcript (rc 2) fail-opens too.
    _sid="$(printf '%s' "$name" | grep -oE 'STORY-[0-9]+' | head -1)"
    _shown=""
    if [ -n "$_sid" ]; then
        if _proof_shown_in_transcript "$_sid" "$_TPATH" "$_fs_kind"; then _shown="yes"; elif [ "$?" = 2 ]; then _shown="yes"; fi
    else
        # No parseable STORY-<n> id (should not happen for a Stories/ dir) -> fall back to the global cell count.
        _c="$(printf '%s' "$recent" | { grep -oE '\|[^|]{0,60}(PROVEN|NOT_PERTINENT)' || true; } | wc -l | tr -d ' ')"
        [ "${_c:-0}" -ge 4 ] && _shown="yes" || _shown=""
    fi
    # LATCH the SHOWN obligation (same fix as the gitlab path). "Shown in the reply" is a
    # one-time-per-session close obligation, but re-checking a SCROLLING transcript window re-demanded the render on
    # every later Stop once the reply aged out (and an unrelated story's repo-wide tool-gate kept the story dirty, so
    # the fully-clean marker was never written). The moment the table IS shown, latch a durable per-(story,proof-hash)
    # marker in the SAME proof-shown state dir; thereafter SHOWN is satisfied this session. A new proof re-arms it.
    _shmk="$state_dir/${name}-shown-${proof_hash}"
    [ "$_shown" = "yes" ] && touch "$_shmk" 2>/dev/null || true
    { [ -f "$_shmk" ] || [ -f "$_vol_state_dir/${name}-shown-${proof_hash}" ]; } && _shown="yes"
    if [ "$_shown" != "yes" ]; then
        add "$name is Done but ITS OWN Proof table was not SHOWN in the reply — right after naming the story, show THIS story's proof exactly as \`story proof $name --format text\` prints it (its terminal form: every dimension + the tally; the stored \`## Proof\` table is accepted too); a tally alone, or a different story's proof, does not count (the user may be remote with no FS access)"
        session_ok=0
    fi

    # (b) INTERVIEW / no-self-N/A — the criteria the DEVELOPER must set are established once (the first-run
    # interview), persisted to CLAUDE.md, then reused. Read the verdict from the dimension-name column ($2) of the
    # relevant Proof row (UNPROVEN rows already blocked above, so a verdict here is PROVEN or NOT_PERTINENT).
    claude_md="$PROJECT_DIR/CLAUDE.md"
    ra_verdict="$(printf '%s' "$proof"  | awk -F'|' 'NF>=3 && $2 ~ /Risk Assessment/ {print $3; exit}')"
    doc_verdict="$(printf '%s' "$proof" | awk -F'|' 'NF>=3 && $2 ~ /Documentation/    {print $3; exit}')"
    td_verdict="$(printf '%s' "$proof"  | awk -F'|' 'NF>=3 && $2 ~ /Test Discipline/  {print $3; exit}')"
    nd_verdict="$(printf '%s' "$proof"  | awk -F'|' 'NF>=3 && $2 ~ /Non-Duplication/  {print $3; exit}')"

    # The Risk Assessment register text (FS backend: the file IS the record). Read once; the RA checks below consume
    # this string so the SAME text-based checks run on the gitlab path (where the register is read via backend_ra_read).
    _ra_text="$(cat "$dir/risk-assessment.md" 2>/dev/null || true)"

    # Risk Assessment: PROVEN requires the persisted criteria (regulatory regime + always-include items); a
    # NOT_PERTINENT requires an explicit recorded waiver — the agent may NEVER self-mark it N/A.
    if [ "$(proof_verdict_class "$ra_verdict" || true)" = NOT_PERTINENT ]; then
        # a no-risk-surface type (docs/test) may self-mark RA NOT_PERTINENT (profile default) — no waiver.
        _stype="$(sed -nE 's/^[[:space:]]*[-*][[:space:]]*\*\*Story-Type:\*\*[[:space:]]*([A-Za-z_-]+).*/\1/p' "$dir/requirements.md" 2>/dev/null | head -1)"
        if _type_waives_ra "$_stype"; then :; elif ! printf '%s' "$_ra_text" | grep -cE '^[[:space:]]*Risk-Assessment-Waived:[[:space:]]*\S' >/dev/null; then
            add "$name marks Risk Assessment NOT_PERTINENT but the agent may not self-waive it — only the user may (via a 'Risk-Assessment-Waived: <who/why>' line in the story's risk-assessment.md), OR set the story type to docs/test if it truly has no risk surface (see the ssdlc-risk-assessment skill)"
            session_ok=0
        fi
    elif proof_verdict_is_proven "$ra_verdict"; then
        if ! grep -qE '^##[[:space:]]+Risk assessment criteria[[:space:]]*$' "$claude_md" 2>/dev/null; then
            add "$name marks Risk Assessment PROVEN but CLAUDE.md has no '## Risk assessment criteria' — the first-run interview was skipped. Run the ssdlc-risk-assessment interview (establish the regulatory regime — CRA/NIS2/IEC-62443 — and the always-include criteria), persist the section, then re-close"
            session_ok=0
        fi
    fi

    # Documentation: PROVEN requires the persisted conventions (audience policy + canonical locations). A
    # NOT_PERTINENT stays agent-decidable (behaviour-anchored: a purely internal change has no doc impact).
    if proof_verdict_is_proven "$doc_verdict"; then
        if ! grep -qE '^##[[:space:]]+Documentation conventions[[:space:]]*$' "$claude_md" 2>/dev/null; then
            add "$name marks Documentation PROVEN but CLAUDE.md has no '## Documentation conventions' — the first-run interview was skipped. Run the update-docs interview (audience policy + canonical doc locations), persist the section, then re-close"
            session_ok=0
        fi
    fi

    # (d) CITED-TEST authentication (best-effort, fail-open) — a Proof that authenticates PROVEN by CITING a
    # named test artifact (a *.sh / *.ps1 file, or a `test-<name>` suite) must cite one that ACTUALLY EXISTS in
    # the repo; a citation that resolves NOWHERE is a fabricated proof. We only ever flag a concretely-FALSE
    # citation — a Proof with NO parseable test citation is NOT blocked (many dimensions are reasoning-signal).
    # The extractor matches only strict test-artifact shapes, so ordinary prose never false-fires. [RiskMitigation]
    if command -v proof_missing_test_citations >/dev/null 2>&1; then
        _miss="$(proof_missing_test_citations "$PROJECT_DIR" "$proof" 2>/dev/null | head -1 || true)"
        if [ -n "$_miss" ]; then
            add "$name is Done but its Proof cites test '$_miss' which is not found anywhere in the repo — verify the proof, do not fabricate it: cite a test that exists (correct the name/path) or remove the citation"
            session_ok=0
        fi
    fi

    # (d2) TOOL-GATE (fail-HARD) — for the tool-gated dimension subset a PROVEN verdict must be backed by a fresh
    # CONTENT token the tool emitted over the changed files (see lib/proof-tool-gate.sh). Applicability is fail-OPEN:
    # a dimension whose tool does not apply to THIS change (e.g. Test Discipline on a story that touched no code) is
    # never blocked — so this can only ever block a genuinely-fabricated PROVEN, never wedge a legitimate close. The
    # bare verdict token is extracted exactly (the cell carries a ✅/❌/∅ glyph, and 'UNPROVEN' contains 'PROVEN').
    #
    # DEFAULT ON (KYKLOS_TOOL_GATE_<DIMENSION>=1 by default; set =0 in a repo's standards.env to opt down). Still fail-OPEN by construction on the two innocent paths: a story that changed NO source is not
    # gated, and a NOT_PERTINENT/UNPROVEN verdict is never blocked — so an armed gate can only ever block a
    # genuinely-fabricated PROVEN, never wedge a legitimate close. This enforces the anti-fabrication spirit fleet-wide.
    _tg_src="$(_tool_gate_source_root)"   # diff the SOURCE repo (nested Repo/ under companion, else $PROJECT_DIR)
    # only re-grade the diff-dependent gates while the live diff is still THIS story's own — if the last
    # commit belongs to a DIFFERENT story (its own Refs: #<other>), or the deliverable is cross-repo, the diff isn't
    # the story's. Run these checks ONLY when attributable (backward-compatible if the helper is absent).
    # Accepted once, not re-gated (same latch as the gitlab path): once one Stop accepted this story's tool tokens
    # for this proof hash, a later change to the same files cannot re-block the closed story.
    _tgmk="$state_dir/${name}-toolgate-${proof_hash}"
    if [ ! -f "$_tgmk" ] && { ! command -v _proof_tool_diff_attributable >/dev/null 2>&1 || _proof_tool_diff_attributable "$_tg_src" "$name"; }; then
    _probs_tg_before="$problems"
    # ops kind: Test Discipline metrics are optional (an ops deliverable may not be coverage-testable) — skip both
    # the PROVEN tool-gate and the NOT_PERTINENT mirror for Test Discipline on ops; every other kind is unchanged.
    if ! kyklos_control_off "${KYKLOS_TOOL_GATE_TEST_DISCIPLINE:-}" && [ "$_fs_kind" != "ops" ] && command -v proof_tool_gate_finding >/dev/null 2>&1; then
        _tdv="$(proof_verdict_class "$td_verdict" || true)"
        _tdgate="$(proof_tool_gate_finding "Test Discipline" "$_tdv" "$_tg_src" "$name" 2>/dev/null | head -1 || true)"
        if [ -n "$_tdgate" ]; then
            add "$name: $_tdgate"
            session_ok=0
        fi
    fi
    # MIRROR check — INDEPENDENT of the PROVEN tool-gate flag above: a NOT_PERTINENT that the diff contradicts
    # (source changed) is refused. Its OWN default-on control (PROOF_NOTPERTINENT_VERIFY, opt out with =off, checked
    # inside the finding); it runs even when the PROVEN gate is opted down (they are orthogonal checks). Extracts its own verdict so it does not depend on the block above.
    if [ "$_fs_kind" != "ops" ] && command -v proof_tool_notpertinent_finding >/dev/null 2>&1; then
        _tdnpv="$(proof_verdict_class "$td_verdict" || true)"
        _tdnp="$(proof_tool_notpertinent_finding "Test Discipline" "$_tdnpv" "$_tg_src" 2>/dev/null | head -1 || true)"
        if [ -n "$_tdnp" ]; then
            add "$name: $_tdnp"
            session_ok=0
        fi
        _ndnpv="$(proof_verdict_class "$nd_verdict" || true)"
        _ndnp="$(proof_tool_notpertinent_finding "Non-Duplication" "$_ndnpv" "$_tg_src" 2>/dev/null | head -1 || true)"
        if [ -n "$_ndnp" ]; then
            add "$name: $_ndnp"
            session_ok=0
        fi
    fi
    # Non-Duplication tool-gate — a PROVEN verdict must be backed by a fresh ssdlc-deduplicate pass token over
    # the changed source. Same DEFAULT-ON discipline (KYKLOS_TOOL_GATE_NON_DUPLICATION=0 to opt down) and the
    # same fail-open applicability (a story that touched no source is never gated) as the Test Discipline gate above.
    if ! kyklos_control_off "${KYKLOS_TOOL_GATE_NON_DUPLICATION:-}" && command -v proof_tool_gate_finding >/dev/null 2>&1; then
        _ndv="$(proof_verdict_class "$nd_verdict" || true)"
        _ndgate="$(proof_tool_gate_finding "Non-Duplication" "$_ndv" "$_tg_src" "$name" 2>/dev/null | head -1 || true)"
        if [ -n "$_ndgate" ]; then
            add "$name: $_ndgate"
            session_ok=0
        fi
    fi
    # Documentation tool-gate — a PROVEN verdict must be backed by a fresh update-docs pass token over the
    # changed source. Same DEFAULT-ON discipline (KYKLOS_TOOL_GATE_DOCUMENTATION=0 to opt down) + fail-open applicability.
    if ! kyklos_control_off "${KYKLOS_TOOL_GATE_DOCUMENTATION:-}" && command -v proof_tool_gate_finding >/dev/null 2>&1; then
        _docv="$(proof_verdict_class "$doc_verdict" || true)"
        _docgate="$(proof_tool_gate_finding "Documentation" "$_docv" "$_tg_src" "$name" 2>/dev/null | head -1 || true)"
        if [ -n "$_docgate" ]; then
            add "$name: $_docgate"
            session_ok=0
        fi
    fi
    [ "$problems" = "$_probs_tg_before" ] && touch "$_tgmk" 2>/dev/null || true
    fi   # end diff-attributable guard

    # (e) RA-## TRACEABILITY (fail-open) — when Risk Assessment is PROVEN, the story's risk-assessment.md must
    # enumerate at least one RA-## item (an empty register cannot back a PROVEN verdict). Any RA-## that claims a
    # code mitigation but has no matching `[RiskMitigation RA-##]` anywhere is a SOFT WARN (not a hard block —
    # some RA items are process, not code).
    if proof_verdict_is_proven "$ra_verdict"; then
        if command -v proof_ra_register_empty >/dev/null 2>&1 && proof_ra_register_empty "$_ra_text" 2>/dev/null; then
            add "$name marks Risk Assessment PROVEN but its register enumerates no 'RA-##' item — a PROVEN Risk Assessment must back the verdict with a numbered register (see the ssdlc-risk-assessment skill)"
            session_ok=0
        elif command -v proof_ra_untraced >/dev/null 2>&1; then
            # SOFT signal only: an untraced RA-## must NEVER block on its own (some RA items are process, not
            # code) — so we surface it as a WARN appended to the reason ONLY if this story is already blocking for
            # another reason. On its own it stays silent (fail-open), so it can never wedge a legitimate close.
            _untraced="$(proof_ra_untraced "$_ra_text" "$PROJECT_DIR" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//' || true)"
            if [ -n "$_untraced" ] && [ "$session_ok" -eq 0 ]; then
                add "$name (WARN) marks Risk Assessment PROVEN and its register cites code-mitigated item(s) [$_untraced] with no matching '[RiskMitigation RA-##]' in the tree — add the greppable marker at the mitigating code, or note why the item is process-only"
            fi
        fi
    fi

    # (c) close-on-green — gated by KYKLOS_MERGE_GREEN (default on) and ci_access_configured (lib/ci-access.sh):
    # a story may close only if its branch's latest pipeline is `success` AND that pipeline is REPRESENTATIVE (see
    # below). CI access not configured, no branch recorded, or curl/jq missing => inert. Configured but the pipeline
    # cannot be READ => BLOCK ("cannot verify" is never green).
    # [RiskMitigation RA-02] the read token is referenced by env-var NAME only (never on disk) and the query is
    # time-bounded — no token value leaks.
    if ! kyklos_control_off "${KYKLOS_MERGE_GREEN:-}"; then   # close-on-green rides the enforcement flag (default ON), NOT the push-context CI_MONITOR
        # Transport: the bridge-first CI seam (the bridge Control Tower CI verbs). PREFERS the ci_pipelines_list /
        # ci_jobs_list verbs (no container token); falls back to a direct token ONLY under the launcher's
        # direct-token exception (KYKLOS_CI_DIRECT_TOKEN=1). "cannot verify" is NEVER green.
        . "$(dirname "${BASH_SOURCE[0]}")/lib/ci-access.sh"   # ci_access_*: the token never leaves its helpers
        _tokok=""; ci_access_configured && _tokok=1
        # Repository model: when THIS container cannot self-drive real CI (KYKLOS_CI_SELF_DRIVE=false — a
        # cross-project CI include the container's own bot cannot resolve, so its push yields a 0-job pipeline),
        # the closed loop is NOT authoritative here. In that mode the agent bridge-verifies + merges LOCALLY and
        # SIGNALS a human for the real push; so "no pipeline" and an empty/0-job pipeline are EXPECTED, not a
        # close-blocker. Unset/true => self-drive (today's behaviour). Fail-open by default.
        _self_drive="${KYKLOS_CI_SELF_DRIVE:-true}"
        _br="$(grep -iE '^[-*[:space:]]*(\*\*)?Branch:' "$dir/requirements.md" 2>/dev/null | head -1 | sed -E 's/.*Branch:(\*\*)?[[:space:]]*//; s/[[:space:]].*$//; s/`//g' || true)"
        if [ -n "$_tokok" ] && [ -n "$_br" ] && [ "$_br" != "—" ] \
           && command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
            # Capture the HTTP code so we can tell "no pipeline exists (never pushed)" from "transient API error".
            # A container that branches -> commits -> merges LOCALLY without ever pushing produces NO pipeline: an
            # answered empty list => BLOCK (push & wait, unless not self-driving); an unreadable answer or an
            # unparseable body => BLOCK too (fail-closed, below). [RiskMitigation]
            # URL-ENCODE the branch: `_br` is the story's agent-authored Branch: field. Raw, a value like
            # `x&ref=<a-green-branch>` injects a second `ref=` and spoofs the "close only on green" gate against a
            # different green branch. Encode exactly as merge-green does. [CySec] Prevents CWE-88 argument/param
            # injection into the pipeline query.
            # NB `set -e` is on: an `x="$(cmd)"` assignment ABORTS the script when cmd fails, so a cannot-verify
            # (rc 3) would silently skip the whole block and pass. Capture through `if` (errexit is suppressed in a
            # condition) so a non-zero rc is HANDLED here (fail-CLOSED below), never an early exit.
            # The project the branch lives in: the bridge picks it from the origin of the repository that holds the
            # branch (a companion's nested source, or the companion itself); without one it would read its default
            # project, where a source branch has no pipeline. The branch is judged in EVERY repository that holds it (the same branch name may live in the companion and
            # in its nested source): each one's pipeline must be green. A branch that no repository holds is judged in
            # the project's only repository; with several candidates nothing is guessed and, through the bridge, the
            # close is refused by name (fail-CLOSED), never read in the default project.
            _repo_list="$(ci_access_branch_repositories "$_br" "$PROJECT_DIR" "$PROJECT_DIR/${KYKLOS_SOURCE_DIR:-Repo}")" || _repo_list=""
            # fd 3: a command in the loop that reads its standard input cannot swallow the list.
            while IFS= read -r _repo_addr <&3; do
            if [ "$(ci_access_mode)" = bridge ] && [ -z "$_repo_addr" ]; then
                _body=""; _plrc=6
            elif _body="$(ci_access_pipelines "$_br" "" 1 "$_repo_addr")"; then _plrc=0; else _plrc=$?; fi
            _where="the CI project of repository '${_repo_addr:-?}'"
            [ "$(ci_access_mode)" = bridge ] || _where="CI project '${KYKLOS_CI_PROJECT_ID:-}'"
            if [ "$_plrc" -eq 0 ]; then
                _st="$(printf '%s' "$_body" | jq -r '.pipelines[0].status // "none"' 2>/dev/null || echo parse_error)"
                _pipe_id="$(printf '%s' "$_body" | jq -r '.pipelines[0].id // empty' 2>/dev/null || echo "")"
                case "$_st" in
                    parse_error) add "$name is Done but its branch '$_br' pipeline in ${_where} could NOT be verified green — the CI response was unparseable. Close only on a VERIFIED green: wait for CI and re-check, or the user may authorize it with a 'Proof-Override:' line in the story."; session_ok=0 ;;   # [fail-CLOSED]
                    success)
                        # A `success` status is NOT enough: a pipeline that resolved to ZERO jobs (a bot that
                        # cannot read the cross-project CI include produces an empty, config-not-resolved pipeline)
                        # reports success while proving NOTHING — the same "not representative" trap
                        # Check-VerificationPipeline classifies. Confirm the pipeline actually ran jobs before we
                        # trust its green. When the jobs cannot be counted (no pipeline id, a failed or unparseable
                        # jobs read) the green is not verified either: in self-drive mode the close is refused until
                        # the jobs can be read (fail-CLOSED; a transient failure only delays the close).
                        # [CySec] Prevents CWE-636 "Not Failing Securely": an unreadable job count never counts as a
                        # representative green.
                        _jobs=""
                        if [ -n "$_pipe_id" ]; then
                            # `if` capture: under `set -e` a non-zero rc must be handled here, not abort the loop.
                            if _jbody="$(ci_access_jobs "$_pipe_id" "$_repo_addr")"; then _jrc=0; else _jrc=$?; fi
                            if [ "$_jrc" -eq 0 ]; then
                                _jobs="$(printf '%s' "$_jbody" | jq '.jobs | length' 2>/dev/null || echo "")"
                            fi
                        fi
                        case "${_jobs:-}" in
                            0)
                                # 0 jobs => NOT REPRESENTATIVE (empty/unresolved include). Never a real green.
                                if [ "$_self_drive" = "false" ]; then
                                    : # EXPECTED in non-self-drive mode: the container's bot resolves 0 jobs;
                                      # it merges locally + signals a human. Do NOT block on the empty pipeline.
                                else
                                    add "$name is Done but its branch '$_br' pipeline #$_pipe_id resolved to 0 JOBS — an EMPTY / config-not-resolved pipeline is NOT a real green (it proves nothing; a bot that cannot read the CI config yields 0 jobs). Do not treat it as success: fix the triggerer's config access (or set KYKLOS_CI_SELF_DRIVE=false if this container is not meant to self-drive CI), then re-verify on a representative pipeline."
                                    session_ok=0
                                fi
                                ;;
                            ''|*[!0-9]*)
                                # The jobs could not be counted: the green is not verified.
                                if [ "$_self_drive" != "false" ]; then
                                    add "$name is Done but the jobs of its branch '$_br' pipeline${_pipe_id:+ #$_pipe_id} could not be counted (no pipeline id, or the jobs list could not be read) — a success status that cannot be shown to have run any job is not a verified green. Re-check once CI answers, or the user may authorize it with a 'Proof-Override:' line in the story."
                                    session_ok=0
                                fi
                                ;;
                            *) : ;;   # >=1 job -> a representative green -> allow.
                        esac
                        ;;
                    none)
                        # No pipeline for the branch. In non-self-drive mode this is EXPECTED (merge locally +
                        # signal a human) — a signal, not a hard "you must push" block. In self-drive mode the
                        # closed loop compels the push.
                        if [ "$_self_drive" = "false" ]; then
                            : # merge-locally + signal: do NOT block the close.
                        else
                            add "$name is Done with merge-green enforcement ON (KYKLOS_MERGE_GREEN=1, the default) and CI configured, but no pipeline was found for its branch '$_br' in ${_where}. If it was not pushed yet: push the feature/hotfix branch, WAIT for the pipeline to go green (<=1 check/min), then close. The closed loop requires CI to see the change before it merges — a never-pushed branch cannot close."
                            session_ok=0
                        fi
                        ;;
                    *)
                        _air=""
                        if command -v ai_review_verdict >/dev/null 2>&1 && [ -n "$_pipe_id" ] \
                           && _verd="$(ai_review_verdict "$_pipe_id" "$_repo_addr")"; then
                            _air=" $(ai_review_note "${_verd%%$'\t'*}" "${_verd#*$'\t'}")"
                        fi
                        add "$name is Done but its branch '$_br' latest pipeline in ${_where} is '$_st', not success — close only on GREEN: push the branch, wait for the pipeline (<=1 check/min), fix if red, then re-close.${_air}"; session_ok=0 ;;
                esac
            else
                # [fail-CLOSED] the pipeline could not be READ but a CI verification mechanism IS configured — do
                # NOT let a Done story pass unverified. This fires when the KyklosBridge is DOWN and no direct-token
                # exception is declared, when the verb is refused as out-of-scope, or when the CI API is unreachable.
                # "cannot verify" is NEVER green. BLOCK; the user waits for CI or authorizes with a
                # 'Proof-Override:' line.
                _why="$(ci_access_failure_reason "$_plrc")"
                [ "$_plrc" = 6 ] && _why="no repository holds the branch (checked the project and its nested source directory, local and origin/ refs) and the project has no single repository to judge it in, so the CI project of the branch cannot be chosen; the default project is never assumed. Fetch the branch (git fetch origin $_br) in the repository it was pushed from, then close again"
                [ -n "$_why" ] || _why="the CI verdict was unreadable from ${_where} (the KyklosBridge is down and no direct-token exception is declared, the call was refused as out-of-scope, or the CI API was unreachable)"
                add "$name is Done but its branch '$_br' pipeline could NOT be verified green — ${_why}. Close only on a VERIFIED green: wait for CI and re-check, or the user may authorize it with a 'Proof-Override:' line in the story."
                session_ok=0
            fi
            done 3<<EOF_REPOS
$_repo_list
EOF_REPOS
        fi
    fi

    if [ "$session_ok" -eq 1 ]; then touch "$marker" 2>/dev/null || true; fi
done

if [ -n "$problems" ]; then
    _psg_block "$problems"
    exit 0
fi

exit 0
