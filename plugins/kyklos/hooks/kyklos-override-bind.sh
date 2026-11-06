#!/usr/bin/env bash
# kyklos-override-bind.sh (Kyklos, PreToolUse on Bash) - binds a one-shot guard override to the agent that sets it.
#
# Several agents share one container (a session and the subagents it starts) and one override store. An override set
# by one agent must never be overwritten or spent by another. A guard knows which agent calls it from its hook input
# (agent_id, absent for the session's main agent), but the `override-marker.sh set` command runs as a plain shell
# command and cannot tell who runs it. This hook sees the agent of the Bash call and leaves a short-lived handoff
# naming it for the CLI, which then writes the marker for that agent only.
#
# It refuses a command that touches the handoff store itself, the one way an agent could name a different agent.
# DEFAULT-ON; it only acts on commands that run override-marker.sh set or touch the handoff store. Any parse error on
# an unrelated command -> silent exit 0.
# [json-answer-required] Every answer this hook reads goes through the JSON reader; without it a check would exit 127
# and fall into a fail-open path, so the hook refuses by name instead (a broken install). [CySec] CWE-636
. "$(dirname "${BASH_SOURCE[0]}")/lib/json-answer.sh" 2>/dev/null
if ! command -v json_test >/dev/null 2>&1; then
    printf '{"decision":"block","reason":"BLOCKED (%s): the JSON reader hooks/lib/json-answer.sh did not load (broken install), so this check cannot run. Reinstall or repin the kyklos plugin."}\n' "$(basename "$0")"
    exit 0
fi
set +e -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v jq >/dev/null 2>&1 || exit 0

INPUT="$(cat 2>/dev/null || true)"
[ -n "$INPUT" ] || exit 0
[ "$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)" = "Bash" ] || exit 0
cmd="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
[ -n "$cmd" ] || exit 0

# shellcheck source=lib/override-marker.sh
. "$HERE/lib/override-marker.sh"

block() {
    jq -cn --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
    exit 0
}

# [CySec] Prevents CWE-863 "Incorrect Authorization": the handoff is the only link between an agent and the marker the
# CLI writes, so no command may read, write or remove it directly. [RiskMitigation RA-01]
case "$cmd" in
    *"/.handoff"*|*".handoff/"*)
        block "Refused: this command touches the guard-override handoff store. An override is bound to the agent that sets it by the kyklos-override-bind hook; set one with: bash $OVERRIDE_MARKER_CLI set <name> <repo-dir|global>" ;;
esac

case "$cmd" in *override-marker.sh*) ;; *) exit 0 ;; esac

agent="$(override_agent_of "$INPUT")" || block "Refused: the calling agent cannot be identified, so no override can be bound to it."
cwd="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"
[ -n "$cwd" ] && [ -d "$cwd" ] || cwd="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# Each `override-marker.sh set <name> <target>` in the command (quotes removed) gets a handoff for this agent.
while IFS= read -r line; do
    name="$(printf '%s' "$line" | awk '{print $1}')"
    target="$(printf '%s' "$line" | awk '{print $2}')"
    [ -n "$name" ] && [ -n "$target" ] || continue
    # [CySec] Hardens CWE-863: a target this hook cannot resolve (a variable, a command substitution, ~) would leave no
    # handoff, and the CLI would bind the override to the main agent instead of the caller. Refuse it instead.
    case "$target" in
        *'$'*|*'`'*|'~'*) block "Refused: 'override-marker.sh set $name $target' names its target through the shell; the override could not be bound to you. Use a literal folder path (or global)." ;;
    esac
    case "$target" in
        global) scope="global" ;;
        /*) scope="$(override_scope_of "$target")" ;;
        *) scope="$(cd "$cwd" 2>/dev/null && override_scope_of "$target")" ;;
    esac
    [ -n "$scope" ] && override_handoff_write "$name" "$scope" "$agent"
done < <(printf '%s' "$cmd" | tr -d "\"'" | grep -oE 'override-marker\.sh[[:space:]]+set[[:space:]]+[^[:space:];&|]+[[:space:]]+[^[:space:];&|]+' \
            | sed -E 's/^override-marker\.sh[[:space:]]+set[[:space:]]+//')
exit 0
