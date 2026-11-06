#!/usr/bin/env bash
# refs-rule.sh -- one branch, one item: the `Refs:` trailers of a branch's commits name one work item, so the file set a
# story's merge request carries is the story's own (the coverage token and the close read that merge request).
#   - On a story branch (`.../story-<N>-...`) every `Refs:` trailer names N: a commit citing another item belongs on that
#     item's own branch.
#   - On a branch whose name names no story, a commit's `Refs:` trailers name only the item the branch's earlier commits
#     already name (its first commit sets it).
# Shared by the commit-message guard (before a commit) and the push guard (every commit of the pushed branch).
# What a `Refs:` footer cites is defined once, in refs-footer.sh (also read by the proof gate, Trunk Reach and the bridge):
# a list of items, a remark after it never read for numbers, `group/project#N` own or foreign by its project path.
# Sourced; needs git-cmd-detect.sh (story_num_from_branch).
# shellcheck source=refs-footer.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/refs-footer.sh" 2>/dev/null

# refs_rule_numbers MESSAGE [OWN] [command] -> the items the `Refs:` footers of MESSAGE cite (refs_footer_cited), one per
# line, sorted, unique: `N` for an item of the story's own project (OWN is its project path), `group/project#N` for
# another project's. With `command` MESSAGE is the text of a `git commit` command line (a `-m` quoted on it).
refs_rule_numbers() {
    refs_footer_cited "${1-}" "${2-}" "${3:-}" | sort -u
}

# _refs_rule_label ITEM -> how a refusal names an item: `#N` for an own item, the project-qualified form for a foreign one.
_refs_rule_label() { case "$1" in *'#'*) printf '%s' "$1" ;; *) printf '#%s' "$1" ;; esac; }

# _refs_rule_labels ITEMS -> the items (one per line) as one space-separated line of labels.
_refs_rule_labels() {
    local item out=""
    while read -r item; do [ -n "$item" ] && out="$out $(_refs_rule_label "$item")"; done <<< "$1"
    printf '%s' "${out# }"
}

# _refs_rule_trunk_base REPO -> the fork point of HEAD from the first trunk found (origin's, then the local one), empty
# when HEAD is on a trunk or none is found.
_refs_rule_trunk_base() {
    local repo="$1" t head mb
    head="$(git -C "$repo" rev-parse --verify -q 'HEAD^{commit}' 2>/dev/null)" || return 0
    for t in origin/develop origin/main origin/master develop main master; do
        git -C "$repo" rev-parse --verify -q "${t}^{commit}" >/dev/null 2>&1 || continue
        mb="$(git -C "$repo" merge-base HEAD "$t" 2>/dev/null)" || continue
        [ "$mb" = "$head" ] && return 0
        printf '%s' "$mb"; return 0
    done
}

# refs_rule_story_answer REPO N -> "story" when item N of REPO's story tracker is a story, "issue" when it is a plain
# issue (with no STORY_BACKEND, as for a local tracker: no story folder, no story), "unknown: <why>" when that cannot be told. A GitLab
# tracker is asked through the bridge (story_get, whose last field says story or issue); a local tracker is the story
# folder Stories/STORY-<N>.
# [CySec] Prevents CWE-636 "Not Failing Securely": an unreadable answer is "unknown", which the caller refuses.
refs_rule_story_answer() {
    local repo="$1" n="$2" cfg backend project reply text
    cfg="$repo/.claude/standards.env"
    command -v standards_env_value >/dev/null 2>&1 || . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/standards-env.sh" 2>/dev/null
    command -v standards_env_value >/dev/null 2>&1 || { echo "unknown: the settings reader (hooks/lib/standards-env.sh) is missing"; return 0; }
    backend="$(standards_env_value "$cfg" STORY_BACKEND)"
    # No STORY_BACKEND line is read like a local tracker: a story folder still names a story, so an undeclared tracker
    # never lets a story's commit pass as a plain issue's.
    case "$backend" in
        gitlab) ;;
        *) if compgen -G "$repo/Stories/STORY-$(printf '%03d' "$n")*" >/dev/null || compgen -G "$repo/Stories/STORY-$n-*" >/dev/null; then echo story; else echo issue; fi
           return 0 ;;
    esac
    project="$(standards_env_value "$cfg" STORY_GITLAB_PROJECT)"
    [ -n "$project" ] || { echo "unknown: the settings declare a GitLab story tracker but no STORY_GITLAB_PROJECT"; return 0; }
    command -v bridge_mcp_call >/dev/null 2>&1 || . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bridge-mcp.sh" 2>/dev/null
    command -v bridge_mcp_call >/dev/null 2>&1 || { echo "unknown: the bridge client (hooks/lib/bridge-mcp.sh) is missing"; return 0; }
    command -v json_test >/dev/null 2>&1 || . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/json-answer.sh" 2>/dev/null
    command -v json_test >/dev/null 2>&1 || { echo "unknown: the JSON reader (hooks/lib/json-answer.sh) is missing"; return 0; }
    reply="$(bridge_mcp_call story_get "$(jq -cn --arg i "$n" --arg p "$project" '{id:$i, project:$p}')" 30)" \
        || { echo "unknown: the bridge could not be reached"; return 0; }
    text="$(bridge_mcp_text "$reply" | tr -d '\r' | head -1)"
    if bridge_mcp_is_error "$reply"; then echo "unknown: the bridge refused story_get: $(printf '%s' "$text" | cut -c1-200)"; return 0; fi
    case "${text##*|}" in
        story) echo story ;;
        issue) echo issue ;;
        *) echo "unknown: the bridge's story_get answer names no story-or-issue field (update the bridge)" ;;
    esac
}

