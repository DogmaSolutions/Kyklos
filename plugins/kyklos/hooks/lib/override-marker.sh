#!/usr/bin/env bash
# override-marker.sh - the one way to grant and spend a guard's one-shot override.
#
# A bare file (`touch $KYKLOS_STATE_DIR/<name>`) would be spent by whichever guard run came first: with several agents
# in one container (a session and the subagents it starts), one agent could spend another's override, overwrite it
# with its own, or get a push or commit through on an override it never set. Here an
# override is bound to a SCOPE (the repository it is meant for, or "global" for guards that are not about one
# repository), to the AGENT that set it, and EXPIRES; a guard spends it only for the same agent and the same scope.
#
# Set one (a separate command, before the command the guard would block):
#   bash override-marker.sh set <name> <repo-dir>     scope = that repository's top folder
#   bash override-marker.sh set <name> global         for guards that are not about one repository
# The agent is never named on the command line. The PreToolUse hook kyklos-override-bind.sh sees which agent runs the
# `set` command (the hook input's agent_id; the session's main agent has none) and hands that identity to this CLI
# through a short-lived handoff file. A `set` run outside an agent's tool call (a terminal) binds to the main agent.
# Library (source this file):
#   override_scope_of <dir>                    -> the scope string for a directory (git top folder, else the path)
#   override_hook_scope <json> [dir]           -> the scope of the tool call's working folder (.cwd of the hook input)
#   override_agent_of <json>                   -> the agent a hook input belongs to (agent_id, or "main"); fails on
#                                                 an empty or unreadable input (no identity, no override)
#   override_take <name> <scope> <hook-json>   -> 0 and the marker is removed if THIS agent set it for this scope and it
#                                                 is fresh; 1 otherwise, with a line on stderr saying why
#   override_hold_keep <name> <scope> <hook-json> <item> <content>
#                                              -> after a guard spent a marker on <item> (a story), keep what it excused:
#                                                 <content> is a fingerprint of the code the override covered
#   override_hold_admits <name> <scope> <hook-json> <item> <content>
#                                              -> 0 when the same agent's spent override for <item> in <scope> excused
#                                                 exactly <content>; a hold for other content is dropped, said on stderr
# Marker file: $KYKLOS_STATE_DIR/<name>.<key> (key from agent + scope), lines "scope=", "agent=", "expires=".
# Lifetime: KYKLOS_OVERRIDE_TTL_SECONDS (default 600). Handoff lifetime: 60 seconds.
# Hold file: $KYKLOS_STATE_DIR/.held/<name>.<key> (key from agent + scope + item), lines "scope=", "agent=", "item=",
# "content=", "set=", "expires=". A hold lasts KYKLOS_OVERRIDE_HOLD_SECONDS (default 86400, a day) from the spend. An owner's override excuses CODE, not one attempt: retrying the same arm (a refused push, a merge
# of the trunk that changed none of the covered files) must not need the owner again, so a spent override holds for as
# long as the covered content is the same; any change to it ends the hold.

# The command a guard's message shows for setting an override (an absolute path, so it can be pasted as-is).
# shellcheck source=lib/json-answer.sh
. "$(dirname "${BASH_SOURCE[0]}")/json-answer.sh"   # json_test / json_read: an empty or cut answer is never valid
OVERRIDE_MARKER_CLI="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/override-marker.sh"

# The agent identity of the session's own (main) agent: its hook input carries no agent_id.
OVERRIDE_MAIN_AGENT="main"

override_state_dir() { printf '%s' "${KYKLOS_STATE_DIR:-/tmp/kyklos-state}"; }

override_scope_of() {
    local dir="${1:-}" top=""
    [ "$dir" = "global" ] && { printf 'global'; return 0; }
    [ -n "$dir" ] || dir="$(pwd)"
    top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -n "$top" ]; then printf '%s' "$top"; else (cd "$dir" 2>/dev/null && pwd -P) || printf '%s' "$dir"; fi
}

