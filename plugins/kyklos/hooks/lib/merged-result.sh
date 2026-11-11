#!/usr/bin/env bash
# merged-result.sh - the one rule for "may a branch behind its target arm auto-merge or be merged through the API".
# Source it; it defines functions only.
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/branch-trunk.sh"   # branch_trunk_kind / branch_trunk_integration
#
# GitLab CE has no merged-results pipelines: a merge request pipeline tests the branch head, not the merge into the
# current target. A branch that contains the target's current head lands exactly what its pipeline tested. A branch
# behind its target is still admitted when the target's new work and the branch's work touch DIFFERENT files: neither
# side then changes a file the other side's tested state relies on directly. Build-wide files (the CI definition and its
# includes, the MSBuild and NuGet configuration, project and solution files, the SDK and tool pins, analyzer and test-run
# settings) affect every file, so a build-wide change
# on either side counts as overlapping with everything.
#
#   merged_result_build_wide <path>       rc 0 when <path> is a build-wide file
#   merged_result_overlap <target-files> <branch-files>
#                                         prints the overlapping paths (one per line, sorted, unique); rc 0 when there
#                                         are none (the two sides are disjoint), rc 1 otherwise. Each argument is a
#                                         newline-separated list of paths relative to the repository root.
#   merged_result_git_verdict <repo> <target-commit> [head]
#                                         rc 0 when <head> (default HEAD) contains <target-commit>, or the files the
#                                         target changed since the fork point are disjoint from the branch's;
#                                         rc 1 on overlap (prints the overlapping paths); rc 2 when it cannot be
#                                         decided (prints the reason). Renames count under both names.
#   merged_result_target_choice <repo> <branch> <known-targets> <ambiguous> <creating> <default-branch>
#                                         which trunk the branch's merge request lands on ("decided" + one ref), or
#                                         "strict" + the candidates when it cannot be told apart; rc 1 when none

