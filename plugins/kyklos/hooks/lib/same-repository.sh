#!/usr/bin/env bash
# same-repository.sh - THE single answer to "is this working tree the SAME repository as that one?". Sourced by the
# code that exempts the session's own project (kyklos-public-source-refs-guard.sh, lib/repo-role.sh, lib/fyi.sh); no
# guard compares two
# repositories by their toplevel folder inline, because a linked worktree or a second clone of the SAME repository
# has a different toplevel and would be misread as a foreign repository.
#
# Two working trees are the same repository when:
#   1. they share one git store (a linked worktree: the same `--git-common-dir`), OR
#   2. they are separate clones whose remotes all point at the session repository: every remote URL of the
#      candidate, normalised, is one of the session repository's normalised remote URLs (a non-empty subset).
#      A candidate with an extra remote elsewhere (for example a public mirror) is NOT the same repository, and a
#      look-alike name or path never matches, because URLs compare whole, never by pattern.
#
# [CySec] Prevents CWE-200 (exposure of internal information): a repository is only exempted from the internal-marker
# block when its identity is PROVEN equal to the session repository; a clone that can push anywhere else stays covered.
# [RiskMitigation RA-03]

# same_repository_remote_parts <url> -> "host<TAB>path" of a network remote URL, original case: scheme, user and
# password, port, and a trailing ".git" or "/" removed; scp style "[user@]host:path" read as host and path. A local
# path or an empty input prints nothing.
# [CySec] CWE-200: a user:token@ prefix is cut before anything is printed, so no credential can leave this function.
same_repository_remote_parts() {
    local u="${1:-}" host path=""
    [ -n "$u" ] || return 0
    u="${u%%[[:space:]]*}"
    case "$u" in
        *://*)
            u="${u#*://}"
            host="${u%%/*}"
            [ "$host" = "$u" ] || path="${u#*/}"
            host="${host##*@}"                   # drop user[:password]@
            host="${host%%:*}" ;;                # drop a port
        [A-Za-z]:[\\/]*|/*|./*|../*) return 0 ;; # a local path is not a network remote
        *:*)                                     # scp style: [user@]host:path
            host="${u%%:*}"; path="${u#*:}"
            host="${host##*@}" ;;
        *) return 0 ;;
    esac
    path="${path%/}"; path="${path%.git}"; path="${path%/}"
    [ -n "$host" ] && [ -n "$path" ] || return 0
    printf '%s\t%s' "$host" "$path"
}

# same_repository_remote_path <url> -> the project path of a network remote URL ("group/sub/project"), original
# case, never a host or credential. Empty for a local path.
same_repository_remote_path() {
    local parts; parts="$(same_repository_remote_parts "${1:-}")"
    [ -n "$parts" ] && printf '%s' "${parts#*$'\t'}"
}

# same_repository_remote_key <url> -> the comparison key of a network remote URL: "host/path" in lower case.
same_repository_remote_key() {
    local parts; parts="$(same_repository_remote_parts "${1:-}")"
    [ -n "$parts" ] || return 0
    printf '%s/%s' "${parts%%$'\t'*}" "${parts#*$'\t'}" | tr '[:upper:]' '[:lower:]'
}

# _same_repository_store <dir> -> the absolute git store shared by every worktree of <dir>'s repository.
_same_repository_store() {
    git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true
}

# _same_repository_remote_keys <dir> -> one key per remote URL (fetch and push), sorted, unique: "host/path" for a
# network remote, "store:<absolute git store>" for a remote that is a local repository path. A local remote that is
# not a readable repository yields no key, so it can never stand in for the session repository.
_same_repository_remote_keys() {
    local d="$1" url store
    git -C "$d" config --get-regexp '^remote\..*\.(url|pushurl)$' 2>/dev/null | while read -r _ url; do
        case "$url" in
            file://*) url="${url#file://}" ;&
            /*|./*|../*|[A-Za-z]:[\\/]*)
                case "$url" in /*|[A-Za-z]:[\\/]*) : ;; *) url="$d/$url" ;; esac
                store="$(_same_repository_store "$url")"
                [ -n "$store" ] && printf 'store:%s\n' "$store" ;;
            *) same_repository_remote_key "$url"; printf '\n' ;;
        esac
    done | grep -v '^$' | sort -u
}

# same_repository <candidate dir> <session dir> -> 0 iff both are working trees of the same repository (see above).
same_repository() {
    local a="${1:-}" b="${2:-}" ca cb ka kb
    { [ -n "$a" ] && [ -n "$b" ]; } || return 1
    ca="$(_same_repository_store "$a")"
    cb="$(_same_repository_store "$b")"
    { [ -n "$ca" ] && [ -n "$cb" ]; } || return 1
    [ "$ca" = "$cb" ] && return 0
    ka="$(_same_repository_remote_keys "$a")"
    # The session repository is also known by its own store, so a clone made from its local path is recognised.
    kb="$( { _same_repository_remote_keys "$b"; printf 'store:%s\n' "$cb"; } | sort -u)"
    [ -n "$ka" ] || return 1
    [ -z "$(comm -23 <(printf '%s\n' "$ka") <(printf '%s\n' "$kb"))" ]
}
