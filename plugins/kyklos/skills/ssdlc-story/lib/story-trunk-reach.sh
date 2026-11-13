#!/usr/bin/env bash
# story-trunk-reach.sh - Trunk Reach: a story closes only when every commit that names it in a `Refs:` trailer is on
# the trunk. A fix once sat on an unmerged branch for weeks after its story closed, and the bug came back; the close is
# the last point where the stranded commit is still cheap to see.
# Sourced by the story CLI after repo-role.sh (repo_workflow, _rr_getkey) and story-lib.sh (_rt_fetch); defines
# functions only.
#
# Which commits: every commit reachable from a local branch, a remote-tracking branch or the HEAD of any worktree of the
# repository (a worktree made from a remote ref is detached; a fix committed there is still a fix), never tags or the
# stash. The remote is fetched FIRST, so a branch only another clone pushed is seen; a failed fetch refuses.
# Which references count: the one footer definition (hooks/lib/refs-footer.sh, shared with the commit hook, the push
# guard, the proof gate and the bridge): a line starting `Refs:` (any case) whose list holds `#<id>` (leading zeros
# allowed) or this project's own path followed by `#<id>` (the path read from the origin URL). A remark after the list
# is never read for numbers. Not counted: other trailers (Closes, Fixes), a `Refs` line without the colon or indented,
# a bracketed `[#<id>]`, another project's path. The commit-message guard demands `Refs: #<id>`, so those spellings come
# only from hand-written commits.
# Which trunk: derived from the repository model (repo_workflow), never hard-coded. gitflow: origin/develop when it
# exists plus every production trunk that exists (origin/HEAD's target when it names main, master or develop,
# origin/main, origin/master; a hotfix lands there first); trunk-based: the production trunk only (origin/HEAD's target
# when it names one of those, else origin/main, else origin/master).
# An invalid model refuses.
# A commit off the trunk still counts as reached when its change is on the trunk already: the same patch landed
# (rebase or cherry-pick: `git cherry`), or merging it, or a branch tip / worktree HEAD that carries it, into the trunk
# would change nothing (a squash merge; a commit reverted later on its own branch counts as abandoned). A squash merge
# whose lines the trunk changed again afterwards cannot be told apart from an unmerged change: it is refused, and the
# fix is to delete the merged branch (which the branch-cleanup rule asks for anyway).
# Escapes, all of them recorded in git or by the owner, none typed by the closing agent: delete the branch carrying an
# abandoned commit (the usual fix); list the commit in KYKLOS_TRUNK_REACH_ABANDONED, or switch the check off with
# KYKLOS_TRUNK_REACH=off, in the .claude/standards.env COMMITTED ON THE TRUNK (read with git show, so an uncommitted
# edit or an environment value never counts: inside the container the launcher's settings arrive through the same
# process environment an agent can change, so the environment is not a safe source for an escape); or the owner's
# override label (shared by every close gate).
# [CySec] Prevents CWE-636 (not failing securely): unreadable git state, a failed fetch or a judging limit refuses the
# close; it never reads as "nothing stranded". [RiskMitigation RA-01]

# The most branch tips and worktree HEADs one close merges into the trunk to judge squash merges. Past it the commit is
# refused as not judged (never passed), naming the limit. [RiskMitigation RA-04]
# shellcheck source=../../../hooks/lib/control-switch.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../hooks/lib/control-switch.sh" 2>/dev/null || true   # kyklos_control_off: the one control-switch reader
# shellcheck source=../../../hooks/lib/refs-footer.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../hooks/lib/refs-footer.sh" 2>/dev/null || true   # REFS_FOOTER_AWK: the one footer definition
TRUNK_REACH_PROBE_LIMIT=40

# _tr_has_origin <repo> -> 0 when the repository has an origin remote.
_tr_has_origin() { git -C "$1" remote get-url origin >/dev/null 2>&1; }

# _tr_sync <repo> -> fetch origin (Remote Truth's _rt_fetch); print a refusal sentence when the fetch fails. A
# repository without an origin has nothing to fetch.
# [RiskMitigation RA-05] The fetch goes through the shared fetch helper, which puts no credential on the command line.
_tr_sync() {
    _tr_has_origin "$1" || return 0
    _rt_fetch "$1" || printf 'cannot fetch origin of %s, so a branch only the remote holds could be missed; retry when the remote answers' "$1"
}

