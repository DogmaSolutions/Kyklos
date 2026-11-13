#!/usr/bin/env bash
# kyklos-no-push-guard.sh (Kyklos) — PreToolUse Bash. Blocks `git push` unless this container is
# authorized to push, or the push is one a project session may make itself.
#
# Push is a PRIVILEGED operation; the policy is the PUSH POLICY section of the managed policy
# (dist/CLAUDE.kyklos.md). This hook enforces it as follows (the code below is the reference):
#   - KYKLOS_ALLOW_PUSH=1 (the push-authorised session named in the organisation's policy layer): any push,
#     except a force update or deletion of a shared ref (trunk, release/*, support/*, tag).
#   - a user-applied 'push-override' label on the story issue, or the one-shot marker
#       bash hooks/lib/override-marker.sh set push-ok <repo-dir>
#     (the marker counts only when KYKLOS_HARDEN_OVERRIDE is explicitly off; it is on by default).
#   - KYKLOS_CI_MONITOR=1: a non-force, non-tag push of the repo's own current feature/* or hotfix/* branch, or
#     of main/master in a trunk-declared repo.
#   - everything else: DENY.
#   - a push ALLOWED above is still refused, as "queued", while the person at the host has declared the git remote
#     unavailable: the bridge records it (repository without credentials, branch, commit) in its own queue through
#     its mode_queue_push verb, and hands it back when the mode ends. This only ADDS a refusal; a bridge that cannot
#     be read, or that does not know the verb, leaves the decision to the checks above. Off-switch:
#     KYKLOS_PUSH_QUEUE=off.
#
# Wired: PreToolUse, matcher Bash.
# [json-answer-required] Every answer this hook reads goes through the JSON reader; without it a check would exit 127
# and fall into a fail-open path, so the hook refuses by name instead (a broken install). [CySec] CWE-636
. "$(dirname "${BASH_SOURCE[0]}")/lib/json-answer.sh" 2>/dev/null
if ! command -v json_test >/dev/null 2>&1; then
    printf '{"decision":"block","reason":"BLOCKED (%s): the JSON reader hooks/lib/json-answer.sh did not load (broken install), so this check cannot run. Reinstall or repin the kyklos plugin."}\n' "$(basename "$0")"
    exit 0
fi
set +e -uo pipefail
_GD_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_GD_HERE/lib/git-cmd-detect.sh"   # git_cmd_invokes: command-position git-subcommand detection (shared)
. "$_GD_HERE/lib/repo-role.sh"        # repo_workflow / repo_role: the SINGLE topology-fed resolver

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
_cfg="$PROJECT_DIR/.claude/standards.env"
# PARSE, never source (CWE-829): a malformed line can't execute (would mis-resolve the push policy + spam the TUI).
. "$(dirname "${BASH_SOURCE[0]}")/lib/standards-env.sh"; load_standards_env "$_cfg"
STATE_DIR="${KYKLOS_STATE_DIR:-/tmp/kyklos-state}"; mkdir -p "$STATE_DIR" 2>/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/override-marker.sh"   # override_take: the scoped, expiring one-shot override
OK_NAME=push-ok
OK_SCOPE_HINT="<repo-dir>"
INPUT="$(cat || true)"
CMD="${INPUT//\\\"/\"}"
# The ACTUAL shell command (jq-extracted) — feed THIS to the command-position detector, NOT the JSON envelope
# (in the envelope a `git push` sits inside a quoted string, correctly NOT a command position). Envelope-fallback
# only if jq is unavailable/empty. CMD (envelope) is kept for the target-repo/dir parsing below (unchanged).
CMD_REAL="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"; [ -n "$CMD_REAL" ] || CMD_REAL="$CMD"
# The shell's ACTUAL working directory for the command, from the hook input (.cwd). A bare `git push`
# (no -C/cd) runs HERE, which is NOT necessarily PROJECT_DIR (CLAUDE_PROJECT_DIR may be unset/inner).
HOOK_CWD="$(printf '%s' "$INPUT" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"

# Resolve the repo a git command targets — delegates to the SHARED git_target_repo_dir (lib/git-cmd-detect.sh,
# sourced above) with op=push, so a `cd` AFTER the push is not mis-picked and the closed-loop allowance judges the
# repo the PUSH lands in. The resolver's rationale (incl. [RiskMitigation RA-01], the bare-push cwd resolution) lives
# with that shared helper.
target_repo_dir() { git_target_repo_dir "$1" "$HOOK_CWD" "$PROJECT_DIR" push; }

