#!/usr/bin/env bash
# kyklos-merge-green-guard.sh (Kyklos) — PreToolUse Bash. Blocks `git merge <feature/*|hotfix/*>` into a
# trunk (main|master|develop) UNLESS the merged branch's latest pipeline is `success`.
#
# The documented closed loop is "push feature -> pipeline GREEN -> merge into trunk". The push guard makes a
# push observable, and the story-proof guard refuses to CLOSE on anything but green — but nothing intercepts
# the `git merge` itself, so an agent can merge a feature into trunk (and delete the branch) BEFORE any
# pipeline ran: the irreversible act beats the gate. This guard closes that hole — the merge is the point of
# no return, so it is where the green must be proven.
#
# FAIL-OPEN by design: KYKLOS_MERGE_GREEN=0 (opted down), any KYKLOS_CI_* unset, an unresolvable branch/repo,
# or any curl/jq/API failure => do NOT block. That inertness is deliberate: an infra/trunk repo that merges LOCALLY
# (no CI vars configured) is never blocked, and a trunk-companion's own bookkeeping commits are not merges of
# feature/hotfix into trunk so they never reach this guard at all. Only the CI-loop source is gated.
#
# One-shot LOGGED override (consumed on the block path only, mirroring push-ok/gitflow-ok):
#   bash hooks/lib/override-marker.sh set merge-ok <repo-dir>
# It counts only when KYKLOS_HARDEN_OVERRIDE is explicitly off (on by default: only a user-applied
# 'merge-override' label on the story issue authorizes). Every block message names the override that is honoured.
#
# The pipeline and merge-request lookups pass the merged repository's origin address; the bridge reads the project
# that repository belongs to (a companion's nested source, not the default stories project). A repository without an
# origin, or one of a project the bridge does not serve, is refused by name: never "no pipeline" in the wrong project.
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

# Make the gate mechanically AWARE of the pipeline's ai-review job (surface its verdict + route to the fix loop
# when it is the cause of a red pipeline). Optional: if the lib is unavailable the gate behaves exactly as before.
_MG_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ai-review-verdict.sh
. "$_MG_HERE/lib/ai-review-verdict.sh" 2>/dev/null || true
. "$_MG_HERE/lib/git-cmd-detect.sh"   # git_cmd_invokes: command-position git-subcommand detection (shared)

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
_cfg="$PROJECT_DIR/.claude/standards.env"
# PARSE, never source (CWE-829): a malformed line can't execute (would mis-resolve CI-monitor + spam the TUI).
. "$(dirname "${BASH_SOURCE[0]}")/lib/standards-env.sh"; load_standards_env "$_cfg"
STATE_DIR="${KYKLOS_STATE_DIR:-/tmp/kyklos-state}"; mkdir -p "$STATE_DIR" 2>/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/override-marker.sh"   # override_take: the scoped, expiring one-shot override
OK_NAME=merge-ok
OK_SCOPE_HINT="<repo-dir>"
INPUT="$(cat || true)"
CMD="${INPUT//\\\"/\"}"
# The ACTUAL shell command (jq-extracted) — feed THIS to the command-position detector, NOT the JSON envelope.
CMD_REAL="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"; [ -n "$CMD_REAL" ] || CMD_REAL="$CMD"
# The shell's ACTUAL working directory for the command, from the hook input (.cwd). A bare `git merge`
# (no -C/cd) runs HERE, which is NOT necessarily PROJECT_DIR (CLAUDE_PROJECT_DIR may be unset/inner).
HOOK_CWD="$(printf '%s' "$INPUT" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"

# Resolve the repo a git command targets — delegates to the SHARED git_target_repo_dir (lib/git-cmd-detect.sh,
# sourced above) with op=merge, so the green check judges the repo the MERGE lands in (esp. a companion's nested
# source reached via `cd Repo && git merge`) from one source of truth.
target_repo_dir() { git_target_repo_dir "$1" "$HOOK_CWD" "$PROJECT_DIR" merge; }

# Only act on a `git merge` at a command position (a `git merge` MENTION in a string is not a merge). Shared detector.
git_cmd_invokes "$CMD_REAL" merge || exit 0

