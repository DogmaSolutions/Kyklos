#!/usr/bin/env bash
# kyklos-automerge-coverage-guard.sh (Kyklos) — PreToolUse Bash. Refuses ARMING AUTO-MERGE on a change that touches
# production C# unless the content ledger shows every changed C# line run by a passing test at the armed commit
# (ledger_answers_story, the answer the story close reads), or a fresh Test Discipline coverage token covers those files.
#
# Why: arming auto-merge lets a change merge itself as soon as CI is green, so it is the last point where the agent
# still decides. An agent that pushes a refactor with auto-merge armed and lets CI "measure it" has skipped the local
# measure-before-push loop. This guard requires the same evidence the story close requires, at the moment the merge
# is delegated: the Test Discipline token the bridge's get_coverage emits over the changed, covered files.
#
# What counts as arming:
#   - git push with the push option merge_request.merge_when_pipeline_succeeds or merge_request.auto_merge (bare,
#     quoted or held in a variable; git started bare, escaped, by full path, by a variable or behind a runner prefix);
#   - a GitLab API call on a merge request that sets merge_when_pipeline_succeeds / auto_merge to true (any client);
#   - glab mr merge (it arms auto-merge by default) unless --auto-merge=false;
#   - any of the above written inside a local script file the command runs (bash|sh|python3 <file>, ./<file>);
#   - the bridge tool mr_auto_merge with action arm (the bridge itself applies the merged-result rule to a merge request
#     behind its target, so this guard adds the coverage check and the same-repository check).
# Plain pushes, and changes with no production C#, are never touched. Neither is text that only QUOTES an arm (a
# commit message, an echo or printf, a grep pattern, a heredoc written to a file, a script that is staged but not run):
# lib/mr-hands-off.sh decides text versus call for this guard and the hands-off guard alike.
#
# Change set: the working tree vs HEAD plus the WHOLE branch since it forked from its trunk
# (proof_tool_changed_files -- the window the coverage emitter and the proof gate use), existing *.cs files that are
# not test code. A repository that contains C# but whose trunk base cannot be resolved (no origin/develop|main|master,
# a shallow clone that does not reach the fork point, or a wrong KYKLOS_CHANGE_BASE_REF) is REFUSED: the change set
# cannot be known, so arming cannot be judged. The token must be bound to the branch's story, verify
# (every recorded file unchanged) and record every one of those files.
#
# Default ON. The only off switch: KYKLOS_AUTOMERGE_COVERAGE=off (parsed by kyklos_control_off; audited).
# The ledger path is default ON too; KYKLOS_AUTOMERGE_LEDGER=off leaves only the token path.
# One-shot override of the COVERAGE verdict only (never of the merged-result check): a marker set in a separate
# command, bound to one repository and to the agent that sets it, spent by the first arm it admits, expiring
# (override-marker.sh), audited:
#   bash hooks/lib/override-marker.sh set automerge-coverage-ok <repo-dir>
# It exists for the cases no token can settle: a change to the token builder itself, measured by the previous build,
# or a change for which no proportionate token exists yet (the full shard set is the only measurement).
# Wired: PreToolUse, matcher Bash, and matcher mcp__KyklosBridge__mr_auto_merge.
# [json-answer-required] Every answer this hook reads goes through the JSON reader; without it a check would exit 127
# and fall into a fail-open path, so the hook refuses by name instead (a broken install). [CySec] CWE-636
. "$(dirname "${BASH_SOURCE[0]}")/lib/json-answer.sh" 2>/dev/null
if ! command -v json_test >/dev/null 2>&1; then
    printf '{"decision":"block","reason":"BLOCKED (%s): the JSON reader hooks/lib/json-answer.sh did not load (broken install), so this check cannot run. Reinstall or repin the kyklos plugin."}\n' "$(basename "$0")"
    exit 0
fi
set +e -uo pipefail

_AC_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_AC_HERE/lib/git-cmd-detect.sh"   # git_cmd_invokes / git_target_repo_dir / cmd_strip
. "$_AC_HERE/lib/proof-tool-gate.sh"  # proof_tool_verify / proof_tool_recorded_files / story derivation; also
                                      # sources the shared control-switch reader (kyklos_control_off)
. "$_AC_HERE/lib/escape-audit.sh" 2>/dev/null || true   # escape_audit: durable trail of an opt-out
. "$_AC_HERE/lib/override-marker.sh"   # override_take: the scoped, expiring one-shot override
. "$_AC_HERE/lib/override-cause.sh"    # override_cause_named: the bridge's Named Cause answer
. "$_AC_HERE/lib/json-answer.sh"   # json_test: an empty or cut answer is never a readable one
. "$_AC_HERE/lib/mr-hands-off.sh"     # the text-or-call matcher (mr_push_arms, mr_only_text_commands) + mr_hand_merge_explain, shared with the hands-off guard
. "$_AC_HERE/lib/merged-result.sh"    # merged_result_git_verdict: the one rule for a branch behind its target
. "$_AC_HERE/lib/push-refspec.sh"     # push_positionals / push_refspec_src: the commit a push actually sends

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
INPUT="$(cat || true)"
TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)"
CMD_REAL="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
[ -n "$CMD_REAL" ] || [ "$TOOL_NAME" = "mcp__KyklosBridge__mr_auto_merge" ] || CMD_REAL="${INPUT//\\\"/\"}"
# Shell comments are dropped before anything below reads the command (the one step shared with the hands-off guard and
# the push parser): a trailing note is neither an arm, an option nor an extra refspec for the merged-result check.
# [CySec] [RiskMitigation RA-01] CWE-184: words the shell never runs do not change the verdict.
CMD_REAL="$(cmd_drop_comments "$CMD_REAL")"
# A backslash-newline splice inside a word is joined first, as bash joins it (lib/push-refspec.sh cmd_join_splices).
CMD_REAL="$(cmd_join_splices "$CMD_REAL")"
HOOK_CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"
[ -n "$HOOK_CWD" ] || HOOK_CWD="$PROJECT_DIR"

readonly DIM="Test Discipline"
# Probe mode (KYKLOS_AUTOMERGE_PROBE=1): the hands-off guard asks "would this arm be admitted?" before it refuses an
# unarmed merge request create. A probe judges exactly like a real arm but never spends a one-shot override and never
# writes the opt-out audit line (the real arm that follows does both), so it can never admit more than the real guard.
_AC_PROBE=0; [ "${KYKLOS_AUTOMERGE_PROBE:-0}" = 1 ] && _AC_PROBE=1
readonly API_TRUE_RE='(merge_when_pipeline_succeeds|auto_merge)["'"'"']?[[:space:]]*[:=,][[:space:]]*["'"'"']?(true|True|TRUE|1)([^0-9A-Za-z_]|$)'

