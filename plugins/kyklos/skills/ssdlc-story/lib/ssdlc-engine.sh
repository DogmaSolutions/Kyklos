#!/usr/bin/env bash
# ssdlc-engine.sh -- the per-project switch between the bash story mechanics and the bridge's C# story stack.
# Source it after story-lib.sh and the backend; it defines functions only.
#
# The MODE is host configuration, read from the bridge (verb ssdlc_mode), never from the container. It is per GitLab
# project: the bridge's story stack serves the projects its host settings list (one, or several for a session that
# develops several projects), answers 'off' for any other, and refuses a verb for a project it does not serve. A backend other than GitLab is always off. Every routed verb names the project it is for:
#   off    - the bridge has no story stack (it answers "unknown tool"): the bash mechanics only.
#   shadow - the bash mechanics stay authoritative. For each routed operation the C# verb runs FIRST on the
#            unchanged story (the bridge drops its saves), then bash runs, then both outcomes are compared and the
#            comparison is appended to the shadow report ($KYKLOS_STATE_DIR/ssdlc-shadow.jsonl).
#   on     - the routed operations go to the C# verbs; bash does not decide or write them.
# Routed operations: new, adopt, requirements (spec authoring), structure, kind, track-finding, set status=..., set of
# header fields, phase, resume, close, parent, the proof read and writes (--set, --apply, --write), the risk-register
# write (ra --apply), the proof draft (proof --draft, mode 'on' only: the bridge alone holds the evidence), epic set and archive (and the epic desk: list, show, close, reopen, delete, which outside mode 'on' run in bash), reopen-root-cause (mode 'on' only: it has no dry run), and block (mode 'on' only: the bridge alone
# records a blocker). Anything else
# stays bash; its reads go through the bridge's story_read verb when the container has no GitLab token of its own.

# Each library below must load completely or this one fails to load too (require-lib.sh explains why).
# shellcheck source=../../../hooks/lib/require-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../../hooks/lib/require-lib.sh" || return 1
# shellcheck source=../../../hooks/lib/bridge-mcp.sh
require_lib "$(dirname "${BASH_SOURCE[0]}")/../../../hooks/lib/bridge-mcp.sh" || return 1
require_lib "$(dirname "${BASH_SOURCE[0]}")/../../../hooks/lib/json-answer.sh" json_test json_read || return 1

_SSDLC_MODE=""

ssdlc_state_dir() { printf '%s' "${KYKLOS_STATE_DIR:-/tmp/kyklos-state}"; }

ssdlc_report_file() { printf '%s/ssdlc-shadow.jsonl' "$(ssdlc_state_dir)"; }

# ssdlc_project -> the GitLab project the story tool reads and writes; empty for any other backend.
ssdlc_project() {
    [ "${STORY_BACKEND:-local}" = gitlab ] || return 0
    printf '%s' "${_GL_PID:-${STORY_GITLAB_PROJECT:-}}"
}

# The last mode the bridge reported for this project, remembered so a bridge that is 'on' and then unreachable fails
# loud instead of silently falling back to bash. One file per project: another project's mode never decides this one.
ssdlc_last_mode_file() {
    printf '%s/ssdlc-mode.%s.last' "$(ssdlc_state_dir)" "$(ssdlc_project | tr -c 'A-Za-z0-9._-' '_')"
}

# ssdlc_engine_mode -> off|shadow|on for this project. A reply other than shadow/on (unknown tool, no stack, another
# project) is off. An unreachable bridge is off unless the last known mode for this project was on, in which case it
# prints 'unreachable' and returns 1.
ssdlc_engine_mode() {
    if [ -n "$_SSDLC_MODE" ]; then printf '%s' "$_SSDLC_MODE"; return 0; fi
    local resp text rc project
    project="$(ssdlc_project)"
    if [ -z "$project" ]; then _SSDLC_MODE="off"; printf 'off'; return 0; fi
    # A sealed test shell (a stubbed tracker) never routes to a bridge it did not start: the stub is what the test
    # exercises, and the live bridge would write the real tracker. Neither the live session's last-known mode is read
    # nor a mode recorded for it.
    if bridge_mcp_sealed && ! bridge_mcp_endpoint >/dev/null 2>&1; then _SSDLC_MODE="off"; printf 'off'; return 0; fi
    resp="$(bridge_mcp_call ssdlc_mode "$(jq -cn --arg p "$project" '{project:$p}')" 30)"; rc=$?
    if [ "$rc" -ne 0 ]; then
        if [ -f "$(ssdlc_last_mode_file)" ] && [ "$(cat "$(ssdlc_last_mode_file)" 2>/dev/null)" = "on" ]; then
            printf 'unreachable'
            return 1
        fi
        _SSDLC_MODE="off"; printf 'off'; return 0
    fi
    # Only a reply naming THIS project ('on 5') routes: a bridge whose reply carries no project cannot tell projects
    # apart, and would resolve the issue number in its own project.
    text="$(bridge_mcp_text "$resp")"
    case "$text" in
        "shadow $project"|"on $project") _SSDLC_MODE="${text%% *}" ;;
        *) _SSDLC_MODE="off" ;;
    esac
    bridge_mcp_sealed || { mkdir -p "$(ssdlc_state_dir)" 2>/dev/null && printf '%s' "$_SSDLC_MODE" > "$(ssdlc_last_mode_file)" 2>/dev/null; }
    printf '%s' "$_SSDLC_MODE"
}

