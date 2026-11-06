#!/usr/bin/env bash
# own-lane.sh -- the ONE ownership rule for story work: an agent works only on issues assigned to its own GitLab user
# or to nobody. The story tool refuses a write to a story owned by another user, and the continue-guard counts only
# the issues that are the agent's own or nobody's as open work. The bridge's story verbs apply the same rule (C#
# OwnLaneRule); both sides run the shared case table skills/ssdlc-story/tests/fixtures/own-lane.json, so the two
# copies cannot drift apart. Source it; it defines functions only.
#
#   own_lane_enabled
#       rc 0 unless STORY_OWN_LANE is off|0|false|no (the greppable per-project opt-out, set in the project's
#       .claude/standards.env or the environment). Default-on.
#   own_lane_verdict <assignees-json> <self-json>
#       prints one word for the issue, read from its assignees and the caller's own identity:
#         own              the caller's own user is among the assignees
#         free             the issue has no assignee (anyone may claim it; the identity is not needed for that)
#         other:<names>    assigned only to other users; <names> are their usernames (an id when no username is known)
#         unknown          the assignees could not be read, the caller's identity is unknown while the issue has an
#                          assignee, or an assignee cannot be compared with the caller (no common id or username)
#       <assignees-json> is the issue's assignees array: objects {id, username} (GitLab's issue answer) or plain
#       username strings (the bridge's issue list). Anything that is not an array (an unreadable issue) is unknown.
#       <self-json> is {id, username}; either may be missing. Only a whole-number id counts (any other id is unknown); usernames are
#       compared without case (GitLab usernames are case-insensitive). When both sides carry an id, the id decides.
#   own_lane_owner <verdict>
#       the <names> of an other:<names> verdict.

# shellcheck source=control-switch.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/control-switch.sh" 2>/dev/null || true   # kyklos_control_off: the one control-switch reader
own_lane_enabled() {
    ! kyklos_control_off "${STORY_OWN_LANE:-}"
}

# shellcheck disable=SC2016  # the jq program is single-quoted on purpose
_OWN_LANE_JQ='
def idof: if type == "number" and . == floor then tostring else null end;
def nameof: if type == "string" and test("\\S") then ascii_downcase else null end;
def norm: if type == "object" then {id: (.id | idof), username: (.username | nameof), shown: (if (.username | nameof) != null then .username elif (.id | idof) != null then (.id | idof) else null end)}
          elif type == "string" then {id: null, username: nameof, shown: .}
          else {id: null, username: null, shown: null} end;
# 1 = the same user, 0 = another user, null = cannot tell
def same($s): if .id != null and $s.id != null then (if .id == $s.id then 1 else 0 end)
              elif .username != null and $s.username != null then (if .username == $s.username then 1 else 0 end)
              else null end;
if ($a | type) != "array" then "unknown"
elif ($a | length) == 0 then "free"
else
  (if ($s | type) == "object" then ($s | norm) else {id: null, username: null} end) as $me
  | if $me.id == null and $me.username == null then "unknown"
    else ($a | map(norm)) as $n
    | [$n[] | same($me)] as $m
    | if any($m[]; . == 1) then "own"
      elif any($m[]; . == null) then "unknown"
      else "other:" + ($n | map(.shown // "an unknown user") | join(", ")) end
    end
end'

own_lane_verdict() {
    local a="${1:-}" s="${2:-}" out
    [ -n "$a" ] || a='null'
    [ -n "$s" ] || s='null'
    # A malformed input (not JSON) is unknown, never "free".
    out="$(jq -rn --argjson a "$a" --argjson s "$s" "$_OWN_LANE_JQ" 2>/dev/null)" || out=""
    case "$out" in own|free|unknown|other:*) printf '%s' "$out" ;; *) printf 'unknown' ;; esac
}

own_lane_owner() { printf '%s' "${1#other:}"; }
