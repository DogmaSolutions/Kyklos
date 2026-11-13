#!/usr/bin/env bash
# repo-facts.sh - THE one collector of a repository's facts for the bridge's one repository resolver (the bridge verb
# project_resolve, and every bridge-side rule that judges the repository a command acts on). It reads only what the
# container alone can read and decides nothing: which project a repository is, which branch is its trunk and whether an
# item may be judged there are the bridge's answers, never this file's.
#
#   repo_facts [--trunk <branch>] <path>...  -> one JSON array on stdout, one object per path, in the order given:
#       path       the path as given
#       top        the repository's canonical top folder ("" when the path is in no repository)
#       origin     the origin address with any credentials, query and fragment removed ("" when none)
#       branch     the checked-out branch ("" when detached or no repository)
#       head       the HEAD commit ("" when none)
#       ahead, behind   the counts against the branch's upstream (null when it has none)
#       declared   the STORY_GITLAB_PROJECT the repository's own .claude/standards.env declares ("" when none)
#       worktree   true when the path is a linked worktree (its git folder is not its common git folder)
#       trunk      only with --trunk: {branch, commit} of the local origin/<branch> ref, else of the local
#                  <branch> ("" when neither exists); the bridge names the branch, this file only reads the ref
#   rc 0 always for readable input; rc 2 for a usage error (no path, or a --trunk that is not a plain branch name).
#
# One command can name two repositories, so several paths are allowed. Each repository's facts are kept for 60 seconds
# per top folder and HEAD (the bridge's trunk cache lifetime) under the session's state folder, so the several rules of
# one command read one set of facts. A repository that moved (a new commit or a checkout) has a new HEAD and is read
# again.
#
# [CySec] Prevents CWE-522 "Insufficiently Protected Credentials" and CWE-532 "Insertion of Sensitive Information into
# Log File": the credentials of an origin address (the user:password or token part of a URL, and its query) are removed
# before the address leaves this file, so they never reach the bridge, a log or the cache.
# [CySec] Prevents CWE-94 "Code Injection": the repository's settings file is PARSED key by key (_rr_getkey), never
# sourced, so a repository the agent merely touches cannot run code in the collector.

_RF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=/dev/null
. "$_RF_DIR/repo-role.sh"

REPO_FACTS_TTL_SECONDS="${REPO_FACTS_TTL_SECONDS:-60}"

# _rf_clean_origin <address> -> the address without credentials, query or fragment.
_rf_clean_origin() {
    local a="$1"
    a="${a%%#*}"; a="${a%%\?*}"
    case "$a" in
        *://*@*)
            local scheme="${a%%://*}" rest="${a#*://}"
            local authority="${rest%%/*}" path=""
            [ "$authority" != "$rest" ] && path="/${rest#*/}"
            # Only the userinfo part of the authority holds credentials; the host and port stay.
            authority="${authority##*@}"
            a="$scheme://$authority$path"
            ;;
    esac
    printf '%s' "$a"
}

# _rf_cache_file <top> <head> -> the cache file of a repository's facts at a commit.
_rf_cache_file() {
    local key
    key="$(printf '%s\n%s' "$1" "$2" | cksum | tr ' ' '-')"
    printf '%s/repo-facts/%s.json' "${KYKLOS_STATE_DIR:-/tmp/kyklos-state}" "$key"
}

# _rf_one <path> <trunk> -> the JSON object of one path.
_rf_one() {
    local path="$1" trunk="$2" top="" origin="" branch="" head="" declared="" worktree=false ahead=null behind=null
    local gitdir common counts trunk_commit="" cache now mtime cached
    if top="$(git -C "$path" rev-parse --show-toplevel 2>/dev/null)" && [ -n "$top" ]; then
        top="$(cd "$top" 2>/dev/null && pwd -P)" || top=""
    fi
    if [ -z "$top" ]; then
        jq -cn --arg p "$path" '{path:$p, top:"", origin:"", branch:"", head:"", ahead:null, behind:null, declared:"", worktree:false}'
        return 0
    fi

    head="$(git -C "$top" rev-parse --verify -q HEAD 2>/dev/null || true)"
    cache="$(_rf_cache_file "$top|$trunk" "$head")"
    if [ -n "$head" ] && [ -f "$cache" ]; then
        now="$(date +%s)"; mtime="$(stat -c %Y "$cache" 2>/dev/null || echo 0)"
        # A cache file that is not one JSON object (cut short, emptied) is not reused: jq fails on it or prints nothing.
        if [ $((now - mtime)) -lt "$REPO_FACTS_TTL_SECONDS" ] \
            && cached="$(jq -c --arg p "$path" 'objects | .path = $p' "$cache" 2>/dev/null)" && [ -n "$cached" ]; then
            printf '%s\n' "$cached"
            return 0
        fi
    fi

    origin="$(_rf_clean_origin "$(git -C "$top" config --get remote.origin.url 2>/dev/null || true)")"
    branch="$(git -C "$top" symbolic-ref -q --short HEAD 2>/dev/null || true)"
    if counts="$(git -C "$top" rev-list --left-right --count 'HEAD...@{upstream}' 2>/dev/null)"; then
        ahead="${counts%%[[:space:]]*}"; behind="${counts##*[[:space:]]}"
    fi
    declared="$(_rr_getkey "$top/.claude/standards.env" STORY_GITLAB_PROJECT 2>/dev/null || true)"
    gitdir="$(git -C "$top" rev-parse --absolute-git-dir 2>/dev/null || true)"
    common="$(cd "$top" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P || true)"
    [ -n "$gitdir" ] && [ -n "$common" ] && [ "$(cd "$gitdir" && pwd -P)" != "$common" ] && worktree=true

    local json
    json="$(jq -cn --arg p "$path" --arg top "$top" --arg origin "$origin" --arg branch "$branch" --arg head "$head" \
        --argjson ahead "$ahead" --argjson behind "$behind" --arg declared "$declared" --argjson worktree "$worktree" \
        '{path:$p, top:$top, origin:$origin, branch:$branch, head:$head, ahead:$ahead, behind:$behind, declared:$declared, worktree:$worktree}')"
    if [ -n "$trunk" ]; then
        trunk_commit="$(git -C "$top" rev-parse --verify -q "refs/remotes/origin/$trunk^{commit}" 2>/dev/null \
            || git -C "$top" rev-parse --verify -q "refs/heads/$trunk^{commit}" 2>/dev/null || true)"
        json="$(printf '%s' "$json" | jq -c --arg b "$trunk" --arg c "$trunk_commit" '.trunk = {branch:$b, commit:$c}')"
    fi

    if [ -n "$head" ] && mkdir -p "$(dirname "$cache")" 2>/dev/null; then
        printf '%s\n' "$json" > "$cache.$$" 2>/dev/null && mv -f "$cache.$$" "$cache" 2>/dev/null
    fi
    printf '%s\n' "$json"
}

repo_facts() {
    local trunk=""
    if [ "${1:-}" = "--trunk" ]; then
        trunk="${2:-}"
        # [CySec] Prevents CWE-88 "Argument Injection": only a plain branch name reaches a git ref.
        case "$trunk" in
            ""|-*|*..*|*[!A-Za-z0-9._/-]*) echo "repo_facts: --trunk needs a plain branch name" >&2; return 2 ;;
        esac
        shift 2
    fi
    [ "$#" -gt 0 ] || { echo "repo_facts: name at least one path" >&2; return 2; }
    local p
    for p in "$@"; do
        _rf_one "$p" "$trunk"
    done | jq -cs .
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
    repo_facts "$@"
fi