# FAIL-OPEN gate 1: enforcement is gated by KYKLOS_MERGE_GREEN, DEFAULT ON. It is
# DELIBERATELY NOT gated on KYKLOS_CI_MONITOR: that knob ALSO opens the no-push feature/hotfix push allowance
# (kyklos-no-push-guard), so gating merge-green on it would have coupled "enforce green merges" to "let projects
# push" — defaulting it on everywhere would have weakened 'projects never push'. So the enforcement (this guard +
# close-on-green) rides its OWN flag, and CI_MONITOR stays the push-context knob (default off). Enforcement still
# needs the CI vars (gate 2) to have a pipeline to check, so a container with no CI configured fails open anyway.
# Opt down per repo with KYKLOS_MERGE_GREEN=0.
# shellcheck source=lib/control-switch.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/control-switch.sh" 2>/dev/null || true   # kyklos_control_off: the one control-switch reader
kyklos_control_off "${KYKLOS_MERGE_GREEN:-}" && exit 0
# Transport: the bridge-first CI seam (the bridge Control Tower CI verbs). PREFERS the ci_pipelines_list verb (no container
# token); falls back to a direct token ONLY under the launcher's direct-token exception (KYKLOS_CI_DIRECT_TOKEN=1).
. "$(dirname "${BASH_SOURCE[0]}")/lib/ci-access.sh"   # ci_access_*: the token never leaves its helpers
# FAIL-OPEN gate 2: this container has NO CI verification mechanism (no bridge endpoint AND no declared direct-token
# exception) => it cannot be a closed-loop CI source, so it is never blocked (an infra/trunk repo that merges locally).
ci_access_configured || exit 0
command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || { echo "[kyklos] WARNING: merge-green guard INERT — curl/jq missing; the merge-only-on-green-pipeline gate is OFF. Install curl+jq." >&2; exit 0; }

_tgt="$(target_repo_dir "$CMD_REAL")"

# The TARGET of `git merge <src>` is the currently checked-out branch of the target repo. Gate ONLY when that
# target is a trunk (main|master|develop); merging into anything else is not a closed-loop trunk merge.
_dest="$(git -C "$_tgt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
case "$_dest" in main|master|develop) : ;; *) exit 0 ;; esac

