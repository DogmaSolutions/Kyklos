#!/usr/bin/env bash
# mutation-due.sh (Kyklos, measuring-test-coverage) -- is a mutation-testing run required, and is it due, for this
# branch?
#
# Mutation testing is the trust check for SECURITY-SENSITIVE code. During development a branch needs ONE mutation run
# only when it changes security-sensitive code: a production source file the branch changed, in a language a mutation
# tool can mutate (C#, JavaScript/TypeScript, Scala), whose changed lines lie within ten lines of a [CySec] annotation comment (the
# ssdlc-cysec convention). Any other change needs no run; an agent may still run one voluntarily. When a run is
# required it happens ONCE per merge intent (right before the push that opens or updates the merge request, or right
# before the story close) and again only when the measured code changed. This tool makes both answers mechanical
# instead of a guess, so an agent never runs Stryker "to be safe" and is never asked for a run its change does not need.
#
# Changed files come from the same change window the proof tool-gate uses (proof_tool_changed_source_files): the
# branch since it forked from its trunk, plus uncommitted changes. Test files, docs, CI, story and config files are not
# production source: they never make a run required, and (except test files) never make a run due again.
#
# What a run measures is fingerprinted as the content of every SOURCE file (production or test) the branch changes.
# A record also holds the trunk commit the branch sits on (a merge or rebase of the trunk changes the code under test
# even when the branch's own files do not) and the run's SCOPE (the one project Stryker mutated; empty when none is
# named), so a run for project A never stands in for project B.
#
# Usage:
#   mutation-due.sh required [DIR]         prints "REQUIRED: <why>" (exit 0) or "NOT REQUIRED: <why>" (exit 1)
#   mutation-due.sh check  [DIR [SCOPE]]   prints "DUE: <reason>" (exit 0), or, when no run is needed, "NOT DUE: <reason>"
#                                          or "NOT REQUIRED: <why>" (exit 1)
#   mutation-due.sh record [DIR [SCOPE]]   stores the fingerprint of what a successful run just measured (exit 0)
#   mutation-due.sh target [DIR]           prints the repository a mutation run from DIR measures
# DIR defaults to the current directory, SCOPE to empty. In a companion workspace (KYKLOS_REPO_SHAPE=companion) the measured
# repository is the nested source repository (KYKLOS_SOURCE_DIR, default Repo), as the bridge measures it.
#
# Never claims NOT REQUIRED or NOT DUE when it cannot tell: no git, no work tree, no trunk base, a corrupt or foreign
# record -> REQUIRED / DUE. Records live under ${KYKLOS_STATE_DIR:-/tmp/kyklos-state}/mutation-ledger/ (volatile by
# design: losing one costs at most one extra run).
set +e -uo pipefail

_MD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../hooks/lib/proof-tool-gate.sh
. "$_MD_DIR/../../hooks/lib/proof-tool-gate.sh"

mutation_ledger_dir() { printf '%s' "${KYKLOS_STATE_DIR:-/tmp/kyklos-state}/mutation-ledger"; }

# mutation_target_repo DIR -> the git top level a mutation run started from DIR measures (non-zero when none).
mutation_target_repo() {
    local dir="${1:-.}" top src
    top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || return 1
    if [ "${KYKLOS_REPO_SHAPE:-}" = "companion" ]; then
        src="$top/${KYKLOS_SOURCE_DIR:-Repo}"
        if git -C "$src" rev-parse --show-toplevel >/dev/null 2>&1; then
            top="$(git -C "$src" rev-parse --show-toplevel)"
        fi
    fi
    printf '%s\n' "$top"
}

# mutation_fingerprint_lines REPO -> "path<TAB>blob-or-deleted" per changed source file, sorted (non-zero when the
# change window cannot be known).
mutation_fingerprint_lines() {
    local repo="$1" files f h
    files="$(proof_tool_changed_source_files "$repo")" || return 1
    [ -n "$(proof_tool_change_base "$repo" 2>/dev/null || true)" ] || return 1
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        if [ -f "$repo/$f" ]; then h="$(git -C "$repo" hash-object -- "$f" 2>/dev/null)" || return 1; else h="deleted"; fi
        printf '%s\t%s\n' "$f" "$h"
    done <<< "$files" | sort
}