# ---- 1. Is this command arming auto-merge? ------------------------------------------------------------------
# arming_mode TEXT -> print push|api|apimerge|glab when TEXT arms auto-merge (or merges through the API), else nothing.
# ONE test, applied both to the command itself and to the body of any local script it runs, so the two can never drift
# apart. Which words are a call and which are only text is decided by the matcher shared with the hands-off guard
# (lib/mr-hands-off.sh): the arm option, the merge endpoint or `glab mr merge` quoted in a commit message, an echo, a
# grep pattern or a heredoc written to a file is text; the same words in any command that may run (whatever its
# prefix, path, escape or variable name) are a call.
# [CySec] Allow-list of text-only commands; everything else is judged as a call (CWE-184).
# [RiskMitigation RA-01] A command substitution inside double quotes ("$(...)", "`...`") or in an unquoted heredoc body
# is run by the shell, so the push-option and merge-command checks read it as a call too: the shared strip
# (lib/cmd-strip.sh) appends those substitutions as command text before the segments are judged.
arming_mode() {
    local t="$1" seg api_call=1
    mr_only_text_commands "$t" && api_call=0
    if mr_push_arms "$t"; then
        echo push
    elif [ "$api_call" = 1 ] && printf '%s' "$t" | grep -c 'merge_requests' >/dev/null && printf '%s' "$t" | grep -cE "$API_TRUE_RE" >/dev/null; then
        echo api
    elif [ "$api_call" = 1 ] && printf '%s' "$t" | grep -cE 'merge_requests/[^/[:space:]"'"'"']+/merge([?"'"'"'[:space:]]|$)' >/dev/null \
         && printf '%s' "$t" | grep -cE '(-X|--request)[[:space:]]*["'"'"']?PUT|--method[=[:space:]]*["'"'"']?PUT|method[[:space:]]*=[[:space:]]*["'"'"']PUT|requests\.put|"PUT"' >/dev/null; then
        echo apimerge   # a merge through the API without auto-merge: judged by the merged-result check only
    else
        while IFS= read -r seg; do
            mr_segment_may_run "$seg" || continue
            # glab by any name: bare, escaped, a full path, after a runner prefix, or a variable/substitution as the command
            printf '%s' "$seg" | grep -cE '(^|[[:space:]/\\])glab[[:space:]]+mr[[:space:]]+merge([[:space:]]|$)|^[[:space:]]*(\$[^[:space:]]*[[:space:]]+)?mr[[:space:]]+merge([[:space:]]|$)' >/dev/null || continue
            printf '%s' "$seg" | grep -cE -- '--auto-merge=false' >/dev/null && continue
            echo glab; return 0
        done < <(mr_command_segments "$t"; mr_heredocs_fed_to_calls "$t")
    fi
}
_mode="$(arming_mode "$CMD_REAL")"
_arm_text="$CMD_REAL"
# Arming through the bridge: the tool call names the merge request and, optionally, its project.
if [ "$TOOL_NAME" = "mcp__KyklosBridge__mr_auto_merge" ]; then
    [ "$(printf '%s' "$INPUT" | jq -r '.tool_input.action // empty' 2>/dev/null)" = "arm" ] || exit 0
    _mode=bridge
    _bridge_proj="$(printf '%s' "$INPUT" | jq -r '.tool_input.project // empty' 2>/dev/null || true)"
