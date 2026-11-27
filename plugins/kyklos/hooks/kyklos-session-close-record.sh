#!/usr/bin/env bash
# kyklos-session-close-record.sh -- PostToolUse on the bridge's story_close verb. Records a close the agent made
# directly through the bridge as this session's close (hooks/lib/session-closes.sh), exactly as `story close` records
# its own, so the Stop-time proof check judges it. Without it a close through the bridge verb would escape that check.
#
# Records only a close the bridge answered as done: a result that is not an error whose first line is "closed", alone or
# followed by " (" and what the close judged (the verb's real answer: "closed (coverage: ...)"). The
# story's project is the one the call names (project), else the session's STORY_GITLAB_PROJECT (environment, then the
# project's .claude/standards.env). A project named by its path is recorded under that path; the Stop-time check
# reads both spellings of its project (id and path), so either one is judged. It never fails the tool call; a broken install (the JSON reader missing) is answered by name, like every other hook.
# Wired: PostToolUse, matcher mcp__KyklosBridge__story_close.
set +e -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# [no-fail-open] Without the record library this close cannot be recorded, so the Stop-time check would never judge it:
# said loudly (a broken install), never in silence. The tool call itself is never failed.
if ! . "$HERE/lib/session-closes.sh" 2>/dev/null || ! command -v session_close_record >/dev/null 2>&1; then
    echo "[kyklos] WARNING: hooks/lib/session-closes.sh did not load (a broken kyklos install), so this story_close is not recorded and the Stop-time proof check will not judge it. Reinstall kyklos." >&2
    echo "$(. "$HERE/lib/help-link.sh" 2>/dev/null && kyklos_help_line broken-install)" >&2
    exit 0
fi
# [json-answer-required] The tool's answer is read through the JSON reader, never jq -e (which accepts an empty answer).
. "$HERE/lib/json-answer.sh" 2>/dev/null
if ! command -v json_test >/dev/null 2>&1; then
    printf '{"decision":"block","reason":"BLOCKED (%s): the JSON reader hooks/lib/json-answer.sh did not load (broken install), so this story_close cannot be recorded and the Stop-time proof check will not judge it. Reinstall or repin the kyklos plugin.%s"}\n' "$(basename "$0")" "$(. "$HERE/lib/help-link.sh" 2>/dev/null && kyklos_help_json_suffix broken-install)"
    exit 0
fi
command -v jq >/dev/null 2>&1 || exit 0
INPUT="$(cat || true)"
[ "$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)" = mcp__KyklosBridge__story_close ] || exit 0
# The tool's answer: an error result never records.
printf '%s' "$INPUT" | json_test '(.tool_response // {}) | (type == "object" and .isError == true)' && exit 0
text="$(printf '%s' "$INPUT" | jq -r '(.tool_response // "") | if type == "string" then . elif type == "array" then (map(select(.type? == "text") | .text) | join("\n")) else ((.content // []) | map(select(.type? == "text") | .text) | join("\n")) end' 2>/dev/null)"
# The verb's answer is its first line: "closed" alone, or "closed (" and what the close judged (a note may follow on
# later lines). Any other first line (a refusal, a pending answer) records nothing.
printf '%s\n' "$text" | tr -d '\r' | head -1 | grep -cE '^[[:space:]]*closed([[:space:]]*$| \()' >/dev/null || exit 0
id="$(printf '%s' "$INPUT" | jq -r '.tool_input.id // empty | tostring' 2>/dev/null | grep -oE '[0-9]+' | head -1)"
[ -n "$id" ] || exit 0
project="$(printf '%s' "$INPUT" | jq -r '.tool_input.project // empty | tostring' 2>/dev/null)"
if [ -z "$project" ]; then
    project="${STORY_GITLAB_PROJECT:-}"
    if [ -z "$project" ]; then
        . "$HERE/lib/standards-env.sh" 2>/dev/null \
            && project="$(standards_env_value "${CLAUDE_PROJECT_DIR:-$PWD}/.claude/standards.env" STORY_GITLAB_PROJECT 2>/dev/null)"
    fi
fi
[ -n "$project" ] || exit 0
session_close_record "$(session_close_scope_gitlab "$project")" "$((10#$id))"
exit 0
