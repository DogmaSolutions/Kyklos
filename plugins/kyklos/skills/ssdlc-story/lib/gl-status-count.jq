# Externalized from backend status-read (was inline multi-line jq = kcov phantom lines). Count DISTINCT
# status states present; >1 = an out-of-band double status (e.g. a 2nd added via the GitLab web UI, which no local
# guard can intercept on CE). The unified status:: scope counts ALL EIGHT lifecycle axes
# (todo/doing/blocked/parked/wontfix/duplicate/invalid/archived), each dual-reading its legacy form(s) - so e.g.
# `status::todo` + the bare GitLab-default `duplicate` correctly reads as 2 conflicting states.
(.labels // []) as $l
| def hasany($names): any($names[]; . as $n | ($l | index($n)) != null);
  [ hasany(["status::todo","status:todo","S:todo"]),
    hasany(["status::doing","status:doing","S:doing"]),
    (hasany(["status::blocked","status:blocked","S:blocked"]) or any($l[]; startswith("status::blocked-on-"))),
    hasany(["status::parked","parked"]),
    hasany(["status::wontfix","wontfix"]),
    hasany(["status::duplicate","duplicate"]),
    hasany(["status::invalid","invalid"]),
    hasany(["status::archived","archived"]) ]
| map(select(.)) | length
