# story-adoption-missing.jq -- an issue (GitLab JSON) -> what it lacks to be an ADOPTED story, one piece per output line
# (nothing when it is adopted). The rule is stated in story-adoption.sh; the caller checks the story label first. The
# labels are read with the bridge's codec vocabulary (story-adoption-vocabulary.jq); one shared table of cases
# (ssdlc-story/tests/fixtures/adoption-rule.json) is judged by this rule and by the bridge's StoryAdoption alike, so the two
# can never drift. A closed issue keeps no status label (a close clears it), so only an open one needs a status. A
# Story-Type or Epic header line counts only with a value ("-" is none). Part 4 counts an epic milestone open or closed: a
# finished epic's closed milestone never makes its stories adoptable again.
include "story-adoption-vocabulary";
def known($ns; $words): any(values($ns)[]; . as $v | $words | index($v) != null);
[ (if (header("Story-Type") and header("Epic")) then empty
   else "the story template (the Story-Type and Epic lines, with the original words quoted)" end),
  ([ (if codec_type != "" then empty else "type" end),
     (if known("kind"; ["development","analysis","documentation","ops"]) then empty else "kind" end),
     (if known("severity"; ["low","medium","high","critical"]) then empty else "severity" end),
     (if ((.state // "opened") == "closed" or has_status) then empty else "status" end),
     (if known("ssdlc:phase"; ["requirements","design","implementation","testing","deployment","review"]) then empty else "phase" end) ]
   | if length == 0 then empty else "the " + join(", ") + " label" + (if length > 1 then "s" else "" end) end),
  (if ((.milestone | type) == "object"
       and (epic_id(.milestone.title // "") != ""))
   then empty else "an epic (an epic milestone, open or closed)" end)
] | .[]
