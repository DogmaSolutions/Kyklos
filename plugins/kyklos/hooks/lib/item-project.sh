#!/usr/bin/env bash
# item-project.sh - the project of a repository, as the bridge's one repository resolver answers it. A thin call: the
# facts come from the one collector (repo-facts.sh), the decision from the bridge verb project_resolve; nothing here
# decides which project a repository is.
#
#   item_project_of <dir> [<project hint>]
#       rc 0: prints the canonical numeric GitLab id of the served project the repository at <dir> belongs to
#       rc 1: the bridge answered a code instead (PROJECT-REQUIRED, PROJECT-NOT-SERVED, PROJECT-AMBIGUOUS, ...): prints
#             its message
#       rc 2: no bridge could be asked (none configured, unreachable, or one without the project_resolve verb): prints why
#   The origin address decides; the repository's own STORY_GITLAB_PROJECT goes as the declared hint, and <project hint>
#   (a name, id or path the caller was given) as the project hint, which must agree with the origin.
#
#   item_story_project_of <dir>
#       as item_project_of, for the project that holds the stories of the work in <dir>: the repository's own project
#       when the bridge serves its stories, else (a companion's nested source, whose project serves only pipelines) the
#       one story project the bridge serves; a bridge serving several story projects then answers PROJECT-REQUIRED.
#
# [CySec] Prevents CWE-639 "Authorization Bypass Through User-Controlled Key": the project of an item is the bridge's
# answer for the item's own repository, never the session's settings.

_IP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=/dev/null
. "$_IP_DIR/repo-facts.sh"
# shellcheck source=/dev/null
command -v bridge_mcp_call >/dev/null 2>&1 || . "$_IP_DIR/bridge-mcp.sh"

# _ip_ask <what> <arguments json> -> the project_resolve answer's JSON text (rc 0), or why not (rc 1: a refusal, rc 2:
# no bridge could be asked).
_ip_ask() {
    local what="$1" args="$2" reply rc=0 text
    reply="$(bridge_mcp_call project_resolve "$args" 30)" || rc=$?
    if [ "$rc" -ne 0 ]; then printf 'the bridge could not be asked which project %s is (bridge client rc %s)' "$what" "$rc"; return 2; fi
    text="$(bridge_mcp_text "$reply")"
    if bridge_mcp_is_error "$reply"; then
        case "$text" in
            *"unknown tool"*) printf 'the bridge has no project_resolve verb (update the bridge)'; return 2 ;;
        esac
        printf 'the bridge refused to resolve the project of %s: %s' "$what" "$(printf '%s' "$text" | tr '\n' ' ' | cut -c1-300)"; return 1
    fi
    # An answer that names neither a project nor a code is no answer: the bridge could not say.
    [ -n "$(printf '%s' "$text" | jq -r 'objects | (.code // .project.id // empty) | tostring' 2>/dev/null)" ] \
        || { printf 'the bridge'"'"'s answer about the project of %s could not be read' "$what"; return 2; }
    printf '%s' "$text"
}

# _ip_id <answer json> [stories] -> the answer's project id (rc 0), or its message (rc 1); with "stories", a project the
# bridge does not serve for stories is rc 3.
_ip_id() {
    local text="$1" want="${2:-}" id code stories
    id="$(printf '%s' "$text" | jq -r '.project.id // empty' 2>/dev/null)"
    code="$(printf '%s' "$text" | jq -r '.code // empty' 2>/dev/null)"
    stories="$(printf '%s' "$text" | jq -r '.project.stories // false' 2>/dev/null)"
    case "$id" in
        ''|*[!0-9]*) ;;
        *) if [ -z "$code" ]; then
               if [ "$want" = stories ] && [ "$stories" != true ]; then return 3; fi
               printf '%s' "$id"; return 0
           fi ;;
    esac
    printf '%s' "$(printf '%s' "$text" | jq -r '.message // "the bridge named no project"' 2>/dev/null | tr '\n' ' ' | cut -c1-300)"
    return 1
}

# _ip_args <dir> <hint> -> the repository question of <dir>: purpose item, its origin, its declared project, the hint.
_ip_args() {
    local facts origin declared
    facts="$(repo_facts "$1")" || return 1
    origin="$(printf '%s' "$facts" | jq -r '.[0].origin // ""')"
    declared="$(printf '%s' "$facts" | jq -r '.[0].declared // ""')"
    jq -cn --arg r "$origin" --arg d "$declared" --arg p "${2:-}" \
        '{purpose:"item"} + (if $r == "" then {} else {repository:$r} end) + (if $d == "" then {} else {declared:$d} end) + (if $p == "" then {} else {project:$p} end)'
}

