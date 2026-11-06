#!/usr/bin/env bash
# kyklos-story-start-guard.sh (Kyklos, PreToolUse:Bash) -- catch SUBSTANTIAL work done with NO active story.
#
# PROBLEM: the SSDLC story discipline is enforced only at the END (story-proof-guard / quality gate block a
# CLOSE; continue-guard blocks a PAUSE). NOTHING fires at the START, so an agent can build a whole feature -- many
# commits, new files, new CI -- entirely OUTSIDE the lifecycle and no guard objects (there was never a story to
# gate). This front-loads the discipline: on a FEATURE-SCALE commit with no In-progress story, nudge (or block)
# to open one first -- where it is cheap, instead of only at close (where a retroactive story needs a bypass).
#
# WHAT IT DOES -- on a `git commit` whose subject is a feature-scale Conventional type (feat|fix|refactor|perf),
# in a project that USES the story workflow (a Stories/BACKLOG.md or a STORY_BACKEND), when there is NO In-progress
# story and no one-shot override:
#   * block (DEFAULT)  -- deny the commit until a story exists or the override is set.
#   * nudge (opt-down) -- allow the commit but SURFACE "open a story first (or set the override)".
#
# FAIL-OPEN: if story state can't be read (no BACKLOG, no story config, jq missing) -> allow silently; never block a
# project that doesn't use stories. EXCEPTION: a CONFIGURED gitlab story backend that is UNREACHABLE blocks (the
# override below admits it, logged). Override: bash hooks/lib/override-marker.sh set story-start-ok <repo-dir>
# (one-shot, consumed only when this guard would otherwise fire). CONFIG: KYKLOS_STORY_START_GUARD=off|nudge|block
# (default block). Wired: PreToolUse (Bash).
# [json-answer-required] Every answer this hook reads goes through the JSON reader; without it a check would exit 127
# and fall into a fail-open path, so the hook refuses by name instead (a broken install). [CySec] CWE-636
. "$(dirname "${BASH_SOURCE[0]}")/lib/json-answer.sh" 2>/dev/null
if ! command -v json_test >/dev/null 2>&1; then
    printf '{"decision":"block","reason":"BLOCKED (%s): the JSON reader hooks/lib/json-answer.sh did not load (broken install), so this check cannot run. Reinstall or repin the kyklos plugin."}\n' "$(basename "$0")"
    exit 0
fi
set +e -uo pipefail

_SS_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_SS_HERE/lib/standards-env.sh"; load_standards_env "$(. "$_SS_HERE/lib/repo-role.sh" 2>/dev/null && repo_companion_root "${CLAUDE_PROJECT_DIR:-$(pwd)}" || printf '%s' "${CLAUDE_PROJECT_DIR:-$(pwd)}")/.claude/standards.env"
. "$_SS_HERE/lib/git-cmd-detect.sh"   # git_cmd_invokes: command-position git-subcommand detection (shared)

# DEFAULT = block: story-first is enforced by default, not advisory. A repo opts down to
# nudge/off via KYKLOS_STORY_START_GUARD in its .claude/standards.env. This closes the "work now, wrap a story
# around it at close" reconstruct-at-close anti-pattern the SSDLC discipline disavows.
MODE="${KYKLOS_STORY_START_GUARD:-block}"
# shellcheck source=lib/control-switch.sh
. "$_SS_HERE/lib/control-switch.sh" 2>/dev/null || true   # kyklos_control_off: the one control-switch reader
kyklos_control_off "$MODE" && exit 0

command -v jq >/dev/null 2>&1 || exit 0   # fail-open: no jq -> cannot read the command safely

INPUT="$(cat || true)"
cmd="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
[ -n "$cmd" ] || exit 0
git_cmd_invokes "$cmd" commit || exit 0

# Subject (same extraction as the commit-message guard). Unreadable subject -> fail-open (that guard handles format).
subj="$(printf '%s' "$cmd" | awk 'match($0,/-m[ \t=]+"/){r=substr($0,RSTART+RLENGTH);q=index(r,"\"");if(q>0)print substr(r,1,q-1);else print r;exit}')"
[ -n "$subj" ] || subj="$(printf '%s' "$cmd" | grep -oE -- "-m[[:space:]=]+'[^']*'" | head -1 | sed -E "s/^-m[[:space:]=]+'//; s/'\$//")"
[ -n "$subj" ] || exit 0

