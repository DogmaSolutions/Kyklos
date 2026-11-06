#!/usr/bin/env bash
# story-adoption.sh (Kyklos hook lib) - the SINGLE definition of "this GitLab issue is an ADOPTED story".
#
# The story label alone is NOT adoption: a user can create an issue with the label pre-applied, and it then has no
# metadata, status, phase, milestone discipline or proof scaffold, yet every label-only check waved it through as
# "adopted". `story adopt` and `story new` always write the tool-managed metadata header into the body (the
# `**Story-Type:**` bullet), so adoption = the story label AND that header. This is the adoption test the story
# backend (skills/ssdlc-story/lib/story-backend-gitlab.sh) uses.
#
# story_issue_is_adopted <issue-json> [story-label] -> exit 0 iff the issue carries the story label (default `story`)
# AND its description carries the adoption metadata header. Pure (no I/O beyond jq/grep on its argument).
# shellcheck source=lib/json-answer.sh
. "$(dirname "${BASH_SOURCE[0]}")/json-answer.sh"   # json_test / json_read: an empty or cut answer is never valid
story_issue_is_adopted() {
    local json="$1" label="${2:-story}"
    printf '%s' "$json" | json_test '(.labels // []) | index($L) != null' --arg L "$label" || return 1
    printf '%s' "$json" | jq -r '.description // ""' 2>/dev/null \
        | grep -ciE '^[[:space:]]*[-*][[:space:]]+\*\*Story-Type:\*\*' >/dev/null
}