# ssdlc_story_key <ref> -> the bare issue number the C# stack loads by (a zero-padded story folder id, or a bare
# number, both give the number).
ssdlc_story_key() {
    local r="$1"
    r="${r#STORY-}"; r="${r#story-}"
    r="${r%%-*}"
    r="$(printf '%s' "$r" | sed 's/^0*//')"
    printf '%s' "${r:-0}"
}

# ssdlc_cs_status <bash status> -> the C# StoryStatus name (empty when there is none, e.g. Done is a close).
ssdlc_cs_status() {
    case "$(story_normalize_status "$1")" in
        Todo) printf 'ToDo' ;;
        In-progress) printf 'Doing' ;;
        Blocked) printf 'Blocked' ;;
        Parked) printf 'Parked' ;;
        Wontfix) printf 'WontFix' ;;
        Duplicate) printf 'Duplicate' ;;
        Invalid) printf 'Invalid' ;;
        Archived) printf 'Archived' ;;
        *) printf '' ;;
    esac
}

# ssdlc_bash_status <C# status> -> the bash status name, so outcomes compare in one vocabulary.
ssdlc_bash_status() {
    case "$1" in
        ToDo) printf 'Todo' ;;
        Doing) printf 'In-progress' ;;
        WontFix) printf 'Wontfix' ;;
        *) printf '%s' "$1" ;;
    esac
}

# ssdlc_proof_digest -> reads a rendered proof on stdin, the markdown table or its terminal form, and prints
# "Dimension=VERDICT" lines, sorted, so two renderings of the same verdicts compare equal whatever their evidence wording.
ssdlc_proof_digest() {
    awk -F'|' '
        /^[0-9]+\. [^ ]+ \*\*.*\*\* [^ ]+ (PROVEN|NOT_PERTINENT|UNPROVEN)$/ {
            line=$0; sub(/^[0-9]+\. [^ ]+ \*\*/, "", line)
            verdict=line; sub(/^.* /, "", verdict)
            sub(/\*\* [^ ]+ [A-Z_]+$/, "", line)
            print line "=" verdict; next
        }
        /^\|/ && $0 !~ /Quality Dimension/ && $2 !~ /^[ :-]*$/ {
            dim=$2; v=$3
            gsub(/^ +| +$/, "", dim)
            # The same reading as the bridge: UNPROVEN wins over NOT_PERTINENT, and a data row of three or more cells
            # without a verdict word counts as UNPROVEN rather than disappearing.
            cells=NF-1; if ($NF ~ /^[ \t]*$/) cells--
            if (v ~ /UNPROVEN/) verdict="UNPROVEN"
            else if (v ~ /NOT_PERTINENT/) verdict="NOT_PERTINENT"
            else if (v ~ /PROVEN/) verdict="PROVEN"
            else if (cells >= 3) verdict="UNPROVEN"
            else next
            print dim "=" verdict
        }' | sort
}

# ssdlc_report_append <op> <id> <agree:true|false> <bash_outcome> <cs_outcome> [note]
ssdlc_report_append() {
    local f; f="$(ssdlc_report_file)"
    mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
    jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg op "$1" --arg id "$2" --argjson agree "$3" \
        --arg bash "$4" --arg cs "$5" --arg note "${6:-}" \
        '{ts:$ts,op:$op,id:$id,agree:$agree,bash:$bash,csharp:$cs,note:$note}' >> "$f" 2>/dev/null || true
}

# ssdlc_version -> the version of this tool, stamped on the stories it writes; empty when it is unknown.
ssdlc_version() {
    command -v kyklos_version >/dev/null 2>&1 || return 0
    kyklos_version 2>/dev/null || true
}