# _tr_committed_setting <repo> <trunk-ref> <KEY> -> the value of KEY in .claude/standards.env as COMMITTED on the
# trunk (parsed with _rr_getkey, never sourced); empty when the file or the key is absent. [RiskMitigation RA-02]
_tr_committed_setting() {
    local repo="$1" trunk="$2" key="$3" tmp v=""
    [ -n "$trunk" ] || return 0
    tmp="$(mktemp)" || return 0
    if git -C "$repo" show "$trunk:.claude/standards.env" > "$tmp" 2>/dev/null; then
        v="$(_rr_getkey "$tmp" "$key" 2>/dev/null || true)"
    fi
    rm -f "$tmp"
    printf '%s' "$v"
}

# _tr_url_location <url> -> "<host>/<path>" of a remote URL without scheme, credentials or .git, lower case
# (scheme://[credentials@]host/path, user@host:path; a plain path stays a path).
_tr_url_location() {
    local url="$1"
    url="${url%/}"; url="${url%.git}"
    case "$url" in
        *://*) url="${url#*://}"; case "${url%%/*}" in *@*) url="${url#*@}" ;; esac ;;
        *@*:*) url="${url#*@}"; url="${url%%:*}/${url#*:}" ;;
    esac
    printf '%s' "$url" | tr '[:upper:]' '[:lower:]'
}

# _tr_project_path <repo> -> the project path of origin (group/[sub/]project, lower case: the location without its
# host), empty when unknown.
_tr_project_path() {
    local url loc
    url="$(git -C "$1" config --get remote.origin.url 2>/dev/null)" || return 0
    loc="$(_tr_url_location "$url")"
    case "$url" in *://*|*@*:*) printf '%s' "${loc#*/}" ;; esac
}

# _tr_origin_problem <repo> [rewrite-only] -> a refusal sentence when the origin a close judges against is not the story's project:
# a URL rewritten by an insteadOf rule (the configured and the effective URL differ), or, when the story backend names
# its project (backend_project_location), an origin at another host or path. An agent could otherwise point origin at
# a copy whose trunk already holds the stranded commit. [RiskMitigation RA-07]
_tr_origin_problem() {
    local repo="$1" rewrite_only="${2:-}" raw eff want got
    raw="$(git -C "$repo" config --get remote.origin.url 2>/dev/null)" || return 0
    eff="$(git -C "$repo" remote get-url origin 2>/dev/null)" || { printf 'cannot read the origin of %s' "$repo"; return 0; }
    [ "$raw" = "$eff" ] || { printf 'the origin of %s is rewritten by an insteadOf rule (%s becomes %s); remove the rule and retry' "$repo" "$(_tr_url_location "$raw")" "$(_tr_url_location "$eff")"; return 0; }
    [ -z "$rewrite_only" ] && command -v backend_project_location >/dev/null 2>&1 || return 0
    want="$(backend_project_location)" || { printf 'cannot read the story project'"'"'s address from the tracker, so the origin of %s cannot be checked; retry when it answers' "$repo"; return 0; }
    got="$(_tr_url_location "$eff")"
    [ "$got" = "$want" ] || printf 'the origin of %s is %s, not the story project %s; point origin at the project (git remote set-url origin <its clone URL>) and retry' "$repo" "$got" "$want"
}

# _tr_production_trunk <repo> -> the production trunk ref (refs/remotes/...), rc 1 when there is none: origin/HEAD's
# target only when it names a trunk branch (main, master or develop), else origin/main, else origin/master. origin/HEAD
# is a local ref (git remote set-head changes it), so it may choose among the trunk names, never make any other branch
# a trunk. [RiskMitigation RA-07]
_tr_production_trunk() {
    local repo="$1" def ref
    def="$(git -C "$repo" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null || true)"
    case "$def" in
        refs/remotes/origin/main|refs/remotes/origin/master|refs/remotes/origin/develop)
            git -C "$repo" rev-parse --verify -q "$def^{commit}" >/dev/null 2>&1 && { printf '%s' "$def"; return 0; } ;;
    esac
    for ref in main master; do
        git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$ref" && { printf 'refs/remotes/origin/%s' "$ref"; return 0; }
    done
    return 1
}

