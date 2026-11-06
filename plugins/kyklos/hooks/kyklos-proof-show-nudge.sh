#!/usr/bin/env bash
# kyklos-proof-show-nudge.sh (Kyklos) - PostToolUse(Bash), ADVISORY (never blocks). Fires the instant a `story close`
# runs and hands that story's Proof (the terminal form the close printed) straight back to the agent with a hard
# instruction to show it, exactly as printed, in the reply. The remote user cannot see a GitLab proof NOTE - only the agent's reply - so a close whose table is not
# shown is invisible to them. This is the PROACTIVE half of the "show the Proof table" rule: the Stop-time
# kyklos-story-proof-guard is the un-bypassable BACKSTOP (it blocks the stop until the table is in the transcript), but
# waiting for a later Stop meant the agent kept satisfying it reactively; this hook puts the demand + the exact table
# in front of the agent AT CLOSE, so it is shown in the same turn.
#
# Wired: PostToolUse, matcher Bash.
set +e -uo pipefail

INPUT="$(cat || true)"
command -v jq >/dev/null 2>&1 || exit 0

CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
[ -n "$CMD" ] || exit 0

# Only act on a `story close <id>` invocation. Match the tool path or a bare `story`, then the `close` verb + an id.
printf '%s' "$CMD" | grep -cE '(^|[/[:space:]"'"'"'])story([[:space:]]|$)' >/dev/null || exit 0
printf '%s' "$CMD" | grep -cE 'close([[:space:]])' >/dev/null || exit 0
ID="$(printf '%s' "$CMD" | grep -oE 'close[[:space:]]+"?(STORY-)?[0-9]+' | grep -oE '[0-9]+' | head -1)"
[ -n "$ID" ] || exit 0
ID="$((10#$ID))"   # normalise zero-padded ids (0042 -> 42) so the receipt match below is exact

# Best-effort render of the CANONICAL proof table via the story tool, so the exact rows+tally are handed to the agent
# (never a paraphrase). Load the project's backend config the SAME way the story tool + guards do. If the render fails
# for any reason we STILL emit the demand (fail-safe: always nudge), just without the pre-rendered table.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
_se="$(dirname "${BASH_SOURCE[0]}")/lib/standards-env.sh"
[ -f "$_se" ] && { . "$_se" 2>/dev/null && load_standards_env "$PROJECT_DIR/.claude/standards.env" 2>/dev/null; } || true
STORY_TOOL="${KYKLOS_PROOF_SHOW_STORY_TOOL:-$(dirname "${BASH_SOURCE[0]}")/../skills/ssdlc-story/story}"   # override = hermetic test seam

# Take the proof table from the CLOSE COMMAND'S OWN OUTPUT, never a re-render. `story close` PRINTS the exact
# proof table for the story it closed (in the project IT resolved), so tool_response.stdout is authoritative and can
# never be the wrong story. A re-render (`story proof $ID` in a reconstructed env) could not see the close's
# EXPORTED project settings and could render a different project's same-numbered story; reading the close's own
# stdout means the table shown is always the one the close actually produced.
CLOSE_OUT="$(printf '%s' "$INPUT" | jq -r '[.tool_response.stdout?, .tool_response.output?, (.tool_response|strings)] | map(select(type=="string")) | .[0] // empty' 2>/dev/null || true)"

# Announce ONLY a close that SUCCEEDED. `story close` prints a close receipt as its LAST line only after every gate
# passed; a refused close exits before it (its "close: refusing" message goes to stderr, and a pipe such as `| tail`
# can even turn the exit status into 0). So the receipt for THIS id, in the close's own output, is the sole evidence
# accepted: no receipt -> stay silent (a refused, failed or output-less close is never reported as done). The
# Stop-time proof guard remains the backstop for a successful close whose output was discarded.
_all_out="$(printf '%s' "$INPUT" | jq -r '[.tool_response.stdout?, .tool_response.output?, .tool_response.stderr?, (.tool_response|strings)] | map(select(type=="string")) | join("\n")' 2>/dev/null || true)"
printf '%s' "$_all_out" | grep -cE "(^|[[:space:]])story: close receipt: \"?(STORY-)?0*${ID}\"? is Done" >/dev/null || exit 0
# The close prints the TERMINAL form of the stored table (rendered by the story tool from the canonical markdown)
# between a start and an end marker: take exactly that block. A close from an older tool printed the markdown table
# instead; then keep its rows (| … |) + the Tally line. Everything else is dropped.
TEXT="$(printf '%s\n' "$CLOSE_OUT" | awk '/^=== end of Proof /{p=0} p{print} /^=== Proof .*terminal form/{p=1}')"
TABLE=""
if [ -z "$TEXT" ]; then
    TABLE="$(printf '%s' "$CLOSE_OUT" | grep -E '^[[:space:]]*\|[^|]*\|' ; printf '%s' "$CLOSE_OUT" | grep -E 'Tally:' | head -1)"
    TABLE="$(printf '%s' "$TABLE" | grep -E '.')"   # collapse to empty if nothing matched
fi

if [ -n "$TEXT" ]; then
    MSG="$(printf '[kyklos] proof-shown: you just closed STORY-%s. The remote user CANNOT see the GitLab proof note - only your reply. Name it #%s / STORY-%s, then SHOW THIS PROOF in your VERY NEXT reply EXACTLY AS PRINTED (the terminal form the story tool rendered from the stored table: every numbered dimension with its evidence and metrics, and the tally; never re-type, merge or shorten it by hand). Do it now, in this turn - do not wait for the Stop gate to force it:\n\n%s' "$ID" "$ID" "$ID" "$TEXT")"
elif [ -n "$TABLE" ]; then
    MSG="$(printf '[kyklos] proof-shown: you just closed STORY-%s. The remote user CANNOT see the GitLab proof note - only your reply. RENDER THIS PROOF TABLE VERBATIM (every dimension row + the tally) in your VERY NEXT reply, naming it #%s / STORY-%s. Do it now, in this turn - do not wait for the Stop gate to force it:\n\n%s' "$ID" "$ID" "$ID" "$TABLE")"
else
    MSG="[kyklos] proof-shown: you just closed STORY-$ID. Name it #$ID and SHOW its proof in your VERY NEXT reply, exactly as \`story proof $ID --format text\` prints it (every dimension + the tally) - the remote user sees only your reply, not the GitLab note. Do it NOW, this turn."
fi

jq -nc --arg ctx "$MSG" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$ctx}}'
exit 0
