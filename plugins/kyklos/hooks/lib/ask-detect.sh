#!/usr/bin/env bash
# ask-detect.sh — the SINGLE source of truth for "is this a PROHIBITED prioritization / preference / defer-to-user
# question?" Used by BOTH kyklos-ask-user-guard.sh (PreToolUse:AskUserQuestion) and kyklos-continue-guard.sh (Stop,
# against the last assistant message) so the detection can never DRIFT between the two enforcement points — and so a
# prohibited question asked as PLAIN PROSE (which the AskUserQuestion hook never sees) is still caught at Stop.
#
# WHY: the standing directive is "prioritize autonomously, keep rolling — the USER intervenes proactively, the agent
# does NOT defer via questions." A question to the user is sanctioned ONLY for a genuine ALWAYS-STOP authorization
# (a DIRECT yes/no on ONE irreversible/outward action) or a hard blocker the agent cannot self-resolve. Everything
# else — "which next?", "in what order?", "your preference?", "keep rolling or…?", "do you want me to X or Y?",
# "where should I point next?", "…or step back?" — is a DISGUISED stop and must be refused.
#
# ask_prohibited_prioritization "<text>"  ->  exit 0 iff the text reads as a prohibited prioritization/preference/
# defer question. Input is matched case-insensitively; callers may pass the whole prompt or just the closing tail.
# A genuine authorization ("Should I publish X to nuget.org?" — a direct yes/no on ONE action) carries NONE of these
# tells and is NOT matched.

ask_prohibited_prioritization() {
    # Keyed on the CHOICE / PREFERENCE / SEQUENCING / DEFER structure — NOT on polite framing. A single-action
    # authorization ("How should I proceed?", "Should I publish X?", "Shall I arm X?", "May I delete X?") carries none
    # of these tells and passes; a "which/what next", "X or step back", "keep rolling?", or "do you want me to X or Y?"
    # is caught. Deliberately NOT matching a bare "should i proceed"/"do you want me to <one action>" (those are how a
    # genuine authorization is phrased) — only the versions with a choice/next/or-defer/permission-to-continue tell.
    printf '%s' "${1:-}" | tr 'A-Z' 'a-z' | grep -cE \
'prefer|preference|keep (on )?rolling|keep going|prioriti[sz]|in (what|which) order|(which|what|where|how) [^?]{0,40}(next|first)|(which|what) (of (these|those|the|them)|one )|(next|first) (task|item|story|issue|step|thing)|should i (continue|keep going|keep rolling|keep at)|shall i (continue|keep going|keep rolling)|want me to (keep|continue|keep going|keep rolling)|continue autonomous|pause here|take on next|which should i (do|take|start|work|tackle|proceed)|do you want me to [^?]{0,60}(\bor\b|,)|\bor (step back|stand by|hold off|wait|pause|review first|breathe|rest|hold\b)|(finish|continue|proceed|build|work|drive|do|point|start) [^?]{0,50}\bor\b [^?]{0,40}(step back|stand by|stop|pause|hold|wait|review|first|rest|breathe)|so you can (breathe|rest|decide|think|catch)|ready to (proceed|continue|move|build|go)\b|review [^?]{0,20}(first|specs)|where to (point|go|focus)' >/dev/null
}

# THE OWNER-BLOCKER QUESTION: the one recognisable form an agent uses to end its turn on something only the person can
# do (a host step, a credential only they hold, a decision that is theirs). Both enforcement points accept it with no
# override: the ask-user guard lets such an AskUserQuestion through, and the continue-guard accepts a stop whose final
# message carries it. The form is a line that starts with the marker below, names the blocker in words (what only the
# person can do, and why), and asks the question, ending with a question mark:
#     Blocked on you: the CI host is powered off and only you can start it. Can you power it on?
# A prioritization or preference question is still refused even in this form (the prioritization check runs first):
# the marker names a blocker, it does not turn "which next?" into one.
# shellcheck disable=SC2034  # read by the guards that source this file
ASK_OWNER_BLOCKER_MARKER='Blocked on you:'

# ask_names_owner_blocker "<text>" -> exit 0 iff the text carries the owner-blocker question: the marker at the start
# of a line or of a sentence (case-insensitive; leading spaces, a list bullet and bold markers allowed), then at least ten characters
# naming the blocker, then a question mark in the same paragraph (the marker line and the non-blank lines after it),
# at most OWNER_BLOCKER_SPAN characters after the marker. The marker inside a sentence, a quote (`>`), a code span or a
# fenced code block does not count, so a message that only mentions or quotes the form cannot end a turn.
OWNER_BLOCKER_SPAN=400
ask_names_owner_blocker() {
    printf '%s\n' "${1:-}" | tr -d '\r' | awk -v span="$OWNER_BLOCKER_SPAN" '
        { line = tolower($0) }
        line ~ /^[[:space:]]*(```|~~~)/ { fenced = !fenced; inpara = 0; next }
        fenced { next }
        inpara {
            if (line ~ /^[[:space:]]*$/) { inpara = 0; next }
            buf = buf " " line
            q = index(buf, "?")
            if (q) { if (q > 10 && q <= span) { found = 1; exit } inpara = 0; next }
            if (length(buf) > span) inpara = 0
            next
        }
        line ~ /^[[:space:]]*>/ { next }
        match(line, /(^[[:space:]]*([-*+][[:space:]]+)?|[.!][[:space:]]+)(\*\*|__)?blocked on you:(\*\*|__)?[[:space:]]*[^[:space:]?`]/) {
            before = substr(line, 1, RSTART); ticks = gsub(/`/, "`", before)
            if (ticks % 2) next
            buf = substr(line, RSTART); sub(/^[^:]*:(\*\*|__)?[[:space:]]*/, "", buf)
            q = index(buf, "?")
            if (q) { if (q > 10 && q <= span) { found = 1; exit } next }
            inpara = 1
        }
        END { exit found ? 0 : 1 }'
}