item_project_of() {
    local dir="${1:-.}" hint="${2:-}" args text rc=0
    args="$(_ip_args "$dir" "$hint")" || { printf 'the repository facts of %s could not be read' "$dir"; return 2; }
    text="$(_ip_ask "$dir" "$args")" || { rc=$?; printf '%s' "$text"; return "$rc"; }
    _ip_id "$text"
}

item_story_project_of() {
    local dir="${1:-.}" args text rc=0 out
    args="$(_ip_args "$dir" "")" || { printf 'the repository facts of %s could not be read' "$dir"; return 2; }
    text="$(_ip_ask "$dir" "$args")" || { rc=$?; printf '%s' "$text"; return "$rc"; }
    out="$(_ip_id "$text" stories)"; rc=$?
    [ "$rc" -eq 3 ] || { printf '%s' "$out"; return "$rc"; }
    # The repository's project serves no stories (a companion's nested source): the story project is the bridge's only one.
    text="$(_ip_ask "the stories of $dir" '{"purpose":"item"}')" || { rc=$?; printf '%s' "$text"; return "$rc"; }
    out="$(_ip_id "$text" stories)"; rc=$?
    [ "$rc" -ne 3 ] || { printf 'the bridge answered a project that serves no stories for the stories of %s' "$dir"; return 1; }
    printf '%s' "$out"; return "$rc"
}

# item_trunk_names_of <dir> -> the trunk branch names of the repository at <dir>, one per line, as the bridge names them
# from GitLab (project_resolve with trunk): the integration trunk (develop when GitLab has it) first, then the default
# branch when it differs (rc 0); rc 1 / rc 2 as item_project_of, printing why, and the caller keeps its own rule. Kept per
# repository for the life of the process, so the several reads of one command ask once.
# [CySec] Prevents CWE-345 "Insufficient Verification of Data Authenticity": the trunk is GitLab's, read through the
# bridge, never a local ref such as origin/HEAD that a local command can point anywhere.
item_trunk_names_of() {
    local dir="${1:-.}" args text names rc=0 key
    key="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$dir")"
    if [ "${_IP_TRUNK_KEY:-}" = "$key" ]; then printf '%s' "$_IP_TRUNK_NAMES"; return "$_IP_TRUNK_RC"; fi
    args="$(_ip_args "$dir" "")" || { printf 'the repository facts of %s could not be read' "$dir"; return 2; }
    args="$(printf '%s' "$args" | jq -c '. + {trunk:true}')"
    text="$(_ip_ask "$dir" "$args")" || rc=$?
    if [ "$rc" -eq 0 ]; then
        names="$(printf '%s' "$text" | jq -r '.trunk.branch // empty, .trunk.default_branch // empty' 2>/dev/null | awk 'NF && !seen[$0]++')"
        # [CySec] Prevents CWE-88 "Argument Injection": only plain branch names reach a git ref.
        case "$names" in
            ''|-*|*$'\n'-*|*..*|*[!A-Za-z0-9._/$'\n'-]*) text="the bridge named no usable trunk for $dir"; rc=1 ;;
            *) text="$names" ;;
        esac
    fi
    _IP_TRUNK_KEY="$key"; _IP_TRUNK_NAMES="$text"; _IP_TRUNK_RC="$rc"
    printf '%s' "$text"; return "$rc"
}

# item_trunk_refs_of <dir> -> the remote-tracking refs (refs/remotes/origin/<name>) of the trunks the bridge names for the
# repository at <dir> (item_trunk_names_of) that the clone holds, integration trunk first, one per line (rc 0); rc 1 / 2
# as item_trunk_names_of, and the caller keeps its own rule. A named trunk the clone does not hold yet is left out.
item_trunk_refs_of() {
    local dir="${1:-.}" names n rc=0
    names="$(item_trunk_names_of "$dir")" || { rc=$?; printf '%s' "$names"; return "$rc"; }
    while IFS= read -r n; do
        [ -n "$n" ] || continue
        git -C "$dir" show-ref --verify --quiet "refs/remotes/origin/$n" && printf 'refs/remotes/origin/%s\n' "$n"
    done <<< "$names"
    return 0
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
    item_project_of "$@"
fi
