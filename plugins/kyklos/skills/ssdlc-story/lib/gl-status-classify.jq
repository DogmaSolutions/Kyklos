# Externalized from backend status-read (was inline multi-line jq = kcov phantom lines). Classify a
# story issue's status from its labels. The unified status:: lifecycle scope: Parked joins the
# open-issue states (precedence Parked > In-progress > Blocked > Todo - a parked story must never read as active
# work), dual-reading the legacy bare `parked` name during the migration window; the older three keep their
# triple-read (scoped status::*, legacy status:*, oldest S:*). Terminal states (wontfix/duplicate/invalid/archived)
# belong to CLOSED issues and are classified by the caller's closed-branch, not here. Blocked reads every kind
# (status::blocked-on-issue|user|external, and any newer status::blocked-on-* word) beside the legacy bare forms.
(.labels // []) as $l
| def hasany($names): any($names[]; . as $n | ($l | index($n)) != null);
  if   hasany(["status::parked","parked"])                        then "Parked"
  elif hasany(["status::doing","status:doing","S:doing"])         then "In-progress"
  elif hasany(["status::blocked","status:blocked","S:blocked"]) or any($l[]; startswith("status::blocked-on-")) then "Blocked"
  else "Todo" end
