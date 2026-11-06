#!/usr/bin/env bash
# kyklos-mr-hands-off-guard.sh (Kyklos) - PreToolUse Bash. A story merge request merges ITSELF: it is armed ("merge
# when pipeline succeeds") in the same push that creates it, and nobody merges it by hand.
#
# Why: an agent that creates a merge request unarmed sees the pipeline go green, and nothing merges the request, so it
# merges by hand ("the pipeline succeeded, so I am merging it into develop"). An agent that does arm it can still try
# to merge by hand after green and race GitLab, which has already merged it or is about to.
#
# What it does:
#   1. Create must arm. `git push -o merge_request.create ...` for a feature/* or hotfix/* branch without
#      `-o merge_request.merge_when_pipeline_succeeds` (or merge_request.auto_merge) is refused, with the same command
#      armed as the one to run. The arm is still judged by the auto-merge guard (coverage + merged-result check): this
#      guard first asks it, in its non-spending probe mode, whether the armed command would be admitted. When the
#      auto-merge guard refuses the arm, the unarmed create is ALLOWED and the agent is told why the request stays
#      unarmed and how to arm it once that refusal is fixed.
#   2. `glab mr create` for such a branch is refused the same way (it cannot arm in the same step); so is a raw API
#      POST that creates a merge request from such a branch.
#   3. `glab mr merge` of a merge request that is already merged, closed, or armed is refused with the reason. (A GitLab
#      API merge is judged in the auto-merge guard, which already reads that merge request; a local `git merge` into a
#      trunk is judged in the merge-green guard.)
# A merge request whose state cannot be read is left to the other guards (no false "already merged").
# No CI: in a repository without a CI pipeline an armed request never merges itself, so 1. and 2. let the request be
# created unarmed (and say to merge it through the API once mergeable), 3. lets an armed open request be merged, and an
# armed create gets a note. The decision is lib/mr-hands-off.sh's (an unreadable answer counts as CI).
#
# Default ON. The only off switch: KYKLOS_MR_AUTOMERGE=off (a project whose merge requests a human merges); audited.
# Wired: PreToolUse, matcher Bash.
# [json-answer-required] Every answer this hook reads goes through the JSON reader; without it a check would exit 127
# and fall into a fail-open path, so the hook refuses by name instead (a broken install). [CySec] CWE-636
. "$(dirname "${BASH_SOURCE[0]}")/lib/json-answer.sh" 2>/dev/null
if ! command -v json_test >/dev/null 2>&1; then
    printf '{"decision":"block","reason":"BLOCKED (%s): the JSON reader hooks/lib/json-answer.sh did not load (broken install), so this check cannot run. Reinstall or repin the kyklos plugin."}\n' "$(basename "$0")"
    exit 0
fi
set +e -uo pipefail

_HO_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_HO_HERE/lib/git-cmd-detect.sh"   # git_cmd_invokes / cmd_word_invokes / git_target_repo_dir / cmd_strip / cmd_last_cd_dir
. "$_HO_HERE/lib/push-refspec.sh"     # push_refspec_dest: the branch a push sends
. "$_HO_HERE/lib/standards-env.sh"    # load_standards_env: parse, never source
# shellcheck source=lib/control-switch.sh
. "$_HO_HERE/lib/control-switch.sh" 2>/dev/null || true   # kyklos_control_off: the one control-switch reader
. "$_HO_HERE/lib/ci-access.sh"        # merge request reads, bridge first
. "$_HO_HERE/lib/mr-hands-off.sh"     # the create/arm options and the hand-merge explanation
. "$_HO_HERE/lib/escape-audit.sh" 2>/dev/null || true
. "$_HO_HERE/lib/gitlab-api-base.sh" 2>/dev/null || true
. "$_HO_HERE/lib/gitlab-curl.sh" 2>/dev/null || true

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
load_standards_env "$PROJECT_DIR/.claude/standards.env"
INPUT="$(cat || true)"
CMD_REAL="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
[ -n "$CMD_REAL" ] || CMD_REAL="${INPUT//\\\"/\"}"
# Shell comments are dropped before anything below reads the command (the one step shared with the auto-merge guard
# and the push parser): a trailing note can neither add the arm option nor turn the probed arm into a refusal.
# [CySec] [RiskMitigation RA-01] CWE-184: words the shell never runs do not change the verdict.
CMD_REAL="$(cmd_drop_comments "$CMD_REAL")"
# A backslash-newline splice inside a word is joined first, as bash joins it (lib/push-refspec.sh cmd_join_splices).
CMD_REAL="$(cmd_join_splices "$CMD_REAL")"
HOOK_CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"
[ -n "$HOOK_CWD" ] || HOOK_CWD="$PROJECT_DIR"

