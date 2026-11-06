#!/usr/bin/env bash
# slnx-solutions.sh (Kyklos) -- the ONE place that knows how a repository's .slnx solutions map to green-build
# records and to the paths a push changes. Shared by record-slnx-green.sh (the recorder) and
# kyklos-slnx-green-guard.sh (the push gate), so the two can never disagree on a marker key. Sourced; functions only.
#
#   slnx_hash <text>                              -> a stable, filesystem-safe 16-char key for <text>
#   slnx_list <top>                               -> the repo's .slnx files, relative to <top>, sorted, one per line
#   slnx_marker_path <state> <top> <sol-rel>      -> the per-solution green marker file
#   slnx_legacy_marker_path <state> <top>         -> the one-per-repo marker written by earlier recorder versions
#   slnx_record_sha <state> <top> <sol-rel> <n>   -> the SHA recorded green for that solution (empty when none)
#   slnx_record_matches <state> <top> <sol-rel> <n> <sha>
#                                                 -> rc 0 when a record applicable to that solution names <sha>
#   slnx_affected_by_paths <solutions> <paths>    -> the solutions (newline lists in, one per line out) the paths touch
#
# <n> is the number of solutions in the repo: a legacy marker (no solution recorded in it) is honoured only when
# the repo has exactly one solution, so it can never stand in for a second one.

# Folders never searched for a solution: VCS data, build output, dependencies.
_SLNX_PRUNE_NAMES=(.git bin obj node_modules)

# MSBuild / SDK files that are imported automatically into every project at or below their folder. A change to one
# of them changes the build of every solution in or under that folder, even when no project file moved.
# [RiskMitigation RA-01] an inherited build input maps to every solution below it, so such a push is never ungated.
_SLNX_ANCESTOR_IMPORTS_RE='^(directory\.build\.(props|targets|rsp)|directory\.packages\.props|directory\.solution\.(props|targets)|global\.json|nuget\.config|\.editorconfig|\.globalconfig)$'

slnx_hash() {
    local text="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$text" | sha256sum | cut -c1-16
    elif command -v shasum >/dev/null 2>&1; then
        printf '%s' "$text" | shasum -a 256 | cut -c1-16
    elif command -v cksum >/dev/null 2>&1; then
        printf '%s' "$text" | cksum | tr -d ' ' | cut -c1-16
    else
        printf '%s' "$text" | tr -c 'A-Za-z0-9' '_'
    fi
}

# slnx_list lists only the solutions that BELONG to the repository: in a git work tree, git itself answers (tracked
# files plus untracked files that are not ignored), so a solution inside an ignored folder - another repository's
# worktree, a scratch clone - or inside a nested repository (its own .git) is never counted as this repository's.
# Outside git (no repository to ask) the folder search applies.
slnx_list() {
    local top="$1" prune=() name file
    if git -C "$top" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        && [ "$(git -C "$top" rev-parse --show-toplevel 2>/dev/null)" = "$(cd "$top" 2>/dev/null && pwd -P)" ]; then
        git -C "$top" ls-files -z --cached --others --exclude-standard -- '*.slnx' 2>/dev/null \
            | tr '\0' '\n' | grep -vE '(^|/)(bin|obj|node_modules)/' \
            | while IFS= read -r file; do [ -f "$top/$file" ] && printf '%s\n' "$file"; done | LC_ALL=C sort -u
        return 0
    fi
    for name in "${_SLNX_PRUNE_NAMES[@]}"; do
        [ "${#prune[@]}" -eq 0 ] || prune+=(-o)
        prune+=(-name "$name")
    done
    find "$top" \( "${prune[@]}" \) -prune -o -type f -name '*.slnx' -print 2>/dev/null \
        | while IFS= read -r file; do printf '%s\n' "${file#"$top"/}"; done | LC_ALL=C sort
}

# [CySec] Mitigates CWE-345 (insufficient verification of data authenticity): one record file per (repo, solution)
# key, computed here for both the recorder and the guard, so one solution's record can never satisfy another's.
# [RiskMitigation RA-02]
slnx_marker_path() {
    printf '%s/slnx-green-%s-%s' "$1" "$(slnx_hash "$2")" "$(slnx_hash "$3")"
}

slnx_legacy_marker_path() {
    printf '%s/slnx-green-%s' "$1" "$(slnx_hash "$2")"
}

