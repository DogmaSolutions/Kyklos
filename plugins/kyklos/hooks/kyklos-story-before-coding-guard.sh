#!/usr/bin/env bash
# kyklos-story-before-coding-guard.sh (Kyklos) - the SSDLC-side interceptor of "coding without a ready story".
# BRIDGE mode (a KyklosBridge build/run_tests) HARD-BLOCKS (with a one-shot escape hatch) - it intercepts the call
# TOWARD the bridge on the agent's side, so the bridge itself stays a clean, general, token-free tool. EDIT
# mode (Edit/Write) only WARNS (an edit is text, not working code). A "ready story" = one in-progress story that is
# fully authored (not an UNFILLED <FILL:> template / missing-section skeleton).
#
# WHY a new hook, not the structure gate: the structure gate (kyklos-story-structure-guard) blocks only a WORK Edit or
# a git-commit, and it FAIL-OPENS when there is NO active story (deliberately, to avoid false-positives). So two real
# slips reached coding unimpeded: coding with no story, and coding through the BRIDGE build/test path (which no story
# hook watches at all). This closes the gap with a coding-time WARNING on source edits (a warn, so legitimate
# story-less touches - docs, config, exploration - are never obstructed) and a BLOCK (with a one-shot override) on the
# bridge build/run_tests path.
#
# Wired: PreToolUse (Edit|Write|MultiEdit, arg "edit"; mcp__KyklosBridge__(build|run_tests), arg "bridge").
# ENABLED by default; KYKLOS_STORY_BEFORE_CODING=0 disables. FAIL-OPEN / SILENT on EVERY uncertainty (disabled, jq
# missing, no Stories/, no story tool, out-of-source-tree edit, ambiguous state) - a mis-fire never blocks a build.
# Non-spammy: the edit warning and the kind nudge fire at most once per project per container (a state stamp that is
# not reset between sessions). Surfaces via hookSpecificOutput.additionalContext
# (a PreToolUse hook's stderr is not delivered; additionalContext is). Regression-locked by
# tests/test-story-before-coding-guard.sh.
# [json-answer-required] Every answer this hook reads goes through the JSON reader; without it a check would exit 127
# and fall into a fail-open path, so the hook refuses by name instead (a broken install). [CySec] CWE-636
. "$(dirname "${BASH_SOURCE[0]}")/lib/json-answer.sh" 2>/dev/null
if ! command -v json_test >/dev/null 2>&1; then
    printf '{"decision":"block","reason":"BLOCKED (%s): the JSON reader hooks/lib/json-answer.sh did not load (broken install), so this check cannot run. Reinstall or repin the kyklos plugin."}\n' "$(basename "$0")"
    exit 0
fi
set +e -uo pipefail

MODE="${1:-edit}"
# shellcheck source=lib/control-switch.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/control-switch.sh" 2>/dev/null || true   # kyklos_control_off: the one control-switch reader
kyklos_control_off "${KYKLOS_STORY_BEFORE_CODING:-}" && exit 0
command -v jq >/dev/null 2>&1 || exit 0
INPUT="$(cat || true)"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/standards-env.sh
. "$HERE/lib/standards-env.sh" 2>/dev/null || true
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
# A project directory inside a companion's nested source (CLAUDE_PROJECT_DIR or the session working directory) is
# resolved to the companion root, where Stories/ and .claude/ live.
. "$(dirname "${BASH_SOURCE[0]}")/lib/repo-role.sh" 2>/dev/null && PROJECT_DIR="$(repo_companion_root "$PROJECT_DIR")"
command -v load_standards_env >/dev/null 2>&1 && load_standards_env "$PROJECT_DIR/.claude/standards.env" 2>/dev/null || true
kyklos_control_off "${KYKLOS_STORY_BEFORE_CODING:-}" && exit 0   # re-check after standards.env