# Only FEATURE-SCALE work needs a story. docs/style/test/build/ci/chore/revert are exempt (a story would be noise).
printf '%s' "$subj" | grep -cE '^(feat|fix|refactor|perf)(\([a-zA-Z0-9_.-]+\))?!?: ' >/dev/null || exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
# A project directory inside a companion's nested source (CLAUDE_PROJECT_DIR or the session working directory) is
# resolved to the companion root, where Stories/ and .claude/ live.
. "$(dirname "${BASH_SOURCE[0]}")/lib/repo-role.sh" 2>/dev/null && PROJECT_DIR="$(repo_companion_root "$PROJECT_DIR")"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/override-marker.sh"   # override_take: the scoped, expiring one-shot override
OK_NAME=story-start-ok
OK_SCOPE_HINT="<repo-dir>"
# the repository this commit targets: an override set for another repository (another agent's) is never spent here
_ss_scope="$(override_scope_of "$(git_target_repo_dir "$cmd" "$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)" "$PROJECT_DIR")")"

# JSON-string-escape a plain message (one implementation, reused by every emit path below — no per-site copy to drift).
_ss_json_escape() { local m="$1"; m="${m//\\/\\\\}"; m="${m//\"/\\\"}"; printf '%s' "$m" | tr '\n' ' '; }

# Resolve the AUTHORITATIVE backlog via the SHARED lib — the SAME resolver kyklos-story-backlog-guard uses,
# so the two guards can NEVER diverge. For the gitlab backend this queries LIVE GitLab; the local Stories/BACKLOG.md
# mirror is NOT trusted (a dead backend can't refresh it, so a stale In-progress row would falsely say "a story is
# active" and silently wave the commit through — the stale-mirror incident). resolve_backlog returns: a parseable
# backlog PATH, the __BACKLOG_UNREACHABLE__ sentinel (gitlab configured but unreachable), or EMPTY (no backend / no
# BACKLOG / genuinely-empty / broken seam).
_bl_lib="$_SS_HERE/lib/backlog-lib.sh"
if [ -f "$_bl_lib" ]; then
  . "$_bl_lib"
  _resolved="$(resolve_backlog "$PROJECT_DIR" 2>/dev/null || true)"
else
  # Broken install: fall back to the local mirror (fail-open on uncertainty — never block a possibly-non-story repo).
  _resolved=""; [ -f "$PROJECT_DIR/Stories/BACKLOG.md" ] && _resolved="$PROJECT_DIR/Stories/BACKLOG.md"
fi

# gitlab backend CONFIGURED but UNREACHABLE -> the active-story state is UNVERIFIABLE and the local mirror
# is stale. FAIL CLOSED (block, with a one-shot LOGGED override), as kyklos-story-backlog-guard does;
# never silently allow feature-scale work off unverifiable state.
if [ "$_resolved" = "__BACKLOG_UNREACHABLE__" ]; then
  if override_take "$OK_NAME" "$_ss_scope" "$INPUT"; then
    echo "[kyklos] story-start gate: OVERRIDDEN once ($OK_NAME spent) — active-story state NOT verified (story backend unreachable)." >&2
    exit 0
  fi
  _umsg="[kyklos] STORY-START: feature-scale commit ('${subj}') but the story backend is CONFIGURED and UNREACHABLE — an active story cannot be verified and the local BACKLOG.md mirror is stale (must not be trusted). Restore connectivity and re-run; or if this is a deliberate no-story commit, bash $OVERRIDE_MARKER_CLI set $OK_NAME $OK_SCOPE_HINT and re-run (logged). (KYKLOS_STORY_START_GUARD=off to disable.)"
  printf '{"decision":"block","reason":"%s"}' "$(_ss_json_escape "$_umsg")"
  exit 0
fi

# No backlog resolved (no backend / no BACKLOG / genuinely-empty backlog / broken seam) -> not a story project or
# nothing to gate -> fail-OPEN (never wedge a repo that doesn't use stories).
{ [ -n "$_resolved" ] && [ -f "$_resolved" ]; } || exit 0