# refs_rule_message_refusal REPO BRANCH MESSAGE [command [FILETEXT]] -> the refusal (one line) when a commit of MESSAGE on
# BRANCH of REPO breaks the rule, nothing otherwise. A message without a `Refs:` trailer is the footer rule's to judge, not
# this one's. With `command` MESSAGE is a `git commit` command line (the commit hook), read as a command; otherwise it is a
# commit message. FILETEXT is the text of a -F message file, always read as a message (a footer starts a line there).
refs_rule_message_refusal() {
    local repo="$1" branch="$2" msg="$3" mode="${4:-}" filetext="${5:-}" story nums n base prior foreign="" own
    own="$(refs_footer_own_project "$repo")"
    nums="$({ refs_rule_numbers "$msg" "$own" "$mode"; [ -z "$filetext" ] || refs_rule_numbers "$filetext" "$own"; } | sort -u)"
    [ -n "$nums" ] || return 0
    story="$(story_num_from_branch "$branch" | sed -E 's/^0*([0-9])/\1/')"
    if [ -n "$story" ]; then
        while read -r n; do [ -n "$n" ] && [ "$n" != "$story" ] && foreign="$foreign $(_refs_rule_label "$n")"; done <<< "$nums"
        [ -z "$foreign" ] || printf "one branch, one item: '%s' is the branch of story %s, so every Refs: trailer must name #%s, but this commit cites%s. Commit that work on its own item's branch (a commit citing another item would make this story's merge request carry another item's change).\n" "$branch" "$story" "$story" "$foreign"
        return 0
    fi
    case "$branch" in ''|HEAD|main|master|develop) return 0 ;; esac
    # Story work goes on its story's branch: a commit on a branch naming no story may cite no story.
    local answer
    while read -r n; do
        [ -n "$n" ] || continue
        # another project's item is no story of this tracker: only the one-item comparison below judges it
        case "$n" in *'#'*) continue ;; esac
        answer="$(refs_rule_story_answer "$repo" "$n")"
        case "$answer" in
            issue) ;;
            story) printf "one branch, one item: #%s is a story, so its work goes on its own story branch (feature/story-%s-<slug>, or hotfix/story-%s-<slug>), not on '%s': there its merge request, which the story's coverage token and close read, carries it.\n" "$n" "$n" "$n" "$branch"; return 0 ;;
            *) printf "one branch, one item: whether #%s is a story cannot be told (%s), so the commit on '%s', a branch naming no story, is refused; retry when the bridge answers, or commit on the item's own story branch.\n" "$n" "${answer#unknown: }" "$branch"; return 0 ;;
        esac
    done <<< "$nums"
    base="$(_refs_rule_trunk_base "$repo")"
    [ -n "$base" ] || return 0
    prior="$(refs_rule_numbers "$(git -C "$repo" log --no-merges --format=%B "$base..HEAD" 2>/dev/null)" "$own")"
    [ -n "$prior" ] || return 0
    while read -r n; do [ -n "$n" ] && ! printf '%s\n' "$prior" | grep -cxF -- "$n" >/dev/null && foreign="$foreign $(_refs_rule_label "$n")"; done <<< "$nums"
    [ -z "$foreign" ] || printf "one branch, one item: the commits of '%s' already cite %s, and this commit cites%s. Commit that work on its own branch (a branch carrying two items' work makes each item's merge request hold the other's change).\n" "$branch" "$(_refs_rule_labels "$prior")" "$foreign"
    return 0
}

# refs_rule_branch_refusal REPO -> the refusal (one line) for the first commit of the checked-out branch (since its fork
# point from a trunk, merges skipped) that breaks the rule, each judged against the commits before it; nothing otherwise.
refs_rule_branch_refusal() {
    local repo="$1" branch base story c msg nums n first="" foreign="" own
    own="$(refs_footer_own_project "$repo")"
    branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null)" || return 0
    case "$branch" in ''|HEAD|main|master|develop) return 0 ;; esac
    base="$(_refs_rule_trunk_base "$repo")"
    [ -n "$base" ] || return 0
    story="$(story_num_from_branch "$branch" | sed -E 's/^0*([0-9])/\1/')"
    while read -r c; do
        [ -n "$c" ] || continue
        msg="$(git -C "$repo" log -1 --format=%B "$c" 2>/dev/null)"
        nums="$(refs_rule_numbers "$msg" "$own")"
        [ -n "$nums" ] || continue
        [ -n "$story" ] && first="$story"
        [ -n "$first" ] || first="$nums"
        foreign=""
        while read -r n; do [ -n "$n" ] && ! printf '%s\n' "$first" | grep -cxF -- "$n" >/dev/null && foreign="$foreign $(_refs_rule_label "$n")"; done <<< "$nums"
        if [ -n "$foreign" ]; then
            printf "one branch, one item: commit %s of '%s' cites%s, but the branch's item is %s. Move that commit to its own item's branch before pushing (a branch carrying two items' work makes each item's merge request hold the other's change).\n" "${c:0:8}" "$branch" "$foreign" "$(_refs_rule_labels "$first")"
            return 0
        fi
        # on a branch naming no story, the item it carries must not be a story (judged once, at its first commit)
        if [ -z "$story" ] && [ -z "${_rr_judged:-}" ]; then
            local _rr_judged=1 _rr_why
            _rr_why="$(refs_rule_message_refusal "$repo" "$branch" "$msg")"
            case "$_rr_why" in *"is a story"*|*"cannot be told"*) printf '%s\n' "$_rr_why"; return 0 ;; esac
        fi
    done < <(git -C "$repo" rev-list --reverse --no-merges "$base..HEAD" 2>/dev/null)
    return 0
}