# The security annotation that makes a mutation run required, and the languages a mutation tool can mutate.
MUTATION_SECURITY_MARKER='[CySec]'
# How far from a changed line an annotation still marks the change as security-sensitive, and what counts as the
# annotation: a comment (// /* * #) carrying [CySec], never the word inside a string.
MUTATION_MARKER_CONTEXT=10
MUTATION_MARKER_COMMENT_PATTERN='^[ +][[:space:]]*(//|/[*]|[*]|#).*\[CySec\]'
MUTATION_MUTABLE_SOURCE_PATTERN='\.(cs|js|jsx|mjs|cjs|ts|tsx|scala)$'
# A test file: under a test folder (tests/, test/, spec/, __tests__/, or a project folder such as App.Tests/), or
# named like a test (FooTests.cs, FooTest.cs, foo.test.ts, foo.spec.js, FooSpec.scala).
# A folder is a test folder only by its whole name (tests, Tests, spec, __tests__) or by a project suffix after a dot
# (.Tests, .UnitTests, .Spec): a production folder such as Auth.Contest or App.Latest is never taken for one, since
# that would skip a required run. The class-name suffixes (Tests.cs, Spec.scala) are case-sensitive for the same reason.
MUTATION_TEST_PATH_PATTERN='(^|/)([Tt]ests?|[Ss]pecs?|__tests__|[^/]*[.]([A-Za-z]*Tests?|[Tt]ests?|[Ss]pecs?))/'
MUTATION_TEST_FILE_PATTERN='[.]([Tt]est|[Ss]pec)[.][A-Za-z]+$'
MUTATION_TEST_NAME_PATTERN='Tests?[.]cs$|(Spec|Test)[.]scala$'

# mutation_security_files REPO -> the changed production source files (mutable languages) with a changed line near a [CySec] annotation comment,
# one per line (possibly none). Non-zero when the change window cannot be known.
mutation_security_files() {
    local repo="$1" files f base
    # The whole change window, filtered here: the shared source-file list does not know every mutable language (Scala).
    files="$(proof_tool_changed_files "$repo")" || return 1
    base="$(proof_tool_change_base "$repo" 2>/dev/null)" || return 1
    [ -n "$base" ] || return 1
    while IFS= read -r f; do
        [ -n "$f" ] && [ -f "$repo/$f" ] || continue
        printf '%s\n' "$f" | grep -ciE "$MUTATION_MUTABLE_SOURCE_PATTERN" >/dev/null || continue
        printf '%s\n' "$f" | grep -cE "$MUTATION_TEST_PATH_PATTERN" >/dev/null && continue
        printf '%s\n' "$f" | grep -ciE "$MUTATION_TEST_FILE_PATTERN" >/dev/null && continue
        printf '%s\n' "$f" | grep -cE "$MUTATION_TEST_NAME_PATTERN" >/dev/null && continue
        mutation_change_touches_marker "$repo" "$base" "$f" && printf '%s\n' "$f"
    done <<< "$files"
    return 0
}

# mutation_change_touches_marker REPO BASE FILE -> 0 when a changed section of FILE (the changed lines and
# MUTATION_MARKER_CONTEXT lines around them, base to working tree) holds a [CySec] annotation written as a comment.
# The annotation sits right above the code it guards, so an edit near it touches security-sensitive code; a marker
# elsewhere in a large file, or the word inside a string, does not make an unrelated edit security-sensitive.
mutation_change_touches_marker() {
    local repo="$1" base="$2" f="$3" hunks from
    # The same window as the shared changed-file list: from the merge base, or, on the trunk itself (merge base ==
    # HEAD), from the previous commit; the working tree is always included.
    from="$base"
    if [ "$from" = "$(git -C "$repo" rev-parse HEAD 2>/dev/null)" ]; then
        from="$(git -C "$repo" rev-parse --verify -q HEAD~1 2>/dev/null)" || from="$base"
    fi
    hunks="$(git -C "$repo" diff --no-color -U"$MUTATION_MARKER_CONTEXT" "$from" -- "$f" 2>/dev/null)" || return 0
    printf '%s\n' "$hunks" | grep -E '^[ +]' | grep -cE "$MUTATION_MARKER_COMMENT_PATTERN" >/dev/null
}

# mutation_required REPO -> "REQUIRED: <why>" (rc 0) or "NOT REQUIRED: <why>" (rc 1). An unknown change window is
# REQUIRED: a security-sensitive change cannot be ruled out.
mutation_required() {
    local repo="$1" files
    # Mutation testing runs by default. A project opts out only through its own launcher configuration, which sets
    # KYKLOS_MUTATION_SUSPENDED=1 for that project's container (the greppable per-project off-switch).
    if [ "${KYKLOS_MUTATION_SUSPENDED:-0}" = "1" ]; then
        echo "NOT REQUIRED: mutation testing is suspended for this project (KYKLOS_MUTATION_SUSPENDED=1, set in its launcher configuration); do not run it. The Test Discipline proof states \"Mutation: not required (mutation testing suspended for this project)\"."
        return 1
    fi
    if ! files="$(mutation_security_files "$repo")" || [ -z "$(proof_tool_change_base "$repo" 2>/dev/null || true)" ]; then
        echo "REQUIRED: the branch's change window cannot be resolved (no trunk base), so a security-sensitive change cannot be ruled out"
        return 0
    fi
    if [ -n "$files" ]; then
        echo "REQUIRED: security-sensitive code changed (a changed line near a $MUTATION_SECURITY_MARKER annotation comment in $(printf '%s\n' "$files" | head -10 | tr '\n' ' ' | sed 's/ $//'))"
        return 0
    fi
    echo "NOT REQUIRED: no security-sensitive code changed (no changed line of production source lies within $MUTATION_MARKER_CONTEXT lines of a $MUTATION_SECURITY_MARKER annotation comment). A mutation run is optional for this branch; you may still run one, and the Test Discipline proof states \"Mutation: not required (no security-sensitive code changed)\"."
    return 1
}