# override_hook_scope <hook-input-json> [fallback-dir] -> the scope of the folder the tool call runs in (.cwd; without
# one: fallback-dir, else CLAUDE_PROJECT_DIR, else the current folder).
# Every agent sharing a container has the same project folder, so a guard with no better target uses the call's own
# working folder: agents working in their own worktrees then never share an override.
override_hook_scope() {
    local cwd=""
    cwd="$(printf '%s' "${1:-}" | jq -r '.cwd // empty' 2>/dev/null || true)"
    [ -n "$cwd" ] && [ -d "$cwd" ] || cwd="${2:-${CLAUDE_PROJECT_DIR:-$(pwd)}}"
    override_scope_of "$cwd"
}

# override_agent_of <hook-input-json> -> the agent the hook input belongs to: its agent_id (a subagent), else "main".
# [CySec] Prevents CWE-863 "Incorrect Authorization": an input with no readable identity yields NO agent (return 1),
# so a guard can never spend an override on behalf of an unknown caller. [RiskMitigation RA-01]
override_agent_of() {
    local input="${1:-}" agent=""
    [ -n "$input" ] || return 1
    printf '%s' "$input" | json_test 'type == "object"' || return 1
    agent="$(printf '%s' "$input" | jq -r '(.agent_id // empty) | tostring' 2>/dev/null || true)"
    [ -n "$agent" ] || agent="$OVERRIDE_MAIN_AGENT"
    case "$agent" in *[!A-Za-z0-9_.:-]*) return 1 ;; esac
    printf '%s' "$agent"
}

# override_key <agent> <scope> -> the file-name key binding a marker to one agent and one scope.
override_key() { printf '%s\n%s' "$1" "$2" | sha256sum | cut -c1-16; }

# The handoff the bind hook leaves for the CLI: which agent is about to run `set <name>` for <scope>.
override_handoff_file() { printf '%s/.handoff/%s.%s' "$(override_state_dir)" "$1" "$(override_key handoff "$2")"; }

override_handoff_write() {
    local name="$1" scope="$2" agent="$3" file dir
    file="$(override_handoff_file "$name" "$scope")"; dir="$(dirname "$file")"
    mkdir -p "$dir" 2>/dev/null || return 2
    printf 'agent=%s\nexpires=%s\n' "$agent" "$(( $(date +%s) + 60 ))" > "$file" || return 2
}

# override_handoff_take <name> <scope> -> the agent named by a fresh handoff (and removes it), else nothing.
override_handoff_take() {
    local file agent="" expires="" line
    file="$(override_handoff_file "$1" "$2")"
    [ -f "$file" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in agent=*) agent="${line#agent=}" ;; expires=*) expires="${line#expires=}" ;; esac
    done < "$file"
    rm -f "$file" 2>/dev/null
    printf '%s' "$expires" | grep -Ec '^[0-9]+$' >/dev/null || return 1
    [ "$(date +%s)" -le "$expires" ] || return 1
    [ -n "$agent" ] || return 1
    printf '%s' "$agent"
}