fi
# Arming written inside a local script the command runs (bash|sh|python3 <file>, ./<file>): apply the same test.
if [ -z "$_mode" ] && [ -n "$CMD_REAL" ]; then
    set -f   # split the command into words WITHOUT glob expansion: `rm *.sh` must not read every script in the folder
    # A line of text-only commands runs no script (`git add arm.sh`, `cat arm.sh`); any other line may run every script it
    # names, also through a pipe (`cat arm.sh | bash`), so all of its words are read.
    _scan_words=""; mr_only_text_commands "$CMD_REAL" || _scan_words="$(mr_command_segments "$CMD_REAL")"
    for _tok in $_scan_words; do
        case "$_tok" in *.sh|*.bash|*.py|./*) : ;; *) continue ;; esac
        _sf="$_tok"; [ "${_sf#/}" != "$_sf" ] || _sf="$HOOK_CWD/$_sf"
        [ -f "$_sf" ] || continue
        _sbody="$(cmd_drop_comments "$(head -c 262144 "$_sf" 2>/dev/null)")"   # a script's comments are not run either
        _mode="$(arming_mode "$_sbody")"
        [ -n "$_mode" ] && { _arm_text="$_sbody"; break; }
    done
    set +f
fi
[ -n "$_mode" ] || exit 0

block() {
    local reason="$1"
    reason="${reason//\\/\\\\}"; reason="${reason//\"/\\\"}"; reason="$(printf '%s' "$reason" | tr '\n' ' ')"
    if [ -n "${_AC_REFUSAL:-}" ]; then printf '{"decision":"block","reason":"%s","refusal":"%s"}' "$reason" "$_AC_REFUSAL"
    else printf '{"decision":"block","reason":"%s"}' "$reason"; fi
    exit 0
}
# block_state MESSAGE -> a refusal over the STATE of the change (its coverage, its merged result, the target or GitLab
# not readable right now), marked "refusal":"state". The mr-hands-off probe lets an unarmed create through with a note
# only for such a refusal; every other refusal is over the SHAPE of the command (several branches, a glob, no work
# tree), which the create shares, so there the create is refused too. [CySec] Fail closed: an unmarked refusal is a
# shape refusal (CWE-636).
block_state() { _AC_REFUSAL=state; block "$1"; }

# [CySec] [RiskMitigation RA-01] [RiskMitigation RA-02] Bounds the only per-arm way past the coverage verdict (CWE-863):
# one arm, one repository, expiring, audited; it never lifts the merged-result check (RA-03).
readonly OK_NAME=automerge-coverage-ok
# refuse_coverage REPO STORY MESSAGE -> the coverage verdict for REPO is a refusal: spend a one-shot override set for
# exactly that repository (audited, admits this one arm), else block with MESSAGE and the override's name.
refuse_coverage() {
    local repo="$1" story="$2" msg="$3"
    [ "$_AC_PROBE" = 1 ] && block_state "$msg"
    # Named Cause: the one-shot override is spent only on a story that names the cause of its gap (an open item that
    # removes it, or the owner's accepted figure); the bridge decides it, and without its answer the marker stays unspent.
    if ls "$(override_state_dir)/$OK_NAME".* >/dev/null 2>&1 \
       && ! override_cause_named "${STORY_GITLAB_PROJECT:-}" "$story" "$OK_NAME"; then
        block_state "$msg The one-shot $OK_NAME override is set but was NOT spent: $OVERRIDE_CAUSE_WHY."
    fi
    if override_take "$OK_NAME" "$(override_scope_of "$repo")" "$INPUT"; then
        command -v escape_audit >/dev/null 2>&1 && escape_audit "$OK_NAME" "mode=$_mode story=$story repo=$repo arm=$(printf '%s' "$_arm_text" | grep -oE 'merge_requests/[0-9]+' | head -1)" 2>/dev/null || true
        echo "[kyklos] auto-merge coverage guard: OVERRIDDEN once ($OK_NAME spent) for story ${story:-?} in $repo: this arm passes WITHOUT a covering Test Discipline token. Refusal it replaced: $msg" >&2
        return 0
    fi
    block "$msg One-shot override, only when the user decides so and no token can settle it: a change to the token builder itself, or a change for which no proportionate token exists yet (the full shard set is the only measurement), where the user's one-shot approval is the path. It is spent by one arm and audited: bash $OVERRIDE_MARKER_CLI set $OK_NAME <repo-dir>, in a separate command."
}
# defer_refusal REPO STORY MESSAGE -> note a coverage refusal; the verdict is given once every repository is judged, so a
# marker is never spent on an arm that another repository refuses anyway.
_ref_repo=(); _ref_story=(); _ref_msg=()
defer_refusal() { _ref_repo+=("$1"); _ref_story+=("$2"); _ref_msg+=("$3"); }

# ---- 1b. Merged-result check (owner-approved blocking rule, independent of the coverage opt-out) ----------------
# GitLab CE has no merged-results pipelines: a merge request pipeline tests the branch head, not the merge into the
# current target. Two branches green on their own can make a red trunk. So an arm (or an API merge) is refused unless
# the branch already contains the target's current head (the commit CI tested is then what lands), OR the target's new
# commits change none of the files the branch changes and no build-wide file changed on either side
# (lib/merged-result.sh; for an API arm or merge the bridge's mr_get answers that comparison). Unknown is refused.
# [CySec] Integrity of the shared trunk (CWE-841, improper enforcement of a behavioural workflow).
if [ "$_mode" = "api" ] || [ "$_mode" = "apimerge" ]; then
    _mr_projs="$(printf '%s' "$_arm_text" | grep -oE 'projects/[^/[:space:]"'"'"'?]+/merge_requests/[0-9]+' | sort -u)"
    [ "$(printf '%s' "$_mr_projs" | grep -c .)" -eq 1 ] || block "Merge BLOCKED: the call must name exactly one merge request as .../projects/<id or url-encoded path>/merge_requests/<n>/..., so the guard can check that the branch contains the target's current head."
    _mr_proj="$(printf '%s' "$_mr_projs" | sed -E 's#^projects/##; s#/merge_requests/.*##')"
    _mr_iid="${_mr_projs##*/}"
    . "$_AC_HERE/lib/gitlab-api-base.sh" 2>/dev/null || true
    . "$_AC_HERE/lib/gitlab-curl.sh" 2>/dev/null || true
    . "$_AC_HERE/lib/coordination-read.sh" 2>/dev/null || true
    _api="$(gitlab_api_base STORY_GITLAB_API 2>/dev/null || true)"
    _tok=""; command -v gitlab_pick_token >/dev/null 2>&1 && gitlab_pick_token _tok "${KYKLOS_STORY_TOKEN_ENV:-}" "${STORY_GITLAB_TOKEN_ENV:-}" "${KYKLOS_ISSUES_TOKEN_ENV:-}" GITLAB_TOKEN KYKLOS_ISSUES_TOKEN || true
    # The bridge answers first (mr_get, with its own token); the container token is the transition path only.
    _mr_json=""; _mrrc=4
    if command -v coordination_read >/dev/null 2>&1; then
        _mr_text="$(coordination_read mr_get "$(jq -cn --arg p "$(printf '%s' "$_mr_proj" | sed 's/%2[Ff]/\//g')" --arg n "$_mr_iid" '{project:$p, merge_request:$n}')" 2>/dev/null)"; _mrrc=$?
        # The project goes as the API address names it (a numeric id or a path); the bridge resolves either to the
        # configured project it is, and refuses one it does not serve. The request's state, arm and the project's CI
        # state travel along, so the hand-merge and no-CI rules below judge the bridge's answer as they judge GitLab's.
        [ "$_mrrc" -eq 0 ] && _mr_json="$(printf '%s' "$_mr_text" | jq -c '{diverged_commits_count: .behind_target, target_branch: .target_branch, merged_result_ok: .merged_result_ok, overlap_files: .overlap_files, merged_result_refusal: .merged_result_refusal, state: .state, auto_merge: .auto_merge, merge_request: .merge_request, sha: .sha, project_ci: .project_ci}' 2>/dev/null || true)"
        [ "$_mrrc" -eq 3 ] && block_state "Merge BLOCKED: the bridge could not read merge request !$_mr_iid, so the guard cannot check that it contains its target's current head. It never lets a merge through unchecked; retry once the bridge answers."
    fi
    if [ "$_mrrc" -ne 0 ]; then
        [ -n "$_api" ] && [ -n "$_tok" ] || block_state "Merge BLOCKED: the guard cannot reach GitLab (the bridge has no mr_get, and no API address or token is configured), so it cannot check that merge request !$_mr_iid contains its target's current head. It never lets a merge through unchecked."
        command -v coordination_read_fallback >/dev/null 2>&1 && coordination_read_fallback automerge-guard "the bridge has no mr_get verb"
        _mr_json="$(gitlab_curl "$_tok" -s --max-time 12 "$_api/projects/$_mr_proj/merge_requests/$_mr_iid?include_diverged_commits_count=true" 2>/dev/null || true)"
    fi
    _behind="$(printf '%s' "$_mr_json" | jq -r '.diverged_commits_count // empty' 2>/dev/null || true)"
    _target="$(printf '%s' "$_mr_json" | jq -r '.target_branch // "its target"' 2>/dev/null || echo 'its target')"
    # A hand merge (or an arm) of a merge request GitLab already merged, closed, or (for a hand merge) will merge on its
    # own is refused with the reason, before any other check: there is nothing for the agent to merge.
    _mr_row="$(mr_row_of "$_mr_json")"
    if [ -n "$_mr_row" ]; then
        IFS=$'\t' read -r _mr_state _mr_armed _ _mr_tgt <<< "$_mr_row"
        # No CI: an armed request of a project without a pipeline never merges itself, so its API merge is the agent's
        # to do (the merged-result check below still applies). The bridge's project_ci answers first ("none" only when
        # GitLab confirmed it); without one (an older bridge, the token read) the guard asks GitLab with its token.
        # [CySec] Fail closed (CWE-636): "configured", "unknown" or an unreadable answer keeps the request's CI rule.
        _no_ci_merge=0
        if [ "$_mode" = apimerge ] && [ "$_mr_state" = opened ] && [ "$_mr_armed" = true ]; then
            _mr_pci="$(printf '%s' "$_mr_json" | jq -r '.project_ci // empty | tostring' 2>/dev/null)"
            if [ "$_mr_pci" = none ]; then
                _no_ci_merge=1
            elif [ -z "$_mr_pci" ]; then
                _mr_ref="$(printf '%s' "$_mr_json" | jq -r '.sha // .source_branch // empty' 2>/dev/null)"
                mr_project_has_no_ci "$_api" "$_tok" "$_mr_proj" "$_mr_ref" && _no_ci_merge=1
            fi
        fi
        if { [ "$_mr_state" != opened ] || [ "$_mode" = apimerge ]; } && [ "$_no_ci_merge" = 0 ]; then
            _why="$(mr_hand_merge_explain "$_mr_state" "$_mr_armed" "$_mr_iid" "$_mr_tgt")" && block_state "$_why"
        fi
    fi
    [[ "$_behind" =~ ^[0-9]+$ ]] || block_state "Merge BLOCKED: GitLab did not say whether merge request !$_mr_iid contains the current head of $_target, so the merge stays refused. Retry once GitLab answers."
    if [ "$_behind" -gt 0 ]; then
        # [RiskMitigation RA-03] Behind: admitted only on the bridge's file comparison saying exactly true (an older bridge, or the direct token
        # read, carries none, so the branch must contain the target's head as before).
        if [ "$(printf '%s' "$_mr_json" | jq -r '.merged_result_ok == true' 2>/dev/null)" != true ]; then
            _ovl="$(printf '%s' "$_mr_json" | jq -r '(.overlap_files // []) | if type == "array" then map(tostring) | join(", ") else "" end' 2>/dev/null)"
            _mrw="$(printf '%s' "$_mr_json" | jq -r '.merged_result_refusal // empty | tostring' 2>/dev/null)"
            if [ -n "$_ovl" ]; then _why=" The target's new commits change files this branch also changes, or a build-wide file: ${_ovl}."
            elif [ -n "$_mrw" ]; then _why=" ${_mrw}"
            else _why=" Whether the target's new commits touch the branch's files was not answered (the bridge's mr_get gives that comparison), so it is not assumed."
            fi
            block_state "Merge BLOCKED: merge request !$_mr_iid is $_behind commit(s) behind $_target. Its pipeline tested the branch without them, so the result that would land was never tested.${_why} Merge $_target into the branch (git fetch origin && git merge origin/$_target), push, wait for the new pipeline, then arm again."
        fi
    fi
