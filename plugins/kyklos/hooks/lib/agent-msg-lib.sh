#!/usr/bin/env bash
# agent-msg-lib.sh — the Kyklos SURFACE of cross-agent COORDINATION issues (the NON-story half of a project's GitLab
# issues). Every operation is decided by the KyklosBridge coordination verbs (coordination_open/reply/route/close/
# reopen/show/open_mine/reconcile); this file only forwards and maps the answer to a return code. The bridge holds the
# GitLab token and resolves the agent's identity from it, so the container needs no token for coordination and a
# container-side edit cannot change a coordination decision.
#
# Taxonomy (mutually exclusive with stories, so the two subsystems can never collide):
#   - a STORY carries the `story` label            (owned by the `story` tool + story guards)
#   - a COORDINATION issue carries `agent-comms`   (owned by THIS tool) + `kind::communication`, and its
#     recipient is the GitLab ASSIGNEE — the single routing scheme
#
# Return codes shared by the forwarders: 0 answered, 1 refused by a coordination rule (the reason is on stderr),
# 3 cannot reach (the bridge is down, has no coordination stack, or GitLab could not be reached). There is no
# fallback: when the bridge cannot answer, the operation stops and says so.
#
# Config — the container's KYKLOS_ISSUES_PROJECT is the default inbox project; agent aliases, the GitLab address and
# the token live on the bridge (set by the launcher). bash + curl + jq.
set -uo pipefail

AM_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$AM_HERE/bridge-mcp.sh"
# shellcheck source=/dev/null
. "$AM_HERE/inbound-issues-fetch.sh"
# the shared kyklos-version resolver: every coordination issue we create or change is stamped with the acting
# `kyklos:version::<v>` label (the bridge applies it). Safe to double-source (guarded internally).
# shellcheck source=/dev/null
. "$AM_HERE/kyklos-version.sh"

AM_MARKER="agent-comms"                                   # the positive coordination-issue marker label
_AM_PID="${KYKLOS_ISSUES_PROJECT:-}"
AM_REPLY_STRANDED=""                                      # set by am_reply: non-empty when the issue is still ours

# _am_call <verb> <arguments-json> — forward one coordination verb to the bridge; the answer text goes to stdout.
# rc 0 answered, rc 1 refused (reason on stderr), rc 3 cannot reach (reason on stderr). Never a silent success or an
# empty answer when the bridge could not answer. [RiskMitigation RA-04]
_am_call() {
    local verb="$1" args="$2" resp text
    # Arguments that could not be built (empty) are never sent: the request would reach the bridge without its body
    # or recipient and could still be answered as a success.
    if [ -z "$args" ]; then
        printf 'agent-msg: %s FAILED — its arguments could not be built; nothing was sent.\n' "$verb" >&2
        return 1
    fi
    if ! resp="$(bridge_mcp_call "$verb" "$args" 60)"; then
        printf 'agent-msg: %s FAILED — the KyklosBridge is not reachable; coordination runs only through the bridge (no fallback).\n' "$verb" >&2
        return 3
    fi
    text="$(bridge_mcp_text "$resp")"
    case "$text" in
        "unknown tool: "*)
            printf 'agent-msg: %s FAILED — this bridge has no coordination stack (the launcher configures it); coordination runs only through the bridge.\n' "$verb" >&2
            return 3 ;;
    esac
    if bridge_mcp_is_error "$resp"; then
        [ -n "$text" ] || text="$(printf '%s' "$resp" | jq -r '.error.message // "refused"' 2>/dev/null)"
        printf 'agent-msg: %s\n' "$text" >&2
        case "$text" in UNREACHABLE:*) return 3 ;; esac
        return 1
    fi
    printf '%s' "$text"
}

# _am_args <--arg name value ...> — a JSON arguments object from name/value pairs, plus the acting version label.
# Each value reaches jq through a file (--rawfile), never on its command line: Linux refuses a single argument over
# 128 KiB, so a long message body passed with --arg failed with "Argument list too long". printf is a shell builtin,
# so writing the value never execs with it either. Key order follows the pairs, as before.
_am_args() {
    local vl dir i=0 rc=0 args=(); vl="$(kyklos_version_label 2>/dev/null || true)"
    dir="$(mktemp -d)" || return 1
    while [ "$#" -ge 3 ] && [ "$1" = "--arg" ]; do
        i=$((i + 1)); printf '%s' "$3" > "$dir/$i"
        args+=(--rawfile "$2" "$dir/$i"); shift 3
    done
    # Anything left is not a name/value pair: refuse it instead of dropping it, so no value is ever lost silently.
    if [ "$#" -gt 0 ]; then
        printf 'agent-msg: internal error - unsupported argument for the bridge call: %s\n' "$1" >&2
        rm -rf "$dir"
        return 2
    fi
    # jq-exit-flag-ok: args holds only the --rawfile name/file pairs built in the loop above, never an exit-status flag.
    jq -cn --arg version_label "$vl" "${args[@]}" '$ARGS.named | with_entries(select(.value != ""))' || rc=$?
    rm -rf "$dir"
    return "$rc"
}