# Repository model: a TRUNK-DECLARED repo (a companion's private outer bookkeeping repo, KYKLOS_SOURCE_DIR
# selecting the inner GitFlow source) pushes its OWN trunk by design. Resolve the target repo's workflow so the
# trunk-bookkeeping push is allowed while the (public, GitFlow) source keeps only the feature/hotfix allowance.
# Unset model => gitflow (back-compat).
# repo_workflow() is provided by lib/repo-role.sh (sourced above) - the single topology-fed resolver. This
# guard consumes it (+ repo_role for the artifact-facade check); it does NOT re-derive the model inline.

# Only act on `git push` at a command position (a `git push` MENTION in a string is not a push). Shared detector.
git_cmd_invokes "$CMD_REAL" push || exit 0

# Two refusals that bind EVEN a push-authorized (KYKLOS_ALLOW_PUSH) session -> checked BEFORE the
# early exit. (a) an INVALID declared topology must never permit a push (no silent default reaches the push path);
# (b) the PUBLIC ARTIFACT FACADE (KYKLOS_ARTIFACT_FACADE=1 / a PriSouPubArt artifact) is published by its source
# repo's pipeline, NEVER hand-pushed. This wires the artifact-facade check the guard's comments already claimed.
_np_block() { local r="${1//\\/\\\\}"; r="${r//\"/\\\"}"; r="$(printf '%s' "$r" | tr '\n' ' ')"; printf '{"decision":"block","reason":"%s"}' "$r"; exit 0; }
_np_tgt="$(target_repo_dir "$CMD")"