# --- scope: only warn for genuine CODING actions -------------------------------------------------------------------
if [ "$MODE" = edit ]; then
  _fp="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null || true)"
  [ -n "$_fp" ] || exit 0
  case "$_fp" in */Stories/*|Stories/*) exit 0 ;; esac         # editing the story itself is never "coding"
  # Restrict to the SOURCE tree (KYKLOS_SOURCE_DIR, default Repo) so docs/config/infra edits are NOT nagged.
  _src="${KYKLOS_SOURCE_DIR:-Repo}"
  case "$_fp" in
    *"/$_src/"*|"$_src/"*) : ;;                                # under the source dir -> in scope
    *)
      # CROSS-REPO coding is coding: a SOURCE/SCRIPT file OUTSIDE the ambient project but inside
      # ANOTHER git work tree is in scope too: a source file in another git work tree is coding too, so scope is
      # not bound to the ONE ambient project. A non-source file (docs/config) in the foreign repo stays silent (parity with the in-project source scope);
      # a file in no git repo (scratch/tmp) stays silent. Inherits this guard's existing KYKLOS_STORY_BEFORE_CODING
      # default-ON flag (one control, no second knob).
      case "$_fp" in "$PROJECT_DIR"/*) exit 0 ;; esac          # in-project non-source (docs/config) -> silent
      case "$_fp" in
        *.sh|*.ps1|*.psm1|*.bat|*.cs|*.py|*.ts|*.tsx|*.js|*.jsx|*.go|*.java|*.rb|*.yml|*.yaml) : ;;
        *) exit 0 ;;                                           # non-source in a foreign tree -> silent
      esac
      _fdir="$(dirname "$_fp" 2>/dev/null)"
      [ -d "$_fdir" ] || exit 0
      git -C "$_fdir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0   # not a git repo -> silent
      ;;                                                       # foreign-repo source edit -> IN SCOPE (fall through)
  esac
fi
# bridge mode: a build / run_tests IS implementation activity -> always in scope.

# No story machinery here -> nothing to warn about. A declared story backend IS story machinery even without a local
# Stories/ mirror (a worktree, a companion clone, a fresh container): its stories live on the tracker.
_backend="${STORY_BACKEND:-}"
[ -d "$PROJECT_DIR/Stories" ] || [ -n "$_backend" ] || exit 0
STORY="${KYKLOS_STORY_BIN:-$HERE/../skills/ssdlc-story/story}"   # KYKLOS_STORY_BIN = test seam (mock the oracle)
[ -f "$STORY" ] || exit 0

reason=""
# --- the branch NAMES a story: judge THAT story ------------------------------------------------------
# The generic oracle below accepts "the single In-progress story is ready" or even "some row says In-progress" - so an
# agent could build (or edit) on feature/story-<N> for a RAW or unfilled issue N while an unrelated story was ready.
# When the work's repo is on a branch that names a story, readiness is judged for THAT story only.
# The work's repo: the edited file's repo (edit mode), else the workspace's source repo (KYKLOS_SOURCE_DIR, the
# nested public source in the companion topology), else the project itself.
. "$HERE/lib/git-cmd-detect.sh" 2>/dev/null || true
_wrepo=""
if [ "$MODE" = edit ] && [ -n "${_fp:-}" ]; then _wrepo="$(dirname "$_fp")"
elif git -C "$PROJECT_DIR/${KYKLOS_SOURCE_DIR:-Repo}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then _wrepo="$PROJECT_DIR/${KYKLOS_SOURCE_DIR:-Repo}"
else _wrepo="$PROJECT_DIR"; fi
_wbranch="$(git -C "$_wrepo" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
_named=""; command -v story_num_from_branch >/dev/null 2>&1 && _named="$(story_num_from_branch "$_wbranch")"
# Only a repo inside THIS workspace has its stories here; a repo outside it (another project's checkout) names a
# story of ANOTHER project, so it is not judged against this workspace's stories.
_wtop="$(git -C "$_wrepo" rev-parse --show-toplevel 2>/dev/null || true)"
case "$(cd "${_wtop:-/nonexistent}" 2>/dev/null && pwd -P)/" in "$(cd "$PROJECT_DIR" 2>/dev/null && pwd -P)"/*) : ;; *) _named="" ;; esac
if [ -n "$_named" ]; then
  if out="$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$STORY" structure "$_named" 2>&1)"; then
    exit 0                                                     # the named story is adopted + fully authored -> silent
  fi
  _o="$(printf '%s' "$out" | tr '\n' ' ' | sed 's/"/\x27/g')"
  reason="the story this work's branch '${_wbranch}' names (#${_named}) is NOT a ready story: ${_o}. Adopt it (story adopt ${_named} --type <t> --epic <E0N>) and author it fully BEFORE coding; another ready story does not count."
fi

# --- readiness oracle ----------------------------------------------------------------------------------------------
if [ -z "$reason" ]; then
# `story structure` (no id -> the single In-progress story): exit 0 = a conforming READY story (silent);
# exit 1 = an in-progress story that is INCOMPLETE (missing section(s) OR unfilled <FILL:> placeholders) -> warn;
# any other exit = no single in-progress story / ambiguous -> fall through to the positive BACKLOG count.
if out="$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$STORY" structure 2>&1)"; then
  # A READY story may still be a NO-CODE kind: an analysis/documentation story gets a
  # SOFT nudge (advisory, NEVER blocking — the spec is dissuasion, not enforcement) when coding starts under it.
  # Once per project per container; every uncertainty path (kind unreadable, jq hiccup) is silent — an advisory
  # must never obstruct a build. Inherits KYKLOS_STORY_BEFORE_CODING (one control, no second knob).
  # The once-per-container stamp is checked BEFORE the kind lookup, so the steady-state cost of the nudge is zero
  # (`story kind` is API-bound under the gitlab backend — it must not run on every edit).
  _kstate="${KYKLOS_STATE_DIR:-/tmp/kyklos-state}"
  _kkey="$(printf '%s' "$PROJECT_DIR" | tr -c 'A-Za-z0-9' _)"
  _kstamp="$_kstate/story-kind-nudge.$_kkey"
  if [ ! -f "$_kstamp" ]; then
    _kind="$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$STORY" kind 2>/dev/null | tr -d '[:space:]' || true)"
    # Stamp on ANY readable kind (development included): the decision is made once per container, so the API-bound
    # lookup never repeats. An UNREADABLE kind (empty) is NOT stamped — a transient must not silence the nudge.
    case "$_kind" in
      development|analysis|documentation|ops) mkdir -p "$_kstate" 2>/dev/null || true; : > "$_kstamp" 2>/dev/null || true ;;
    esac
    case "$_kind" in
      analysis|documentation)
        _KMSG="[kyklos] story-kind NUDGE: the active story is kind::${_kind} — a NO-CODE kind (research/documentation). You are starting ${MODE} activity that looks like coding. Prefer analysis/writing over code changes here; if real code work emerged, move it to a development story (or re-kind this one: story set <id> kind=development). This is a soft nudge, not a block — proceed if the touch is deliberate. Silenced for this project for the rest of this container's life."
        jq -nc --arg ctx "$_KMSG" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$ctx}}'
        ;;
    esac
  fi
  exit 0
else
  rc=$?
fi
if [ "$rc" -eq 1 ]; then
  _o="$(printf '%s' "$out" | tr '\n' ' ' | sed 's/"/\x27/g')"
  reason="the in-progress story is NOT ready yet: ${_o}. Author its content (fill every <FILL:> and required section) BEFORE writing code."
else
  _bl="$PROJECT_DIR/Stories/BACKLOG.md"
  # No local mirror to count from: with a declared backend the tool's own answer (no single in-progress story) stands.
  if [ -f "$_bl" ]; then
    # Count In-progress STORY ROWS only (table lines), never the prose that explains the marker -> no false "has one".
    _ip="$(grep -cE '^[[:space:]]*\|.*In-progress' "$_bl" 2>/dev/null || true)"; _ip="${_ip:-0}"
  elif [ -n "$_backend" ]; then _ip=0
  else exit 0; fi
  if [ "$_ip" = "0" ]; then
    reason="there is NO in-progress story. SSDLC requires the Requirements + Design phases to PRECEDE Implementation - open/adopt a story (story new ... / story adopt <id>) and author it BEFORE coding."
  else
    exit 0                                                     # a story is in progress but state was ambiguous -> silent
  fi
fi
fi   # end: generic oracle (skipped when the branch names a story)

STATE_DIR="${KYKLOS_STATE_DIR:-/tmp/kyklos-state}"; mkdir -p "$STATE_DIR" 2>/dev/null || true

# BRIDGE build/run_tests -> HARD BLOCK a build without a ready story. This is the SSDLC-side INTERCEPTOR of the
# call TOWARD the KyklosBridge (a PreToolUse deny on the agent's side), NOT a gate inside the bridge -- the bridge
# stays a clean, general, token-free tool. An EDIT is text, not working code, so it stays a WARN (below). Escape hatch
# for a legitimate non-story build: set the one-shot override (override-marker.sh set build-without-story-ok <your-working-folder>) in a SEPARATE prior step, or KYKLOS_STORY_BEFORE_CODING=0.
if [ "$MODE" = bridge ]; then
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/override-marker.sh"   # override_take: the scoped, expiring one-shot override
  if override_take build-without-story-ok "$(override_hook_scope "$INPUT" "$PROJECT_DIR")" "$INPUT"; then
    echo "[kyklos] story-before-coding: build-without-story ESCAPE HATCH consumed (one-shot) -> allowing this build." >&2
    exit 0
  fi
  _r="BLOCKED (story-before-coding): a KyklosBridge build/run_tests without a ready in-progress story -- ${reason} This is the SSDLC-side interceptor of the call to the bridge (the bridge itself is not gated). Open + FULLY author a story first (story new ... / story adopt <id>), OR for a deliberate non-story build run: bash ${OVERRIDE_MARKER_CLI} set build-without-story-ok <your-working-folder> in a SEPARATE prior step (spent once), OR set KYKLOS_STORY_BEFORE_CODING=0."
  _r="${_r//\\/\\\\}"; _r="${_r//\"/\\\"}"; _r="$(printf '%s' "$_r" | tr '\n' ' ')"
  printf '{"decision":"block","reason":"%s"}' "$_r"
  exit 0
fi

# --- EDIT mode: WARN (non-blocking), once per project per container --------------------------------------------------
_key="$(printf '%s' "$PROJECT_DIR" | tr -c 'A-Za-z0-9' _)"
_stamp="$STATE_DIR/story-before-coding-warned.$_key"
[ -f "$_stamp" ] && exit 0
: > "$_stamp" 2>/dev/null || true

MSG="[kyklos] story-before-coding WARNING: you are starting Implementation, but ${reason} (SSDLC Requirements/Design must precede Implementation - coding with an absent or unfilled story skips those phases.) This is a WARN, NOT a block: proceed if you have a deliberate reason (a quick doc/config touch), but the normal path is to open + FULLY author the story first. Disable with KYKLOS_STORY_BEFORE_CODING=0. Silenced for this project for the rest of this container's life."
jq -nc --arg ctx "$MSG" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$ctx}}'
exit 0