# trunk_reach_trunks <repo> -> the trunk refs for <repo>, one per line, the integration trunk first; rc 1 with the
# reason on stdout when the model is invalid or no trunk exists. The trunks are the ones the bridge names from GitLab
# (item_trunk_refs_of: develop when GitLab has it, then the default branch; a trunk-based repository uses the default
# branch alone); only when no bridge can say does the local rule below choose among the usual names.
trunk_reach_trunks() {
    local repo="$1" wf prod ref named
    wf="$(repo_workflow "$repo" 2>/dev/null)" || wf="__INVALID__"
    case "$wf" in
        gitflow|agent-readonly|trunk) ;;
        *) printf 'the repository model of %s is invalid (%s), so its trunk cannot be named' "$repo" "${wf:-unreadable}"; return 1 ;;
    esac
    if command -v item_trunk_refs_of >/dev/null 2>&1 && named="$(item_trunk_refs_of "$repo")"; then
        named="$(printf '%s\n' "$named" | sed '/^$/d')"
        [ -n "$named" ] || { printf 'the trunks GitLab names for %s are not in its clone yet (git fetch origin, then retry)' "$repo"; return 1; }
        if [ "$wf" = trunk ]; then printf '%s\n' "$named" | tail -n 1; else printf '%s\n' "$named"; fi
        return 0
    fi
    prod="$(_tr_production_trunk "$repo")" || { printf '%s has no remote trunk (origin/HEAD, origin/main or origin/master)' "$repo"; return 1; }
    if [ "$wf" = trunk ]; then printf '%s\n' "$prod"; return 0; fi
    # GitFlow: develop first (the integration trunk the squash check merges into), then every production trunk that
    # exists: origin/HEAD may name develop when it is the default branch, and a hotfix lands on main before develop.
    { git -C "$repo" show-ref --verify --quiet refs/remotes/origin/develop && printf 'refs/remotes/origin/develop\n'
      printf '%s\n' "$prod"
      for ref in main master; do
          git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$ref" && printf 'refs/remotes/origin/%s\n' "$ref"
      done
      true; } | awk '!seen[$0]++'   # a missing optional trunk must not become the status (callers may set pipefail)
}

# _tr_worktree_heads <repo> -> "<sha> <path>" for every worktree of the repository whose HEAD is detached (a worktree on
# a branch is walked through the branch already). A worktree whose folder is gone still counts (its commit would
# otherwise be lost silently); its line says to run git worktree prune.
_tr_worktree_heads() {
    git -C "$1" worktree list --porcelain 2>/dev/null | awk '
        function emit() { if (head != "" && detached) print head, path (gone ? " (its folder is gone: run git worktree prune)" : "") }
        /^worktree / { emit(); path = substr($0, 10); head = ""; detached = 0; gone = 0; next }
        /^HEAD /     { head = $2; next }
        /^detached/  { detached = 1; next }
        /^prunable/  { gone = 1; next }
        END          { emit() }'
}

# trunk_reach_refs_commits <repo> <id> <project-path> <trunk-ref>... -> the commits on a local or remote branch or a
# detached worktree HEAD, but on none of the trunks, whose message has a `Refs:` line naming <id>; one sha per line.
# rc 1 when git cannot answer.
trunk_reach_refs_commits() {
    local repo="$1" id="$2" proj="$3"; shift 3
    local -a revs=(--branches --remotes); local t sha path
    while read -r sha path; do [ -n "$sha" ] && revs+=("$sha"); done < <(_tr_worktree_heads "$repo")
    for t in "$@"; do revs+=("^$t"); done
    # git narrows the walk to messages holding "#" and the number (cheap); awk then demands an exact Refs token.
    # The awk judges each footer line by the one footer definition (hooks/lib/refs-footer.sh: a list of items, a remark
    # never read for numbers, `group/project#N` the story's own only when the path is <project-path>).
    git -C "$repo" log "${revs[@]}" --extended-regexp --grep="#0*$id([^0-9]|$)" --format='%H%x1f%B%x1e' 2>/dev/null \
        | awk -v id="$id" -v proj="$proj" "${REFS_FOOTER_AWK:-}"'BEGIN { RS = "\x1e"; FS = "\x1f" }
            NF >= 2 {
                sha = $1; gsub(/[[:space:]]/, "", sha); n = split($2, lines, "\n")
                for (i = 1; i <= n; i++) if (refs_footer_cites_line(lines[i], proj, id, 0)) { print sha; break }
            }'
    local -a status=("${PIPESTATUS[@]}")
    # [CySec] CWE-636: a footer reader that did not load or run (awk status other than 0) is "git cannot answer", which
    # refuses the close; it never reads as "nothing stranded".
    [ "${status[1]:-1}" = 0 ] || return 1
    return "${status[0]}"
}

