#!/usr/bin/env bash
# kyklos-gitflow-branch-guard.sh (Kyklos) — enforces the GitFlow branching model + Conventional Commits.
#
# master/main = production, develop = integration; ALL work happens on a short-lived branch off develop
# (or master, for hotfixes): feature/*, release/*, hotfix/*, support/*. Never edit or commit
# directly on master/main/develop.
#
# Wired (see hooks.json), PreToolUse:
#   edit : Edit|Write|MultiEdit -> block editing a REPO FILE whose repo is on a protected branch
#                                  (branch first). Out-of-repo paths (agent memory, scratchpad) are allowed.
#   bash : Bash                 -> require a GitFlow prefix on a NEW branch; block `git commit` on a
#                                  protected branch; block an inline -m message that is not a Conventional
#                                  Commits subject (the subject rule itself is owned by kyklos-commit-message-guard.sh)
#
# One-shot escape (rare legit protected-branch op, e.g. a release/hotfix merge):
#   bash hooks/lib/override-marker.sh set gitflow-ok <repo-dir>   (spent by the first block in THAT repository;
#   an override set for another repository - another agent's - is left alone)
# [json-answer-required] Every answer this hook reads goes through the JSON reader; without it a check would exit 127
# and fall into a fail-open path, so the hook refuses by name instead (a broken install). [CySec] CWE-636
. "$(dirname "${BASH_SOURCE[0]}")/lib/json-answer.sh" 2>/dev/null
if ! command -v json_test >/dev/null 2>&1; then
    printf '{"decision":"block","reason":"BLOCKED (%s): the JSON reader hooks/lib/json-answer.sh did not load (broken install), so this check cannot run. Reinstall or repin the kyklos plugin."}\n' "$(basename "$0")"
    exit 0
fi
set -euo pipefail
_GD_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/control-switch.sh
. "$_GD_HERE/lib/control-switch.sh" 2>/dev/null || true   # kyklos_control_off: the one control-switch reader
. "$_GD_HERE/lib/git-cmd-detect.sh"   # git_cmd_invokes: command-position git-subcommand detection (shared)
. "$_GD_HERE/lib/repo-role.sh"        # repo_workflow / repo_role / repo_model_declared: the SINGLE topology-fed resolver

_cfg="${CLAUDE_PROJECT_DIR:-$(pwd)}/.claude/standards.env"
. "$_GD_HERE/lib/standards-env.sh"; load_standards_env "$_cfg"   # PARSE, never source (CWE-829): a malformed line can't execute
STATE_DIR="${KYKLOS_STATE_DIR:-/tmp/kyklos-state}"
mkdir -p "$STATE_DIR"

MODE="${1:-edit}"
. "$_GD_HERE/lib/override-marker.sh"   # override_take: the scoped, expiring one-shot override
_GF_SCOPE_DIR=""   # the repository the operation being judged targets (set per mode below); the override scope
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
INPUT="$(cat || true)"
# The shell's ACTUAL working directory for the command, from the hook input (.cwd) — used to resolve a bare
# git command (no -C/cd) to the repo it really runs in, rather than a possibly-inner/unset PROJECT_DIR.
HOOK_CWD="$(printf '%s' "$INPUT" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"

is_protected() { printf '%s' "$1" | grep -cE '^(develop|main|master)$' >/dev/null; }
branch_of()    { git -C "$1" rev-parse --abbrev-ref HEAD 2>/dev/null || echo ""; }

# Resolve the repo a git command ACTUALLY targets, so the branch check reads the repo the commit lands in
# (not blindly PROJECT_DIR); the precedence is documented in git_target_repo_dir (lib/git-cmd-detect.sh). This
# avoids the companion/nested-Repo model false-positive: PROJECT_DIR is the companion (often on a protected trunk like main),
# but `cd Repo && git commit` lands in the nested source repo on a feature branch. [CySec] Enforces
# poka-yoke: the guard must inspect the operation's real target, never a sibling repo that happens to be cwd.
# Thin wrapper over the SHARED resolver (lib/git-cmd-detect.sh) — one source of truth for "which repo does this
# git command target", reused by the commit-message + branch-cleanup guards so all three judge the same target.
target_repo_dir() { git_target_repo_dir "$1" "$HOOK_CWD" "$PROJECT_DIR"; }