# When the commit's TARGET branch names a story (feature/story-<N>-...), judge THAT story: it must itself be
# In-progress. "Some other story is active" must not wave through work on a raw or not-started story - the live hole
# where a companion agent worked user issues while an unrelated story was In-progress. Resolve the target repo the
# same way the branch guard does (git -C / cd / the hook's cwd), so a nested-source commit reads the nested branch.
_hook_cwd="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"
_tgt="$(git_target_repo_dir "$cmd" "$_hook_cwd" "$PROJECT_DIR")"
_branch="$(git -C "$_tgt" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
_named="$(story_num_from_branch "$_branch")"
# Only a repo that belongs to THIS workspace (the project itself, or a repo nested inside it such as the companion's
# public source) has its stories in THIS workspace's backlog. A commit in a repo OUTSIDE the workspace (a sibling
# checkout or worktree of another project) names a story of ANOTHER project: it is judged in that project's own
# backlog when the repo declares its story workflow, and not judged at all otherwise (see the case below).
_pd_real="$(cd "$PROJECT_DIR" 2>/dev/null && pwd -P)"; _tg_real="$(cd "$_tgt" 2>/dev/null && pwd -P)"
case "$_tg_real/" in
  "$_pd_real"/*) : ;;
  *)
    # The repo is OUTSIDE this workspace, so its story lives in THAT project's backlog, never this one's. When the
    # repo declares its own story workflow (.claude/standards.env), judge the named story in ITS backlog: the project
    # identity comes from the target (never leaked from this session). A repo with no declared workflow cannot be
    # judged here (unchanged behaviour).
    # [CySec] Prevents credential exfiltration and environment hijack (CWE-522, CWE-426, CWE-829): the foreign repo's
    # file contributes ONLY its story identity (STANDARDS_ENV_FOREIGN_KEYS). The API endpoint, the token variable and
    # every other setting (PATH, proxies, ...) stay this session's own.
    _ext=""
    if [ -n "$_named" ] && [ -f "$_tgt/.claude/standards.env" ] && command -v resolve_backlog >/dev/null 2>&1; then
      # A repository whose stories live on another GitLab instance cannot be judged with this session's instance.
      standards_env_same_instance "$_tgt/.claude/standards.env" && \
      _ext="$( unset STORY_BACKEND STORY_GITLAB_PROJECT STORY_GITLAB_LABEL
               # shellcheck disable=SC2086  # the key list is a space-separated constant, split on purpose
               load_standards_env_keys "$_tgt/.claude/standards.env" $STANDARDS_ENV_FOREIGN_KEYS 2>/dev/null
               resolve_backlog "$_tgt" 2>/dev/null )"
    fi
    if [ -n "$_ext" ] && [ -f "$_ext" ]; then _resolved="$_ext"; else _named=""; fi
    ;;
esac
# Broken install (backlog-lib absent): the named-story check cannot run, so fall through to the generic check below,
# which keeps enforcing on its own fallback - never a silent pass.
command -v backlog_story_in_progress >/dev/null 2>&1 || _named=""
if [ -n "$_named" ]; then
  backlog_story_in_progress "$_resolved" "$_named" && exit 0
  if override_take "$OK_NAME" "$_ss_scope" "$INPUT"; then exit 0; fi
  _nmsg="[kyklos] STORY-START: feature-scale commit ('${subj}') on branch '${_branch}', which names story #${_named}, but story #${_named} is NOT In-progress (another active story does not count). Adopt/start THAT story first: story adopt ${_named} --type <t> --epic <E0N> (a user-created issue), or story set ${_named} status=In-progress. Deliberate one-off: bash $OVERRIDE_MARKER_CLI set $OK_NAME $OK_SCOPE_HINT and re-run. (KYKLOS_STORY_START_GUARD=off to disable.)"
  if [ "$MODE" = block ]; then printf '{"decision":"block","reason":"%s"}' "$(_ss_json_escape "$_nmsg")"
  else printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"%s"}}' "$(_ss_json_escape "$_nmsg")"; fi
  exit 0
fi

# Is there an active (In-progress) story in the AUTHORITATIVE backlog? Use backlog-lib's COLUMN-AWARE, prose-safe
# status parse (backlog_count_status) — the SAME SSoT kyklos-story-backlog-guard uses — NOT a raw `grep In-progress`.
# A loose grep matches the word "In-progress" ANYWHERE on a row (e.g. a Notes cell reading "In-progress spike ...")
# and mis-fires on wide tables where Status is not column 3 — the exact wide/narrow + prose bug backlog-lib exists to
# kill; a divergent copy here would silently reintroduce it (R4: the two guards must not diverge). Errs toward
# not-firing. Broken install (lib absent, so the fn is undefined) -> fall back to the loose grep rather than crash.
if command -v backlog_count_status >/dev/null 2>&1; then
  [ "$(backlog_count_status "$_resolved" '[Ii]n[- ]?[Pp]rogress' 2>/dev/null)" -gt 0 ] 2>/dev/null && exit 0
else
  grep -qE '^\|.*[Ii]n[- ]?[Pp]rogress' "$_resolved" 2>/dev/null && exit 0
fi

# Feature-scale commit, no active story. Spend the one-shot override if present (a deliberate no-story commit).
if override_take "$OK_NAME" "$_ss_scope" "$INPUT"; then exit 0; fi

_msg="[kyklos] STORY-START: this is a feature-scale commit ('${subj}') but there is NO In-progress story. The SSDLC discipline is: open a story BEFORE substantial work (story new, or story adopt for an existing issue; story --help or the SessionStart tool catalog lists the required flags), so the work is planned + proof-gated -- not reconstructed at close. If this is a deliberate one-off with no story, bash $OVERRIDE_MARKER_CLI set $OK_NAME $OK_SCOPE_HINT and re-run. (KYKLOS_STORY_START_GUARD=nudge to only remind, =off to disable.)"
_esc="$(_ss_json_escape "$_msg")"

if [ "$MODE" = block ]; then
  printf '{"decision":"block","reason":"%s"}' "$_esc"
else
  # nudge (opt-down): allow the commit but surface the reminder for the NEXT step.
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"%s"}}' "$_esc"
fi
exit 0