# ssdlc_verb_for <op> <args...> -> prints "verb<TAB>json-args" for a routed operation, or nothing (not routed).
ssdlc_verb_for() {
    local op="$1"; shift
    case "$op" in
        new)
            # A new story names its slug, not an issue.
            local slug="${1:-}" type="" epic="" title="" kind="" parent="" work="" severity=""
            case "$slug" in ''|--*) return 0 ;; esac
            shift
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --type) type="${2:-}"; shift 2 || return 0 ;;
                    --epic) epic="${2:-}"; shift 2 || return 0 ;;
                    --no-epic) epic="-"; shift ;;
                    --title) title="${2:-}"; shift 2 || return 0 ;;
                    --kind) kind="${2:-}"; shift 2 || return 0 ;;
                    --severity) severity="${2:-}"; shift 2 || return 0 ;;
                    --parent) parent="${2:-}"; shift 2 || return 0 ;;
                    --work) work="${2:-}"; shift 2 || return 0 ;;
                    --dir) shift 2 || return 0 ;;
                    *) return 0 ;;
                esac
            done
            [ -n "$type" ] && [ -n "$epic" ] || return 0
            printf 'story_new\t%s' "$(jq -cn --arg s "$slug" --arg t "$type" --arg e "$epic" --arg ti "${title:-$slug}" --arg k "$kind" --arg p "$parent" --arg w "$work" --arg v "$(ssdlc_version)" --arg sv "$severity" \
                '{slug:$s,type:$t,epic:$e,title:$ti} + (if $k == "" then {} else {kind:$k} end) + (if $sv == "" then {} else {severity:$sv} end) + (if $p == "" then {} else {parent:$p} end) + (if $w == "" then {} else {work:$w} end) + (if $v == "" then {} else {version:$v} end)')"
            return 0 ;;
        track_finding)
            # The finding comes on stdin; ssdlc_route saved it to the file named by _SSDLC_INPUT.
            local type="fix"
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --type) type="${2:-}"; shift 2 || return 0 ;;
                    --dir) shift 2 || return 0 ;;
                    *) return 0 ;;
                esac
            done
            [ -n "${_SSDLC_INPUT:-}" ] && json_test 'type == "object" and ((.title // "") != "")' < "$_SSDLC_INPUT" || return 0
            printf 'track_finding\t%s' "$(jq -c --arg t "$type" --arg v "$(ssdlc_version)" \
                '{title:(.title|tostring), file:((.file // "")|tostring), line:((.line // "")|tostring), detail:((.detail // "")|tostring), severity:((.severity // "")|tostring), type:$t} + (if $v == "" then {} else {version:$v} end)' "$_SSDLC_INPUT")"
            return 0 ;;
        requirements)
            # The spec file is read here; the story id may come before or after the flags.
            local ref="" file=""
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --file) file="${2:-}"; shift 2 || return 0 ;;
                    --dir) shift 2 || return 0 ;;
                    -*) return 0 ;;
                    *) [ -z "$ref" ] || return 0; ref="$1"; shift ;;
                esac
            done
            [ -n "$ref" ] && [ -n "$file" ] && [ -f "$file" ] || return 0
            printf 'story_spec_set\t%s' "$(jq -cn --arg id "$(ssdlc_story_key "$ref")" --rawfile t "$file" '{id:$id,text:$t}')"
            return 0 ;;
        epic_set|archive)
            # The epic operations name an epic, not a story. Only the options given travel: an update keeps the goal
            # and the dates it is not given.
            local epic="${1:-}" opts='{}'
            case "$epic" in E[0-9]*) shift ;; *) return 0 ;; esac
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --title) opts="$(printf '%s' "$opts" | jq -c --arg v "${2:-}" '. + {title:$v}')"; shift 2 || return 0 ;;
                    --goal) opts="$(printf '%s' "$opts" | jq -c --arg v "${2:-}" '. + {goal:$v}')"; shift 2 || return 0 ;;
                    --start) opts="$(printf '%s' "$opts" | jq -c --arg v "${2:-}" '. + {start_date:$v}')"; shift 2 || return 0 ;;
                    --due) opts="$(printf '%s' "$opts" | jq -c --arg v "${2:-}" '. + {due_date:$v}')"; shift 2 || return 0 ;;
                    --dir) shift 2 || return 0 ;;
                    *) return 0 ;;
                esac
            done
            if [ "$op" = archive ]; then
                printf 'epic_archive\t%s' "$(jq -cn --arg e "$epic" '{epic:$e}')"
            elif printf '%s' "$opts" | json_test '(.title // "") != ""'; then
                printf 'epic_set\t%s' "$(printf '%s' "$opts" | jq -c --arg e "$epic" '{epic:$e} + .')"
            fi
            return 0 ;;
    esac
    local ref="${1:-}"; [ -n "$ref" ] || return 0
    local id; id="$(ssdlc_story_key "$ref")"; shift
    case "$op" in
        set)
            local kv status="" flags=0 fields='{}'
            while [ "$#" -gt 0 ]; do
                kv="$1"
                case "$kv" in
                    --dir) shift ;;
                    --no-sync) : ;;
                    --reason) flags=1; shift ;;   # its value is free text, never a field=value pair
                    --*) flags=1 ;;
                    *=*) if [ "$(canonical_field "${kv%%=*}" 2>/dev/null)" = "Status" ]; then status="${kv#*=}"
                         else fields="$(printf '%s' "$fields" | jq -c --arg k "${kv%%=*}" --arg v "${kv#*=}" '. + {($k): $v}')"; fi ;;
                esac
                shift
            done
            # Header fields (anything but the status) are one write through the bridge, all checked before any lands.
            if [ -z "$status" ]; then
                [ "$fields" != '{}' ] && [ "$flags" -eq 0 ] || return 0
                printf 'story_field_set\t%s' "$(jq -cn --arg id "$id" --arg f "$fields" '{id:$id,fields:$f}')"
                return 0
            fi
            # A close may carry the deliverable it cites and its summary: the bridge judges and records them with the close.
            if [ "$(story_normalize_status "$status")" = "Done" ] && [ "$flags" -eq 0 ] \
               && printf '%s' "$fields" | json_test '(keys | map(ascii_downcase)) - ["branch","summary"] == []'; then
                printf 'story_close\t%s' "$(jq -cn --arg id "$id" --argjson f "$fields" '{id:$id} + ($f | with_entries(.key |= ascii_downcase))')"
                return 0
            fi
            if [ "$fields" != '{}' ]; then
                printf 'refuse\t%s' "set: the status and other fields are separate writes for the bridge's story stack; run 'set $ref status=$status' and 'set $ref <field>=<value>' as two commands."
                return 0
            fi
            [ "$flags" -eq 0 ] || return 0
            if [ "$(story_normalize_status "$status")" = "Done" ]; then
                printf 'story_close\t%s' "$(jq -cn --arg id "$id" '{id:$id}')"
            else
                local cs; cs="$(ssdlc_cs_status "$status")"; [ -n "$cs" ] || return 0
                printf 'story_set_status\t%s' "$(jq -cn --arg id "$id" --arg s "$cs" '{id:$id,status:$s}')"
            fi ;;
        phase)
            local ph="${1:-}" reason="" a
            [ -n "$ph" ] && [ "${ph#--}" = "$ph" ] || return 0
            shift
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --reason) reason="${2:-}"; shift 2 || return 0 ;;
                    --dir) shift 2 || return 0 ;;
                    *) return 0 ;;
                esac
            done
            a="$(jq -cn --arg id "$id" --arg p "$(story_phase_canon "$ph")" --arg r "$reason" '{id:$id,phase:$p} + (if $r == "" then {} else {reason:$r} end)')"
            printf 'story_phase\t%s' "$a" ;;
        resume)
            printf 'story_resume\t%s' "$(jq -cn --arg id "$id" '{id:$id}')" ;;
        close)
            # The cited deliverable and the summary travel with the close, so Remote Truth judges what the close cites.
            local branch="" summary="" have_branch=0 have_summary=0
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --branch) branch="${2:-}"; have_branch=1; shift 2 || break ;;
                    --summary) summary="${2:-}"; have_summary=1; shift 2 || break ;;
                    --dir) shift 2 || break ;;
                    *) shift ;;
                esac
            done
            printf 'story_close\t%s' "$(jq -cn --arg id "$id" --arg b "$branch" --arg s "$summary" --argjson hb "$have_branch" --argjson hs "$have_summary" \
                '{id:$id} + (if $hb == 1 then {branch:$b} else {} end) + (if $hs == 1 then {summary:$s} else {} end)')" ;;
        adopt)
            local type="" epic="" kind="" work="" severity=""
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --type) type="${2:-}"; shift 2 || return 0 ;;
                    --epic) epic="${2:-}"; shift 2 || return 0 ;;
                    --kind) kind="${2:-}"; shift 2 || return 0 ;;
                    --severity) severity="${2:-}"; shift 2 || return 0 ;;
                    --work) work="${2:-}"; shift 2 || return 0 ;;
                    --dir) shift 2 || return 0 ;;
                    *) return 0 ;;
                esac
            done
            [ -n "$type" ] && [ -n "$epic" ] || return 0
            printf 'story_adopt\t%s' "$(jq -cn --arg id "$id" --arg t "$type" --arg e "$epic" --arg k "$kind" --arg w "$work" --arg v "$(ssdlc_version)" --arg sv "$severity" \
                '{id:$id,type:$t,epic:$e} + (if $k == "" then {} else {kind:$k} end) + (if $sv == "" then {} else {severity:$sv} end) + (if $w == "" then {} else {work:$w} end) + (if $v == "" then {} else {version:$v} end)')" ;;
        structure|kind)
            [ "$#" -eq 0 ] || { [ "$1" = "--dir" ] && [ "$#" -eq 2 ]; } || return 0
            printf 'story_%s\t%s' "$op" "$(jq -cn --arg id "$id" '{id:$id}')" ;;
        reopen_root_cause)
            # The root-cause note is written by the bridge's coordination desk, which re-checks the same rules.
            local reason="" have=0
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --reason) reason="${2:-}"; have=1; shift 2 || return 0 ;;
                    --file) [ "$have" -eq 0 ] && [ -f "${2:-}" ] || return 0; reason="$(cat "$2")"; have=1; shift 2 || return 0 ;;
                    --dir) shift 2 || return 0 ;;
                    *) return 0 ;;
                esac
            done
            [ "$have" -eq 1 ] || return 0
            printf 'story_reopen_root_cause\t%s' "$(jq -cn --arg id "$id" --arg r "$reason" '{iid:$id,reason:$r}')" ;;
        parent)
            local parent="${1:-}"
            case "$parent" in ''|--*) return 0 ;; esac
            shift
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --dir) shift 2 || return 0 ;;
                    *) return 0 ;;
                esac
            done
            printf 'story_parent\t%s' "$(jq -cn --arg id "$id" --arg p "$parent" '{id:$id,parent:$p}')" ;;
        proof)
            # The bridge parses, validates and renders every proof write; the tool only forwards the request.
            local -a sets=(); local apply="" write=0 template=0 format=markdown draft=0 branch="" have_branch=0
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --draft) draft=1; shift ;;
                    --branch) branch="${2:-}"; have_branch=1; shift 2 || return 0 ;;
                    --format) format="${2:-}"; shift 2 || return 0 ;;
                    --set) sets+=("${2:-}"); shift 2 || return 0 ;;
                    --apply) apply="${2:-}"; shift 2 || return 0 ;;
                    --write) write=1; shift ;;
                    --template) template=1; shift ;;
                    --dir) shift 2 || return 0 ;;
                    *) return 0 ;;
                esac
            done
            # The draft is the bridge's alone: it assembles the proof from the evidence it holds (proof_draft).
            if [ "$draft" -eq 1 ]; then
                if [ -n "$apply" ] || [ "${#sets[@]}" -gt 0 ] || [ "$write" -eq 1 ] || [ "$template" -eq 1 ]; then
                    printf 'refuse\t%s' "proof: --draft is a write of its own; run 'proof $ref --draft' alone, then fill the rows it leaves open with --set."
                    return 0
                fi
                printf 'proof_draft\t%s' "$(jq -cn --arg id "$id" --arg b "$branch" --argjson hb "$have_branch" '{id:$id} + (if $hb == 1 then {branch:$b} else {} end)')"
                return 0
            fi
            [ "$have_branch" -eq 0 ] || return 0
            # A format other than markdown/text, or one given with a write, stays with bash, which refuses it.
            case "$format" in markdown|text) : ;; *) return 0 ;; esac
            [ "$format" = markdown ] || { [ -z "$apply" ] && [ "${#sets[@]}" -eq 0 ] && [ "$write" -eq 0 ]; } || return 0
            if [ -n "$apply" ]; then
                [ -f "$apply" ] || return 0
                printf 'proof_set\t%s' "$(jq -cn --arg id "$id" --rawfile t "$apply" '{id:$id,table:$t}')"
            elif [ "${#sets[@]}" -gt 0 ] || [ "$write" -eq 1 ]; then
                printf 'proof_set\t%s' "$(jq -cn --arg id "$id" '{id:$id,sets:($ARGS.positional|tojson)}' --args "${sets[@]}")"
            elif [ "$template" -eq 0 ]; then
                if [ "$format" = text ]; then
                    printf 'proof_get\t%s' "$(jq -cn --arg id "$id" '{id:$id,format:"text"}')"
                else
                    printf 'proof_get\t%s' "$(jq -cn --arg id "$id" '{id:$id}')"
                fi
            fi ;;
        ra)
            local apply=""
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --apply) apply="${2:-}"; shift 2 || return 0 ;;
                    --dir) shift 2 || return 0 ;;
                    *) return 0 ;;
                esac
            done
            [ -n "$apply" ] && [ -f "$apply" ] || return 0
            printf 'ra_set\t%s' "$(jq -cn --arg id "$id" --rawfile t "$apply" '{id:$id,text:$t}')" ;;
    esac
}