# Repository model (persisted in .claude/standards.env): each repo declares its workflow, so the guard
# enforces GitFlow only where it applies. A companion project's OUTER repo (the private companion at the
# workspace root) is TRUNK-BASED bookkeeping — committing straight to main is CORRECT there, not a violation;
# only the INNER product source (KYKLOS_SOURCE_DIR, e.g. Repo) runs GitFlow. An internal tooling repo can be
# declared trunk too (KYKLOS_SOURCE_WORKFLOW=trunk). An undeclared repo is REFUSED (the no-default policy,
# KYKLOS_REPO_MODEL_REQUIRED, on by default) and the interview is demanded; only an explicit off value restores the
# old gitflow default.
# The model is read PER-REPO — from the TARGET repo's own .claude/standards.env first, then the container env — so
# working on a nested / cloned repo reads ITS model, not the container's CLAUDE_PROJECT_DIR. The model keys
# (KYKLOS_PROJECT_TOPOLOGY, legacy KYKLOS_REPO_SHAPE / KYKLOS_SOURCE_DIR / KYKLOS_SOURCE_WORKFLOW) and their
# resolution are owned by lib/repo-role.sh and lib/topology.sh (model: the ssdlc-repo-model skill). Guard switches:
#   KYKLOS_REPO_MODEL_REQUIRED    -> default on; no silent default: an undeclared repo is BLOCKED until interviewed
#   KYKLOS_STORY_FIRST            -> default on; a feature branch not linked to a story (feature/story-<n>-…) is
#                                      BLOCKED; a repo opts out with KYKLOS_STORY_FIRST=0
# The model read (_rr_model) + repo_workflow + repo_model_declared live in lib/repo-role.sh (the single
# topology-fed resolver, sourced above). This guard consumes them; it does NOT re-derive the model inline
# (test-no-inline-repo-workflow.sh forbids that).

# [Poka-Yoke] No silent default. When the target repo declares NO model (neither its own .claude/standards.env nor
# the container), REFUSE the write and demand the ssdlc-repo-model interview instead of assuming gitflow — this is the
# hole that let an undeclared /tmp clone be branched + committed outside SSDLC. On by default
# (KYKLOS_REPO_MODEL_REQUIRED); an unset value or a typo keeps it on, only an explicit off value opts out.
# assert_model_valid <dir> — fail-HARD (regardless of the REQUIRED phase flag) if the target repo declares an
# INVALID topology (an unknown value or a topology<->legacy-shape conflict). This is where topology.sh's fail-hard
# contract reaches the LIVE enforcement path: a garbage KYKLOS_PROJECT_TOPOLOGY must NEVER silently resolve to
# gitflow.
assert_model_valid() {
    local top; top="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null || echo "")"
    [ -n "$top" ] || return 0
    repo_model_invalid "$top" && block "Invalid repository model for '$top': KYKLOS_PROJECT_TOPOLOGY is an unknown topology or conflicts with the legacy KYKLOS_REPO_SHAPE. Fix it — run the ssdlc-repo-model interview (topology-declare.sh)."
    return 0   # not invalid -> success (else `set -e` would kill the guard on the &&-list's non-zero rc)
}

require_model() {
    local dir="$1"
    assert_model_valid "$dir"                     # an INVALID declared topology fails hard ALWAYS (not gated by REQUIRED)
    kyklos_control_off "${KYKLOS_REPO_MODEL_REQUIRED:-}" && return 0   # on by default; only an explicit off value opts out
    local top; top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || echo "")"
    [ -n "$top" ] || return 0                     # not a git repo -> nothing to declare
    repo_model_declared "$top" && return 0   # DECLARED (topology or legacy shape)
    block "No repository model is declared for '$top'. The Kyklos will NOT assume a default workflow (no-default policy). Declare it: run the ssdlc-repo-model interview (persists KYKLOS_PROJECT_TOPOLOGY to this repo's .claude/standards.env). One-shot override: bash $OVERRIDE_MARKER_CLI set gitflow-ok <repo-dir>."
}