elif [ "$_mode" = "bridge" ]; then
    :   # mr_auto_merge applies the merged-result rule (lib/merged-result.sh's twin) in the bridge itself
else
    if [ "$_mode" = "push" ]; then _mrr="$(git_target_repo_dir "$CMD_REAL" "$HOOK_CWD" "$PROJECT_DIR" push)"
    else
        # glab: judge the repository the command runs in, following a `cd` before the call (as the API path does).
        # Cut the text at the glab command itself (not at the first "glab" anywhere: a folder may be named so).
        _gpre="$(printf '%s' "$_arm_text" | sed -E 's/(^|[;&|({[:space:]\/\\])glab[[:space:]]+mr[[:space:]]+merge([[:space:]].*)?$/\1/')"
        _gcd="$(cmd_last_cd_dir "$_gpre")"
        case "$_gcd" in *'$('*|*'`'*|*'${'*) block "Merge BLOCKED: the folder this glab merge runs in is computed by the shell (a substitution feeds the cd), so the guard cannot check that the branch contains its target's current head. Run it from the branch's work tree." ;; esac
        if [ -n "$_gcd" ]; then case "$_gcd" in /*) : ;; *) _gcd="$HOOK_CWD/$_gcd" ;; esac; else _gcd="$HOOK_CWD"; fi
        _mrr="$(git -C "$_gcd" rev-parse --show-toplevel 2>/dev/null || true)"
        # glab merges the merge request of the checked-out branch unless told otherwise. A named merge request (an id
        # or another branch) or another repository (-R/--repo) is not what this work tree holds, so it cannot be judged.
        _gargs="$(printf '%s' "$_arm_text" | sed -nE 's/.*(^|[;&|({[:space:]\/\\])glab[[:space:]]+mr[[:space:]]+merge([[:space:]]+|$)//p' | head -1 \
            | sed -E 's/[;&|].*//' | awk '{ for (i = 1; i <= NF; i++) {
                if ($i ~ /^(-R|--repo)(=|$)/) { print "--repo"; exit }
                if ($i ~ /^(-m|--message|--squash-message|--sha)$/) { i++; continue }
                if ($i ~ /^-/) continue
                print $i; exit } }')"
        if [ -n "$_gargs" ] && [ -n "$_mrr" ]; then
            _gcur="$(git -C "$_mrr" rev-parse --abbrev-ref HEAD 2>/dev/null)"
            [ "$_gargs" = "$_gcur" ] || block "Merge BLOCKED: this glab merge names '$_gargs', not the merge request of the branch checked out in '$_mrr', so the guard cannot check what it would land. Run 'glab mr merge' with no merge request named, from the branch's work tree."
        fi
    fi
    [ -n "$_mrr" ] || block "Merge BLOCKED: this merge does not run inside a git work tree, so the guard cannot check that the branch contains its target's current head. Run it from the branch's work tree."
    [ "$_mrr" = "__UNDECIDABLE__" ] && block "Merge BLOCKED: the repository of this push cannot be determined (a command substitution feeds it), so the guard cannot check that the branch contains its target's current head."
    # The commit judged is the one the push sends: the source of its refspec, not the checked-out HEAD (a push of
    # another branch arms that branch). More than one refspec, or a source that does not resolve, cannot be judged.
    _mrhead=HEAD; _mrbr=""
    if [ "$_mode" = "push" ]; then
        [ "$(push_positionals "$CMD_REAL" | grep -c .)" -le 2 ] || block "Merge BLOCKED: this push names more than one refspec, so the guard cannot tell which branch it arms. Push the one branch to arm on its own."
        push_options "$CMD_REAL" | grep -cxE -e '--all|--branches|--mirror' >/dev/null \
            && block "Merge BLOCKED: this push sends every branch (--all, --branches or --mirror), so the guard cannot tell which branch it arms. Push the one branch to arm on its own (git push ... origin <branch>)."
        _psrc="$(push_refspec_src "$CMD_REAL")"
        # Without a refspec, git's configuration decides what is pushed (remote.<name>.push, push.default=matching,
        # or the same set for one command with -c or GIT_CONFIG_*): the checked-out HEAD is then not known to be it.
        if [ -z "$_psrc" ]; then
            if printf '%s' "$CMD_REAL" | grep -ciE 'push\.default|\.push[[:space:]]*=|GIT_CONFIG' >/dev/null \
               || [ -n "$(git -C "$_mrr" config --get-regexp '^remote\..*\.push$' 2>/dev/null)" ] \
               || [ "$(git -C "$_mrr" config --get push.default 2>/dev/null)" = matching ]; then
                block "Merge BLOCKED: this push names no branch and git's configuration (a push refspec or push.default) decides what it sends, so the guard cannot tell which branch it arms. Name the branch: git push ... origin <branch>."
            fi
        fi
        if [ -n "$_psrc" ]; then
            _mrhead="$(git -C "$_mrr" rev-parse --verify -q "$_psrc^{commit}" 2>/dev/null)" \
                || block "Merge BLOCKED: the branch this push sends ('$_psrc') does not resolve to a commit in '$_mrr', so the guard cannot check that it contains its target's current head."
        fi
        _mrbr="$(push_refspec_dest "$CMD_REAL")"; [ "$_mrbr" = HEAD ] && _mrbr=""
    fi
    [ -n "$_mrbr" ] || _mrbr="$(git -C "$_mrr" symbolic-ref -q --short HEAD 2>/dev/null || true)"

    # Which trunk the merge request lands on. A push-option arm or a glab merge does not carry it, and guessing it from
    # the nearest history is wrong whenever two trunks tie (after a release develop holds all of main, so a hotfix
    # forked from main ties): the change would be judged against a trunk it never lands on. The known target decides
    # (the push's merge_request.target option, the branch's open merge request), then GitFlow naming; when it still
    # cannot be told apart, the branch must contain the head of every candidate (lib/merged-result.sh).
    . "$_AC_HERE/lib/gitlab-api-base.sh" 2>/dev/null || true
    . "$_AC_HERE/lib/gitlab-curl.sh" 2>/dev/null || true
    . "$_AC_HERE/lib/coordination-read.sh" 2>/dev/null || true
    _api="$(gitlab_api_base STORY_GITLAB_API 2>/dev/null || true)"
    _tok=""; command -v gitlab_pick_token >/dev/null 2>&1 && gitlab_pick_token _tok "${KYKLOS_STORY_TOKEN_ENV:-}" "${STORY_GITLAB_TOKEN_ENV:-}" "${KYKLOS_ISSUES_TOKEN_ENV:-}" GITLAB_TOKEN KYKLOS_ISSUES_TOKEN || true
    _oproj="$(git -C "$_mrr" remote get-url origin 2>/dev/null | sed -E 's#^[a-z]+://[^/]+/##; s#^[^@]+@[^:]+:##; s#\.git$##; s#/#%2F#g')"
    _known=""; _amb=0; _creating=0; _def=""
    if [ "$_mode" = "push" ]; then
        # The target option as git sends it: only the push's OWN options count (push_option_values), so an option-like
        # word of another command in the line (`echo -o merge_request.target=x; git push ...`) never names the target.
        # A value the shell computes, a target mentioned anywhere else in the line, or one set in the repository's
        # push.pushOption configuration makes the target unknown, and an unknown target is judged by the strict rule.
        # [CySec] Mitigates CWE-693: the merged-result check cannot be steered to a trunk the request does not land on.
        _topts="$(push_option_values "$CMD_REAL" | grep -E '^merge_request\.target=' || true)"
        _known="$(printf '%s\n' "$_topts" | sed -nE 's/^merge_request\.target=//p')"
        printf '%s\n' "$_known" | grep -cE '[$`"'"'"'\\]' >/dev/null && _amb=1
        [ "$(printf '%s' "$CMD_REAL" | grep -oE 'merge_request\.target=' | grep -c .)" -gt "$(printf '%s' "$_topts" | grep -c .)" ] && _amb=1
        git -C "$_mrr" config --get-all push.pushOption 2>/dev/null | grep -cE 'merge_request\.target=' >/dev/null && _amb=1
        # An option the shell may rewrite (a quote, a variable, a backtick or a backslash in it), or a merge_request option
        # name this guard does not know, could still be the target once the shell expands it: the target is unknown.
        push_option_values "$CMD_REAL" | grep -cE '[$`"'"'"'\\]' >/dev/null && _amb=1
        # An option source the shared reader cannot show (a GIT_CONFIG_* variable, -c include.path, an alias,
        # --config-env) may set another target: the named one does not decide alone.
        push_options_unknown "$CMD_REAL" >/dev/null && _amb=1
        push_option_values "$CMD_REAL" | grep -E '^merge_request\.' \
            | grep -cvE '^merge_request\.(create|target|merge_when_pipeline_succeeds|auto_merge|remove_source_branch|title|description|label|unlabel|assign|unassign|draft|milestone|squash)(=|$)' >/dev/null && _amb=1
        # Only one push per command may arm or create a request: a second push in the same line would not be judged.
        # (Not in the mr-hands-off probe: there a refusal would let the create through unarmed with a note, while
        # mr-hands-off itself refuses an unarmed create of a story branch.)
        [ "${KYKLOS_AUTOMERGE_PROBE:-}" != 1 ] && [ "$(mr_command_segments "$CMD_REAL" | grep -cE '(^|[[:space:]/(`])git([[:space:]]+-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?)*[[:space:]]+push([[:space:]]|$)')" -gt 1 ] \
            && block "Merge BLOCKED: this command holds more than one git push and one of them arms or creates a merge request, so the guard could not judge each of them. Run the push that arms (or creates) the merge request as a command of its own."
        mr_push_creates "$CMD_REAL" && _creating=1
    fi
    # The target of the branch's open merge request: the bridge first, the container token as the transition path.
    _mrread=0
    if [ -n "$_mrbr" ] && [ -n "$_oproj" ]; then
        _mrl=""; _mrlrc=4
        if command -v coordination_read >/dev/null 2>&1; then
            _mrl="$(coordination_read mr_list "$(jq -cn --arg p "$(printf '%s' "$_oproj" | sed 's/%2[Ff]/\//g')" --arg b "$_mrbr" '{project:$p, source_branch:$b, state:"opened"}')" 2>/dev/null)"; _mrlrc=$?
            [ "$_mrlrc" -eq 0 ] && _mrl="$(printf '%s' "$_mrl" | jq -c '.merge_requests | select(type == "array")' 2>/dev/null || true)"
        fi
        if [ "$_mrlrc" -eq 4 ] && [ -n "$_api" ] && [ -n "$_tok" ]; then
            _mrl="$(gitlab_curl "$_tok" -s --max-time 12 "$_api/projects/$_oproj/merge_requests?state=opened&per_page=20&source_branch=$(jq -rn --arg b "$_mrbr" '$b|@uri')" 2>/dev/null \
                | jq -c 'select(type == "array")' 2>/dev/null || true)"
        fi
        # Read only when an answer came back and it is a list (json_test refuses an empty or cut answer). Without the
        # reader nothing here can be judged, so the arm is refused by name. [CySec] CWE-636
        command -v json_test >/dev/null 2>&1 \
            || block "Merge BLOCKED: the JSON reader hooks/lib/json-answer.sh did not load (broken install), so the merge request's target cannot be read. Reinstall or repin the plugin, then arm again."
        printf '%s' "$_mrl" | json_test 'type == "array"' && _mrread=1
        _known="$(printf '%s\n%s\n' "$_known" "$(printf '%s' "$_mrl" | jq -r '.[]? | .target_branch // empty' 2>/dev/null)")"
        if [ "$_creating" = 1 ] && [ -n "$_api" ] && [ -n "$_tok" ]; then
            _def="$(gitlab_curl "$_tok" -s --max-time 12 "$_api/projects/$_oproj" 2>/dev/null | jq -r '.default_branch // empty' 2>/dev/null || true)"
        fi
    fi
    if [ "$_creating" = 1 ] && [ -z "$_def" ]; then
        _def="$(git -C "$_mrr" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)"; _def="${_def#origin/}"
    fi
    # The open merge request's target could not be read and the push neither creates the request nor names the target:
    # the branch name must not decide (the request may land elsewhere), so the strict rule judges it.
    if [ "$_mrread" = 0 ] && [ "$_creating" = 0 ] && [ -z "$(printf '%s' "$_known" | tr -d '[:space:]')" ]; then _amb=1; fi
    _choice="$(merged_result_target_choice "$_mrr" "$_mrbr" "$_known" "$_amb" "$_creating" "$_def")"
    if [ -z "$_choice" ]; then
        [ "$(git -C "$_mrr" rev-parse --is-shallow-repository 2>/dev/null)" = "true" ] \
            && block_state "Merge BLOCKED: '$_mrr' is a shallow clone whose history does not reach the point where this branch forked from its target, so the guard cannot check that the branch contains the target's current head. Run 'git fetch --unshallow' (or deepen the fetch), then arm again."
        block_state "Merge BLOCKED: the target this branch forked from cannot be resolved in '$_mrr' (no origin/develop, origin/main or origin/master, or KYKLOS_CHANGE_BASE_REF='${KYKLOS_CHANGE_BASE_REF:-}' does not exist), so the guard cannot check that the branch contains the target's current head. Fetch it ('git fetch origin'), or set KYKLOS_CHANGE_BASE_REF to the branch's target (e.g. origin/develop), then arm again."
    fi
    # _target_head <ref> -> sets _tsha, _rsha and _where for the target <ref>. The local trunk ref may be stale (last
    # fetched before the target moved); when GitLab can be asked, its answer about the branch's real head decides.
    _target_head() {
        _tref="$1"; _rsha=""; _tbr="${1#origin/}"
        if [ "$_tbr" != "$_tref" ] && [ -n "$_oproj" ] && [ -n "$_api" ] && [ -n "$_tok" ]; then
            _rsha="$(gitlab_curl "$_tok" -s --max-time 12 "$_api/projects/$_oproj/repository/branches/$(jq -rn --arg b "$_tbr" '$b|@uri')" 2>/dev/null | jq -r '.commit.id // empty' 2>/dev/null || true)"
        fi
        if [[ "$_rsha" =~ ^[0-9a-f]{40}$ ]]; then
            _tsha="$_rsha"; _where="$_tbr on GitLab (${_rsha:0:8}); the local $_tref may be stale"
        else
            _rsha=""; _tsha="$(git -C "$_mrr" rev-parse --verify -q "$_tref^{commit}" 2>/dev/null || true)"; _where="$_tref (as last fetched)"
        fi
    }
    if [ "$(printf '%s\n' "$_choice" | head -1)" = strict ]; then
        # The target cannot be told apart: no file comparison, the branch must contain the head of every candidate.
        _cands="$(printf '%s\n' "$_choice" | sed '1d' | paste -sd, - | sed 's/,/, /g')"
        while IFS= read -r _c; do
            [ -n "$_c" ] || continue
            _target_head "$_c"
            if [ -z "$_tsha" ] || ! git -C "$_mrr" merge-base --is-ancestor "$_tsha" "$_mrhead" 2>/dev/null; then
                block_state "Merge BLOCKED: the target of this merge request cannot be told apart among $_cands (no merge_request.target option, no open merge request read, no GitFlow branch name that decides it), so the branch must contain the current head of each, and it does not contain $_where. Name the target in the push (git push -o merge_request.target=<branch> ...), or merge that target in first (git fetch origin && git merge $_tref), push, then arm again."
            fi
        done <<< "$(printf '%s\n' "$_choice" | sed '1d')"
    else
        _target_head "$(printf '%s\n' "$_choice" | sed -n 2p)"
        [ -n "$_tsha" ] || _tsha="$_tref"
        # [RiskMitigation RA-03] Every push-option and glab arm is judged by the one shared rule.
        _mrv="$(merged_result_git_verdict "$_mrr" "$_tsha" "$_mrhead")"
        _mrrc=$?
        # A branch admitted only because its files are disjoint from the target's new commits must be judged against the
        # target's real head: when GitLab could not be asked, the local ref may be stale and newer target commits unseen.
        if [ "$_mrrc" -eq 0 ] && ! [[ "$_rsha" =~ ^[0-9a-f]{40}$ ]] && ! git -C "$_mrr" merge-base --is-ancestor "$_tsha" "$_mrhead" 2>/dev/null; then
            _mrrc=2; _mrv="the current head of the target could not be read from GitLab, and the local $_tref may be stale"
        fi
        case $_mrrc in
            0) : ;;
            1) block_state "Merge BLOCKED: this branch does not contain the current head of $_where, and the target's new commits change files this branch also changes, or a build-wide file: $(printf '%s' "$_mrv" | paste -sd, - | sed 's/,/, /g'). Its pipeline would test a branch without those commits. Merge it in first (git fetch origin && git merge $_tref), push, then arm again." ;;
            *) block_state "Merge BLOCKED: this branch does not contain the current head of $_where, and whether the target's new commits touch the branch's files cannot be checked: $_mrv. Its pipeline would test a branch without those commits. Merge it in first (git fetch origin && git merge $_tref), push, then arm again." ;;
        esac
    fi
