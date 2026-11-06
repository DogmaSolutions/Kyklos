# Story state audit over an array of OPEN story issues. Emits one TAB-separated line per violation:
#   <iid> TAB <rule> TAB <detail>
# Rules:
#   status-count         - an open story must carry exactly one status state (0 or >1 is broken)
#   phase-not-started    - a phase past Design on a story nobody has started (todo / parked / no status)
#   doing-no-phase       - a story in progress with no ssdlc:phase label
#   doing-no-branch      - a story in progress whose Branch field is empty or "-"
#   blocked-no-kind      - a Blocked story with the legacy bare status::blocked: blocked for a reason nobody recorded
#   blocked-no-detail    - a story blocked on a kind (status::blocked-on-<kind>) whose Blocked-On bullet does not carry
#                          the detail that kind needs (a reference, the link to the question, or who or what is awaited)
#   blocked-kind-conflict - a story with two different block kinds (status::blocked-on-<kind>) at once, which the
#                          bridge refuses to read as one status (it names the conflict), so the audit reports it too
# The merged-but-open check needs merge request data and is done by the caller.
def states($l):
  [ (["status::todo","status:todo","S:todo"]         | any(. as $n | $l | index($n) != null)) as $t | if $t then "todo" else empty end,
    (["status::doing","status:doing","S:doing"]      | any(. as $n | $l | index($n) != null)) as $t | if $t then "doing" else empty end,
    ((["status::blocked","status:blocked","S:blocked"]| any(. as $n | $l | index($n) != null)) or any($l[]; startswith("status::blocked-on-"))) as $t | if $t then "blocked" else empty end,
    (["status::parked","parked"]                     | any(. as $n | $l | index($n) != null)) as $t | if $t then "parked" else empty end ];
def phase($l): ([$l[] | select(startswith("ssdlc:phase")) | sub("^ssdlc:phase:+"; "")] | first) // "";
def late($p): ["Implementation","Testing","Deployment","Review"] | index($p) != null;
def blockkinds($l): [$l[] | select(test("^status::blocked-on-.")) | sub("^status::blocked-on-"; "") | ascii_downcase] | unique;
def blockkind($l): (blockkinds($l) | first) // "";
def blockedon($d): ((($d // "") | gsub("\r"; "") | [capture("(?m)^[ \t]*[-*][ \t]+\\*\\*Blocked-On:\\*\\*[ \t]*(?<v>[^\n]*)")] | first | .v) // "");
def detailok($k; $v): if $k == "issue" then ($v | test("^([A-Za-z0-9._/-]*[#!][0-9]+|https?://[^ ]+/-/(issues|merge_requests)/[0-9]+)( |$)"))
  elif $k == "user" then ($v | test("^user since [0-9]{4}-[0-9]{2}-[0-9]{2}: https?://[^ ]+/-/(issues|merge_requests)/[0-9]+#note_[0-9]+"))
  elif $k == "external" then ($v | test("^external since [0-9]{4}-[0-9]{2}-[0-9]{2}: [^ ]"))
  else true end;
def branch($d): ((($d // "") | [capture("\\*\\*Branch:\\*\\*[ \\t]*(?<b>[^\\n]*)")] | first | .b) // "") | gsub("^\\s+|\\s+$"; "");
.[]
| (.labels // []) as $l
| states($l) as $s
| phase($l) as $p
| (.iid | tostring) as $i
| ( if ($s | length) != 1 then "\($i)\tstatus-count\t\($s | length) status states: \($s | join(","))" else empty end ),
  ( if late($p) and (($s | index("doing")) == null) and (($s | index("blocked")) == null)
      then "\($i)\tphase-not-started\tphase \($p) but status \(if ($s|length)==0 then "none" else ($s|join(",")) end)" else empty end ),
  ( if (["status::blocked","status:blocked","S:blocked"] | any(. as $n | $l | index($n) != null)) and blockkind($l) == ""
      then "\($i)\tblocked-no-kind\tblocked, reason unknown: block it again with story block \($i) --kind <issue|user|external>" else empty end ),
  ( blockkinds($l) as $ks | if ($ks | length) > 1
      then "\($i)\tblocked-kind-conflict\t\($ks | length) block kinds at once: \($ks | join(",")); keep one (story block \($i) --kind <kind>)" else empty end ),
  ( blockkind($l) as $k | if $k != "" and (detailok($k; blockedon(.description)) | not)
      then "\($i)\tblocked-no-detail\tblocked on \($k) but the Blocked-On bullet does not carry its detail" else empty end ),
  ( if ($s | index("doing")) != null and $p == "" then "\($i)\tdoing-no-phase\tin progress with no ssdlc:phase label" else empty end ),
  ( if ($s | index("doing")) != null and (branch(.description) | (. == "" or . == "-"))
      then "\($i)\tdoing-no-branch\tin progress with Branch field \"\(branch(.description))\"" else empty end )