# story_first_for <dir> -> rc 0 when STORY-FIRST (KYKLOS_STORY_FIRST) is on for the repo at <dir>, preferring the
# target repo's own .claude/standards.env over the container env (same per-repo resolution as lib/repo-role.sh). On
# by default: only an explicit off value opts a repo out (a typo keeps it on).
story_first_for() {
    local top; top="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null || echo "")"
    local sf="${KYKLOS_STORY_FIRST:-}"
    if [ -n "$top" ] && [ -f "$top/.claude/standards.env" ]; then
        local v; v="$(_rr_getkey "$top/.claude/standards.env" KYKLOS_STORY_FIRST)" && sf="$v"   # PARSE, never source (CWE-829)
    fi
    ! kyklos_control_off "$sf"
}

# _enforce_adopted_story <target-top> <branch> — the STORY-FIRST branch names a story (feature/story-<N>-…); under
# the GITLAB backend, VERIFY #N is a REAL adopted story (carries the story label), not a raw/user-created issue that
# is invisible to the proof gate + milestone logic. This is the poka-yoke for the hole where a user filed an issue,
# the agent branched feature/story-<N>, worked + closed it, and NO milestone / NO proof was ever enforced.
# Config: the TARGET repo's own .claude/standards.env; a nested source repo without one uses the workspace project's.
#   - #N is an adopted story with an authored spec -> allow (cache a marker so we hit the API only once per (project,N)).
#   - #N is a raw issue (rc 1)                      -> HARD BLOCK: demand `story adopt <N>` first.
#   - a DETERMINATE 401/403/404 (rc 2)              -> BLOCK (fail closed: the gate cannot verify).
#   - adopted but the spec still has `<FILL:` (rc 4) -> BLOCK until the spec is authored.
#   - any other (transient) error                   -> loud WARNING + allow (a transient API must never wedge a commit).
# gl_api is already bounded (--max-time); only the gitlab backend has this hazard (the FS backend has no raw issues).
_enforce_adopted_story() {
    local top branch cfg pid num seam key marker rc miss pdir
    top="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null || echo "")"; branch="$2"
    [ -n "$top" ] || return 0
    cfg="$top/.claude/standards.env"
    if [ ! -f "$cfg" ]; then
        # A repo with no settings of its own INSIDE the workspace project is the companion topology's nested public
        # source repo (AI-artifact-free by policy, so it can never carry .claude/). Its story backend is the workspace
        # project's. Returning here made the gate silently inert for EVERY nested-source commit (the live hole: raw
        # issues worked on feature/story-<N> in Repo/). A repo outside the workspace is not ours to judge.
        pdir="$(cd "$PROJECT_DIR" 2>/dev/null && pwd -P)"
        case "$(cd "$top" 2>/dev/null && pwd -P)/" in "$pdir"/?*) cfg="$PROJECT_DIR/.claude/standards.env" ;; *) return 0 ;; esac
        [ -f "$cfg" ] || return 0
    fi
    [ "$(_rr_getkey "$cfg" STORY_BACKEND)" = "gitlab" ] || return 0
    num="$(story_num_from_branch "$branch")"
    [ -n "$num" ] || return 0
    pid="$(_rr_getkey "$cfg" STORY_GITLAB_PROJECT)"
    key="$(printf '%s' "${pid}_${num}" | tr -c 'A-Za-z0-9._-' '_')"
    marker="$STATE_DIR/story-adopted-$key"
    [ -f "$marker" ] && return 0
    seam="$_GD_HERE/../skills/ssdlc-story/lib/story-backend.sh"
    rc=0; miss=""
    miss="$( export STORY_BACKEND=gitlab STORY_GITLAB_PROJECT="$pid" \
             STORY_GITLAB_TOKEN_ENV="$(_rr_getkey "$cfg" STORY_GITLAB_TOKEN_ENV)" \
             STORY_GITLAB_API="$(_rr_getkey "$cfg" STORY_GITLAB_API)" \
             STORY_GITLAB_LABEL="$(_rr_getkey "$cfg" STORY_GITLAB_LABEL)"
      # A missing or broken seam, or a library it could not load completely, is a broken install (exit 5, said
      # loudly below), never a transient: the seam records such a library in STORY_LIB_LOAD_FAILED and returns
      # success, so only require_story_seam can tell.
      STORY_SEAM_PROBLEM="cannot load $_GD_HERE/lib/require-lib.sh completely"
      { . "$_GD_HERE/lib/require-lib.sh" 2>/dev/null && require_story_seam "$seam" backend_is_adopted_story 2>/dev/null; } \
        || { printf '%s' "$STORY_SEAM_PROBLEM"; exit 5; }
      backend_is_adopted_story . "$num" >/dev/null 2>&1 || exit $?
      # adopted -> now REQUIRE the spec to be AUTHORED before work (a commit) proceeds. The gap is a story left as the `story new`/adopt SKELETON: block a commit while the linked story body
      # still carries an unfilled `<FILL: ...>` placeholder — the SAME discriminator the story CLI structure check
      # and the close gate use (a legitimately-authored `<word>` never matches `<FILL:`). Scoped to that POSITIVE
      # signal on purpose: a fleet gate that blocks EVERY commit must not false-block, so an authored spec, an
      # unreadable body, or a partial install all FAIL-OPEN (allow) — only a present `<FILL:` blocks.
      command -v backend_body_read >/dev/null 2>&1 || exit 0
      _body="$(backend_body_read . "$num" 2>/dev/null)"; [ -n "$_body" ] || exit 0
      printf '%s' "$_body" | grep -c '<FILL:' >/dev/null || exit 0
      exit 4 )" || rc=$?
    if [ "$rc" = 1 ]; then
        block "Story-first: issue #$num exists but is NOT an adopted story (no 'story' label, or a story label but never adopted - no tool-written metadata). A raw/user-created issue bypasses the proof gate AND the milestone requirement — exactly the hole that let a story close with no proof + no milestone. Adopt it into the lifecycle first:  story adopt $num --type <t> --epic <E0N>  (stamps the story label, attaches the epic milestone, injects the proof scaffold). Then work feature/story-$num-<slug>. Override once: bash $OVERRIDE_MARKER_CLI set gitflow-ok <repo-dir>."
    elif [ "$rc" = 2 ]; then
        # FAIL-CLOSED on a DETERMINATE auth/config failure (HTTP 401/403/404 — the story token cannot
        # read STORY_GITLAB_PROJECT, or #$num is absent). A story gate that CANNOT verify must NOT silently pass:
        # that fail-open is exactly what made this gate inert (the token could read one project but got a 404 on another) and let
        # un-adopted feature/story-<N> work land. BLOCK loudly; the one-shot override is the audited escape.
        block "Story-first: could NOT verify issue #$num is an adopted story — the adoption check hit a DETERMINATE auth/config error (HTTP 401/403/404: the story token cannot read STORY_GITLAB_PROJECT, or #$num does not exist). A story gate must not silently allow an unverified branch, so this is a BLOCK, not a pass. Fix the cause: adopt it (story adopt $num --type <t> --epic <E0N>) if it is a raw issue, OR point STORY_GITLAB_TOKEN_ENV at a token that can read the project. Deliberate one-shot override (a known-transient blip): bash $OVERRIDE_MARKER_CLI set gitflow-ok <repo-dir>."
    elif [ "$rc" = 4 ]; then
        # adopted, but the story body still carries the unfilled <FILL:> skeleton.
        block "Story-first: the linked story #$num is ADOPTED but its SPEC is NOT authored yet — the body still carries unfilled <FILL: ...> placeholder(s). Committing on a story whose Requirements / 2a-2f sections are still the skeleton is exactly the gap that let a story accrue commits before it was structured. Author the spec FIRST — fill the required sections, re-check with 'story structure $num' — then commit. Override once: bash $OVERRIDE_MARKER_CLI set gitflow-ok <repo-dir>."
    elif [ "$rc" = 5 ]; then
        # Not a close gate: a broken install is said loudly and the commit goes on (the story tool itself refuses to
        # run, so no story can be closed until the plugin is reinstalled).
        echo "[kyklos] WARNING: could not verify story issue #$num is adopted: the story backend $miss (a broken kyklos install). Reinstall kyklos; until then the story tool refuses to run." >&2
        return 0
    elif [ "$rc" != 0 ]; then
        echo "[kyklos] WARNING: could not verify story issue #$num is adopted (TRANSIENT gitlab/network error) — allowing this commit for availability. If #$num is a raw user-created issue it will bypass the proof gate + milestone; run 'story adopt $num --type <t> --epic <E0N>' to be safe." >&2
        return 0
    fi
    touch "$marker" 2>/dev/null || true
    return 0
}