# ssdlc_bash_outcome <verb> <verb-args-json> <rc> <dir> <ref> <captured stdout> -> the bash result in the shared
# vocabulary. A successful set or phase lands exactly as asked (the bash tool either applies the requested value or
# refuses), so the requested value IS the outcome; a resume derives its target, so that one is read back.
ssdlc_bash_outcome() {
    local verb="$1" args="$2" rc="$3" out="$6"
    [ "$rc" -eq 0 ] || { printf 'refused'; return 0; }
    case "$verb" in
        story_close) printf 'closed' ;;
        story_set_status) ssdlc_bash_status "$(printf '%s' "$args" | jq -r '.status')" ;;
        story_phase) printf '%s' "$args" | jq -r '.phase' ;;
        # The resume target is derived, and a read-back right after the write can still see the old state, so the
        # outcome is the target the tool itself reports ("resumed <id> -> <status> ...").
        story_resume) story_normalize_status "$(printf '%s' "$out" | sed -n 's/^resumed [^ ]* -> \([^ ]*\).*/\1/p' | tail -1)" ;;
        proof_get|proof_set) ssdlc_proof_outcome "$(printf '%s' "$out" | ssdlc_proof_digest)" "$out" ;;
        story_kind) printf '%s' "$out" | tr -d '[:space:]' ;;
        *) printf 'stored' ;;
    esac
}

