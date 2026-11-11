#!/usr/bin/env bash
# story-mr-target.sh - a branch's merge request lands on the trunk its name says, never on the production trunk by
# habit. Source it; it defines functions only.
#
# With GitFlow's two trunks, the integration trunk (develop) integrates every feature/* branch (story branches are
# feature/story-<n>-<slug>) with the fast CI tier, and main receives only promotions (release/<version>, which ran the
# full tier) and real hotfixes. Which trunk a branch goes to is the one mapping of lib/branch-trunk.sh, shared with the
# CI gates; this check refuses the arm, creation, retarget or merge of a request aimed anywhere else.
#
# When it applies: ONLY in a repository that DECLARES its integration trunk (KYKLOS_INTEGRATION_BRANCH in its model or
# in the environment, lib/branch-trunk.sh branch_trunk_integration). The rule is opt-in by that declaration: a
# repository that declares nothing is admitted at once, with no git call, no network call and no notice, so the guard
# behaves there exactly as it did before the rule existed. In a declared repository every feature/* branch is judged,
# and the declared workflow (lib/repo-role.sh repo_workflow) decides:
#   trunk        one trunk by declaration: admitted.
#   __INVALID__  the model cannot be read: refused (no silent default).
#   gitflow      the integration trunk must exist: when the clone lacks origin/<trunk>, the remote is asked once,
#                bounded; missing there too, or not answering, is refused (fail-hard). A hotfix/* (also hotfix/story-*)
#                request aimed at the production trunk is refused when the branch carries commits of the integration
#                trunk that the production trunk lacks: a hotfix branches from main, and such a branch is integration
#                work that would reach a release without the full tier.
#
#   story_mr_integration_state <repo>
#       the declared reading: prints "yes" (the integration trunk exists: in the clone, or on the remote when the clone
#       lacks it), "no" (the remote answered without it) or "unknown" (it could not be asked).
#   story_mr_target_refusal <repo> <source-branch> <choice>
#       <choice> is merged_result_target_choice's answer (lib/merged-result.sh): "decided" or "strict" on the first
#       line, then the target refs (origin/<name> or a bare name). Prints the refusal and returns 0 when a declared
#       repository refuses the request (above); returns 1 when admitted, always in an undeclared repository. A notice
#       may go to stderr (declared repositories only).
#
# Default ON. The off switch (read by the calling guard, audited there): KYKLOS_STORY_MR_TARGET=off. A one-shot
# override, bound to one repository and one agent, also audited: bash hooks/lib/override-marker.sh set
# story-mr-target-ok <repo-dir>.
# [CySec] Fails closed (CWE-636): a request whose target, model or trunk cannot be read is refused, never guessed.

_SMT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$_SMT_DIR/branch-trunk.sh"
# shellcheck source=/dev/null
command -v repo_workflow >/dev/null 2>&1 || . "$_SMT_DIR/repo-role.sh"

STORY_MR_TARGET_OK_NAME=story-mr-target-ok
# The bound of the one remote question (seconds).
STORY_MR_LS_REMOTE_TIMEOUT="${STORY_MR_LS_REMOTE_TIMEOUT:-10}"

story_mr_integration_state() {
    local repo="$1" integ out rc
    integ="$(branch_trunk_integration "$repo")"
    if git -C "$repo" rev-parse --verify -q "refs/remotes/origin/$integ^{commit}" >/dev/null 2>&1; then
        printf 'yes'; return 0
    fi
    git -C "$repo" remote get-url origin >/dev/null 2>&1 || { printf 'no'; return 0; }
    out="$(GIT_TERMINAL_PROMPT=0 timeout "$STORY_MR_LS_REMOTE_TIMEOUT" git -C "$repo" ls-remote --heads origin "refs/heads/$integ" 2>/dev/null)"
    rc=$?
    if [ "$rc" -ne 0 ]; then printf 'unknown'
    elif [ -n "$out" ]; then printf 'yes'
    else printf 'no'
    fi
}

# _smt_ref <repo> <branch> -> the commit of <branch> in the clone (local branch first, then origin/<branch>); rc 1 none.
_smt_ref() {
    local c
    for c in "refs/heads/$2" "refs/remotes/origin/$2"; do
        git -C "$1" rev-parse --verify -q "$c^{commit}" 2>/dev/null && return 0
    done
    return 1
}

story_mr_target_refusal() {
    local integ
    # An undeclared repository: no target rule at all. The rule is opt-in by declaration, so it never refuses
    # anything in a repository that did not choose two trunks.
    integ="$(branch_trunk_integration "$1")" || return 1
    _smt_declared_refusal "$1" "$2" "$3" "$integ"
}