# Extract the SOURCE branch = the first non-flag, non-option-value merge argument. Strip a leading `origin/`
# so a `git merge origin/feature/x` resolves to the branch `feature/x`. Flags (-X, --no-ff, ...) and the
# value of `-m <msg>`/`-X <strategy>` are skipped. Fail-open (allow) if we cannot isolate a source branch.
_src=""
# shellcheck disable=SC2086
_read_merge_source() {
    local seen_merge=0 skipnext=0 a
    # The COMMAND (CMD_REAL, never the JSON envelope: there the last argument carries the envelope's trailing "} or ","description" text) is intentionally word-split into tokens; disable pathname globbing so a `*` in a branch/arg (or an IFS
    # oddity) can't expand against the cwd and mis-read the merge source.
    set -f
    for a in $CMD_REAL; do
        if [ "$skipnext" = 1 ]; then skipnext=0; continue; fi
        if [ "$seen_merge" = 0 ]; then
            [ "$a" = "merge" ] && seen_merge=1
            continue
        fi
        case "$a" in
            -m|-X|-s|-S|--strategy|--strategy-option|--gpg-sign) skipnext=1; continue ;;
            -*) continue ;;                       # any flag (--no-ff, --ff-only, -q, ...)
            "&&"|"||"|";"|"|") break ;;           # command boundary — stop before the next command's args
        esac
        _src="$a"; break
    done
    set +f
}
_read_merge_source
_src="${_src%\"}"; _src="${_src#\"}"; _src="${_src%\'}"; _src="${_src#\'}"
_src="${_src#origin/}"
case "$_src" in
    feature/*|hotfix/*) : ;;                       # a closed-loop branch — gate it
    *) exit 0 ;;                                   # FAIL-OPEN: not a feature/hotfix source (e.g. `git merge develop`)
esac

# The project the branch lives in. In a companion workspace the stories live in one CI project and the nested source,
# with its pipelines and merge requests, in another; asking without a project reads the bridge's DEFAULT (the stories)
# project and finds no pipeline for any source branch. So every lookup below passes the merged repository's own origin
# address, and the bridge chooses the configured project it belongs to (or refuses by name one it does not serve).
_repo_addr="$(ci_access_repository_address "$_tgt")" || _repo_addr=""
if [ "$(ci_access_mode)" = bridge ]; then
    _where="the CI project of repository '${_repo_addr}' (chosen by the KyklosBridge from that origin)"
else
    _where="CI project '${KYKLOS_CI_PROJECT_ID:-}' (the declared direct-token exception)"
fi

# Hands off: a branch that closes through its merge request is never merged into a trunk by hand. GitLab merges an
# armed request itself once its pipeline succeeds; a merged one has nothing left to merge. This is judged BEFORE the
# green check: a green pipeline is exactly when an agent is tempted to merge by hand. A state that cannot be read
# leaves the decision to the green check below (never a false "already merged").
. "$_MG_HERE/lib/mr-hands-off.sh"
_mr_row="$(mr_row_for_branch "$_src" "$_repo_addr")"
if [ -n "$_mr_row" ]; then
    IFS=$'\t' read -r _mst _marm _mn _mtgt <<< "$_mr_row"
    if _why="$(mr_hand_merge_explain "$_mst" "$_marm" "$_mn" "$_mtgt")"; then
        jq -nc --arg r "$_why Merging '$_src' into '$_dest' locally would also leave the local trunk diverged from GitLab." '{decision:"block",reason:$r}'
        exit 0
    fi
    case "$_src" in hotfix/*) _cmode="${HOTFIX_BRANCH_CLOSE_MODE:-}" ;; *) _cmode="${FEATURE_BRANCH_CLOSE_MODE:-}" ;; esac
    if [ "$_mst" = opened ]; then
        case "$_cmode" in
            mr|mr-automerge)
                jq -nc --arg r "Local merge REFUSED: branch '$_src' closes through merge request !$_mn (close mode $_cmode), which is open but NOT armed. Arm it instead of merging into '$_dest' by hand: push the branch again with -o merge_request.merge_when_pipeline_succeeds (with a new commit), or arm it with the bridge tool mr_auto_merge (action arm) on merge request $_mn. GitLab then merges it once its pipeline succeeds; then delete the local branch, pull the trunk and close the story." '{decision:"block",reason:$r}'
                exit 0 ;;
        esac
    fi
fi

# One-shot LOGGED override — consumed on the block path only, so a benign non-blocking merge cannot silently
# eat it. Spend it just before the query so it always covers a real block.
# Query the SOURCE branch's latest pipeline through the bridge-first seam (same semantics as close-on-green).
# [RiskMitigation RA-02] the read token (direct fallback only) is referenced by env-var NAME only, the call is
# time-bounded, and a scope refusal never silently reaches for a token.
# [no-fail-open -> fail-CLOSED] The container HAS a CI verification mechanism (gated above) but the pipeline could
# not be READ (bridge DOWN with no declared exception, a scope refusal, or an API error). Do NOT allow an
# UNVERIFIED merge into trunk — BLOCK (with the one-shot override). "cannot verify" is NEVER green.
_verify_fail=""
_body=""
# [no-fail-open -> fail-CLOSED] (FM1) Through the bridge, a repository without a readable origin cannot name its project:
# refuse by name, never ask the default project instead.
if [ "$(ci_access_mode)" = bridge ] && [ -z "$_repo_addr" ]; then
    _verify_fail="the repository '$_tgt' has no readable origin address, so the CI project that holds branch '$_src''s pipeline cannot be chosen (the bridge picks it from the origin; the default project is never assumed). Add the origin remote (git -C '$_tgt' remote add origin <address>) and merge again"
    _pl_rc=3
else
    _errf="$(mktemp 2>/dev/null || printf '%s' "$STATE_DIR/merge-green.err")"
    if _body="$(ci_access_pipelines "$_src" "" 1 "$_repo_addr" 2>"$_errf")"; then _pl_rc=0; else _pl_rc=$?; fi
    _refusal="$(head -c 600 "$_errf" 2>/dev/null | tr '\n' ' ')"; rm -f "$_errf"
fi
if [ "$_pl_rc" -ne 0 ] && [ -z "$_verify_fail" ]; then
    _verify_fail="$(ci_access_failure_reason "$_pl_rc")"
    if [ -z "$_verify_fail" ] && [ -n "${_refusal// /}" ]; then
        # (FM2, FM3, UC6) The bridge answered with a reason: a project it does not serve, or one its token cannot read.
        # That is a configuration or access problem, not a missing pipeline, and it says what to change.
        _verify_fail="the pipeline lookup in ${_where} was refused: ${_refusal% }. This is a configuration or access problem, not a missing pipeline"
    fi
    [ -n "$_verify_fail" ] || _verify_fail="the CI verdict could not be read from ${_where} (the KyklosBridge is down and no direct-token exception is declared, the call was refused as out-of-scope, or the CI API was unreachable)"
fi
if [ -z "$_verify_fail" ]; then
    _st="$(printf '%s' "$_body" | jq -r '.pipelines[0].status // "none"' 2>/dev/null || echo parse_error)"
    [ "$_st" = "parse_error" ] && _verify_fail="the CI pipeline response was unparseable"
else
    _st="none"
fi
# ALLOW only on a VERIFIED green.
{ [ -z "$_verify_fail" ] && [ "$_st" = "success" ]; } && exit 0

# Block (unverifiable, OR a real non-success status). Un-self-grantable override FIRST: a USER-applied
# `merge-override` label on the merged branch's story issue (an agent cannot author a label as another user).
. "$(dirname "${BASH_SOURCE[0]}")/lib/user-applied-label.sh" 2>/dev/null || true
if command -v override_user_applied >/dev/null 2>&1 && override_user_applied "$CMD_REAL" "merge-override"; then
    echo "[kyklos] merge-green gate: ALLOWED by a USER-applied 'merge-override' label on the story issue (un-self-grantable)." >&2; exit 0
fi
# Legacy one-shot self-touch override — honored only while the hardening is explicitly off; warns it is self-granted.
if kyklos_control_off "${KYKLOS_HARDEN_OVERRIDE:-}" && override_take "$OK_NAME" "$(override_scope_of "$_tgt")" "$INPUT"; then
    echo "[kyklos] merge-green gate: OVERRIDDEN once ($OK_NAME spent) — merge allowed via a SELF-GRANTED marker WITHOUT a verified green pipeline. DEPRECATED: remove the KYKLOS_HARDEN_OVERRIDE opt-out to require a user-applied 'merge-override' label instead." >&2; exit 0
fi

# (R5, FM5) The override the message names is the one that is honoured here, so the agent is never sent to a dead marker.
if kyklos_control_off "${KYKLOS_HARDEN_OVERRIDE:-}"; then
    _override_hint="For a single deliberate exception: the owner applies the 'merge-override' label to the story issue, or (hardening is off in this project) set the one-shot marker: bash $OVERRIDE_MARKER_CLI set $OK_NAME $OK_SCOPE_HINT"
else
    _override_hint="The only override honoured here is the 'merge-override' label, applied by the owner to the story issue (an agent cannot apply it for itself). The self-set '$OK_NAME' marker is NOT honoured while KYKLOS_HARDEN_OVERRIDE is on (the default): do not set it"
fi
if [ -n "$_verify_fail" ]; then
    reason="Merge BLOCKED — cannot verify branch '$_src' is green: ${_verify_fail}. An unverified merge must not reach trunk '$_dest'. Fix the cause above, or wait for CI (under an MR close mode the armed merge request merges itself: do not merge it locally). ${_override_hint}."
else
    _disp="$_st"; [ "$_st" = "none" ] && _disp="none: no pipeline was found for branch '$_src' in ${_where}"
    # ai-review AWARENESS: if this red pipeline carries an ai-review job that did not pass, name it as the likely cause.
    _air_note=""
    if command -v ai_review_verdict >/dev/null 2>&1; then
        _pipe_id="$(printf '%s' "$_body" | jq -r '.pipelines[0].id // empty' 2>/dev/null || true)"
        if [ -n "$_pipe_id" ] && _verd="$(ai_review_verdict "$_pipe_id" "$_repo_addr")"; then
            _air_note=" $(ai_review_note "${_verd%%$'\t'*}" "${_verd#*$'\t'}")"
        fi
    fi
    reason="Merge BLOCKED. Branch '$_src' is being merged into trunk '$_dest' but its latest pipeline is '$_disp', not success.${_air_note} A merge into the trunk needs a green pipeline first; merging first would make the irreversible act (merge + branch delete) beat the CI gate. How to close the branch in this project's close mode: the PUSH POLICY section of the managed policy. ${_override_hint}."
fi
reason="${reason//\\/\\\\}"; reason="${reason//\"/\\\"}"; reason="$(printf '%s' "$reason" | tr '\n' ' ')"
printf '{"decision":"block","reason":"%s"}' "$reason"
exit 0