# ssdlc_proof_outcome <digest> <rendered> -> 'none' when there is no stored proof, else the digest on one line. With
# no stored proof the bash tool renders the empty template (every row UNPROVEN, a placeholder tally) while the C#
# stack refuses with "carries no proof table"; both mean the same thing, so both become 'none'.
ssdlc_proof_outcome() {
    local digest="$1" rendered="$2"
    if printf '%s' "$rendered" | grep -c 'Tally: _ PROVEN' >/dev/null || [ -z "$digest" ]; then printf 'none'; return 0; fi
    printf '%s' "$digest" | paste -sd';' -
}

# ssdlc_cs_outcome <verb> <reply> -> the C# result in the shared vocabulary.
ssdlc_cs_outcome() {
    local verb="$1" resp="$2" text
    if bridge_mcp_is_error "$resp"; then
        if [ "$verb" = proof_get ] && bridge_mcp_text "$resp" | grep -c 'carries no proof table' >/dev/null; then printf 'none'; return 0; fi
        printf 'refused'; return 0
    fi
    # A shadow-mode bridge ends a dropped write with a '[shadow] ...' line (nothing was saved); it is not part of the
    # outcome, so it is dropped before comparing.
    text="$(bridge_mcp_text "$resp" | grep -v '^\[shadow\] ')"
    case "$verb" in
        story_close) if [ "$text" = "closed" ]; then printf 'closed'; else printf '%s' "$text"; fi ;;
        story_set_status|story_resume) ssdlc_bash_status "$text" ;;
        story_phase) printf '%s' "$text" ;;
        proof_get|proof_set) ssdlc_proof_outcome "$(printf '%s' "$text" | ssdlc_proof_digest)" "$text" ;;
        story_kind) printf '%s' "$text" | tr -d '[:space:]' ;;
        *) printf 'stored' ;;
    esac
}

# SSDLC_SPEC_REFUSAL_TAG -- the word the bridge's spec-completeness refusal starts with (StorySpecCompleteness.RefusalTag).
SSDLC_SPEC_REFUSAL_TAG="spec-incomplete"

