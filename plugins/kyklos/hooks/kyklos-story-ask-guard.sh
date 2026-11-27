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
. "$(dirname "${BASH_SOURCE[0]}")/lib/json-escape.sh" 2>/dev/null || true   # kyklos_json_escape: the one escaper for text inside a JSON answer
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
ASKED="$(printf '%s\n' "$DETECTED" | awk '$1 == "ask" { print $2 "\t" $3 }')"
[ -n "$ASKED" ] || clean_stop
LINKED="$(printf '%s\n' "$DETECTED" | awk '$1 == "linked" { print $2 "\t" $3 }')"
HOME_PROJECT="${STORY_GITLAB_PROJECT:-}"

# The posts of this session, each as "<item>TAB<project the call named>TAB<project path of the note link>" (an empty
# field means the call named none: the session's home project). Found by the candidate calls first (cheap grep), then
# their answers by id, so a long transcript is never parsed whole. Only a post PROVEN on that item counts: a shell
# command counts only when one of the commands it runs IS `story ask` or `agent-msg reply|new` (after optional
# environment assignments, a wrapper such as `timeout 60` or `bash -c '...'`, a path; inside `$(...)` too, see
# posting_segments), so a command that merely mentions them (`agent-msg show 42`, `grep "story ask"`) never does, and
# its note link or "replied on" line must name the item the command was given.
CALLS="$(grep -E '"tool_use"' -- "$TRANSCRIPT" 2>/dev/null | grep -E 'story_note|coordination_reply|agent-msg|story.{0,40}ask' \
    | jq -c '(.message.content // .content) | if type == "array" then .[] else empty end
             | select(type == "object" and .type == "tool_use")
             | {id, name, cmd: (.input.command // ""), project: ((.input.project // "") | tostring), item: ((.input.id // .input.iid // "") | tostring)}
             | select((.name | test("(^|__)(story_note|coordination_reply)$")) or .name == "Bash")' 2>/dev/null)"
POSTED=""
if [ -n "$CALLS" ]; then
    IDS="$(printf '%s\n' "$CALLS" | jq -r '.id // empty' 2>/dev/null)"
    ANSWERS="$(grep -F -- "$IDS" "$TRANSCRIPT" 2>/dev/null | grep -E '"tool_result"' \
        | jq -c '(.message.content // .content) | if type == "array" then .[] else empty end
                 | select(type == "object" and .type == "tool_result")
                 | {id: .tool_use_id, error: (.is_error // false),
                    text: (.content | if type == "string" then . else ([.[]? | select(type == "object") | .text // empty] | join("\n")) end)}' 2>/dev/null)"
    POSTED="$(jq -rn --slurpfile calls <(printf '%s\n' "$CALLS") --slurpfile answers <(printf '%s\n' "$ANSWERS") '
        # The commands a shell command line runs, one per line: the line is cut at &, |, ;, a newline, ( and ) and a
        # backtick only where the shell would cut it, outside quotes. Inside single quotes nothing is cut; inside double
        # quotes only a command substitution ($( or a backtick) opens a new command, and its closing ) or backtick
        # returns to the quote it was opened in. A backslash outside single quotes keeps the next character.
        def shell_commands:
            reduce (split("")[]) as $c ({o: "", q: "", st: [], esc: false, prev: ""};
                if .esc then .o += $c | .esc = false
                elif .q == "\u0027" then (if $c == "\u0027" then .q = "" else . end) | .o += $c
                elif $c == "\\" then .o += $c | .esc = true
                elif $c == "`" then
                    (if ((.st | length) > 0 and (.st[-1] | startswith("`"))) then .q = (.st[-1] | .[1:]) | .st |= .[:-1]
                     else .st += ["`" + .q] | .q = "" end) | .o += "\n"
                elif .q == "\"" then
                    if $c == "\"" then .q = "" | .o += $c
                    elif $c == "(" and .prev == "$" then .st += [.q] | .q = "" | .o += "\n"
                    else .o += $c end
                elif $c == "\u0027" or $c == "\"" then .q = $c | .o += $c
                elif $c == "(" then .st += [""] | .o += "\n"
                elif $c == ")" and (.st | length) > 0 and ((.st[-1] | startswith("`")) | not) then .q = .st[-1] | .st |= .[:-1] | .o += "\n"
                elif $c == ";" or $c == "|" or $c == "&" or $c == "\n" then .o += "\n"
                else .o += $c end
                | .prev = $c)
            | .o | split("\n")[];
        # The posting commands of a shell command line, each as {verb, rest}: a command (shell_commands) posts when,
        # after environment assignments, a wrapper (timeout <n>, env, nice, nohup, command, exec, time, bash or sh with
        # their flags such as -c) and their opening quotes, and an optional path (quoted or not), it runs
        # `story ask`, `agent-msg reply` or `agent-msg new`. A command that only mentions them (grep, agent-msg show, a
        # quoted text) never matches, because the verb must be the command itself.
        def posting_segments:
            [shell_commands
             | capture("^[\\s\"\u0027]*(?:(?:[A-Za-z_][A-Za-z0-9_]*=\\S*|timeout(?:\\s+-\\S+(?:\\s+[A-Z0-9]+)?)*\\s+[0-9.]+[smhd]?|env(?:\\s+-\\S+)*|nice(?:\\s+-n\\s*-?[0-9]+|\\s+-[0-9]+)?|nohup|command|exec|time|(?:bash|sh)(?:\\s+-[A-Za-z]+)*)\\s+[\"\u0027]*)*(?:\"[^\"]*/|\u0027[^\u0027]*/|[^\\s\"\u0027]*/)?(?<verb>story[\"\u0027]?\\s+ask|agent-msg[\"\u0027]?\\s+(?:reply|new))(?=[\\s\"\u0027)]|$)(?<rest>.*)$")];
        # The item a posting command was given: its first argument that is not an option or an option value (every
        # option of story ask and agent-msg reply takes a value), read the way the story tool reads a story key: a
        # leading hash, the upper- or lower-case story key prefix, a slug after the number and leading zeros are
        # dropped, so the key form of story 42 names 42.
        def first_item:
            [scan("\"[^\"]*\"|\u0027[^\u0027]*\u0027|\\S+")] as $t
            | (reduce range(0; $t | length) as $i ({skip: false, item: null};
                  if .item != null then .
                  elif .skip then .skip = false
                  elif ($t[$i] | startswith("--")) then .skip = ($t[$i] | test("=") | not)
                  else .item = $t[$i] end)
               | .item // "")
            | gsub("[\"\u0027`)(#]"; "") | sub("^(?:STORY|story)-"; "") | sub("-.*$"; "") | sub("^0+(?=[0-9])"; "")
            | select(test("^[0-9]+$"));
        ($answers | map({(.id): .}) | add // {}) as $by
        | $calls[] | . as $c | ($by[$c.id] // empty) | select(.error | not) | .text as $t
        | if $c.name == "Bash" then
              ($c.cmd | posting_segments) as $segs
              | if ($segs | length) == 0 then empty else
                    ($c.cmd | ([scan("STORY_GITLAB_PROJECT=([^\\s]+)"), scan("--project[ =]([^\\s]+)")] | flatten | .[0] // "") | gsub("[\"\u0027]"; "")) as $pp
                    | ($segs | any(.verb | test("new$"))) as $isnew
                    | ($segs | map(.rest | first_item)) as $args
                    | ([($t | scan("https?://[^/\\s]+/(\\S*?)/-/issues/([0-9]+)#note_[0-9]+") | {iid: .[1], lp: .[0]}),
                        ($t | scan("replied on #([0-9]+)") | {iid: .[0], lp: ""}),
                        ($t | scan("opened #([0-9]+)") | {iid: .[0], lp: ""}),
                        ($t | scan("posted the note on story ([0-9]+)") | {iid: .[0], lp: ""})]
                       | .[] | select($isnew or (.iid as $i | $args | index($i) != null))
                       | "\(.iid)\t\($pp)\t\(.lp)")
                end
          elif ($c.name | test("story_note$")) and ($t | test("\\[shadow\\]")) then empty
          else ($c.item | gsub("[^0-9]"; "")) as $iid | select($iid | length > 0) | "\($iid)\t\($c.project)\t"
          end' 2>/dev/null)"
fi

# path_match <a> <b>: two project paths name the same project (equal, or one is the other's trailing part).
path_match() { local a="${1,,}" b="${2,,}"; [ -n "$a" ] && [ -n "$b" ] && { [ "$a" = "$b" ] || [[ "$a" == */"$b" ]] || [[ "$b" == */"$a" ]]; }; }
is_number() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }
# on_project <call's project> <note link's project> <question's project>: the post is proven to be on the project the
# question is about. A question that names a project needs the post's project proven equal to it; a question that
# names none is about the home project, so only a PROVEN other project refuses it (an unknown home lets it through).
on_project() {
    local pp="$1" lp="$2" qp="$3"
    if [ -n "$qp" ]; then
        if [ -n "$lp" ]; then path_match "$lp" "$qp"; return; fi
        if [ -n "$pp" ]; then is_number "$pp" && return 1; path_match "$pp" "$qp"; return; fi
        path_match "$HOME_PROJECT" "$qp"; return
    fi
    if [ -n "$lp" ] && [ -n "$HOME_PROJECT" ] && ! is_number "$HOME_PROJECT"; then path_match "$lp" "$HOME_PROJECT" || return 1; fi
    [ -z "$pp" ] || [ -z "$HOME_PROJECT" ] && return 0
    if is_number "$pp" && is_number "$HOME_PROJECT"; then [ "$pp" = "$HOME_PROJECT" ]; return; fi
    if ! is_number "$pp" && ! is_number "$HOME_PROJECT"; then path_match "$pp" "$HOME_PROJECT"; return; fi
    return 0
}

UNPOSTED=""
while IFS=$'\t' read -r iid qp; do
    [ -n "$iid" ] || continue
    found=0
    while IFS=$'\t' read -r piid pp lp; do
        [ "$piid" = "$iid" ] || continue
        on_project "$pp" "$lp" "$qp" && { found=1; break; }
    done <<<"$POSTED"
    if [ "$found" -eq 0 ]; then
        while IFS=$'\t' read -r liid lqp; do
            [ "$liid" = "$iid" ] || continue
            on_project "" "$lqp" "$qp" && { found=1; break; }
        done <<<"$LINKED"
    fi
    [ "$found" -eq 1 ] && continue
    UNPOSTED="${UNPOSTED:+$UNPOSTED, }$iid"
done <<<"$ASKED"
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
reason="$(kyklos_json_escape "$reason")"
printf '{"decision":"block","reason":"%s"}' "$reason"
exit 0