# The last step of every ALLOWED push: while the git remote is declared unavailable, the bridge queues the push and the
# guard refuses it as queued (the agent runs it when the mode ends, through this same guard). The record lives only in
# the bridge's host-side store, never in a file the agent can edit; the remote address loses any user name or token
# before it leaves (the bridge refuses one anyway). The record names what the command pushes: the branch of its one
# refspec (`origin feature/x`, `origin HEAD:feature/x`) and that refspec's commit, else the checked-out branch. A push the
# bridge cannot record while the mode is on (a detached HEAD, several refspecs, a project it does not serve) comes back
# "not queued, push refused:" and is refused too. Any other answer changes nothing.
# [CySec] Prevents CWE-522 "Insufficiently Protected Credentials": a credential embedded in the remote address is never
# sent to the queue. [RiskMitigation RA-01]
_np_queue_if_remote_down() {
    kyklos_control_off "${KYKLOS_PUSH_QUEUE:-}" && return 0
    command -v jq >/dev/null 2>&1 || return 0
    # shellcheck source=lib/bridge-mcp.sh
    . "$_GD_HERE/lib/bridge-mcp.sh" 2>/dev/null || return 0
    local current branch commit remote url args reply text seg tok expect="" src dst
    local -a toks positional=()
    current="$(git -C "$_np_tgt" symbolic-ref --quiet --short HEAD 2>/dev/null)"
    # The words after the last `git ... push`, up to the next command separator.
    seg="$(sed -E 's/.*(^|[[:space:];&|(])git([[:space:]]+-C[[:space:]]+[^[:space:]]+)*[[:space:]]+push([[:space:]]|$)//; s/(&&|\|\||;|\|).*//' <<< "$CMD_REAL")"
    read -ra toks <<< "${seg//[\"\']/}"
    for tok in "${toks[@]}"; do
        if [ -n "$expect" ]; then expect=""; continue; fi
        case "$tok" in
            -o|--push-option|--repo|--receive-pack|--exec) expect=1 ;;
            -*) ;;
            *) positional+=("$tok") ;;
        esac
    done
    remote="${positional[0]:-}"
    branch="$current"; src="HEAD"
    if [ "${#positional[@]}" -eq 2 ]; then
        dst="${positional[1]#+}"; src="${dst%%:*}"; dst="${dst#*:}"
        dst="${dst#refs/heads/}"
        [ "$dst" = "HEAD" ] && dst="$current"
        branch="$dst"; [ -n "$src" ] || src="HEAD"
    elif [ "${#positional[@]}" -gt 2 ]; then
        branch=""   # several refspecs: one record cannot name them, so the bridge refuses it while the mode is on
    fi
    commit="$(git -C "$_np_tgt" rev-parse --verify --quiet "$src^{commit}" 2>/dev/null)"
    if [ -z "$remote" ]; then
        remote="$(git -C "$_np_tgt" config --get "branch.$current.pushRemote" 2>/dev/null || git -C "$_np_tgt" config --get "branch.$current.remote" 2>/dev/null || echo origin)"
    fi
    case "$remote" in
        *://*|*@*:*) url="$remote" ;;
        *) url="$(git -C "$_np_tgt" remote get-url --push "$remote" 2>/dev/null)" ;;
    esac
    url="$(sed -E 's#^(https?://)[^/@]*@#\1#' <<< "$url")"
    args="$(jq -nc --arg r "$url" --arg b "$branch" --arg c "$commit" '{repository:$r,branch:$b,commit:$c}')" || return 0
    reply="$(bridge_mcp_call mode_queue_push "$args" 10)" || return 0
    bridge_mcp_is_error "$reply" && return 0
    text="$(bridge_mcp_text "$reply")"
    case "$text" in
        queued:*|"not queued, push refused:"*) _np_block "Push not made, $text" ;;
    esac
    return 0
}
_np_allow() { _np_queue_if_remote_down; exit 0; }
# Fail-SAFE on an UNDECIDABLE push target: the shared resolver returns the sentinel when a command substitution feeds
# the target, so the guard cannot tell which repo the push lands in. Refuse with a disambiguation remedy rather than
# judge a bogus literal path (and never resolve it to a repo that happened to match). [RiskMitigation RA-02]
[ "$_np_tgt" = "__UNDECIDABLE__" ] && _np_block "Push refused: the push target is UNDECIDABLE — it is fed by a command substitution, so the guard cannot determine which repo it lands in and fails safe. Re-run with an explicit, literal target, e.g. git -C <repo-dir> push origin <branch>."
_np_top="$(git -C "$_np_tgt" rev-parse --show-toplevel 2>/dev/null || echo "")"
# ONE BRANCH, ONE ITEM (lib/refs-rule.sh), binding every session: the checked-out branch's commits cite one item (its
# story on a story branch), so the merge request this push feeds carries only that item's change. Switched off together
# with the commit footer rule.
# shellcheck source=lib/refs-rule.sh
. "$_GD_HERE/lib/refs-rule.sh"
. "$_GD_HERE/lib/control-switch.sh" 2>/dev/null || true
if [ -n "$_np_top" ] && ! kyklos_control_off "${KYKLOS_REQUIRE_REFS:-}"; then
    # [refs-footer-required] the rule reads footers through the one definition (lib/refs-footer.sh): without it the
    # check would silently find nothing, so the push is refused by name instead (a broken install). [CySec] CWE-636
    command -v refs_footer_cited >/dev/null 2>&1 && command -v refs_rule_branch_refusal >/dev/null 2>&1 \
        || _np_block "Push refused: the footer reader hooks/lib/refs-footer.sh or hooks/lib/refs-rule.sh did not load (broken install), so the one-branch-one-item check cannot run. Reinstall or repin the kyklos plugin."
    _np_rr="$(refs_rule_branch_refusal "$_np_top")"
    [ -z "$_np_rr" ] || _np_block "Push refused: $_np_rr"
fi
[ -n "$_np_top" ] && repo_model_invalid "$_np_top" && _np_block "Push refused: the target repo declares an INVALID topology (unknown value or a topology<->shape conflict). Fix it: run the ssdlc-repo-model interview (topology-declare.sh)."
[ "$(repo_role "$_np_tgt")" = "artifact" ] && _np_block "Push refused: this is a PUBLIC ARTIFACT FACADE - published by its source repo's pipeline, NEVER hand-pushed. Push the private SOURCE repo instead."