# ssdlc_leaves_requirements <verb> <verb-args-json> -> rc 0 iff the routed request may move a story out of Requirements:
# a phase move to a later phase, or an adoption with existing work (which starts the story at Implementation).
ssdlc_leaves_requirements() {
    local verb="$1" args="$2" rank
    case "$verb" in
        story_phase)
            rank="$(story_phase_rank "$(printf '%s' "$args" | jq -r '.phase // ""')")"
            [ -n "$rank" ] && [ "$rank" -gt 0 ] ;;
        story_adopt) printf '%s' "$args" | json_test '(.work // "") != ""' ;;
        *) return 1 ;;
    esac
}

# ssdlc_spec_gate_shadow <verb> <verb-args-json> <transport-rc> <reply> -> rc 1 (and the reason on stdout) when the
# bridge's spec-completeness check decides a shadow-mode request that leaves Requirements: the bridge refused it with
# that check's refusal, or a reachable bridge could not answer it. The check lives only in the bridge, so in shadow
# mode its verdict is not merely recorded: the bash mechanics do not run. rc 0 lets bash decide as before.
# [RiskMitigation RA-03]
ssdlc_spec_gate_shadow() {
    local verb="$1" args="$2" rc="$3" resp="$4"
    ssdlc_leaves_requirements "$verb" "$args" || return 0
    if [ "$rc" -ne 0 ]; then
        printf "the bridge's spec-completeness check could not run (bridge call '%s' failed, transport rc %s); a story leaves Requirements only when that check passes. Nothing was changed; retry once the bridge answers." "$verb" "$rc"
        return 1
    fi
    if bridge_mcp_is_error "$resp" && bridge_mcp_text "$resp" | head -1 | grep -c "^$SSDLC_SPEC_REFUSAL_TAG" >/dev/null; then
        bridge_mcp_text "$resp"
        return 1
    fi
    return 0
}

# ssdlc_spec_notice_off <verb> <verb-args-json> -> one loud notice on stderr when a story may leave Requirements in mode
# 'off': the full spec-completeness check runs only in the bridge's story stack, which this project's bridge lacks, so
# only the bash 2a-2f check at close applies here.
ssdlc_spec_notice_off() {
    ssdlc_leaves_requirements "$1" "$2" || return 0
    printf '%s\n' "story: NOTICE - the full spec check (every section of the story skeleton filled before a story leaves Requirements) runs only where the bridge's story stack is on. This project's bridge serves no story stack, so only the 2a-2f check at close applies here." >&2
}

# ssdlc_route <op> <args...> -- run a story operation through the switch. <op> is the story subcommand; the bash
# implementation is cmd_<op>. An '--apply -' (the input on stdin) is first saved to a file, so the bridge request and
# the bash run (in shadow both) read the same input.
ssdlc_route() {
    local op="$1"; shift
    local -a argv=("$@"); local i stdin_copy="" rc
    for i in "${!argv[@]}"; do
        if [ "${argv[$i]}" = "--apply" ] && [ "${argv[$((i + 1))]:-}" = "-" ]; then
            stdin_copy="$(mktemp)"; cat > "$stdin_copy"; argv[i + 1]="$stdin_copy"
        fi
    done
    if [ "$op" = track_finding ]; then
        # The finding is read from stdin by both the bridge request and the bash run.
        stdin_copy="$(mktemp)"; cat > "$stdin_copy"
        _SSDLC_INPUT="$stdin_copy" _ssdlc_route_run "$op" "${argv[@]}" < "$stdin_copy"; rc=$?
        rm -f "$stdin_copy"
        return "$rc"
    fi
    _ssdlc_route_run "$op" "${argv[@]}"; rc=$?
    [ -n "$stdin_copy" ] && rm -f "$stdin_copy"
    return "$rc"
}

