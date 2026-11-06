#!/usr/bin/env bash
# story-mirror-git.sh - keep the generated story copies out of git.
#
# Under the gitlab backend the Stories/ tree is a regenerable copy of the issue tracker: BACKLOG.md, every STORY-*/
# folder whose requirements.md carries the GENERATED MIRROR banner, and the .mirror-stale marker. Every refresh
# rewrites them. A repository that TRACKS them is left dirty after each refresh, and a later pull turns that into a
# conflict; a repository that merely does not IGNORE them sees them as leftovers, and a broad `git add` sweeps them
# into an unrelated commit (which is how they end up tracked). So after every mirror write:
#   - an untracked, not-ignored generated copy is listed in the repository's local exclude file (info/exclude): it
#     no longer shows as a leftover and cannot be swept into a commit. No tracked file changes, nothing to commit.
#   - a TRACKED generated copy gets one notice naming the exact fix (stop tracking + the two ignore lines). The tool
#     never rewrites the index itself: untracking is a commit the repository owner makes.
# Hand-written files under Stories/ (no banner: templates, epics, backlog header/footer) are never touched.
# Exempt by design: a companion or trunk-model repository commits its mirror on purpose as bookkeeping (the
# mirror-autocommit hook), unless that autocommit is switched off.
# Default-on; opt out with STORY_MIRROR_GIT_HYGIENE=off. Best-effort: it never fails the story command.

# The banner every generated copy carries in its first lines (BACKLOG.md after the header, requirements.md first).
# Matched at the start of a line only, so a hand-written file that merely mentions the phrase is never a copy. The
# one definition of the banner: the mirror edit guard uses it too. (Extended regex; awk turns the \t into a tab.)
# shellcheck source=../../../hooks/lib/control-switch.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../hooks/lib/control-switch.sh" 2>/dev/null || true   # kyklos_control_off: the one control-switch reader
STORY_MIRROR_BANNER_PATTERN='^[ \t]*<!--[ \t]*GENERATED MIRROR'
# How far into a file the banner may sit (BACKLOG.md places it after the generated header block).
STORY_MIRROR_BANNER_LINES=20
# The marker `story refresh` drops when the tracker was unreachable; regenerable like the copies themselves.
STORY_MIRROR_STALE_MARKER=.mirror-stale

# The single-pass banner scanner (one process for any number of files).
STORY_MIRROR_SCAN_AWK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sm-generated-copies.awk"

# _story_generated_files <file>... -> print each given file that carries the generated-copy banner near its top.
_story_generated_files() {
    [ "$#" -gt 0 ] || return 0
    awk -v lines="$STORY_MIRROR_BANNER_LINES" -v pat="$STORY_MIRROR_BANNER_PATTERN" -f "$STORY_MIRROR_SCAN_AWK" "$@" 2>/dev/null
}

# _story_is_generated_copy <file> -> rc 0 iff the file carries the generated-copy banner near its top.
_story_is_generated_copy() {
    [ -f "$1" ] && [ -n "$(_story_generated_files "$1")" ]
}

# story_path_is_generated_copy <repo-top> <relative path> -> rc 0 iff the path is a generated story copy: a file that
# carries the banner, or any file inside a STORY-*/ folder whose requirements.md carries it (e.g. its tasks.md).
story_path_is_generated_copy() {
    local top="$1" p="$2"
    _story_is_generated_copy "$top/$p" && return 0
    case "/$p" in */STORY-*/*) ;; *) return 1 ;; esac
    _story_is_generated_copy "$top/${p%/*}/requirements.md"
}

# _story_mirror_exempt <repo-top> -> rc 0 iff this repository commits its mirror on purpose (companion or trunk
# model with the mirror autocommit on). The repository's own declared model wins over the session environment.
_story_mirror_exempt() {
    local env="$1/.claude/standards.env" shape="" workflow="" autocommit=""
    if command -v _rr_getkey >/dev/null 2>&1; then
        shape="$(_rr_getkey "$env" KYKLOS_REPO_SHAPE 2>/dev/null)" || shape=""
        workflow="$(_rr_getkey "$env" KYKLOS_SOURCE_WORKFLOW 2>/dev/null)" || workflow=""
        autocommit="$(_rr_getkey "$env" KYKLOS_MIRROR_AUTOCOMMIT 2>/dev/null)" || autocommit=""
    fi
    shape="${shape:-${KYKLOS_REPO_SHAPE:-}}"
    workflow="${workflow:-${KYKLOS_SOURCE_WORKFLOW:-}}"
    autocommit="${autocommit:-${KYKLOS_MIRROR_AUTOCOMMIT:-on}}"
    kyklos_control_off "$autocommit" && return 1
    [ "$shape" = companion ] || [ "$workflow" = trunk ]
}

# _story_exclude_pattern <relative path> [variable] -> an anchored, literal info/exclude pattern for that path (glob
# characters escaped, so a folder name can never widen the pattern to other files). With a variable name the result
# is assigned to it (no subshell per story folder); without one it is printed.
_story_exclude_pattern() {
    local p="$1"
    p="${p//\\/\\\\}"; p="${p//\*/\\*}"; p="${p//\?/\\?}"; p="${p//\[/\\[}"
    if [ -n "${2:-}" ]; then printf -v "$2" '/%s' "$p"; else printf '/%s' "$p"; fi
}

