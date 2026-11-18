#!/usr/bin/env bash
# kyklos-story-ask-guard.sh (Kyklos) - Stop hook: a question to the owner about a story is asked ON the story.
#
# The policy asks every question for the owner that concerns a story or issue as a tickable note on that story
# (`story ask <id> --file <file>`), with the terminal pointing to the note. A question asked only in the closing
# message of a turn is lost when the person is away, and a block on the user's answer has no note to link. This hook
# refuses to end a turn whose closing message asks the owner something about a story or issue, unless a note was
# posted on that story or issue during this session, or the closing message links a note on it.
#
# WHAT COUNTS AS AN ASK (lib/story-ask-detect.pl): a sentence of the closing message that ends with a question mark,
# is addressed to the owner (you, your, "should I", approve, confirm, decide, which, whether, ...) and names a story or
# issue in that very sentence (or in a parenthesis right after its question mark); or the owner-blocker form ("Blocked
# on you: ... ?") naming one. A status line before an unrelated question, a generic continuation question ("Do you want
# me to continue?") and a question the message answers itself never count; a bare number is not a reference (only
# "#<n>", "story <n>", "issue <n>" and the like). Code, quotes and code spans are not read. A closing message with no
# such question is never refused.
#
# WHAT COUNTS AS POSTED (read from this session's transcript, the tool calls and their answers): a `story ask` or
# `agent-msg` shell command that succeeded and answered a note link on the item (".../-/issues/<iid>#note_<n>"),
# "replied on #<iid>" or "opened #<iid>"; or a bridge call of story_note (not in shadow mode) or coordination_reply
# that succeeded, for the item it names. A note link on the item in the closing message also admits it (a reminder
# that points to a note asked earlier).
#
# NEVER A WEDGE: when the check cannot tell (no transcript, an unreadable one, no jq or perl) it lets the stop
# through and says so on stderr. The same refusal (the same unposted items) is given at most
# STORY_ASK_GUARD_REPEAT_LIMIT times in a row (a stop that is not refused in between starts the count again); the
# next identical stop is let through with a loud note, so an agent
# whose `story ask` cannot post (the bridge is down) is never held forever. It deliberately does not read
# stop_hook_active: that flag is set whenever ANY Stop hook continued the agent (the continue-guard does so on every
# stop with open work), so honouring it would skip this check on most autonomous turns.
#
# Off-switch (greppable): KYKLOS_STORY_ASK_CHECK=off (environment or .claude/standards.env). Wired in hooks.json
# under "Stop".
set +e -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/control-switch.sh
. "$HERE/lib/control-switch.sh" 2>/dev/null || true   # kyklos_control_off: the one control-switch reader
# shellcheck source=lib/standards-env.sh
. "$HERE/lib/standards-env.sh" 2>/dev/null && load_standards_env "${CLAUDE_PROJECT_DIR:-$(pwd)}/.claude/standards.env"   # PARSE, never source (CWE-829)

kyklos_control_off "${KYKLOS_STORY_ASK_CHECK:-}" && exit 0

INPUT="$(cat || true)"
readonly STORY_ASK_GUARD_REPEAT_LIMIT=2
# The repeat counter of this session; every stop that is let through as clean resets it, so "in a row" means in a row.
STATE_DIR="${KYKLOS_STATE_DIR:-/tmp/kyklos-state}"
SID="$(printf '%s' "$INPUT" | jq -r '.session_id // "nosession"' 2>/dev/null | tr -c 'A-Za-z0-9_-' '_')"
COUNT_FILE="$STATE_DIR/story-ask-guard.${SID:-nosession}"
clean_stop() { rm -f -- "$COUNT_FILE" 2>/dev/null; exit 0; }
cannot_tell() { printf '[kyklos] story-ask guard: could not check whether the closing message asks the owner about a story without a note on it (%s); this stop is let through.\n' "$1" >&2; exit 0; }

command -v jq >/dev/null 2>&1 || cannot_tell "jq is not installed"
command -v perl >/dev/null 2>&1 || cannot_tell "perl is not installed"
TRANSCRIPT="$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)"
[ -n "$TRANSCRIPT" ] || cannot_tell "the stop names no transcript"
[ -f "$TRANSCRIPT" ] && [ -r "$TRANSCRIPT" ] || cannot_tell "the transcript cannot be read"