_ssdlc_route_run() {
    local op="$1"; shift
    local routed; routed="$(ssdlc_verb_for "$op" "$@")"
    [ -n "$routed" ] || { "cmd_$op" "$@"; return $?; }
    local mode; mode="$(ssdlc_engine_mode)" || die "the bridge was last reported in story-stack mode 'on' and is unreachable now; refusing to fall back to the bash mechanics. Start the bridge (relaunch the container) and retry." 3
    local verb="${routed%%	*}" args="${routed#*	}"
    # The root-cause note has no dry run to compare: outside mode 'on' bash alone records it.
    if [ "$verb" = story_reopen_root_cause ] && [ "$mode" != on ]; then "cmd_$op" "$@"; return $?; fi
    # The proof draft exists only in the bridge (it holds the evidence): outside mode 'on' it is refused by name.
    if [ "$verb" = proof_draft ] && [ "$mode" != on ]; then
        die "proof --draft: the bridge assembles the proof from the evidence it holds (proof_draft), and this project's bridge story stack is '$mode'. Write the table with 'proof <id> --write' and '--set' instead." 2
    fi
    # A request the bridge's verbs cannot take as one write: refused in 'on' mode, left to bash otherwise.
    if [ "$verb" = refuse ]; then
        [ "$mode" = on ] && die "$args" 2
        "cmd_$op" "$@"; return $?
    fi
    [ "$mode" = off ] || args="$(printf '%s' "$args" | jq -c --arg p "$(ssdlc_project)" '. + {project:$p}')"
    case "$mode" in
        off) ssdlc_spec_notice_off "$verb" "$args"; "cmd_$op" "$@"; return $? ;;
        on)
            local resp rc
            # The bridge's close does not see this container's git branches: Trunk Reach is judged here first.
            # [RiskMitigation RA-03]
            if [ "$verb" = story_close ] && command -v story_trunk_reach_route_gate >/dev/null 2>&1; then
                story_trunk_reach_route_gate "$@" || return 1
            fi
            resp="$(bridge_mcp_call "$verb" "$args" 300)"; rc=$?
            [ "$rc" -eq 0 ] || die "story-stack mode is 'on' but the bridge call '$verb' failed (transport rc $rc); nothing was changed." 3
            # The bridge text already ends with a line break; print it as one block ending in exactly one, so a caller
            # reading the last line (tail -1, a captured id) gets the answer, not an empty line.
            local text; text="$(bridge_mcp_text "$resp")"
            [ -n "$text" ] && printf '%s\n' "$text"
            if bridge_mcp_is_error "$resp"; then return 1; fi
            return 0 ;;
        shadow)
            local resp rc cs_out out brc dir ref="$1"
            resp="$(bridge_mcp_call "$verb" "$args" 300)"; rc=$?
            local spec_refusal
            spec_refusal="$(ssdlc_spec_gate_shadow "$verb" "$args" "$rc" "$resp")" || {
                printf '%s\n' "$spec_refusal"
                ssdlc_report_append "$op" "$(ssdlc_story_key "$ref")" true "refused" "refused" "the bridge's spec-completeness check decided"
                return 1
            }
            if [ "$rc" -eq 0 ]; then cs_out="$(ssdlc_cs_outcome "$verb" "$resp")"; else cs_out="unavailable"; fi
            # bash stays authoritative: run it as asked, keep its output visible, capture it for the comparison.
            out="$( "cmd_$op" "$@" )"; brc=$?
            [ -n "$out" ] && printf '%s\n' "$out"
            dir="$(dir_from_args "$@")"
            local b_out id; b_out="$(ssdlc_bash_outcome "$verb" "$args" "$brc" "$dir" "$ref" "$out")"; id="$(ssdlc_story_key "$ref")"
            if [ "$cs_out" = "unavailable" ]; then
                ssdlc_report_append "$op" "$id" false "$b_out" "$cs_out" "c# unavailable (transport rc $rc)"
            elif [ "$b_out" = "$cs_out" ]; then
                ssdlc_report_append "$op" "$id" true "$b_out" "$cs_out"
            else
                local reason=""; [ "$cs_out" = "refused" ] && reason="$(bridge_mcp_text "$resp" | head -c 400)"
                ssdlc_report_append "$op" "$id" false "$b_out" "$cs_out" "$reason"
                printf 'story: shadow divergence on %s %s: bash=%s c#=%s (recorded in %s)\n' "$op" "$ref" "$b_out" "$cs_out" "$(ssdlc_report_file)" >&2
            fi
            return "$brc" ;;
    esac
}

# ssdlc_epic_verb_for <sub> <args...> -> prints "verb<TAB>json-args<TAB>read|write" for an epic-desk subcommand
# (list, show, close, reopen, delete), or "usage<TAB><message>" when the arguments are wrong.
ssdlc_epic_verb_for() {
    local sub="$1"; shift
    local epic="" opts='{}'
    case "$sub" in
        list) : ;;
        show|close|reopen|delete)
            epic="${1:-}"
            case "$epic" in E[0-9]*) shift ;; *) printf 'usage\tepic %s: expected an epic id like E<nn>, got: %s' "$sub" "${epic:-<none>}"; return 0 ;; esac ;;
        *) printf 'usage\tepic: unknown subcommand %s' "$sub"; return 0 ;;
    esac
    while [ "$#" -gt 0 ]; do
        case "$sub:$1" in
            list:--state|list:--search|show:--state|show:--search)
                [ "$#" -ge 2 ] || { printf 'usage\tepic %s: missing value after %s' "$sub" "$1"; return 0; }
                opts="$(printf '%s' "$opts" | jq -c --arg k "${1#--}" --arg v "$2" '. + {($k):$v}')"; shift 2 || return 0 ;;
            *:--dir) shift 2 || shift ;;
            *) printf 'usage\tepic %s: unknown argument: %s' "$sub" "$1"; return 0 ;;
        esac
    done
    [ -z "$epic" ] || opts="$(printf '%s' "$opts" | jq -c --arg e "$epic" '. + {epic:$e}')"
    case "$sub" in
        list) printf 'epic_list\t%s\tread' "$opts" ;;
        show) printf 'epic_get\t%s\tread' "$opts" ;;
        *) printf 'epic_%s\t%s\twrite' "$sub" "$opts" ;;
    esac
}