# repo_workflow() is provided by lib/repo-role.sh (sourced above).

block() {
    local reason="$1" _gf_scope
    # One-shot override, spent only when a block is due and only for the repository this operation targets.
    if [ -n "$_GF_SCOPE_DIR" ]; then _gf_scope="$(override_scope_of "$_GF_SCOPE_DIR")"; else _gf_scope="$(override_hook_scope "$INPUT" "$PROJECT_DIR")"; fi
    if override_take gitflow-ok "$_gf_scope" "$INPUT"; then
        echo "[kyklos] gitflow-branch gate: OVERRIDDEN once (gitflow-ok spent for '$_gf_scope') - a protected-branch edit/commit was allowed." >&2; exit 0
    fi
    reason="${reason//\\/\\\\}"; reason="${reason//\"/\\\"}"; reason="${reason//$'\n'/\\n}"
    printf '{"decision":"block","reason":"%s"}' "$reason"
    exit 0
}

BRANCH_HELP="Create a GitFlow branch first (from develop, or master for a hotfix): git checkout -b feature/<slug> | release/<x.y.z> | hotfix/<slug> | support/<x.y>. Escape a legitimate protected-branch op with (a separate command first): bash $OVERRIDE_MARKER_CLI set gitflow-ok <repo-dir>"