override_set() {
    local name="$1" scope="$2" agent="${3:-}" ttl="${KYKLOS_OVERRIDE_TTL_SECONDS:-600}" dir now
    case "$name" in ''|*/*|.*|*.*) echo "override-marker: invalid marker name '$name'" >&2; return 2 ;; esac
    [ -n "$scope" ] || { echo "override-marker: a scope is required" >&2; return 2; }
    case "$agent" in ''|*[!A-Za-z0-9_.:-]*) echo "override-marker: no valid agent identity for '$name'; nothing set" >&2; return 2 ;; esac
    dir="$(override_state_dir)"; mkdir -p "$dir" 2>/dev/null || { echo "override-marker: cannot create $dir" >&2; return 2; }
    now="$(date +%s)"
    printf 'scope=%s\nagent=%s\nexpires=%s\n' "$scope" "$agent" "$((now + ttl))" > "$dir/$name.$(override_key "$agent" "$scope")" || return 2
    return 0
}

# override_others <name> <agent> [scope] -> the live markers of <name> other than <agent>'s own for <scope> (without a
# scope: those of other agents), one "<scope> (agent <a>)" per line.
override_others() {
    local name="$1" agent="$2" want="${3:-}" f a s e line now
    now="$(date +%s)"
    for f in "$(override_state_dir)/$name".*; do
        [ -f "$f" ] || continue
        a=""; s=""; e=""
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in scope=*) s="${line#scope=}" ;; agent=*) a="${line#agent=}" ;; expires=*) e="${line#expires=}" ;; esac
        done < "$f"
        [ -n "$a" ] || continue
        if [ -n "$want" ]; then [ "$a" = "$agent" ] && [ "$s" = "$want" ] && continue; else [ "$a" = "$agent" ] && continue; fi
        printf '%s' "$e" | grep -Ec '^[0-9]+$' >/dev/null && [ "$now" -le "$e" ] && printf '%s (agent %s)\n' "$s" "$a"
    done
    return 0
}

# [RiskMitigation RA-01] A guard spends only the marker its own caller set for this scope, never another agent's.
override_take() {
    local name="$1" want="$2" agent file scope="" owner="" expires="" now line legacy
    legacy="$(override_state_dir)/$name"
    if [ -f "$legacy" ]; then
        rm -f "$legacy" 2>/dev/null
        echo "[kyklos] override '$name' ignored and removed: it is an old-style marker not bound to an agent. Set it with: bash $OVERRIDE_MARKER_CLI set $name <repo-dir|global>" >&2
    fi
    if ! agent="$(override_agent_of "${3:-}")"; then
        ls "$(override_state_dir)/$name".* >/dev/null 2>&1 \
            && echo "[kyklos] override '$name' NOT used: this guard could not tell which agent is calling, so no override applies." >&2
        return 1
    fi
    file="$(override_state_dir)/$name.$(override_key "$agent" "$want")"
    if [ ! -f "$file" ]; then
        local others; others="$(override_others "$name" "$agent" "$want")"
        [ -n "$others" ] && echo "[kyklos] override '$name' NOT used: it is held by another agent or for another target ($(printf '%s' "$others" | paste -sd ';' -)); this command is agent '$agent' on '$want'. It is left for its owner." >&2
        return 1
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in scope=*) scope="${line#scope=}" ;; agent=*) owner="${line#agent=}" ;; expires=*) expires="${line#expires=}" ;; esac
    done < "$file"
    if [ -z "$scope" ] || [ "$scope" != "$want" ] || [ "$owner" != "$agent" ] || ! printf '%s' "$expires" | grep -Ec '^[0-9]+$' >/dev/null; then
        rm -f "$file" 2>/dev/null
        echo "[kyklos] override '$name' ignored and removed: the marker is malformed. Set it with: bash $OVERRIDE_MARKER_CLI set $name <repo-dir|global>" >&2
        return 1
    fi
    now="$(date +%s)"
    if [ "$now" -gt "$expires" ]; then
        rm -f "$file" 2>/dev/null
        echo "[kyklos] override '$name' ignored and removed: it expired (set for '$scope'). Set it again right before the command it is for." >&2
        return 1
    fi
    rm -f "$file" 2>/dev/null
    return 0
}

# _override_hold_file <name> <agent> <scope> <item> -> the hold file of that agent's spent override for <item> in <scope>.
_override_hold_file() { printf '%s/.held/%s.%s' "$(override_state_dir)" "$1" "$(printf '%s\n%s\n%s' "$2" "$3" "$4" | sha256sum | cut -c1-16)"; }

# override_hold_keep <name> <scope> <hook-json> <item> <content> -> records that the agent of <hook-json> spent its
# override <name> on <item> in <scope> for exactly <content>. Best effort: a hold that cannot be written only means the
# owner is asked again on a retry. rc 1 without an agent, an item or a content.
override_hold_keep() {
    local name="$1" scope="$2" agent file item="${4:-}" content="${5:-}"
    agent="$(override_agent_of "${3:-}")" || return 1
    [ -n "$item" ] && [ -n "$content" ] || return 1
    case "$item$content" in *[!A-Za-z0-9_.:-]*) return 1 ;; esac
    file="$(_override_hold_file "$name" "$agent" "$scope" "$item")"
    mkdir -p "$(dirname "$file")" 2>/dev/null || return 1
    local ttl="${KYKLOS_OVERRIDE_HOLD_SECONDS:-86400}"
    case "$ttl" in ''|*[!0-9]*) ttl=86400 ;; esac
    printf 'scope=%s\nagent=%s\nitem=%s\ncontent=%s\nset=%s\nexpires=%s\n' "$scope" "$agent" "$item" "$content" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(( $(date +%s) + ttl ))" > "$file" 2>/dev/null
}

# override_hold_admits <name> <scope> <hook-json> <item> <content> -> rc 0 when this agent's override <name>, spent on
# <item> in <scope>, excused exactly <content> and has not run out (OVERRIDE_HOLD_SET then says when it was spent). A hold
# for other content (the covered code changed since) or past its time is removed and said on stderr; anything unreadable
# admits nothing.
# [CySec] Prevents CWE-863 "Incorrect Authorization": a hold admits only the agent, scope, item and content it was spent
# on; any change to the covered code needs the owner's decision again. [RiskMitigation RA-01]
OVERRIDE_HOLD_SET=""
override_hold_admits() {
    local name="$1" scope="$2" agent file item="${4:-}" content="${5:-}" line s="" a="" i="" c="" t="" e=""
    OVERRIDE_HOLD_SET=""
    agent="$(override_agent_of "${3:-}")" || return 1
    [ -n "$item" ] && [ -n "$content" ] || return 1
    file="$(_override_hold_file "$name" "$agent" "$scope" "$item")"
    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in scope=*) s="${line#scope=}" ;; agent=*) a="${line#agent=}" ;; item=*) i="${line#item=}" ;; content=*) c="${line#content=}" ;; set=*) t="${line#set=}" ;; expires=*) e="${line#expires=}" ;; esac
    done < "$file"
    # A hold written before holds had a time limit carries no expiry: it runs out a day after the file was written.
    if ! [[ "$e" =~ ^[0-9]+$ ]]; then e="$(( $(stat -c %Y -- "$file" 2>/dev/null || echo 0) + 86400 ))"; fi
    if [ "$(date +%s)" -gt "$e" ]; then
        rm -f "$file" 2>/dev/null
        echo "[kyklos] override '$name' spent on $item no longer holds: its time ran out (spent ${t:-at an unknown time}; a spent override holds for a day), so it needs the owner's decision again." >&2
        return 1
    fi
    if [ "$s" = "$scope" ] && [ "$a" = "$agent" ] && [ "$i" = "$item" ] && [ -n "$c" ] && [ "$c" = "$content" ]; then
        OVERRIDE_HOLD_SET="$t"; return 0
    fi
    rm -f "$file" 2>/dev/null
    echo "[kyklos] override '$name' spent on $item no longer holds: the code it covered changed since (spent ${t:-at an unknown time}), so it needs the owner's decision again." >&2
    return 1
}

# CLI
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set +e +u +o pipefail   # run as a command: declare the options, never inherit them from an exported SHELLOPTS
    case "${1:-}" in
        set)
            [ $# -eq 3 ] || { echo "usage: override-marker.sh set <name> <repo-dir|global>" >&2; exit 2; }
            scope="$(override_scope_of "$3")"
            agent="$(override_handoff_take "$2" "$scope" || true)"
            [ -n "$agent" ] || agent="$OVERRIDE_MAIN_AGENT"
            override_set "$2" "$scope" "$agent" || exit $?
            echo "override-marker: '$2' set for '$scope', agent '$agent' (valid ${KYKLOS_OVERRIDE_TTL_SECONDS:-600}s, spent once by that agent's matching guard run)"
            others="$(override_others "$2" "$agent")"
            [ -n "$others" ] && printf 'override-marker: other live "%s" overrides, left untouched: %s\n' "$2" "$(printf '%s' "$others" | paste -sd ';' -)"
            ;;
        *) echo "usage: override-marker.sh set <name> <repo-dir|global>" >&2; exit 2 ;;
    esac
fi