# ssdlc_epic_desk <sub> <args...> -- the epic desk subcommands (list, show, close, reopen, delete). In mode 'on' they go
# to the bridge's epic verbs; otherwise (off, shadow, a backend other than GitLab) the bash mechanics run them with the
# same rules (cmd_epic_desk), because in 'shadow' the bridge writes nothing and the bash tool is the only writer.
ssdlc_epic_desk() {
    local sub="${1:-}" routed verb args mode resp rc text
    routed="$(ssdlc_epic_verb_for "$@")"
    case "$routed" in usage*) die "${routed#usage	}" 2 ;; esac
    verb="${routed%%	*}"; args="${routed#*	}"; args="${args%	*}"
    mode="$(ssdlc_engine_mode)" || die "the bridge was last reported in story-stack mode 'on' and is unreachable now; 'epic $sub' needs it. Start the bridge (relaunch the container) and retry." 3
    if [ "$mode" != on ]; then cmd_epic_desk "$sub" "$args" "$(dir_from_args "${@:2}")"; return $?; fi
    args="$(printf '%s' "$args" | jq -c --arg p "$(ssdlc_project)" '. + {project:$p}')"
    resp="$(bridge_mcp_call "$verb" "$args" 300)"; rc=$?
    [ "$rc" -eq 0 ] || die "epic $sub: the bridge call '$verb' failed (transport rc $rc); nothing was changed." 3
    text="$(bridge_mcp_text "$resp")"
    [ -n "$text" ] && printf '%s\n' "$text"
    if bridge_mcp_is_error "$resp"; then return 1; fi
    return 0
}

# ssdlc_block <ref> [--kind <issue|user|external> --on <target> --reason "<why>"] -- `story block`: the bridge's
# story_block verb is the only implementation (it checks the target for its kind, records the blocker once, marks the open
# tasks, sets the status label that names the kind and posts the note; with the id alone it lifts an issue block once the
# reference has closed or merged, and reports a user or external block with its age). The tool only forwards the request,
# so it needs the bridge's story stack in mode 'on' for this project; any other mode refuses, naming why. The kind is
# required on every block (the bridge refuses one without it); the tool refuses early with the same rule.
ssdlc_block() {
    local ref="${1:-}" on="" reason="" kind="" have_on=0 mode resp rc text args
    case "$ref" in ''|--*) die "block: usage: story block <id> --kind <issue|user|external> --on <target> --reason \"<why>\" (target: the issue, story or merge request; the link to the note that asks the user; or who or what is awaited) (or 'story block <id>' to re-check the blocker)" 2 ;; esac
    shift
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --on) on="${2:-}"; have_on=1; shift 2 || die "block: missing value after --on" 2 ;;
            --kind) kind="${2:-}"; shift 2 || die "block: missing value after --kind" 2 ;;
            --reason) reason="${2:-}"; shift 2 || die "block: missing value after --reason" 2 ;;
            --dir) shift 2 || shift ;;
            *) die "block: unknown argument: $1" 2 ;;
        esac
    done
    [ "$have_on" -eq 0 ] || [ -n "$on" ] || die "block: --on needs what the story waits on (the issue, story or merge request; the link to the note that asks the user; or who or what is awaited)." 2
    [ "$have_on" -eq 1 ] || { [ -z "$reason" ] && [ -z "$kind" ]; } || die "block: --kind and --reason go with --on <target>; 'story block <id>' alone only re-checks the recorded blocker." 2
    if [ "$have_on" -eq 1 ]; then
        case "$kind" in
            issue|user|external) : ;;
            '') die "block: --kind is required: issue (another issue, story or merge request), user (the user's answer) or external (something outside the tracker)." 2 ;;
            *) die "block: --kind '$kind' is not one of issue, user, external." 2 ;;
        esac
    fi
    mode="$(ssdlc_engine_mode)" || die "the bridge was last reported in story-stack mode 'on' and is unreachable now; 'block' needs it. Start the bridge (relaunch the container) and retry." 3
    [ "$mode" = on ] || die "block: blocking a story records its blocker through the bridge's story_block verb, and this project's bridge story stack is '$mode'. Nothing was changed." 2
    args="$(jq -cn --arg id "$(ssdlc_story_key "$ref")" --arg p "$(ssdlc_project)" --arg on "$on" --arg r "$reason" --arg k "$kind" \
        '{id:$id,project:$p} + (if $on == "" then {} else {kind:$k,on:$on,reason:$r} end)')"
    resp="$(bridge_mcp_call story_block "$args" 300)"; rc=$?
    [ "$rc" -eq 0 ] || die "block: the bridge call 'story_block' failed (transport rc $rc); nothing was changed." 3
    text="$(bridge_mcp_text "$resp")"
    [ -n "$text" ] && printf '%s\n' "$text"
    if bridge_mcp_is_error "$resp"; then return 1; fi
    return 0
}

# cmd_shadow_report [--all] -- summarise the shadow report: counts, then every divergence (or every line with --all).
cmd_shadow_report() {
    local all=0; [ "${1:-}" = "--all" ] && all=1
    local f; f="$(ssdlc_report_file)"
    [ -s "$f" ] || { printf 'shadow report: no comparisons recorded yet (%s)\n' "$f"; return 0; }
    local total agree
    total="$(wc -l < "$f" | tr -d ' ')"
    agree="$(jq -s '[.[] | select(.agree)] | length' "$f")"
    printf 'shadow report (%s): %s comparisons, %s agree, %s diverge\n' "$f" "$total" "$agree" "$((total - agree))"
    if [ "$all" -eq 1 ]; then
        jq -r '"\(.ts) \(.op) #\(.id) agree=\(.agree) bash=\(.bash) c#=\(.csharp) \(.note)"' "$f"
    else
        jq -r 'select(.agree | not) | "\(.ts) \(.op) #\(.id) bash=\(.bash) c#=\(.csharp) \(.note)"' "$f"
    fi
}