# The one-shot escape applies to both modes; block() spends it (see above), so a call that is not blocked never does.

# ------------------------------------------------------------------ EDIT mode
# Path-aware and self-contained: block ONLY when the edited file lives in a git repo that is on a
# protected branch. Files outside any repo (agent memory, scratchpad) and files in a repo on a
# feature branch are always allowed — regardless of what branch CLAUDE_PROJECT_DIR sits on.
if [ "$MODE" = "edit" ]; then
    EDIT_PATH="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)"
    [ -z "$EDIT_PATH" ] && exit 0
    EDIT_DIR="$(dirname "$EDIT_PATH")"; _GF_SCOPE_DIR="$EDIT_DIR"
    [ -d "$EDIT_DIR" ] || exit 0
    EDIT_BRANCH="$(branch_of "$EDIT_DIR")"
    [ -z "$EDIT_BRANCH" ] && exit 0        # not inside a git repo -> allow
    assert_model_valid "$EDIT_DIR"         # an INVALID topology fails hard (never silently treated as non-gitflow -> allowed)
    # Only enforce the protected-branch block where the repo's declared workflow is GitFlow. A trunk-based repo
    # (a companion's outer bookkeeping repo, or a trunk-declared internal repo) edits main directly by design.
    if is_protected "$EDIT_BRANCH" && [ "$(repo_workflow "$EDIT_DIR")" = "gitflow" ]; then
        block "GitFlow: '${EDIT_PATH}' is in a repo on the protected branch '${EDIT_BRANCH}'. Never edit repo files directly on master/main/develop — branch first. ${BRANCH_HELP}"
    fi
    exit 0
fi