# The closing message: the text of the assistant entries after the last user entry (a prompt or a tool answer).
# A tool input is never read as the closing message. `tail -n 400` bounds the window: the closing message is the end of
# the transcript, and a turn whose closing text spans more than 400 transcript lines is read only in its last 400, so
# a long transcript is never loaded whole.
CLOSING="$(tail -n 400 -- "$TRANSCRIPT" 2>/dev/null | jq -rs '
    (map((.type // .message.role // .role // "") as $r | if $r == "user" then "user" elif $r == "assistant" then "assistant" else "other" end) ) as $roles
    | ([range(0; length) | select($roles[.] == "user")] | last // -1) as $cut
    | [.[($cut + 1):][] | select((.type // .message.role // .role) == "assistant")
       | (.message.content // .content) | if type == "string" then . else (.[]? | select(type == "object" and .type == "text") | .text // empty) end]
    | join("\n")' 2>/dev/null)" || cannot_tell "the transcript is not readable JSON lines"
[ -n "$CLOSING" ] || clean_stop

DETECTED="$(printf '%s' "$CLOSING" | perl "$HERE/lib/story-ask-detect.pl" 2>/dev/null)" || cannot_tell "the question reader failed"
ASKED="$(printf '%s\n' "$DETECTED" | awk '$1 == "ask" { print $2 }')"
[ -n "$ASKED" ] || clean_stop
LINKED="$(printf '%s\n' "$DETECTED" | awk '$1 == "linked" { print $2 }')"

# The items a note was posted on this session. The candidate calls are found first (cheap grep), then their answers
# by id, so a long transcript is never parsed whole.
CALLS="$(grep -E '"tool_use"' -- "$TRANSCRIPT" 2>/dev/null | grep -E 'story_note|coordination_reply|agent-msg|story[^"]{0,40}ask' \
    | jq -c '(.message.content // .content) | if type == "array" then .[] else empty end
             | select(type == "object" and .type == "tool_use")
             | {id, name, cmd: (.input.command // ""), item: ((.input.id // .input.iid // "") | tostring)}
             | select((.name | test("(^|__)(story_note|coordination_reply)$")) or (.name == "Bash" and (.cmd | test("agent-msg|(^|[/[:space:]])story[^[:space:]]*[[:space:]]+ask[[:space:]]"))))' 2>/dev/null)"
POSTED=""
if [ -n "$CALLS" ]; then
    IDS="$(printf '%s\n' "$CALLS" | jq -r '.id // empty' 2>/dev/null)"
    ANSWERS="$(grep -F -- "$IDS" "$TRANSCRIPT" 2>/dev/null | grep -E '"tool_result"' \
        | jq -c '(.message.content // .content) | if type == "array" then .[] else empty end
                 | select(type == "object" and .type == "tool_result")
                 | {id: .tool_use_id, error: (.is_error // false),
                    text: (.content | if type == "string" then . else ([.[]? | select(type == "object") | .text // empty] | join("\n")) end)}' 2>/dev/null)"
    POSTED="$(jq -rn --slurpfile calls <(printf '%s\n' "$CALLS") --slurpfile answers <(printf '%s\n' "$ANSWERS") '
        ($answers | map({(.id): .}) | add // {}) as $by
        | $calls[] | . as $c | ($by[$c.id] // empty) | select(.error | not) | .text as $t
        | if $c.name == "Bash" then
              ($t | [scan("/-/issues/([0-9]+)#note_[0-9]+"), scan("replied on #([0-9]+)"), scan("opened #([0-9]+)"), scan("posted the note on story ([0-9]+)")] | .[][])
          elif ($c.name | test("story_note$")) and ($t | test("\\[shadow\\]")) then empty
          else ($c.item | gsub("[^0-9]"; ""))
          end
        | select(length > 0) | tonumber | tostring' 2>/dev/null)"
fi

UNPOSTED=""
for iid in $ASKED; do
    grep -cxF -- "$iid" <<<"$(printf '%s\n' "$POSTED" "$LINKED")" >/dev/null && continue
    UNPOSTED="${UNPOSTED:+$UNPOSTED, }$iid"
done
[ -n "$UNPOSTED" ] || clean_stop

# Repeat limit: the same refusal is given at most STORY_ASK_GUARD_REPEAT_LIMIT times in a row in this session.
mkdir -p "$STATE_DIR" 2>/dev/null || true
last_sig=""; count=0
[ -r "$COUNT_FILE" ] && read -r last_sig count < "$COUNT_FILE" 2>/dev/null
SIG="$(printf '%s' "$UNPOSTED" | tr -d ' ')"
if [ "$SIG" = "$last_sig" ]; then count=$((count + 1)); else count=1; fi
if [ "$count" -gt "$STORY_ASK_GUARD_REPEAT_LIMIT" ]; then
    rm -f -- "$COUNT_FILE" 2>/dev/null
    printf '[kyklos] story-ask guard: LET THROUGH after %s identical refusals: the closing message still asks the owner about %s with no note posted on it this session. The question is NOT on the story; post it there (story ask <id> --file <file>) as soon as you can.\n' "$STORY_ASK_GUARD_REPEAT_LIMIT" "$UNPOSTED" >&2
    exit 0
fi
printf '%s %s\n' "$SIG" "$count" > "$COUNT_FILE" 2>/dev/null

reason="BLOCKED (story-ask guard): your closing message asks the owner about story or issue ${UNPOSTED}, but no note asking it was posted on that item in this session. A question for the owner about a story is asked ON the story, so it is recorded next to the work and the owner is notified. Write the question (context, references, why it is theirs, each option with its effect, one tickable box per option) into a file with your editor tool, run: story ask <id> --file <that file>, and in the closing message point to the note link it prints (for a coordination issue: agent-msg reply <iid> \"<body>\"). Then block the story on the answer: story block <id> --kind user --on <the link> --reason $'<what blocks it>\nsearched: <what you looked at>'. If the closing message only reports and asks nothing, rephrase it without the question. Off-switch: KYKLOS_STORY_ASK_CHECK=off."
reason="${reason//\\/\\\\}"; reason="${reason//\"/\\\"}"; reason="$(printf '%s' "$reason" | tr '\n' ' ')"
printf '{"decision":"block","reason":"%s"}' "$reason"
exit 0