# am_new <recipient> <title> <body> [project] -> prints the created iid (rc 0); rc 1/3 (+ stderr WHY) on failure.
# Opens a coordination issue in the RECIPIENT's inbox project (default: our own), ASSIGNED to the recipient. The bridge
# refuses an unknown or non-member recipient: an unaddressed comm is never created.
am_new() {
    local to="$1" title="$2" body="$3" project="${4:-$_AM_PID}"
    [ -n "$to" ] && [ -n "$title" ] && [ -n "$project" ] || return 2
    _am_call coordination_open "$(_am_args --arg recipient "$to" --arg title "$title" --arg body "$body" --arg project "$project")"
}

# am_reply <iid> <body> [project] -> rc 0 on a posted note; rc 1/3 (+ stderr WHY) otherwise. The bridge refuses repeated
# work on an open, un-adopted issue (adopt it first). AM_REPLY_STRANDED is set when the issue is still assigned to us.
am_reply() {
    local iid="$1" body="$2" project="${3:-$_AM_PID}" out
    AM_REPLY_STRANDED=""
    [ -n "$iid" ] && [ -n "$body" ] && [ -n "$project" ] || return 2
    out="$(_am_call coordination_reply "$(_am_args --arg iid "$iid" --arg body "$body" --arg project "$project")")" || return $?
    case "$out" in *"still assigned to you"*) AM_REPLY_STRANDED=1 ;; esac
    return 0
}

# am_route <iid> <to_agent> [project] -> re-route a coordination issue (the new recipient becomes the one assignee).
am_route() {
    local iid="$1" to="$2" project="${3:-$_AM_PID}"
    [ -n "$iid" ] && [ -n "$to" ] && [ -n "$project" ] || return 2
    _am_call coordination_route "$(_am_args --arg iid "$iid" --arg recipient "$to" --arg project "$project")" >/dev/null
}

# am_close <iid> [comment] [project] -> post an optional closing note, then close.
am_close() {
    local iid="$1" comment="${2:-}" project="${3:-$_AM_PID}"
    [ -n "$iid" ] && [ -n "$project" ] || return 2
    _am_call coordination_close "$(_am_args --arg iid "$iid" --arg comment "$comment" --arg project "$project")" >/dev/null
}

# am_reopen <iid> [comment] [project] -> post an optional note, then reopen. The sanctioned door for reopening a
# coordination issue (a raw `state_event=reopen` is blocked by kyklos-agent-msg-guard, which names this command).
am_reopen() {
    local iid="$1" comment="${2:-}" project="${3:-$_AM_PID}"
    [ -n "$iid" ] && [ -n "$project" ] || return 2
    _am_call coordination_reopen "$(_am_args --arg iid "$iid" --arg comment "$comment" --arg project "$project")" >/dev/null
}

# am_show <iid> [project] -> the raw issue JSON.
am_show() {
    local project="${2:-$_AM_PID}"
    [ -n "${1:-}" ] && [ -n "$project" ] || return 2
    _am_call coordination_show "$(jq -cn --arg iid "$1" --arg project "$project" '$ARGS.named')"
}

# am_inbox -> the ball-in-court inbound issues, one per line (rc 0 = some await our reply, 1 = clean, 2 = not
# configured, 3 = cannot check). This IS the fetch the inbound gate enforces, so the tool and the gate agree.
am_inbox() {
    local rc=0
    inbound_issues_collect "$@" || rc=$?
    [ "$rc" -eq 0 ] && printf '%s\n' "${INBOUND_LINES#$'\n'}"
    return "$rc"
}

# _am_list <verb> [project] -> the verb's lines; rc 0 some, rc 1 none, rc 2 no project, rc 3 cannot answer (refused or
# unreachable; the reason is on stderr) — never read as "none".
_am_list() {
    local verb="$1" project="${2:-$_AM_PID}" out
    [ -n "$project" ] || return 2
    out="$(_am_call "$verb" "$(jq -cn --arg project "$project" '$ARGS.named')")" || return 3
    [ -n "$out" ] || return 1
    printf '%s\n' "$out"
}

# am_reconcile [project] -> open non-story issues that look out of band (kind::communication without agent-comms ==
# created outside the tool, or a retired for: routing label). Report-only.
am_reconcile() { _am_list coordination_reconcile "$@"; }

# am_open_mine [project] -> EVERY open coordination issue addressed to us, regardless of who noted last, each marked
# [awaiting-YOU], [replied-last] (the blind spot am_inbox hides) or [opened-by-you]. Report-only.
am_open_mine() { _am_list coordination_open_mine "$@"; }
