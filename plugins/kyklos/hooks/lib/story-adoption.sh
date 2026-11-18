#!/usr/bin/env bash
# story-adoption.sh (Kyklos hook lib) - the SINGLE definition of "this GitLab issue is an ADOPTED story" for the shell side
# (the bridge's twin is StoryAdoption.cs; both state the same four parts, and each suite tests them).
#
# An issue WITHOUT the story label is neither adoptable nor adopted. An issue WITH it is adopted only when all four hold:
#   1+2. the words a person wrote are quoted verbatim and the description follows the story template: adoption writes
#        both (the metadata header, of which its Story-Type and Epic lines are judged; the original words under their heading);
#   3.   the labels are applied: type, kind, severity, phase, and status while the issue is open;
#   4.   it is attached to an epic: its milestone, open or closed, has a title that is an epic id (E and digits, then a
#        blank, a dash, a colon or the end - "E2E hardening" is no epic, the same rule as epic-records.jq).
# A story missing any of them is ADOPTABLE: `story adopt` completes it. The story label alone was never adoption: a user
# can create an issue with the label pre-applied, and every label-only check then waved it through.
# shellcheck source=lib/json-answer.sh
. "$(dirname "${BASH_SOURCE[0]}")/json-answer.sh"   # json_test / json_read: an empty or cut answer is never valid

# story_issue_adoption_missing <issue-json> [story-label] -> prints what the story lacks to be adopted, one piece per line
# in the order of the rule (nothing when it is adopted). Exit 1 when the issue carries no story label (it is no story at
# all, so nothing is printed), else 0. Pure (no I/O beyond jq on its argument).
story_issue_adoption_missing() {
    local json="$1" label="${2:-story}"
    # the story label is matched as the bridge's label codec matches it: trimmed, any letter case
    printf '%s' "$json" | json_test 'any((.labels // [])[]; type == "string" and (gsub("^\\s+|\\s+$"; "") | ascii_downcase) == ($L | ascii_downcase))' --arg L "$label" || return 1
    # [no-fail-open] An answer the rule cannot read is never taken for an adopted story: it lacks what cannot be read.
    printf '%s' "$json" | jq -r -L "$(dirname "${BASH_SOURCE[0]}")" -f "$(dirname "${BASH_SOURCE[0]}")/story-adoption-missing.jq" 2>/dev/null \
        || printf 'a readable issue (its labels, description and milestone could not be read)\n'
}

# story_issue_is_adopted <issue-json> [story-label] -> exit 0 iff the issue carries the story label AND all four parts of
# the adoption (story_issue_adoption_missing prints nothing). The adoption test the story backend, and through it the
# branch guard and the story tool, use.
story_issue_is_adopted() {
    local missing
    missing="$(story_issue_adoption_missing "$@")" || return 1
    [ -z "$missing" ]
}

# story_issue_vocabulary <issue-json> <jq-expression> -> the expression evaluated with the codec vocabulary
# (story-adoption-vocabulary.jq) on the issue: the one way adoption reads the issue's type and status.
story_issue_vocabulary() {
    printf '%s' "$1" | jq -r -L "$(dirname "${BASH_SOURCE[0]}")" "include \"story-adoption-vocabulary\"; $2" 2>/dev/null
}