# The push classes that rewrite or remove history, detected ONCE for both paths below.
# _np_is_force: any force form - --force, --force-with-lease[=..], --force-if-includes, -f (also bundled, e.g. -fu)
# or a +refspec (a non-fast-forward update).
_np_is_force() {
    printf '%s' "$1" | grep -ciE '(^|[[:space:]])(--force|--force-with-lease|--force-if-includes|-f)([[:space:]=]|$)' >/dev/null && return 0
    # A BUNDLED short-flag group can hide -f (e.g. `git push -fu origin x`): an f inside a run of lowercase short
    # flags, anchored on whitespace so a filename or refspec containing 'f' is not caught. [CySec] Enforces
    # least-privilege push (CWE-284): closes the bundled-force-flag evasion of the force-push denial.
    printf '%s' "$1" | grep -cE '(^|[[:space:]])-[a-eg-z]*f[a-z]*([[:space:]]|$)' >/dev/null && return 0
    # A `+refspec` (`+feature/x`, `+HEAD:main`) is a force update the flags miss. [CySec] Enforces least-privilege
    # push (CWE-284): closes the +refspec force-push evasion of the force-push denial.
    printf '%s' "$1" | grep -cE '(^|[[:space:]])\+[^[:space:]]' >/dev/null && return 0
    return 1
}
# _np_is_delete: --delete, -d (also bundled) or an empty-source refspec `:ref`.
_np_is_delete() {
    printf '%s' "$1" | grep -ciE '(^|[[:space:]])(--delete|-[a-ce-z]*d[a-z]*)([[:space:]]|$)' >/dev/null && return 0
    printf '%s' "$1" | grep -cE '(^|[[:space:]]):[^[:space:]]' >/dev/null && return 0
    return 1
}
# _np_shared_ref: the push names a trunk (main/master/develop, also as +main, :main or a refspec destination),
# release/*, support/* or any tag.
_np_shared_ref() {
    printf '%s' "$1" | grep -ciE '(^|[[:space:]"+:])(refs/heads/)?(master|main|develop)([[:space:]"]|$)' >/dev/null && return 0
    printf '%s' "$1" | grep -ciE '(release|support)/[^[:space:]"]*(:|[[:space:]"]|$)' >/dev/null && return 0
    printf '%s' "$1" | grep -ciE '(^|[[:space:]])--(tags|follow-tags)([[:space:]"]|$)|refs/tags/' >/dev/null && return 0
    # A tag pushed by its bare name (`v1.2`, `+v1.2`, `:v1.2`, `HEAD:v1.2`): a token naming an existing tag of the
    # target repository. [CySec] Enforces integrity of published tags (CWE-284): closes the bare-name evasion.
    local tok
    for tok in $(printf '%s' "$1" | tr '"' ' '); do
        tok="${tok##*:}"; tok="${tok#+}"
        case "$tok" in ''|-*|*[!A-Za-z0-9._/-]*) continue ;; esac
        git -C "$_np_tgt" show-ref --verify --quiet "refs/tags/$tok" 2>/dev/null && return 0
    done
    return 1
}

# Authorized container (the push-authorised session)? It pushes trunks and shared repos, but it never REWRITES or DELETES shared
# history: a force update or deletion of a trunk, release/*, support/* or a tag is refused even here. Its own
# feature/hotfix branches stay force-pushable (a rebase of unmerged work). [CySec] Enforces least-privilege push
# (CWE-284) and integrity of shared history (CWE-494 class: what every consumer builds from).
if [ "${KYKLOS_ALLOW_PUSH:-0}" = "1" ]; then
    if { _np_is_force "$CMD" || _np_is_delete "$CMD"; } && _np_shared_ref "$CMD"; then
        _np_block "Push refused: this would force-update or delete a SHARED ref (a trunk main/master/develop, release/*, support/* or a tag). Even a push-authorized session never rewrites or deletes shared history. Push a new commit instead, or ask the owner to do it by hand."
    fi
    _np_allow
fi
# Override, hardest rung FIRST: a USER-applied `push-override` label on the pushed branch's story issue.
# An agent cannot author a label as ANOTHER GitLab user, so it cannot self-grant this (unlike the touch-able marker
# below). Fail-closed => falls through to the legacy marker.
. "$(dirname "${BASH_SOURCE[0]}")/lib/user-applied-label.sh" 2>/dev/null || true
if command -v override_user_applied >/dev/null 2>&1 && override_user_applied "$CMD_REAL" "push-override"; then
    echo "[kyklos] no-push gate: ALLOWED by a USER-applied 'push-override' label on the story issue (un-self-grantable)." >&2; _np_allow
fi
# Legacy one-shot self-touch escape — honored only while the hardening is explicitly off. Warns that it is a
# SELF-GRANTED (deprecated) override: it counts only when KYKLOS_HARDEN_OVERRIDE is explicitly off (on by default, so
# by default only the user-applied label authorizes).
# shellcheck source=lib/control-switch.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/control-switch.sh" 2>/dev/null || true   # kyklos_control_off: the one control-switch reader
if kyklos_control_off "${KYKLOS_HARDEN_OVERRIDE:-}" && override_take "$OK_NAME" "$(override_scope_of "${_np_top:-$PROJECT_DIR}")" "$INPUT"; then
    echo "[kyklos] no-push gate: OVERRIDDEN once ($OK_NAME spent) — push allowed via a SELF-GRANTED marker. DEPRECATED: remove the KYKLOS_HARDEN_OVERRIDE opt-out to require a user-applied 'push-override' label instead." >&2; _np_allow