# The rule as one awk program (one process for any number of paths, so a large change set never runs past the hook's
# time limit). Run it with LC_ALL=C: tolower then folds ASCII letters only, exactly like the bridge.
#   bw(p)  - 1 for a file whose change can break any other file of the build: the CI definition (.gitlab-ci.yml, any
#            *.gitlab-ci.yml, a root ci/ folder, any .gitlab/ folder), the MSBuild and NuGet configuration, project
#            and solution files, the SDK and tool pins (global.json, dotnet-tools.json, any .config/ folder), analyzer
#            and test-run settings, .editorconfig and .gitattributes. A CI file included from elsewhere is not seen:
#            keep included CI files under ci/ or .gitlab/, or name them *.gitlab-ci.yml. MergedResult.IsBuildWide in the
#            bridge is the same list; the case table tests/fixtures/merged-result-build-wide.tsv holds both to it.
#   key(p) - two paths are taken for one file (a case-insensitive checkout) when their keys match: ASCII letters
#            lowered and every non-ASCII byte dropped. Dropping is deliberately coarse (src/É.cs and src/Ö.cs share a
#            key): an over-match refuses, never admits. MergedResult.SameFileKey in the bridge computes the same key.
_MERGED_RESULT_AWK_LIB='
function key(s) { s = tolower(s); gsub(/[\200-\377]/, "", s); return s }
function bw(p,   l, b) {
    l = tolower(p); b = l; sub(/.*\//, "", b)
    if (l ~ /^ci\// || l ~ /(^|\/)\.gitlab\// || l ~ /(^|\/)\.config\//) return 1
    if (b ~ /^(global\.json|dotnet-tools\.json|nuget\.config|packages\.lock\.json|directory\.build\.rsp|\.editorconfig|\.gitattributes)$/) return 1
    if (b ~ /\.gitlab-ci\.ya?ml$/) return 1
    if (b ~ /\.(props|targets|sln|slnx|slnf|csproj|fsproj|vbproj|sqlproj|wixproj|vcxproj|dcproj|shproj|proj|projitems|runsettings|ruleset|globalconfig)$/) return 1
    return 0
}'

# A file list this long may have been cut, and is refused as undecidable (the bridge applies the same cap).
MERGED_RESULT_MAX_FILES=1000

# merged_result_build_wide <path> -> rc 0 for a build-wide file (bw above).
merged_result_build_wide() { printf '%s\n' "$1" | LC_ALL=C awk "$_MERGED_RESULT_AWK_LIB"' { exit !bw($0) }'; }

# [RiskMitigation RA-01] One decision for every enforcement point: a path both sides changed, or any build-wide path
# either side changed while the other side changed anything, is an overlap.
# [CySec] Integrity of the shared trunk (CWE-841, improper enforcement of a behavioural workflow): only changes on
# disjoint, non-build-wide files may land without a pipeline over their merge result.
merged_result_overlap() {
    local target="$1" branch="$2" out
    target="$(printf '%s\n' "$target" | sed '/^$/d' | sort -u)"
    branch="$(printf '%s\n' "$branch" | sed '/^$/d' | sort -u)"
    { [ -n "$target" ] && [ -n "$branch" ]; } || return 0
    # First file: the branch (its build-wide paths printed, its keys kept); second: the target (a path whose key the
    # branch shares, or a build-wide path, printed).
    out="$(LC_ALL=C awk "$_MERGED_RESULT_AWK_LIB"'
        NR == FNR { seen[key($0)] = 1; if (bw($0)) print; next }
        (key($0) in seen) || bw($0) { print }' <(printf '%s\n' "$branch") <(printf '%s\n' "$target") | sed '/^$/d' | LC_ALL=C sort -u)"
    [ -z "$out" ] && return 0
    printf '%s\n' "$out"
    return 1
}

# merged_result_git_verdict <repo> <target-commit> [head] -> rc 0 admit, 1 overlap (prints paths), 2 undecidable.
# [RiskMitigation RA-02] Every read that fails is undecidable, never admitted (fail closed).
merged_result_git_verdict() {
    local r="$1" target="$2" head="${3:-HEAD}" mb tfiles bfiles
    git -C "$r" cat-file -e "$target^{commit}" 2>/dev/null \
        || { printf 'the target head %s is not in this clone (fetch it: git fetch origin)\n' "${target:0:8}"; return 2; }
    git -C "$r" rev-parse --verify -q "$head^{commit}" >/dev/null 2>&1 || { printf 'the branch head %s cannot be read\n' "$head"; return 2; }
    git -C "$r" merge-base --is-ancestor "$target" "$head" 2>/dev/null && return 0
    mb="$(git -C "$r" merge-base "$target" "$head" 2>/dev/null)" \
        || { printf 'the branch and its target share no history in this clone (a shallow clone? git fetch --unshallow)\n'; return 2; }
    tfiles="$(_merged_result_names "$r" "$mb" "$target")" || { printf 'the files the target changed cannot be listed%s\n' "$tfiles"; return 2; }
    bfiles="$(_merged_result_names "$r" "$mb" "$head")" || { printf 'the files the branch changed cannot be listed%s\n' "$bfiles"; return 2; }
    # Behind with no file listed for the target is a contradiction the rule does not guess about.
    [ -n "$tfiles" ] || { printf 'the target is ahead of the branch but no file it changed was listed\n'; return 2; }
    # A branch behind its target that changes nothing has nothing tested to land; an empty list is not a pass either.
    [ -n "$bfiles" ] || { printf 'no file the branch changed was listed\n'; return 2; }
    if [ "$(printf '%s\n' "$tfiles" | wc -l)" -ge "$MERGED_RESULT_MAX_FILES" ] || [ "$(printf '%s\n' "$bfiles" | wc -l)" -ge "$MERGED_RESULT_MAX_FILES" ]; then
        printf 'a file list reached %s entries, too many to compare here\n' "$MERGED_RESULT_MAX_FILES"; return 2
    fi
    merged_result_overlap "$tfiles" "$bfiles"
}

# _merged_result_names <repo> <from> <to> -> the paths changed between the two commits, one per line, renames under
# both names, a moved submodule whatever its ignore setting, never quoted (git quotes a path with special characters, which would hide its name from the
# build-wide test). rc 1 when they cannot be listed or a path holds a line break (prints why).
_merged_result_names() {
    local breaks
    breaks="$(git -C "$1" diff -z --no-renames --ignore-submodules=none --name-only "$2" "$3" -- 2>/dev/null | tr -cd '\n' | wc -c; exit "${PIPESTATUS[0]}")" || return 1
    [ "$breaks" -eq 0 ] || { printf ' (a path holds a line break)'; return 1; }
    git -C "$1" diff -z --no-renames --ignore-submodules=none --name-only "$2" "$3" -- 2>/dev/null | tr '\0' '\n'; return "${PIPESTATUS[0]}"
}

# merged_result_target_choice <repo> <branch> <known-targets> <ambiguous> <creating> <default-branch>
#   -> which trunk a branch's merge request lands on, for a caller that is not told (an arm sent as a push option, a glab
#   merge). Prints "decided" or "strict" on the first line, then the target refs (origin/<name>, or the explicit ref
#   given), one per line; prints nothing and returns rc 1 when no target can be named at all.
#     <known-targets>  newline-separated branch names already known to be the target: the push's
#                      merge_request.target option and the target of any open merge request of the branch
#     <ambiguous>      1 when the push names a target the guard cannot read (computed by the shell)
#     <creating>       1 when the push creates the merge request (GitLab then targets the project's default branch
#                      unless a target is named)
#     <default-branch> the project's default branch when known, else empty
#   decided: exactly one target follows, judged by the full rule (disjoint files admitted).
#   strict:  the target cannot be told apart among the refs that follow; the branch must contain the head of each.
#   Order: a known target; the explicit KYKLOS_CHANGE_BASE_REF or CI_MERGE_REQUEST_TARGET_BRANCH_NAME; the default
#   branch of a merge request this push creates; GitFlow naming (hotfix/* and release/* land on the production trunk,
#   feature/* on the integration trunk, else on the production trunk: lib/branch-trunk.sh, the one mapping); the only
#   trunk the clone has. A tie is never broken by a guess.
# [RiskMitigation RA-03] [CySec] A target that cannot be named exactly is never guessed (CWE-636, not failing
# securely): judging against the wrong trunk would admit a change the real target overlaps.
merged_result_target_choice() {
    local r="$1" br="$2" known="$3" amb="${4:-0}" creating="${5:-0}" def="${6:-}" t ref integ
    local -a cands=() prod=() strict=()
    integ="$(branch_trunk_integration "$r")"
    for ref in "origin/$integ" origin/main origin/master; do
        git -C "$r" rev-parse --verify -q "$ref^{commit}" >/dev/null 2>&1 && cands+=("$ref")
    done
    for ref in origin/main origin/master; do
        git -C "$r" rev-parse --verify -q "$ref^{commit}" >/dev/null 2>&1 && prod+=("$ref")
    done
    known="$(printf '%s\n' "$known" | sed '/^$/d' | LC_ALL=C sort -u)"
    if [ "$amb" != 1 ] && [ -n "$known" ] && [ "$(printf '%s\n' "$known" | wc -l)" -eq 1 ]; then
        printf 'decided\norigin/%s\n' "$known"; return 0
    fi
    if [ "$amb" = 1 ] || [ -n "$known" ]; then
        while IFS= read -r t; do [ -n "$t" ] && strict+=("origin/$t"); done <<< "$known"
        strict+=("${cands[@]}")
        printf 'strict\n'; printf '%s\n' "${strict[@]}" | awk '!seen[$0]++'; return 0
    fi
    if [ -n "${KYKLOS_CHANGE_BASE_REF:-}" ]; then
        git -C "$r" rev-parse --verify -q "$KYKLOS_CHANGE_BASE_REF^{commit}" >/dev/null 2>&1 || return 1
        printf 'decided\n%s\n' "$KYKLOS_CHANGE_BASE_REF"; return 0
    fi
    if [ -n "${CI_MERGE_REQUEST_TARGET_BRANCH_NAME:-}" ]; then
        for ref in "origin/$CI_MERGE_REQUEST_TARGET_BRANCH_NAME" "$CI_MERGE_REQUEST_TARGET_BRANCH_NAME"; do
            git -C "$r" rev-parse --verify -q "$ref^{commit}" >/dev/null 2>&1 && { printf 'decided\n%s\n' "$ref"; return 0; }
        done
        return 1
    fi
    [ "${#cands[@]}" -gt 0 ] || return 1
    if [ "$creating" = 1 ]; then
        [ -n "$def" ] && { printf 'decided\norigin/%s\n' "$def"; return 0; }
    else
        if [ "$(branch_trunk_kind "$br" "$r")" = integration ]; then
            git -C "$r" rev-parse --verify -q "origin/$integ^{commit}" >/dev/null 2>&1 && { printf 'decided\norigin/%s\n' "$integ"; return 0; }
            [ "${#prod[@]}" -eq 1 ] && { printf 'decided\n%s\n' "${prod[0]}"; return 0; }
        else
            case "$br" in
                hotfix/*|release/*)
                    [ "${#prod[@]}" -eq 1 ] && { printf 'decided\n%s\n' "${prod[0]}"; return 0; }
                    [ "${#prod[@]}" -gt 1 ] && { printf 'strict\n'; printf '%s\n' "${prod[@]}"; return 0; } ;;
            esac
        fi
    fi
    [ "${#cands[@]}" -eq 1 ] && { printf 'decided\n%s\n' "${cands[0]}"; return 0; }
    printf 'strict\n'; printf '%s\n' "${cands[@]}"
}