# _smt_aimed <choice> -> prints the one target <choice> decides (origin/ stripped); prints nothing when it names none or
# several.
_smt_aimed() {
    local t targets
    t="$(printf '%s\n' "$1" | head -1)"
    targets="$(printf '%s\n' "$1" | sed '1d' | sed -E 's#^origin/##; /^$/d')"
    if [ "$t" = decided ] && [ "$(printf '%s\n' "$targets" | grep -c .)" -eq 1 ]; then printf '%s' "$targets"; fi
}

# _smt_aim_refusal <source-branch> <choice> <trunk> <rule sentence> -> rc 1 when <choice> names exactly <trunk>; else
# prints the refusal (aimed elsewhere, or a target that cannot be read) and returns 0.
_smt_aim_refusal() {
    local src="$1" choice="$2" want="$3" rule="$4" aimed t
    aimed="$(_smt_aimed "$choice")"
    [ -n "$aimed" ] && [ "$aimed" = "$want" ] && return 1
    local fix="$rule Name the target: git push -o merge_request.create -o merge_request.target=$want ... origin $src (or retarget the open merge request to $want)."
    if [ -n "$aimed" ]; then
        printf "Merge request REFUSED: '%s' merges into %s and its merge request is aimed at '%s', not %s. %s" "$src" "$want" "$aimed" "$want" "$fix"
    else
        t="$(printf '%s\n' "$choice" | sed '1d' | sed -E 's#^origin/##; /^$/d' | paste -sd, - | sed 's/,/, /g')"
        printf "Merge request REFUSED: '%s' merges into %s and the target of its merge request cannot be read (candidates: %s), so it may land on the production trunk. %s" "$src" "$want" "${t:-none}" "$fix"
    fi
    return 0
}

# The two-trunk rule of a repository that declares its integration trunk <integ>.
_smt_declared_refusal() {
    local repo="$1" src="$2" choice="$3" integ="$4" kind wf state aimed prod src_c base_c carried
    kind="$(branch_trunk_kind "$src" "$repo")"
    case "$src" in hotfix/*) ;; *) [ "$kind" = integration ] || return 1 ;; esac
    wf="$(repo_workflow "$repo")"
    case "$wf" in
        trunk) return 1 ;;
        gitflow) ;;
        *) printf "Merge request REFUSED: the repository model of '%s' cannot be read (workflow '%s'), so the trunk '%s' must land on cannot be decided. Fix the repository model (.claude/standards.env, the ssdlc-repo-model skill)." "$repo" "$wf" "$src"
           return 0 ;;
    esac
    state="$(story_mr_integration_state "$repo")"
    if [ "$state" != yes ]; then
        if [ "$state" = no ]; then
            printf "Merge request REFUSED: this repository declares the integration trunk '%s' (KYKLOS_INTEGRATION_BRANCH), but origin has no such branch, so '%s' cannot land where it must. Create and protect '%s' from main first (the two-trunk rollout), or correct the repository model." "$integ" "$src" "$integ"
        else
            printf "Merge request REFUSED: this repository declares the integration trunk '%s' (KYKLOS_INTEGRATION_BRANCH), the clone has no origin/%s and origin could not be asked, so the target of '%s' cannot be checked. Run 'git fetch origin', then retry." "$integ" "$integ" "$src"
        fi
        return 0
    fi
    prod="${CI_DEFAULT_BRANCH:-main}"
    if [ "$kind" != integration ]; then
        # A hotfix: it lands on the production trunk (and is merged back into the integration trunk). Aimed at the
        # production trunk, it must not carry the integration trunk's unreleased commits.
        aimed="$(_smt_aimed "$choice")"
        [ -n "$aimed" ] && [ "$aimed" != "$integ" ] || return 1
        src_c="$(_smt_ref "$repo" "$src")" || { echo "[kyklos] story merge-request target check: '$src' is not in this clone, so whether it carries unreleased $integ commits was not checked." >&2; return 1; }
        git -C "$repo" rev-parse --verify -q "refs/remotes/origin/$aimed^{commit}" >/dev/null 2>&1 || return 1
        base_c="$(git -C "$repo" merge-base "$src_c" "refs/remotes/origin/$integ" 2>/dev/null)" || return 1
        carried="$(git -C "$repo" rev-list --count "$base_c" --not "refs/remotes/origin/$aimed" 2>/dev/null || echo 0)"
        [ "${carried:-0}" -gt 0 ] 2>/dev/null || return 1
        printf "Merge request REFUSED: '%s' is aimed at '%s' but carries %s commit(s) of '%s' that '%s' does not have. A hotfix branches from %s and holds only the fix; work that started from %s is integration work: name it feature/story-<n>-<slug> (or feature/<slug>) and target %s, where it reaches %s through a release/<version> promotion that runs the full CI tier." "$src" "$aimed" "$carried" "$integ" "$aimed" "$aimed" "$integ" "$integ" "$aimed"
        return 0
    fi
    _smt_aim_refusal "$src" "$choice" "$integ" "Branches named feature/* (story branches feature/story-<n>-<slug>) merge into $integ; $prod receives only a release/<version> promotion or a hotfix/* branch."
}