fi
[ "$_mode" = "apimerge" ] && exit 0   # a plain API merge is judged by the merged-result check only

# ---- 2. Opt-out (explicit, greppable, audited) -----------------------------------------------------------------
if kyklos_control_off "${KYKLOS_AUTOMERGE_COVERAGE:-}"; then
    [ "$_AC_PROBE" = 1 ] && exit 0
    command -v escape_audit >/dev/null 2>&1 && escape_audit "automerge-coverage-off" "mode=$_mode" 2>/dev/null || true
    echo "[kyklos] auto-merge coverage guard: OFF (KYKLOS_AUTOMERGE_COVERAGE=off) — arming allowed without a Test Discipline token." >&2
    exit 0
fi

# ---- 3. Which repositories does the change live in? ------------------------------------------------------------
_repos=()
if [ "$_mode" = "push" ]; then
    _t="$(git_target_repo_dir "$CMD_REAL" "$HOOK_CWD" "$PROJECT_DIR" push)"
    _repos+=("$_t")
else
    _t="$(git -C "$HOOK_CWD" rev-parse --show-toplevel 2>/dev/null || true)"
    [ -n "$_t" ] || _t="$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
    [ -n "$_t" ] && _repos+=("$_t")
    # Companion workspace: the C# lives in the nested source repo, while the API call runs from the companion root.
    for _base in "$HOOK_CWD" "$PROJECT_DIR"; do
        [ -n "$_base" ] && git -C "$_base/Repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 && _repos+=("$(git -C "$_base/Repo" rev-parse --show-toplevel)")
    done
    # An API call names the merge request's project in its URL. Judge only a repository that IS that project: a
    # command run from another repository must not borrow that repository's (clean, C#-free) change set.
    # [CySec] Closes the wrong-repository bypass of the coverage gate (CWE-863, incorrect authorization).
    if [ "$_mode" = "bridge" ] && [ -n "${_bridge_proj:-}" ]; then
        # The tool call names its project: judge only a repository that IS that project (same rule as the API path).
        _match=()
        for _r in "${_repos[@]}"; do
            _decl="$(sed -n 's/^[[:space:]]*STORY_GITLAB_PROJECT=//p' "$_r/.claude/standards.env" 2>/dev/null | tail -1 | tr -d '"'"'"' \r')"
            _orig="$(git -C "$_r" remote get-url origin 2>/dev/null | sed -E 's#^[a-z]+://[^/]+/##; s#^[^@]+@[^:]+:##; s#\.git$##')"
            if [ -n "$_decl" ] && [ "$_decl" = "$_bridge_proj" ]; then _match+=("$_r")
            elif [ -n "$_orig" ] && [ "$(printf '%s' "$_orig" | tr 'A-Z' 'a-z')" = "$(printf '%s' "$_bridge_proj" | tr 'A-Z' 'a-z')" ]; then _match+=("$_r")
            fi
        done
        [ "${#_match[@]}" -gt 0 ] || block "Auto-merge arming BLOCKED: mr_auto_merge arms a merge request of project '$_bridge_proj', but the session works in a repository that is not that project, so the guard would check the wrong change set. Arm it from a session working in that project's work tree."
        _repos=("${_match[@]}")
    fi
    if [ "$_mode" = "api" ]; then
        # The call may run from another folder than the shell started in: `cd <tree> && curl ...` or
        # `git -C <tree> ...` before it. Add that folder's repository to the candidates.
        _pre="${_arm_text%%merge_requests*}"
        _cd="$(cmd_last_cd_dir "$_pre")"
        case "$_cd" in *'$('*|*'`'*|*'${'*) _cd="" ;; esac
        if [ -n "$_cd" ]; then
            case "$_cd" in /*) : ;; *) _cd="$HOOK_CWD/$_cd" ;; esac
            _t="$(git -C "$_cd" rev-parse --show-toplevel 2>/dev/null || true)"
            [ -n "$_t" ] && _repos+=("$_t")
        fi
        # Every project the command names. More than one is refused: a read of a clean project's merge request
        # beside the arm of another project's would otherwise be judged against the clean one.
        _url_projs="$(printf '%s' "$_arm_text" | grep -oE 'projects/[^/[:space:]"'"'"'?]+/merge_requests' | sed -E 's#^projects/##; s#/merge_requests$##; s/%2[Ff]/\//g' | sort -u)"
        [ "$(printf '%s' "$_url_projs" | grep -c .)" -le 1 ] || block "Auto-merge arming BLOCKED: this command names merge requests of more than one project ($(printf '%s' "$_url_projs" | tr '\n' ' ')), so the guard cannot tell which repository's C# change the arm concerns. Arm one merge request per command, run from that branch's work tree."
        _url_proj="$_url_projs"
        [ -n "$_url_proj" ] || block "Auto-merge arming BLOCKED: the merge request's project cannot be read from the API call, so the guard cannot tell which repository's C# change it must check. Write the call with an explicit .../projects/<id or url-encoded path>/merge_requests/<n>/merge URL."
        # The URL may name the project by numeric id or by path; a repository declares one or the other. Know both:
        # the merge request answer (already read above) carries the id, and GitLab maps an id to its path.
        # [RiskMitigation RA-04] Match by exact id or by the full path GitLab itself reports, never a partial name (CWE-639).
        _proj_id=""; _proj_path=""
        case "$_url_proj" in
            *[!0-9]*) _proj_path="$_url_proj" ;;
            *) _proj_id="$_url_proj" ;;
        esac
        [ -n "$_proj_id" ] || _proj_id="$(printf '%s' "${_mr_json:-}" | jq -r '.project_id // empty' 2>/dev/null || true)"
        if [ -z "$_proj_path" ] && [ -n "$_proj_id" ] && [ -n "${_api:-}" ] && [ -n "${_tok:-}" ]; then
            _proj_path="$(gitlab_curl "$_tok" -s --max-time 12 "$_api/projects/$_proj_id" 2>/dev/null | jq -r '.path_with_namespace // empty' 2>/dev/null || true)"
        fi
        _lc() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }
        _match=()
        for _r in "${_repos[@]}"; do
            _decl="$(sed -n 's/^[[:space:]]*STORY_GITLAB_PROJECT=//p' "$_r/.claude/standards.env" 2>/dev/null | tail -1 | tr -d '"'"'"' \r')"
            _orig="$(git -C "$_r" remote get-url origin 2>/dev/null | sed -E 's#^[a-z]+://[^/]+/##; s#^[^@]+@[^:]+:##; s#\.git$##')"
            if [ -n "$_decl" ] && { [ "$_decl" = "$_proj_id" ] || { [ -n "$_proj_path" ] && [ "$(_lc "$_decl")" = "$(_lc "$_proj_path")" ]; }; }; then _match+=("$_r")
            elif [ -n "$_orig" ] && [ -n "$_proj_path" ] && [ "$(_lc "$_orig")" = "$(_lc "$_proj_path")" ]; then _match+=("$_r")
            fi
        done
        [ "${#_match[@]}" -gt 0 ] || block "Auto-merge arming BLOCKED: this call arms a merge request of project '$_url_proj', but it runs from a repository that is not that project, so the guard would check the wrong change set. Run it from a work tree of the branch being merged (cd into it, or git -C), where the C# change can be checked against its Test Discipline token."
        _repos=("${_match[@]}")
    fi
fi
[ "${#_repos[@]}" -gt 0 ] || block "Auto-merge arming BLOCKED: this command arms auto-merge, but it does not run inside a git work tree, so the changed C# files cannot be checked against a Test Discipline coverage token. Run it from the repository whose branch is being merged. (Opt-out, if the user decides so: KYKLOS_AUTOMERGE_COVERAGE=off.)"

# is_test_code PATH -> rc 0 for test code: a path segment that IS test/tests or ends in Test/Tests after a
# separator or as a capitalised word (Foo.Tests, UnitTests, tests), or a *Test.cs / *Tests.cs file. Case matters, so
# a production folder or file that merely ends in lowercase "test" (Latest/, Contest.cs) is NOT exempted.
is_test_code() { printf '%s' "$1" | grep -cE '(^|/)([Tt]ests?|[^/]*[._-][Tt]ests?|[^/]*Tests?)(/|$)|(Tests?|[._-][Tt]ests?)\.cs$' >/dev/null; }

# ledger_answers_story REPO STORY -> rc 0 when the bridge's content ledger (test_facts) says every changed executable C#
# line of STORY was run by a passing test, for exactly the commit REPO has checked out: the answer's "Story N at <sha>"
# head is a prefix of REPO's HEAD, and its C# summary reads "gap 0, expired 0". The same answer the story close reads,
# so a change the close would accept is never refused here for want of the old whole-suite token. Anything else (no
# bridge, an older bridge without test_facts, a refusal, another head, a GAP or an EXPIRED line, an unreadable answer)
# answers rc 1 and the token check below decides exactly as before. Default ON; the only off switch:
# KYKLOS_AUTOMERGE_LEDGER=off. LEDGER_REASON names why the ledger did not settle it, for the refusal text.
# [CySec] CWE-636: fails closed; the ledger can only admit, never weaken the existing token refusal.
LEDGER_REASON=""
ledger_answers_story() {
    local repo="$1" story="$2" reply text answered summary run exe gap exp rc dirty
    LEDGER_REASON=""
    if kyklos_control_off "${KYKLOS_AUTOMERGE_LEDGER:-}"; then LEDGER_REASON="the ledger check is off (KYKLOS_AUTOMERGE_LEDGER=off)"; return 1; fi
    # The ledger answers from committed content only, while the change set below includes the working tree: an
    # uncommitted C# edit is never covered by the ledger's answer, so it leaves the decision to the token check.
    git -C "$repo" status --porcelain --untracked-files=all >/dev/null 2>&1 || { LEDGER_REASON="the work tree's state cannot be read (git status failed)"; return 1; }
    dirty="$(git -C "$repo" status --porcelain --untracked-files=all -- '*.cs' '*.CS' 2>/dev/null | head -3 | tr '\n' ' ')"
    if [ -n "$dirty" ]; then LEDGER_REASON="the work tree holds uncommitted C# changes (${dirty% }), which the ledger cannot answer for: commit them"; return 1; fi
    if ! command -v bridge_mcp_call >/dev/null 2>&1; then
        [ -f "$_AC_HERE/lib/bridge-mcp.sh" ] && . "$_AC_HERE/lib/bridge-mcp.sh"
    fi
    command -v bridge_mcp_call >/dev/null 2>&1 || { LEDGER_REASON="the bridge client is missing"; return 1; }
    reply="$(bridge_mcp_call test_facts "$(jq -cn --arg s "$story" '{story:$s}')" 120)"; rc=$?
    [ "$rc" -eq 0 ] && [ -n "$reply" ] || { LEDGER_REASON="the bridge's ledger could not be asked"; return 1; }
    if bridge_mcp_is_error "$reply"; then LEDGER_REASON="the bridge refused test_facts"; return 1; fi
    text="$(bridge_mcp_text "$reply")"
    # The bridge writes "story N at <sha>"; a client may capitalise the first letter. Either spelling is read.
    answered="$(printf '%s\n' "$text" | sed -n "s/^[Ss]tory ${story} at \([0-9a-f]\{7,40\}\) .*/\1/p" | head -1)"
    [ -n "$answered" ] || { LEDGER_REASON="the ledger did not answer for story ${story} ($(printf '%s' "$text" | head -1 | cut -c1-160))"; return 1; }
    case "$(git -C "$repo" rev-parse HEAD 2>/dev/null)" in
        "$answered"*) : ;;
        *) LEDGER_REASON="the ledger answered for ${answered}, not for the commit checked out here"; return 1 ;;
    esac
    summary="$(printf '%s\n' "$text" | grep -E '^dotnet: run [0-9]+ of [0-9]+ ' | head -1)"
    [ -n "$summary" ] || { LEDGER_REASON="the ledger answer has no C# summary"; return 1; }
    run="$(printf '%s' "$summary" | sed -n 's/^dotnet: run \([0-9]*\) of \([0-9]*\) .*/\1/p')"
    exe="$(printf '%s' "$summary" | sed -n 's/^dotnet: run \([0-9]*\) of \([0-9]*\) .*/\2/p')"
    gap="$(printf '%s' "$summary" | sed -n 's/.*, gap \([0-9]*\),.*/\1/p')"
    exp="$(printf '%s' "$summary" | sed -n 's/.*, expired \([0-9]*\),.*/\1/p')"
    [ -n "$run" ] && [ -n "$exe" ] && [ -n "$gap" ] && [ -n "$exp" ] || { LEDGER_REASON="the ledger's C# summary could not be read ($summary)"; return 1; }
    if [ "$gap" -eq 0 ] && [ "$exp" -eq 0 ] && [ "$run" -eq "$exe" ]; then return 0; fi
    LEDGER_REASON="the ledger says ${run} of ${exe} changed C# lines run, ${gap} not run (GAP), ${exp} expired"
    return 1
}