block() {
    jq -nc --arg r "$1" '{decision:"block",reason:$r}'
    exit 0
}
note() {
    jq -nc --arg c "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$c}}'
    exit 0
}
is_story_branch() { case "$1" in feature/*|hotfix/*) return 0 ;; *) return 1 ;; esac; }
enabled() {
    if kyklos_control_off "${KYKLOS_MR_AUTOMERGE:-}"; then
        command -v escape_audit >/dev/null 2>&1 && escape_audit "mr-automerge-off" "cmd=$(printf '%s' "$CMD_REAL" | head -c 200)" 2>/dev/null || true
        return 1
    fi
    return 0
}
_STRIPPED="$(cmd_strip "$CMD_REAL")"
readonly ARM_HINT="-o merge_request.merge_when_pipeline_succeeds"
readonly NO_CI_NEXT="This repository has no CI pipeline, so an armed merge request would never merge itself: create it unarmed and, once GitLab reports it mergeable, merge it through the API (PUT .../projects/<id>/merge_requests/<n>/merge, or the bridge tool mr_merge, which merges a request without a pipeline once GitLab confirms the project runs no CI). The merged-result rule applies (lib/merged-result.sh)."
# api_project_has_no_ci <project> <ref> -> rc 0 when GitLab says <project> runs no CI for <ref>.
api_project_has_no_ci() {
    mr_gitlab_access || return 1   # no way to ask GitLab: the project counts as having CI
    mr_project_has_no_ci "$MR_GITLAB_API" "$MR_GITLAB_TOKEN_NAME" "$1" "$2"
}

# ---- 1. git push that creates a merge request ---------------------------------------------------------------------
# story_push_target -> sets _dest (the branch the push sends) and _repo (the repository it pushes from).
# The pushes judged are those of the command AND of every heredoc body it feeds to a shell (`bash <<E`, `cat <<E | sh`).
_JUDGE="$CMD_REAL"
_fed="$(mr_heredocs_fed_to_calls "$CMD_REAL")"; [ -z "$_fed" ] || _JUDGE="$(printf '%s\n%s' "$CMD_REAL" "$_fed")"
story_push_target() {
    local d
    _dest="$(push_refspec_dest "$_JUDGE")"
    _repo="$(git_target_repo_dir "$CMD_REAL" "$HOOK_CWD" "$PROJECT_DIR" push)"
    if [ -z "$_dest" ] || [ "$_dest" = HEAD ] || [ "$_dest" = @ ]; then   # `origin HEAD` pushes the checked-out branch
        [ "$_repo" = "__UNDECIDABLE__" ] || _dest="$(git -C "$_repo" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    fi
    # A line may hold several pushes, and a push several refspecs (`git push origin main feature/x`, a push inside a
    # substitution): the story branch among all of them is the one judged.
    while IFS= read -r d; do
        is_story_branch "$d" && { _dest="$d"; break; }
    done < <(push_refspec_dests_all "$_JUDGE")
}
push_repo_has_no_ci() { [ "$_repo" != "__UNDECIDABLE__" ] && mr_repo_has_no_ci "$_repo" "$_dest"; }
# A create counts as ARMED only when the creating push itself carries the arm option, written out
# (mr_push_creates_armed): here "armed" lets the create through, so an option this hook cannot read (a variable, a
# substitution) or one only mentioned elsewhere on the line (a commit message, an echo) reads as "may be unarmed".
# [CySec] Fail closed for this guard's purpose (CWE-636).
# An ARMED create in a repository without CI is allowed, with a warning; otherwise the later sections still run.
# The push is found by the shared reader as well as by git_cmd_invokes, so a quoted or escaped spelling of `git` or
# `push` (`"git" push`, `git p\ush`) is the same push.
_pushes=0; { git_cmd_invokes "$CMD_REAL" push || mr_line_pushes "$CMD_REAL"; } && _pushes=1
# The line names the create option where the reader cannot read it (a command word that is not literally git, an
# alias, a push held in a variable): what it runs is unknown, so it is refused rather than let through unjudged.
# [CySec] [RiskMitigation RA-01] fail closed on a create the hook cannot read (CWE-636).
if { mr_option_unread "$CMD_REAL" "$MR_CREATE_NAME_RE" "$MR_CREATE_VALUE_RE" || mr_push_options_unread "$CMD_REAL"; } && enabled; then
    block "Merge request create REFUSED: this command names the merge request create option, but the guard cannot read the push that would send it (the command word is not git written out, an alias runs it, or the push is held in a variable), so it cannot check that the request is created armed. Run the push written out, armed in the same push: git push -o merge_request.create $ARM_HINT origin <branch>"
fi
# A push with an option the shared reader cannot read (a value the shell builds: an expansion, a substitution, a brace
# list or a glob; a GIT_CONFIG_* variable, -c include.path, --config-env) or a variable before the remote may create a
# merge request the guard cannot see; unless every push sends the arm, it is refused. [CySec] fail closed (CWE-636).
if [ "$_pushes" = 1 ] && enabled && ! mr_push_all_armed "$CMD_REAL"; then
    _unk="$(_mr_line_values "$CMD_REAL" | grep -E '^\?unknown ' | head -1)"
    # (a create with a computed positional is refused below, naming the destination it cannot read)
    [ -z "$_unk" ] && ! mr_push_creates "$CMD_REAL" && push_positionals "$CMD_REAL" | head -1 | grep -cE '[$`]|__QUOTED__' >/dev/null \
        && _unk="a computed word where the remote goes"
    [ -n "$_unk" ] && block "Push REFUSED: part of this push's options comes from a source the guard cannot read (${_unk#\?unknown }), so it cannot tell whether the push creates a merge request unarmed. Write the push options out on the command (git push -o ... origin <branch>), and arm a create in the same push with $ARM_HINT."
fi
if [ "$_pushes" = 1 ] && mr_push_creates "$CMD_REAL" && mr_push_creates_armed "$CMD_REAL"; then
    story_push_target
    if is_story_branch "$_dest" && push_repo_has_no_ci && enabled; then
        note "[kyklos] mr-hands-off: $NO_CI_NEXT This push ARMS the request, so it will wait for a pipeline that never runs."
    fi
fi
if [ "$_pushes" = 1 ] && mr_push_creates "$CMD_REAL" && ! mr_push_creates_armed "$CMD_REAL"; then
    story_push_target
    # A positional the shell expands (`git push -o merge_request.create $p origin feature/x`) hides which word is the
    # remote and which the branch: the destination is unknown, so the unarmed create is refused rather than judged by a
    # misread branch. [CySec] Fail closed on an unreadable destination (CWE-636).
    if push_positional_unknown_all "$_JUDGE" && enabled; then
        block "Merge request create REFUSED: this push creates a merge request UNARMED, and a word the shell expands (a variable or a substitution) stands where the remote or the branch goes, so the guard cannot tell which branch it creates the request for. Write the remote and the branch out, and arm the request in the same push: git push -o merge_request.create $ARM_HINT origin <branch>"
    fi
    # --all, --branches or --mirror send branches the text does not list: the destination is unknown as well.
    if push_sends_every_branch "$_JUDGE" && enabled; then
        block "Merge request create REFUSED: this push creates a merge request UNARMED and sends every branch (--all, --branches or --mirror), so the guard cannot tell which branch it creates the request for. Push the one branch, armed: git push -o merge_request.create $ARM_HINT origin <branch>"
    fi
    is_story_branch "$_dest" || exit 0
    enabled || exit 0
    push_repo_has_no_ci && note "[kyklos] mr-hands-off: the merge request for '$_dest' is created unarmed. $NO_CI_NEXT"
    _armed="$(mr_with_arm "$CMD_REAL")"
    # A create spelled with quotes or escapes inside the word gets no arm from mr_with_arm: suggest the plain form.
    [ "$_armed" != "$CMD_REAL" ] || _armed="git push -o merge_request.create $ARM_HINT origin $_dest"
    _guard="$_HO_HERE/kyklos-automerge-coverage-guard.sh"
    if [ -f "$_guard" ]; then
        _verdict="$(KYKLOS_AUTOMERGE_PROBE=1 bash "$_guard" 2>/dev/null \
            <<<"$(jq -nc --arg c "$_armed" --arg w "$HOOK_CWD" '{cwd:$w, tool_input:{command:$c}}')")"
        if printf '%s' "$_verdict" | grep -c '"decision":"block"' >/dev/null; then
            _why="$(printf '%s' "$_verdict" | jq -r '.reason // empty' 2>/dev/null)"
            # Only a refusal over the STATE of the change (coverage, merged result) lets the create through unarmed: a
            # refusal over the SHAPE of the command (several branches, a glob, no work tree) applies to the create too.
            # [CySec] fail closed: an unmarked refusal is a shape refusal (CWE-636).
            [ "$(printf '%s' "$_verdict" | jq -r '.refusal // empty' 2>/dev/null)" = state ] \
                || block "Merge request create REFUSED: this push creates the merge request for '$_dest' UNARMED, and the same push could not be armed as written: ${_why} Push the one story branch, armed, from its work tree: git push -o merge_request.create $ARM_HINT origin $_dest"
            note "[kyklos] mr-hands-off: this push creates the merge request for '$_dest' UNARMED, because arming it is refused right now: ${_why} The request will NOT merge itself. Fix that refusal, then arm it: push again with $ARM_HINT (with a new commit), or arm it with the bridge tool mr_auto_merge (action arm). Do not merge it by hand after green."
        fi
    fi
    block "Merge request create REFUSED: a story merge request must be armed to merge itself in the same push that creates it, so GitLab merges it once its pipeline succeeds and nobody merges it by hand. Run this instead: $_armed  (Then only watch the pipeline: if it fails, fix and push again with $ARM_HINT; once GitLab has merged it, delete the local branch and close the story.) A project whose merge requests a human merges opts out with KYKLOS_MR_AUTOMERGE=off in .claude/standards.env."
fi

# ---- 2. glab mr create / API create for a story branch ------------------------------------------------------------
# glab is found the way every guard finds a command (cmd_word_invokes): behind runner words, by path or escaped.
if cmd_word_invokes "$CMD_REAL" glab '[[:space:]]+mr[[:space:]]+(create|new)([[:space:]]|$)'; then
    _src="$(printf '%s' "$CMD_REAL" | grep -oE -- '(-s|--source-branch)[=[:space:]]+["'"'"']?[^[:space:]"'"'"']+' | head -1 | sed -E 's/^(-s|--source-branch)[=[:space:]]+["'"'"']?//')"
    if [ -z "$_src" ]; then
        _gcd="$(cmd_last_cd_dir "$(printf '%s' "$CMD_REAL" | sed -E 's/glab[[:space:]]+mr[[:space:]]+(create|new).*//')")"
        case "$_gcd" in '') _gcd="$HOOK_CWD" ;; /*) : ;; *) _gcd="$HOOK_CWD/$_gcd" ;; esac
        _src="$(git -C "$_gcd" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    fi
    _gcd2="$(cmd_last_cd_dir "$(printf '%s' "$CMD_REAL" | sed -E 's/glab[[:space:]]+mr[[:space:]]+(create|new).*//')")"
    case "$_gcd2" in '') _gcd2="$HOOK_CWD" ;; /*) : ;; *) _gcd2="$HOOK_CWD/$_gcd2" ;; esac
    if is_story_branch "$_src" && enabled && ! mr_repo_has_no_ci "$_gcd2" "$_src"; then
        block "Merge request create REFUSED: glab mr create cannot arm the request in the same step, so it would sit unarmed after a green pipeline. Create it armed with one push instead: git push -o merge_request.create -o merge_request.target=<trunk> $ARM_HINT origin $_src"
    fi
fi
# The same words inside a commit message, a note body or an echo are text about the merge endpoint, not a call to it:
# the shared matcher (lib/mr-hands-off.sh, also used by the auto-merge guard) lets a line through only when every
# command it runs can only print or record text. [CySec] Allow-list of text-only commands (CWE-184).
if ! mr_only_text_commands "$CMD_REAL" \
   && printf '%s' "$CMD_REAL" | grep -cE 'merge_requests([?"'"'"'[:space:]]|$)' >/dev/null \
   && printf '%s' "$CMD_REAL" | grep -cE '(-X|--request)[[:space:]=]*["'"'"']?POST|requests\.post|method[[:space:]]*=[[:space:]]*["'"'"']POST' >/dev/null; then
    _src="$(printf '%s' "$CMD_REAL" | grep -oE 'source_branch["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"']?[^[:space:]"'"'"'&,}]+' | head -1 | sed -E 's/.*[:=][[:space:]]*["'"'"']?//')"
    _cproj="$(printf '%s' "$CMD_REAL" | grep -oE 'projects/[^/[:space:]"'"'"'?]+/merge_requests' | head -1 | sed -E 's#^projects/##; s#/merge_requests$##')"
    if is_story_branch "$_src" && enabled && ! api_project_has_no_ci "$_cproj" "$_src"; then
        block "Merge request create REFUSED: an API call creates the request unarmed, so it would sit unarmed after a green pipeline. Create it armed with one push instead: git push -o merge_request.create -o merge_request.target=<trunk> $ARM_HINT origin $_src"
    fi
fi

# ---- 3. glab mr merge of a merge request that is merged, closed or armed ------------------------------------------
if cmd_word_invokes "$CMD_REAL" glab '[[:space:]]+mr[[:space:]]+merge([[:space:]]|$)' \
   && ! printf '%s' "$_STRIPPED" | grep -cE -- '[[:space:]](-R|--repo)([=[:space:]]|$)' >/dev/null; then   # another project: its number means nothing here
    _arg="$(printf '%s' "$_STRIPPED" | sed -nE 's/.*glab[[:space:]]+mr[[:space:]]+merge[[:space:]]*//p' | head -1 | tr ' ' '\n' \
        | sed -E 's/[;&|)].*//' | grep -vE '^(-|$)' | head -1)"
    _row=""
    # glab acts on the repository it runs in: its origin names the project the number or branch belongs to, so the
    # lookup reads that project (a companion's nested source), not the bridge's default one.
    _gcd="$(cmd_last_cd_dir "$(printf '%s' "$CMD_REAL" | sed -E 's/glab[[:space:]]+mr[[:space:]]+merge.*//')")"
    case "$_gcd" in '') _gcd="$HOOK_CWD" ;; /*) : ;; *) _gcd="$HOOK_CWD/$_gcd" ;; esac
    _repo_addr="$(ci_access_repository_address "$_gcd")" || _repo_addr=""
    # [no-fail-open] Through the bridge, a repository without a readable origin names no project: the request's state
    # cannot be read where it lives, so the hand merge is refused by name rather than judged in the default project.
    if [ -z "$_repo_addr" ] && [ "$(ci_access_mode)" = bridge ] && ! ci_access_direct_usable && enabled; then
        block "Hand merge REFUSED: the repository '$_gcd' has no readable origin address, so the merge request's state cannot be read in its project (the bridge picks the project from the origin; the default project is never assumed). Add the origin remote (git -C '$_gcd' remote add origin <address>), or let GitLab merge the armed request."
    fi
    case "$_arg" in
        '!'*|[0-9]*) _row="$(mr_row_for_number "${_arg#!}" "$_repo_addr")" ;;
        ?*) _row="$(mr_row_for_branch "$_arg" "$_repo_addr")" ;;
        *) _row="$(mr_row_for_branch "$(git -C "$_gcd" rev-parse --abbrev-ref HEAD 2>/dev/null)" "$_repo_addr")" ;;
    esac
    if [ -n "$_row" ]; then
        IFS=$'\t' read -r _st _armed_now _n _tgt <<< "$_row"
        if [ "$_st" = opened ] && [ "$_armed_now" = true ]; then
            _mcd="$(cmd_last_cd_dir "$(printf '%s' "$CMD_REAL" | sed -E 's/glab[[:space:]]+mr[[:space:]]+merge.*//')")"
            case "$_mcd" in '') _mcd="$HOOK_CWD" ;; /*) : ;; *) _mcd="$HOOK_CWD/$_mcd" ;; esac
            mr_repo_has_no_ci "$_mcd" && exit 0   # no pipeline will ever fire the arm: the merge is the agent's to do
        fi
        _why="$(mr_hand_merge_explain "$_st" "$_armed_now" "$_n" "$_tgt")" && block "$_why"
    fi
fi
exit 0