fi

# ---- Closed-loop allowance (feature/hotfix, monitored) ----
# A PROJECT session MAY push its OWN feature/hotfix branch, but ONLY when a CI monitor is configured
# (KYKLOS_CI_MONITOR=1) — so it can watch the pipeline its push triggers and close the story only on
# green (why these branches are safe to push: the closed-loop exception of the PUSH POLICY in the managed
# policy). Everything riskier stays blocked: trunks (master/main/develop),
# release/*, support/*, TAG pushes, and FORCE pushes. With no monitor configured, ALL project pushes stay
# blocked (fall through). [CySec] Enforces least-privilege push (CWE-284): the high-risk push classes stay
# impossible-by-design; only the provably-safe feature/hotfix case is opened, and only when observable.
# [RiskMitigation RA-01] the current-branch-must-be-feature/hotfix gate + explicit deny of trunk/tag/force/
# release/support destinations keeps a too-permissive push impossible even under an adversarial refspec.
if [ "${KYKLOS_CI_MONITOR:-0}" = "1" ]; then
    _tgt="$(target_repo_dir "$CMD")"
    push_branch="$(git -C "$_tgt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
    # Force/tag pushes are NEVER bookkeeping and stay denied regardless of workflow.
    _forcetag=0
    printf '%s' "$CMD" | grep -ciE '(^|[[:space:]])--tags([[:space:]"]|$)|refs/tags/' >/dev/null && _forcetag=1
    _np_is_force "$CMD" && _forcetag=1

    # TRUNK-DECLARED repo (e.g. the private companion): a non-force/non-tag push to its OWN trunk (main/master)
    # is the declared bookkeeping workflow. The GitFlow source is NOT trunk (repo_workflow => gitflow), so this
    # NEVER opens a trunk push to the public source. [RiskMitigation RA-01]
    if [ "$_forcetag" = 0 ] && [ "$(repo_workflow "$_tgt")" = "trunk" ]; then
        case "$push_branch" in
            main|master) _np_allow ;;   # ALLOW: trunk bookkeeping push to a trunk-declared repo
        esac
    fi

    # GitFlow repo: the existing feature/hotfix-only allowance; trunks/release/support/tags/force stay blocked.
    deny="$_forcetag"
    printf '%s' "$CMD" | grep -ciE '[[:space:]"](master|main|develop)([[:space:]"]|$)' >/dev/null && deny=1
    printf '%s' "$CMD" | grep -ciE ':(refs/heads/)?(master|main|develop)([[:space:]"]|$)' >/dev/null && deny=1
    printf '%s' "$CMD" | grep -ciE '(release|support)/[^[:space:]"]*(:|[[:space:]"]|$)' >/dev/null && deny=1
    if [ "$deny" = 0 ]; then
        case "$push_branch" in
            feature/*|hotfix/*) _np_allow ;;   # ALLOW: observable feature/hotfix push under the closed loop
        esac
    fi
fi

# The refusal explains itself: WHY (the kind of push, and the topology, KYKLOS_CI_MONITOR and KYKLOS_ALLOW_PUSH as
# read) and WHICH setting, if any, would allow it. It only describes the decision taken above; it never changes which
# push passes.
_np_cur="$(git -C "$_np_tgt" symbolic-ref --quiet --short HEAD 2>/dev/null || echo "")"
_np_wf="$(repo_workflow "$_np_tgt")"
_np_topo="$(topology_effective "$(repo_setting_of "$_np_tgt" KYKLOS_PROJECT_TOPOLOGY 2>/dev/null || true)" \
    "$(repo_setting_of "$_np_tgt" KYKLOS_REPO_SHAPE 2>/dev/null || true)" 2>/dev/null)" || _np_topo="not declared"
_np_topo="$_np_topo ($(repo_role "$_np_tgt") repository, $_np_wf branch model)"
_np_trunk_names() { printf '%s' "$1" | grep -ciE '(^|[[:space:]"+:])(refs/heads/)?(master|main|develop)([[:space:]"]|$)' >/dev/null; }
_np_release_names() { printf '%s' "$1" | grep -ciE '(release|support)/[^[:space:]"]*(:|[[:space:]"]|$)' >/dev/null; }
_np_tag_names() {
    printf '%s' "$1" | grep -ciE '(^|[[:space:]])--(tags|follow-tags)([[:space:]"]|$)|refs/tags/' >/dev/null && return 0
    # A tag pushed by its bare name: a shared ref that is neither a trunk nor a release/support branch.
    _np_shared_ref "$1" && ! _np_trunk_names "$1" && ! _np_release_names "$1"
}
# _np_kind_of: the kind of push, from the command first (force, tag, a named trunk, a named release/support branch),
# else from the checked-out branch a bare push sends.
_np_kind_of() {
    if _np_is_force "$CMD"; then printf 'force'
    elif _np_tag_names "$CMD"; then printf 'tag'
    elif _np_trunk_names "$CMD"; then printf 'trunk'
    elif _np_release_names "$CMD"; then printf 'release'
    else
        case "$_np_cur" in
            main|master|develop) printf 'trunk' ;;
            release/*|support/*) printf 'release' ;;
            feature/*|hotfix/*) printf 'feature' ;;
            "") printf 'detached' ;;
            *) printf 'other' ;;
        esac
    fi
}
_np_only_authorised="Only the push-authorised session your organisation names (KYKLOS_ALLOW_PUSH=1) may push it; a project session pushes its story branch and lets the merge request bring the work to the trunk."
case "$(_np_kind_of)" in
    force)
        _np_kind="it is a force push, which rewrites the history of the branch it updates"
        _np_fix="No setting lets a project session force-push. The push-authorised session (KYKLOS_ALLOW_PUSH=1) may force-push only a feature/* or hotfix/* branch, never a trunk, a release/* or support/* branch or a tag. Push a new commit instead." ;;
    tag)
        _np_kind="it pushes a tag"
        _np_fix="$_np_only_authorised" ;;
    trunk)
        _np_kind="it pushes a trunk (main, master or develop)"
        case "$_np_wf:$_np_cur:${KYKLOS_CI_MONITOR:-0}" in
            trunk:main:1|trunk:master:1) _np_fix="$_np_only_authorised" ;;
            trunk:main:*|trunk:master:*) _np_fix="KYKLOS_CI_MONITOR=1 would allow it: this repository's branch model is trunk-based, so a project session then pushes its own main or master, without force." ;;
            *) _np_fix="$_np_only_authorised" ;;
        esac ;;
    release)
        _np_kind="it pushes a release/* or support/* branch"
        _np_fix="$_np_only_authorised" ;;
    feature)
        _np_kind="it pushes the feature or hotfix branch $_np_cur"
        if [ "${KYKLOS_CI_MONITOR:-0}" = "1" ]; then
            _np_fix="KYKLOS_CI_MONITOR=1 is already set: push only the current branch, by name or as HEAD, without force."
        else
            _np_fix="KYKLOS_CI_MONITOR=1 would allow it: a project session then pushes its own current feature/* or hotfix/* branch, without force, and watches the pipeline the push starts."
        fi ;;
    detached)
        _np_kind="no branch is checked out (a detached HEAD), so it is not a push of a feature or hotfix branch"
        _np_fix="No setting lets a project session push it: check out a feature/* or hotfix/* branch and push that." ;;
    *)
        _np_kind="it pushes the branch $_np_cur, which is not a feature/* or hotfix/* branch"
        _np_fix="No setting lets a project session push it: move the work to a feature/* or hotfix/* branch and push that." ;;
esac
reason="Push refused: $_np_kind. Read for this push: topology $_np_topo, KYKLOS_CI_MONITOR=${KYKLOS_CI_MONITOR:-not set}, KYKLOS_ALLOW_PUSH=${KYKLOS_ALLOW_PUSH:-not set}. What would allow it: $_np_fix The rules: the PUSH POLICY section of the managed policy. For a single authorized exception: bash $OVERRIDE_MARKER_CLI set $OK_NAME $OK_SCOPE_HINT"
reason="${reason//\\/\\\\}"; reason="${reason//\"/\\\"}"; reason="$(printf '%s' "$reason" | tr '\n' ' ')"
printf '{"decision":"block","reason":"%s"}' "$reason"
exit 0