# _tr_merges_to_trunk <repo> <rev> <trunk-ref> -> 0 when merging <rev> into the trunk yields the trunk's own tree.
_tr_merges_to_trunk() {
    local tree
    tree="$(git -C "$1" merge-tree --write-tree "$3" "$2" 2>/dev/null | head -1)"
    [ -n "$tree" ] && [ "$tree" = "$(git -C "$1" rev-parse "$3^{tree}" 2>/dev/null)" ]
}

# _tr_probe <repo> <rev> <trunk-ref> -> as _tr_merges_to_trunk, counted against TRUNK_REACH_PROBE_LIMIT; rc 2 (and
# _TR_LIMITED=1) once the limit is spent, so the caller refuses instead of passing.
_tr_probe() {
    if [ "$_TR_PROBES" -ge "$TRUNK_REACH_PROBE_LIMIT" ]; then _TR_LIMITED=1; return 2; fi
    _TR_PROBES=$((_TR_PROBES + 1))
    _tr_merges_to_trunk "$@"
}

# _tr_change_on_trunk <repo> <sha> <trunk-ref> -> 0 when the commit's change is on the trunk already: the same patch
# landed (git cherry marks it "-": a rebase or cherry-pick), or a branch tip or detached worktree HEAD that carries it
# merges into the trunk without changing anything (a squash merge; judged once per tip, cached in _TR_TIP_VERDICT,
# since every git call is costly on a slow file system), or merging the commit alone changes nothing. Sets
# _TR_BRANCHES to what carries the commit, for the refusal message. rc 2 when the probe limit stopped the judging.
_tr_change_on_trunk() {
    local repo="$1" sha="$2" trunk="$3" mark tip name verdict rc
    _TR_BRANCHES=""
    mark="$(git -C "$repo" cherry "$trunk" "$sha" "$sha^" 2>/dev/null | awk '{print $1; exit}')"
    while read -r tip name; do
        [ -n "$tip" ] || continue
        case "$name" in */HEAD) continue ;; esac
        _TR_BRANCHES="$_TR_BRANCHES${_TR_BRANCHES:+, }$name"
        [ "$mark" = "-" ] && continue
        verdict="${_TR_TIP_VERDICT[$tip]:-}"
        if [ -z "$verdict" ]; then
            _tr_probe "$repo" "$tip" "$trunk"; rc=$?
            [ "$rc" -eq 2 ] && return 2
            if [ "$rc" -eq 0 ]; then verdict=reached; else verdict=open; fi
            _TR_TIP_VERDICT[$tip]="$verdict"
        fi
        [ "$verdict" = reached ] && return 0
    done < <(git -C "$repo" for-each-ref --contains "$sha" --format='%(objectname) %(refname:short)' refs/heads refs/remotes 2>/dev/null
             _tr_worktree_heads "$repo" | while read -r tip name; do
                 git -C "$repo" merge-base --is-ancestor "$sha" "$tip" 2>/dev/null && printf '%s detached HEAD at %s\n' "$tip" "$name"
             done)
    [ "$mark" = "-" ] && return 0
    _tr_probe "$repo" "$sha" "$trunk"
}

# _tr_abandoned <list> <sha> -> 0 when the KYKLOS_TRUNK_REACH_ABANDONED list names the commit (a prefix of at least 7
# characters). The list is split without pathname expansion.
_tr_abandoned() {
    local list="$1" sha="$2" a
    local -a items=()
    IFS=$' ,\t' read -r -a items <<< "$list"
    for a in "${items[@]}"; do
        [ "${#a}" -ge 7 ] || continue
        case "$sha" in "$a"*) return 0 ;; esac
    done
    return 1
}