# ---- 4. Judge each repository's change set ---------------------------------------------------------------------
_seen=""
for _r in "${_repos[@]}"; do
    case " $_seen " in *" $_r "*) continue ;; esac; _seen="$_seen $_r"
    git -C "$_r" rev-parse --is-inside-work-tree >/dev/null 2>&1 || block "Auto-merge arming BLOCKED: '$_r' is not a git work tree, so its changed C# files cannot be checked against a Test Discipline coverage token."
    # Fail closed when the branch's change set cannot be known, but only where it matters: a repository with C#.
    if git -C "$_r" ls-files -- '*.cs' '*.CS' 2>/dev/null | grep -c . >/dev/null && ! proof_tool_change_base "$_r" >/dev/null 2>&1; then
        if [ "$(git -C "$_r" rev-parse --is-shallow-repository 2>/dev/null)" = "true" ]; then
            block_state "Auto-merge arming BLOCKED: '$_r' is a shallow clone whose history does not reach the point where this branch forked from its trunk, so the branch's changed C# files cannot be determined. Run 'git fetch --unshallow' (or deepen the fetch), then arm auto-merge again."
        fi
        block_state "Auto-merge arming BLOCKED: the trunk this branch forked from cannot be resolved in '$_r' (no origin/develop, origin/main or origin/master, or KYKLOS_CHANGE_BASE_REF='${KYKLOS_CHANGE_BASE_REF:-}' does not exist), so the branch's changed C# files cannot be determined. Fetch the trunk ('git fetch origin'), or set KYKLOS_CHANGE_BASE_REF to the branch's target (e.g. origin/develop), then arm auto-merge again."
    fi
    _changed="$(proof_tool_changed_files "$_r" || true)"
    _prod=()
    while IFS= read -r _f; do
        [ -n "$_f" ] || continue
        # A name with a line break arrives in git's quoted form and cannot be opened: it is required (fail closed), not skipped.
        case "$_f" in \"*.cs\"|\"*.CS\") _prod+=("$_f"); continue ;; esac
        case "$_f" in *.cs|*.CS) : ;; *) continue ;; esac
        [ -f "$_r/$_f" ] || continue
        is_test_code "$_f" && continue
        _prod+=("$_f")
    done <<< "$_changed"
    [ "${#_prod[@]}" -gt 0 ] || continue

    _story="$(_proof_tool_detect_story "$_r")"
    _list="$(printf '%s, ' "${_prod[@]}")"; _list="${_list%, }"
    if [ -z "$_story" ]; then
        block_state "Auto-merge arming BLOCKED: this change touches C# (${_list}) but no story can be derived from the branch or the last commit in '$_r', so no Test Discipline coverage token can match it. Put the work on a feature/story-<N>-... branch (or add 'Refs: #<N>' to the commit), measure coverage locally with the bridge get_coverage (story=<N>), then arm auto-merge. A plain push without auto-merge is still allowed."
    fi
    # The content ledger first: the answer the story close reads. A change whose every changed C# line a passing test
    # ran, at exactly this commit, needs no whole-suite token.
    if ledger_answers_story "$_r" "$_story"; then continue; fi
    # The token's entries are read under the root the token names (proof_tool_token_root, the rule the Stop gate uses):
    # its .base sidecar, else this repository. Entries are then compared with this repository's changed files, so a root
    # that is a subfolder of the repository (a solution below its top) is mapped back; a root outside it matches nothing.
    _tr="$(proof_tool_token_root "$DIM" "$_story" "$_r")"
    if proof_tool_verify "$DIM" "$_tr" "$_story" && ! proof_tool_verify_sealed "$DIM" "$_tr" "$_story" arm; then
        defer_refusal "$_r" "$_story" "Auto-merge arming BLOCKED: the Test Discipline coverage token for story ${_story} has the right content, but ${PROOF_TOOL_SEAL_REASON}. A plain push without auto-merge is still allowed." && continue
    fi
    if ! proof_tool_verify "$DIM" "$_tr" "$_story"; then
        defer_refusal "$_r" "$_story" "Auto-merge arming BLOCKED: this change touches C# (${_list}) and neither the content ledger nor a token settles it for story ${_story}. Ledger: ${LEDGER_REASON}. The usual way: run the bridge get_coverage WITHOUT story and with a filter over the tests that run the changed lines (runs add up), until test_facts for story ${_story} shows no GAP at this commit; then arm again. The old way still works: a valid Test Discipline token from get_coverage with story=${_story} over the whole suite (missing here, or a recorded file changed since it was measured). A plain push without auto-merge is still allowed." && continue
    fi
    # Each recorded entry, resolved under the token's root (an absolute one as it is), is compared as a path relative to
    # this repository; an entry outside it matches none of this repository's files.
    _rc_top="$(_proof_tool_canon_path "$_r")"
    _recorded="$(proof_tool_recorded_files "$DIM" "$_tr" "$_story" | while IFS= read -r _e; do
        [ -n "$_e" ] || continue
        case "$_e" in /*|[A-Za-z]:/*) _a="$(_proof_tool_canon_path "$_e")" ;; *) _a="$(_proof_tool_join_rel "$_tr" "$_e")" ;; esac
        case "$_a" in "$_rc_top"/*) printf '%s\n' "${_a#"$_rc_top"/}" ;; esac
    done)"
    _missing=()
    for _f in "${_prod[@]}"; do
        printf '%s\n' "$_recorded" | grep -cxF -- "$_f" >/dev/null || _missing+=("$_f")
    done
    if [ "${#_missing[@]}" -gt 0 ]; then
        _ml="$(printf '%s, ' "${_missing[@]}")"; _ml="${_ml%, }"
        defer_refusal "$_r" "$_story" "Auto-merge arming BLOCKED: the Test Discipline coverage token for story ${_story} does not cover these changed C# files: ${_ml}. get_coverage records a changed file with no executable code (an interface, an enum) by itself, so each file listed here has code the measured run did not cover: add or extend a test that exercises it, re-run the bridge get_coverage (story=${_story}, with tree=<this repository> when it is not the bridge's solution root), then arm auto-merge. A plain push without auto-merge is still allowed." && continue
    fi
done
case "${#_ref_repo[@]}" in
    0) : ;;
    1) refuse_coverage "${_ref_repo[0]}" "${_ref_story[0]}" "${_ref_msg[0]}" ;;
    *) block_state "$(printf '%s ' "${_ref_msg[@]}")This arm is refused in ${#_ref_repo[@]} repositories (${_ref_repo[*]}); a one-shot override names one repository, so it is not used here: settle each with its coverage token." ;;
esac
exit 0