# One record per repository and scope; git's own hashing keeps the name portable.
_mutation_record_file() { printf '%s/%s.rec' "$(mutation_ledger_dir)" "$(printf '%s\n%s' "$1" "$2" | git hash-object --stdin | cut -c1-16)"; }

mutation_record() {
    local repo scope="${2:-}" lines rec tmp
    repo="$(mutation_target_repo "${1:-.}")" || { echo "record: not inside a git work tree" >&2; return 2; }
    lines="$(mutation_fingerprint_lines "$repo")" || { echo "record: the branch's change window cannot be resolved (no trunk base)" >&2; return 2; }
    rec="$(_mutation_record_file "$repo" "$scope")"
    mkdir -p "$(mutation_ledger_dir)" || return 2
    tmp="$rec.tmp.$$"
    {
        printf 'repo\t%s\n' "$repo"
        printf 'scope\t%s\n' "$scope"
        printf 'base\t%s\n' "$(proof_tool_change_base "$repo" 2>/dev/null)"
        printf 'commit\t%s\n' "$(git -C "$repo" rev-parse HEAD 2>/dev/null)"
        printf 'recorded\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '%s\n' "$lines" | sed '/^$/d; s/^/file\t/'
    } > "$tmp" && mv "$tmp" "$rec"
    echo "recorded: mutation run over $(printf '%s\n' "$lines" | sed '/^$/d' | wc -l | tr -d ' ') changed source file(s) at $(git -C "$repo" rev-parse --short HEAD 2>/dev/null)"
}

_mutation_freshness() {
    local repo scope="${2:-}" rec now before commit changed
    repo="$(mutation_target_repo "${1:-.}")" || { echo "DUE: not inside a git work tree, so a previous run cannot be matched"; return 0; }
    now="$(mutation_fingerprint_lines "$repo")" || { echo "DUE: the branch's change window cannot be resolved (no trunk base), so a previous run cannot be matched"; return 0; }
    rec="$(_mutation_record_file "$repo" "$scope")"
    [ -f "$rec" ] || { echo "DUE: no mutation run is recorded for this branch${scope:+ and project $scope} yet"; return 0; }
    [ "$(sed -n 's/^repo\t//p' "$rec" | head -1)" = "$repo" ] || { echo "DUE: the recorded run belongs to another repository"; return 0; }
    [ "$(sed -n 's/^scope\t//p' "$rec" | head -1)" = "$scope" ] || { echo "DUE: the recorded run mutated another project"; return 0; }
    [ "$(sed -n 's/^base\t//p' "$rec" | head -1)" = "$(proof_tool_change_base "$repo" 2>/dev/null)" ] \
        || { echo "DUE: the branch now sits on a different trunk commit (a merge or rebase changed the code under test)"; return 0; }
    commit="$(sed -n 's/^commit\t//p' "$rec" | head -1)"
    [ -n "$commit" ] || { echo "DUE: the recorded run is incomplete"; return 0; }
    before="$(sed -n 's/^file\t//p' "$rec")"
    if [ "$now" = "$before" ]; then
        echo "NOT DUE: the last mutation run (commit ${commit:0:8}) measured exactly the source this branch has now; only non-source files changed since. Cite that run; run again only if production or test source changes before the merge."
        return 1
    fi
    changed="$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$now") | sed -n 's/^[<>] \([^	]*\)\t.*/\1/p' | sort -u | head -10 | tr '\n' ' ')"
    echo "DUE: source changed since the last mutation run (commit ${commit:0:8}): ${changed% }"
    return 0
}

# mutation_check DIR SCOPE -> NOT REQUIRED when no security-sensitive code changed; otherwise DUE / NOT DUE, and a DUE
# answer says why the run is required.
mutation_check() {
    local repo req out rc
    repo="$(mutation_target_repo "${1:-.}")" || { echo "DUE: not inside a git work tree, so a previous run cannot be matched"; return 0; }
    req="$(mutation_required "$repo")" || { echo "$req"; return 1; }
    out="$(_mutation_freshness "$repo" "${2:-}")"; rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "$out. A run is required because ${req#REQUIRED: }."
    else
        echo "$out"
    fi
    return "$rc"
}

case "${1:-}" in
    required) shift; _r="$(mutation_target_repo "${1:-.}")" || { echo "REQUIRED: not inside a git work tree, so a security-sensitive change cannot be ruled out"; exit 0; }
              mutation_required "$_r" ;;
    check)  shift; mutation_check "${1:-.}" "${2:-}" ;;
    record) shift; mutation_record "${1:-.}" "${2:-}" ;;
    target) shift; mutation_target_repo "${1:-.}" ;;
    *) echo "usage: mutation-due.sh required|check|record|target [DIR]" >&2; exit 2 ;;
esac