# trunk_reach_repo_problem <repo> <id> [<abandoned list>] [synced] -> one refusal sentence for <repo>, or nothing when
# every Refs commit of the story is on the trunk. Fetches origin first unless the caller already did ("synced").
trunk_reach_repo_problem() {
    local repo="$1" id="$2" abandoned="${3:-}" synced="${4:-}" trunks shas sha stranded="" n=0 integ proj p rc
    local -A _TR_TIP_VERDICT=()
    local _TR_BRANCHES="" _TR_PROBES=0 _TR_LIMITED=0
    if ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
        # A folder that is no repository holds no commit that could be stranded; a broken repository refuses.
        [ -e "$repo/.git" ] && printf 'cannot read the git repository %s' "$repo"
        return 0
    fi
    if [ -z "$synced" ]; then
        p="$(_tr_origin_problem "$repo" rewrite-only)"; [ -n "$p" ] && { printf '%s' "$p"; return 0; }
        p="$(_tr_sync "$repo")"; [ -n "$p" ] && { printf '%s' "$p"; return 0; }
    fi
    proj="$(_tr_project_path "$repo")"
    if ! trunks="$(trunk_reach_trunks "$repo")"; then
        # No trunk to judge against: only a story some commit names needs one.
        shas="$(trunk_reach_refs_commits "$repo" "$id" "$proj")" || { printf 'git could not list the commits of %s' "$repo"; return 0; }
        [ -n "$shas" ] && printf '%s' "$trunks"
        return 0
    fi
    integ="$(printf '%s\n' "$trunks" | head -1)"
    # One walk, trunk-reachable history excluded (the trunk is the fetched origin, checked above).
    # shellcheck disable=SC2086
    shas="$(trunk_reach_refs_commits "$repo" "$id" "$proj" $trunks)" || { printf 'git could not list the commits of %s' "$repo"; return 0; }
    [ -n "$shas" ] || return 0
    # The refusal is certain at the first stranded commit; judging stops after five (each judgement costs several git
    # calls), and the count then reads "at least". [RiskMitigation RA-04]
    local judged=0 total more=""
    total="$(printf '%s\n' "$shas" | grep -c .)"
    while IFS= read -r sha; do
        [ -n "$sha" ] || continue
        judged=$((judged + 1))
        _tr_abandoned "$abandoned" "$sha" && continue
        _tr_change_on_trunk "$repo" "$sha" "$integ"; rc=$?
        [ "$rc" -eq 0 ] && continue
        n=$((n + 1))
        if [ "$rc" -eq 2 ]; then
            stranded="$stranded${stranded:+; }${sha:0:8} (not judged: more than $TRUNK_REACH_PROBE_LIMIT branch tips to merge-check; delete branches that are already merged)"
        else
            stranded="$stranded${stranded:+; }${sha:0:8} (on ${_TR_BRANCHES:-no branch})"
        fi
        [ "$n" -ge 5 ] || [ "$_TR_LIMITED" = 1 ] && break
    done <<< "$shas"
    [ "$n" -eq 0 ] && return 0
    [ "$judged" -lt "$total" ] && more="at least "
    printf '%s%s commit(s) naming #%s are not on the trunk (%s) of %s: %s. Merge each into the trunk, or, if it was abandoned, delete the branch that carries it (or list the commit in KYKLOS_TRUNK_REACH_ABANDONED in .claude/standards.env, committed on the trunk)' \
        "$more" "$n" "$id" "${integ#refs/remotes/}" "$repo" "$stranded"
}