# ------------------------------------------------------------------ BASH mode
CMD="${INPUT//\\\"/\"}"
# The ACTUAL shell command (jq-extracted) — feed THIS to the command-position detector, NOT the JSON envelope
# (in the envelope a `git commit` sits inside a quoted string, correctly NOT a command position). CMD (envelope)
# is kept for target_repo_dir parsing (unchanged). Envelope-fallback only if jq is unavailable/empty.
CMD_REAL="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"; [ -n "$CMD_REAL" ] || CMD_REAL="$CMD"
printf '%s' "$CMD" | grep -ciE '\bgit\b' >/dev/null || exit 0
# strip heredoc bodies + quoted substrings before the branch-name match too, so a `git checkout -b …`
# MENTION in prose/a heredoc is not read as a real branch creation (same class the commit check already avoids).
CMD_BRANCH="$(git_cmd_strip "$CMD_REAL")"

# 1) A NEW branch must use a GitFlow prefix. Only branch-CREATING forms count:
#    `checkout [-flags] -b <name>`, `switch [-flags] -c <name>`, or `git branch <name>` where <name> is a plain name.
#    A flag token (-d, -D, -m, -a, -r, -v, --show-current, --list, ...) is NOT a new branch name.
# The create flag may sit AFTER other flags (`checkout -q -b x`, `switch --quiet -c x`) or be a combined
#    short cluster ending in the create letter (`checkout -qb x`) — the old `checkout -b` literal MISSED all of
#    those, silently letting a bad-named branch through. `([[:space:]]+-[^[:space:]]+)*` tolerates the leading flags
#    and `-[^[:space:]]*[bB]` / `-[^[:space:]]*[cC]` matches the create flag whether separate or clustered.
if printf '%s' "$CMD_BRANCH" | grep -ciE 'git[[:space:]]+(checkout([[:space:]]+-[^[:space:]]+)*[[:space:]]+-[^[:space:]]*[bB]([[:space:]]|$)|switch([[:space:]]+-[^[:space:]]+)*[[:space:]]+-[^[:space:]]*[cC]([[:space:]]|$)|branch[[:space:]])' >/dev/null; then
    NEWNAME="$(printf '%s' "$CMD_BRANCH" | grep -oiE 'git[[:space:]]+(checkout([[:space:]]+-[^[:space:]]+)*[[:space:]]+-[^[:space:]]*[bB]|switch([[:space:]]+-[^[:space:]]+)*[[:space:]]+-[^[:space:]]*[cC]|branch)[[:space:]]+[^[:space:]"'"'"']+' | head -1 | awk '{print $NF}' || true)"
    # A FLAG (-d/-a/--list/--show-current…) OR a shell OPERATOR (| ; & > < ( ) ` { }) captured after `git branch`
    # is LIST/pipe mode, not a branch name — so `git branch | grep …`, `git branch --show-current`, and
    # `git branch && …` are never mis-read as a branch-create (a live false block).
    case "$NEWNAME" in -*|'|'*|'&'*|';'*|'>'*|'<'*|'('*|')'*|'`'*|'{'*|'}'*) NEWNAME="" ;; esac
    # Enforce the GitFlow naming convention ONLY where the target repo's declared workflow is GitFlow — a
    # trunk-based repo (KYKLOS_SOURCE_WORKFLOW=trunk) may name branches freely (e.g. `git branch experiment`).
    # Resolve the target repo the same way the commit check does, so the naming rule reads the right repo.
    _NTGT="$(target_repo_dir "$CMD")"; _GF_SCOPE_DIR="$_NTGT"
    require_model "$_NTGT"   # no silent default: an undeclared repo must be interviewed before a branch is created
    if [ -n "$NEWNAME" ] && [ "$(repo_workflow "$_NTGT")" = "gitflow" ] \
       && ! printf '%s' "$NEWNAME" | grep -cE '^(feature|release|hotfix|support)/' >/dev/null; then
        block "GitFlow: branch name '${NEWNAME}' must start with feature/, release/, hotfix/, or support/. Rename it, e.g. feature/${NEWNAME}."
    fi
fi

