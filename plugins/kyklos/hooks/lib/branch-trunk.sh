#!/usr/bin/env bash
# branch-trunk.sh - THE one answer to "which trunk does this branch merge into". Source it; it defines functions only
# and reads no file but the repository model it is pointed at (parsed, never sourced: CWE-829).
#
# GitFlow with two trunks: an integration trunk (develop) receives every feature/* branch, story branches
# (feature/story-<n>-<slug>) included; the production trunk (the default branch, main) receives only a release/<version>
# promotion, a hotfix/* (a hotfix/story-* branch is a hotfix too) and a support/* branch. Everything else, the
# integration trunk itself included, is compared with the production trunk. The story merge-request target guard
# (lib/story-mr-target.sh), the merged-result target choice (lib/merged-result.sh) and the CI gates
# (ci/merge-target.sh, which ci/fresh-merge.sh and ci/coverage-gates.sh ask) all call these functions, so they cannot
# disagree about where a branch goes.
#
#   branch_trunk_integration [<repo>]
#       prints the integration trunk's name: KYKLOS_INTEGRATION_BRANCH from the environment when set (the CI file sets
#       it as a global variable), else the value the repository's .claude/standards.env declares, else 'develop'.
#       rc 0 when it was DECLARED (environment or model), rc 1 for the default. A repository that declares it runs two
#       trunks for certain: its tools fail hard when the branch is missing instead of assuming a one-trunk repository.
#   branch_trunk_kind <branch> [<repo>]
#       prints 'integration' for a branch that merges into the integration trunk (feature/*), 'production' otherwise.
#   branch_trunk_target <branch> [<repo>]
#       prints the name of the trunk the branch merges into: the integration trunk, or the production trunk
#       (CI_DEFAULT_BRANCH when set, else main). It does not check that the trunk exists: each caller decides what a
#       missing one means and says so.

BRANCH_TRUNK_DEFAULT_INTEGRATION=develop

branch_trunk_integration() {
    local repo="${1:-}" v="" f
    if [ -n "${KYKLOS_INTEGRATION_BRANCH:-}" ]; then
        printf '%s' "$KYKLOS_INTEGRATION_BRANCH"; return 0
    fi
    if [ -n "$repo" ]; then
        f="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$repo")/.claude/standards.env"
        if [ -f "$f" ]; then
            # Text mode: a NUL in the file must not make grep treat it as binary and hide the key (CWE-158).
            v="$(LC_ALL=C grep -aE '^KYKLOS_INTEGRATION_BRANCH=' "$f" 2>/dev/null | tail -n1)"
            v="${v%$'\r'}"; v="${v#*=}"
            case "$v" in \"*\") v="${v#\"}"; v="${v%\"}" ;; \'*\') v="${v#\'}"; v="${v%\'}" ;; esac
        fi
    fi
    # [CySec] Only a plain branch name is accepted from the file (CWE-20): anything else is ignored as undeclared.
    case "$v" in ''|*[!A-Za-z0-9._/-]*|-*|*..*) printf '%s' "$BRANCH_TRUNK_DEFAULT_INTEGRATION"; return 1 ;; esac
    printf '%s' "$v"
}

branch_trunk_kind() {
    case "$1" in
        feature/*) printf 'integration' ;;
        *)         printf 'production' ;;
    esac
}

branch_trunk_target() {
    if [ "$(branch_trunk_kind "$1" "${2:-}")" = integration ]; then
        branch_trunk_integration "${2:-}"
    else
        printf '%s' "${CI_DEFAULT_BRANCH:-main}"
    fi
    return 0
}