# story_trunk_reach_problem <workspace-root> <story-handle-or-id> -> one refusal line, or nothing. Checks the workspace
# repository and, in a companion, its nested source repository. Runs with every environment variable that redirects
# git (an injected config, another repository or object store) removed, so the close judges the repository on disk
# against its real origin. [RiskMitigation RA-07]
story_trunk_reach_problem() {
    local out rc
    out="$(
        for v in $(compgen -e); do
            case "$v" in GIT_CONFIG*|GIT_DIR|GIT_WORK_TREE|GIT_COMMON_DIR|GIT_INDEX_FILE|GIT_OBJECT_DIRECTORY|GIT_ALTERNATE_OBJECT_DIRECTORIES|GIT_NAMESPACE|GIT_CEILING_DIRECTORIES|GIT_REPLACE_REF_BASE|GIT_NO_REPLACE_OBJECTS|GIT_GRAFT_FILE) unset "$v" ;; esac
        done
        _tr_story_problem "$@"
    )"; rc=$?
    # A check that dies (an unset variable, a killed git) prints nothing, which would read as "nothing stranded":
    # an abnormal exit refuses instead. [RiskMitigation RA-01]
    if [ "$rc" -ne 0 ] && [ -z "$out" ]; then out="Trunk Reach: the check stopped with exit status $rc before it could judge the story; retry, and report it if it repeats"; fi
    printf '%s' "$out"
}

# _tr_story_problem <workspace-root> <story-handle-or-id> -> the body of story_trunk_reach_problem. The opt-out, the
# abandoned list and the nested source directory come only from the workspace repository's .claude/standards.env as
# committed on its integration trunk.
_tr_story_problem() {
    local root="$1" ref="$2" id srcdir="" p out="" abandoned="" trunk="" src="" extra=""
    # A tracker handle ends in the issue number; a local one is STORY-<number>-<slug>.
    id="$(basename "$ref")"; id="${id#STORY-}"; id="${id#\#}"; id="${id%%-*}"
    id="$(printf '%s' "$id" | sed 's/^0*//')"
    case "$id" in ''|*[!0-9]*) printf 'Trunk Reach: cannot read a story number from %s' "$ref"; return 0 ;; esac
    if git -C "$root" rev-parse --git-dir >/dev/null 2>&1 && _tr_has_origin "$root"; then
        p="$(_tr_origin_problem "$root")"; [ -n "$p" ] && { printf 'Trunk Reach: %s' "$p"; return 0; }
        p="$(_tr_sync "$root")"; [ -n "$p" ] && { printf 'Trunk Reach: %s' "$p"; return 0; }
        trunk="$(trunk_reach_trunks "$root" 2>/dev/null | head -1)" || trunk=""
        kyklos_control_off "$(_tr_committed_setting "$root" "$trunk" KYKLOS_TRUNK_REACH)" && return 0
        abandoned="$(_tr_committed_setting "$root" "$trunk" KYKLOS_TRUNK_REACH_ABANDONED)"
        srcdir="$(_tr_committed_setting "$root" "$trunk" KYKLOS_SOURCE_DIR)"
    fi
    p="$(trunk_reach_repo_problem "$root" "$id" "$abandoned" synced)"
    [ -n "$p" ] && out="$p"
    # The nested source the trunk declares must be there; a source named only by the working tree or the environment is
    # checked too when it exists (one more check can only refuse, never pass).
    if [ -n "$srcdir" ]; then
        case "$srcdir" in /*|*..*) out="$out${out:+; }the nested source directory '$srcdir' declared on the trunk is not a folder inside $root" ;;
            *) if [ -d "$root/$srcdir" ] && git -C "$root/$srcdir" rev-parse --git-dir >/dev/null 2>&1; then
                   p="$(trunk_reach_repo_problem "$root/$srcdir" "$id" "$abandoned")"; [ -n "$p" ] && out="$out${out:+; }$p"
               else
                   out="$out${out:+; }the nested source '$srcdir' declared on the trunk is missing or not a git repository in $root, so its commits cannot be checked"
               fi ;;
        esac
    fi
    for extra in "$(_rr_getkey "$root/.claude/standards.env" KYKLOS_SOURCE_DIR 2>/dev/null || true)" "${KYKLOS_SOURCE_DIR:-}"; do
        [ -n "$extra" ] && [ "$extra" != "$srcdir" ] || continue
        case "$extra" in /*|*..*) continue ;; esac
        src="$root/$extra"
        [ -d "$src" ] && git -C "$src" rev-parse --git-dir >/dev/null 2>&1 || continue
        p="$(trunk_reach_repo_problem "$src" "$id" "$abandoned")"; [ -n "$p" ] && out="$out${out:+; }$p"
        srcdir="$extra"
    done
    [ -n "$out" ] && printf 'Trunk Reach: %s' "$out"
    return 0
}