# _slnx_first_line <file> -> the marker's recorded SHA (its first line, whitespace stripped), empty when absent.
_slnx_first_line() {
    [ -f "$1" ] || return 0
    head -1 "$1" 2>/dev/null | tr -d '[:space:]'
}

# _slnx_legacy_applies <legacy-marker> <top> <sol-rel> <n> -> rc 0 when the legacy marker speaks for that solution:
# it names exactly that solution, or it names none and the repo has a single solution. [RiskMitigation RA-02]
_slnx_legacy_applies() {
    local marker="$1" top="$2" sol="$3" count="$4" named
    [ -f "$marker" ] || return 1
    named="$(grep -m1 '^solution=' "$marker" 2>/dev/null)"; named="${named#solution=}"
    if [ -z "$named" ]; then
        [ "$count" -eq 1 ]
        return
    fi
    [ "$named" = "$top/$sol" ]
}

slnx_record_sha() {
    local state="$1" top="$2" sol="$3" count="$4" sha legacy
    sha="$(_slnx_first_line "$(slnx_marker_path "$state" "$top" "$sol")")"
    if [ -z "$sha" ]; then
        legacy="$(slnx_legacy_marker_path "$state" "$top")"
        _slnx_legacy_applies "$legacy" "$top" "$sol" "$count" && sha="$(_slnx_first_line "$legacy")"
    fi
    printf '%s' "$sha"
}

slnx_record_matches() {
    local state="$1" top="$2" sol="$3" count="$4" want="$5" legacy
    [ -n "$want" ] || return 1
    [ "$(_slnx_first_line "$(slnx_marker_path "$state" "$top" "$sol")")" = "$want" ] && return 0
    legacy="$(slnx_legacy_marker_path "$state" "$top")"
    _slnx_legacy_applies "$legacy" "$top" "$sol" "$count" && [ "$(_slnx_first_line "$legacy")" = "$want" ]
}

# slnx_affected_by_paths <solutions> <paths>: each path maps to the solution(s) in the closest folder, at or above its
# own, that holds any (two solutions side by side both own that folder; never a guess). An automatically imported
# MSBuild file also maps to every solution in or under its folder (MSBuild walks up from each project and picks it
# up). Pure bash (no subshell per path): solutions are indexed by folder and each distinct folder is resolved once,
# so a push of thousands of files stays fast inside a hook.
slnx_affected_by_paths() {
    local sol path dir base
    local -a sols=() paths=()
    local -A by_dir=() resolved=() affected=()
    # Loaded into arrays (not `while read ... <<<` loops) so a line-coverage tool can measure every line.
    mapfile -t sols <<< "$1"
    mapfile -t paths <<< "$2"
    for sol in "${sols[@]}"; do
        [ -n "$sol" ] || continue
        case "$sol" in */*) dir="${sol%/*}" ;; *) dir="." ;; esac
        by_dir[$dir]+="$sol"$'\n'
    done
    for path in "${paths[@]}"; do
        [ -n "$path" ] || continue
        case "$path" in */*) dir="${path%/*}" ;; *) dir="." ;; esac
        if [ -z "${resolved[$dir]+set}" ]; then
            resolved[$dir]=1
            _slnx_mark_nearest "$dir"
        fi
        base="${path##*/}"; base="${base,,}"
        [[ "$base" =~ $_SLNX_ANCESTOR_IMPORTS_RE ]] || continue
        for sol in "${sols[@]}"; do
            [ -n "$sol" ] || continue
            if [ "$dir" = "." ]; then affected[$sol]=1; continue; fi
            case "$sol" in "$dir"/*) affected[$sol]=1 ;; esac
        done
    done
    [ "${#affected[@]}" -gt 0 ] || return 0
    printf '%s\n' "${!affected[@]}" | LC_ALL=C sort
}

# _slnx_mark_nearest <folder>: walk up from <folder> to the first one holding a solution and mark its solutions.
# Uses the caller's by_dir/affected maps (bash dynamic scope).
_slnx_mark_nearest() {
    local dir="$1" sol
    local -a here=()
    while :; do
        if [ -n "${by_dir[$dir]+set}" ]; then
            mapfile -t here <<< "${by_dir[$dir]%$'\n'}"
            for sol in "${here[@]}"; do affected[$sol]=1; done
            return 0
        fi
        [ "$dir" = "." ] && return 0
        case "$dir" in */*) dir="${dir%/*}" ;; *) dir="." ;; esac
    done
}