# 2) No commit on a protected branch (only when we can read the project's branch — never fail closed).
# git_cmd_invokes anchors to a command position, so a `git commit` MENTION in a string does not trip this gate.
if git_cmd_invokes "$CMD_REAL" commit; then
    _TGT="$(target_repo_dir "$CMD")"; _GF_SCOPE_DIR="$_TGT"
    require_model "$_TGT"   # no silent default: an undeclared repo must be interviewed before a commit is made
    CURRENT_BRANCH="$(branch_of "$_TGT")"
    # Block a commit on a protected branch ONLY when that repo runs GitFlow. A trunk-based repo (companion
    # bookkeeping / trunk-declared internal) commits straight to main on purpose — allow it.
    if [ -n "$CURRENT_BRANCH" ] && is_protected "$CURRENT_BRANCH" && [ "$(repo_workflow "$_TGT")" = "gitflow" ]; then
        block "GitFlow: refusing to commit on the protected branch '${CURRENT_BRANCH}'. ${BRANCH_HELP}"
    fi
    # [Poka-Yoke] STORY-FIRST (default on; a repo opts out with KYKLOS_STORY_FIRST=0): on a story-first repo, a feature branch
    # must be DRIVEN by a story — its name must reference one (feature/story-<n>-<slug>). A feature branch
    # with no story is the un-tracked freelancing this blocks (e.g. a `feature/<slug>` created with no story behind
    # it). Override once: bash $OVERRIDE_MARKER_CLI set gitflow-ok <repo-dir>. (Branch-linkage is the stateless proxy; strengthen to a live
    # In-progress-story backend check later if needed.)
    if story_first_for "$_TGT" && printf '%s' "$CURRENT_BRANCH" | grep -cE '^feature/' >/dev/null; then
        if [ -z "$(story_num_from_branch "$CURRENT_BRANCH")" ]; then
            block "Story-first: branch '${CURRENT_BRANCH}' is not linked to a story. Start one (story new <slug> --type <t> --kind <development|analysis|documentation|ops> --severity <critical|high|medium|low> --epic <e>), then name the branch after it (feature/story-<n>-<slug>), so every change is story-driven. Override once: bash $OVERRIDE_MARKER_CLI set gitflow-ok <repo-dir>."
        else
            # The branch NAMES a story — verify it is a REAL adopted story, not a raw user-created issue that would
            # bypass the proof gate + milestone (the enforcement hole this closes). Gitlab-backend only; transient-safe.
            _enforce_adopted_story "$_TGT" "$CURRENT_BRANCH"
        fi
    fi
    # 3) BLOCK an inline -m message that is not a Conventional Commits subject (canonical type set — no 'data').
    #    Match a double-quoted, single-quoted, OR bare (unquoted single-word) -m argument so the check is not evaded
    #    by quoting style. The authoritative subject rule (incl. the scope syntax) is kyklos-commit-message-guard.sh;
    #    this coarser copy only catches an obviously wrong inline message early.
    MSG="$(printf '%s' "$CMD" | grep -oE -- '-m[[:space:]]+"[^"]+"' | head -1 | sed -E 's/^-m[[:space:]]+"//; s/"$//' || true)"
    [ -z "$MSG" ] && MSG="$(printf '%s' "$CMD" | grep -oE -- "-m[[:space:]]+'[^']+'" | head -1 | sed -E "s/^-m[[:space:]]+'//; s/'\$//" || true)"
    [ -z "$MSG" ] && MSG="$(printf '%s' "$CMD" | grep -oE -- '-m[[:space:]]+[^-][^[:space:]"'"'"']*' | head -1 | sed -E 's/^-m[[:space:]]+//' || true)"
    if [ -n "$MSG" ] && ! printf '%s' "$MSG" | grep -cE '^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([^)]+\))?!?: .+' >/dev/null; then
        block "Conventional Commits: '${MSG}' must be '<type>(<scope>): <subject>' with type one of feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert (scope optional; '!' for breaking). Example: feat(auth): add token refresh."
    fi
fi

exit 0