# story_mirror_git_hygiene <storiesdir> -> exclude untracked generated copies, warn once about tracked ones.
# A fixed number of processes whatever the backlog size: one banner scan, one ls-files, one check-ignore.
story_mirror_git_hygiene() {
    local dir="$1" top prefix exclude entry plural verb line
    local files=() candidates=() untracked=() tracked=() missing=()
    local -A tracked_set=() ignored_set=() excluded_set=()
    kyklos_control_off "${STORY_MIRROR_GIT_HYGIENE:-}" && return 0
    [ "${STORY_BACKEND:-local}" = gitlab ] || return 0          # local backend: the files ARE the record
    [ -n "$dir" ] && [ -d "$dir" ] || return 0
    case "$dir" in *$'\n'*|*$'\r'*) return 0 ;; esac             # see the CWE-93 note below
    top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || return 0
    [ -n "$top" ] || return 0                                    # not in a git work tree: nothing to keep clean
    _story_mirror_exempt "$top" && return 0
    prefix="$(git -C "$dir" rev-parse --show-prefix 2>/dev/null)" || return 0

    [ -f "$dir/BACKLOG.md" ] && files+=("$dir/BACKLOG.md")
    # [CySec] CWE-93: a folder name carrying a line break would split the scanner's line output and could write
    # extra lines (any pattern, even a negation) into info/exclude; such a name is never a story the tool generated,
    # so it is left alone before anything reads it.
    for entry in "$dir"/STORY-*/requirements.md; do
        case "$entry" in *$'\n'*|*$'\r'*) continue ;; esac
        [ -f "$entry" ] && files+=("$entry")
    done
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        if [ "$entry" = "$dir/BACKLOG.md" ]; then candidates+=("${prefix}BACKLOG.md")
        else entry="${entry%/requirements.md}"; candidates+=("${prefix}${entry##*/}/"); fi
    done < <(_story_generated_files "${files[@]}")
    [ -f "$dir/$STORY_MIRROR_STALE_MARKER" ] && candidates+=("${prefix}$STORY_MIRROR_STALE_MARKER")
    [ "${#candidates[@]}" -gt 0 ] || return 0

    # Tracked: every tracked file under the stories folder, and the story folder that holds it at any depth
    # (literal pathspec, so a folder name can never act as a glob).
    # NUL-separated: git quotes unusual names (spaces, non-ASCII) in its line output, which would never match.
    while IFS= read -r -d '' line; do
        [ -n "$line" ] || continue
        tracked_set["$line"]=1
        entry="${line#"$prefix"}"
        case "$entry" in */*) tracked_set["$prefix${entry%%/*}/"]=1 ;; esac
    done < <(GIT_LITERAL_PATHSPECS=1 git -C "$top" ls-files -z -- "${prefix:-.}" 2>/dev/null)
    for entry in "${candidates[@]}"; do
        if [ -n "${tracked_set[$entry]:-}" ]; then tracked+=("$entry"); else untracked+=("$entry"); fi
    done

    exclude="$(git -C "$top" rev-parse --git-path info/exclude 2>/dev/null)" || exclude=""
    case "$exclude" in ""|/*) ;; *) exclude="$top/$exclude" ;; esac
    if [ "${#untracked[@]}" -gt 0 ] && [ -n "$exclude" ]; then
        while IFS= read -r -d '' line; do [ -n "$line" ] && ignored_set["$line"]=1; done \
            < <(printf '%s\0' "${untracked[@]}" | git -C "$top" check-ignore -z --stdin 2>/dev/null)
        if [ -f "$exclude" ]; then
            while IFS= read -r line; do excluded_set["$line"]=1; done < "$exclude"
        fi
        for entry in "${untracked[@]}"; do
            [ -n "${ignored_set[$entry]:-}" ] && continue
            _story_exclude_pattern "$entry" line
            [ -n "${excluded_set[$line]:-}" ] || missing+=("$line")
        done
        # One write per line on an append-mode descriptor: a short appended write is atomic, so story commands
        # running at the same time can at worst add a duplicate line, never a torn one.
        if [ "${#missing[@]}" -gt 0 ] && mkdir -p "$(dirname "$exclude")" 2>/dev/null; then
            { for line in "${missing[@]}"; do printf '%s\n' "$line"; done; } >> "$exclude" 2>/dev/null || true
        fi
    fi

    [ "${#tracked[@]}" -gt 0 ] || return 0
    if [ "${#tracked[@]}" -eq 1 ]; then plural=y; verb=is; else plural=ies; verb=are; fi
    printf '[story] WARNING: %s generated story cop%s under %s %s tracked by git in %s. They are regenerated from the issue tracker on every refresh, so they keep this checkout dirty and turn later pulls into conflicts. Stop tracking them in one commit: git -C %s rm -r -q --cached --ignore-unmatch -- '\''%sBACKLOG.md'\'' '\''%sSTORY-*'\'' '\''%s%s'\'' and add these lines to .gitignore: /%sBACKLOG.md and /%sSTORY-*/ (opt out of this check: STORY_MIRROR_GIT_HYGIENE=off).\n' \
        "${#tracked[@]}" "$plural" "${prefix:-./}" "$verb" "$top" "$top" \
        "$prefix" "$prefix" "$prefix" "$STORY_MIRROR_STALE_MARKER" "$prefix" "$prefix" >&2
    return 0
}
