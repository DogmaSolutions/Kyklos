# Externalized from backend_status_conflicts (was an inline multi-line jq string, which kcov mis-counts
# as eternally-uncovered bash "phantom" lines). Over the open-story list, emit one `iid<TAB>n<TAB>status-labels`
# line per story carrying >=2 DISTINCT status states - the CE positive single-status invariant (report-only).
# Extended to the unified 8-axis status:: scope, each axis dual-reading its legacy form(s).
.[]? | . as $i | (.labels // []) as $l
| def hasany($names): any($names[]; . as $n | ($l | index($n)) != null);
  [ hasany(["status::todo","status:todo","S:todo"]),
    hasany(["status::doing","status:doing","S:doing"]),
    (hasany(["status::blocked","status:blocked","S:blocked"]) or any($l[]; startswith("status::blocked-on-"))),
    hasany(["status::parked","parked"]),
    hasany(["status::wontfix","wontfix"]),
    hasany(["status::duplicate","duplicate"]),
    hasany(["status::invalid","invalid"]),
    hasany(["status::archived","archived"]) ]
| (map(select(.)) | length) as $n
| select($n > 1)
| "\($i.iid)\t\($n)\t\(($i.labels // []) | map(select(test("^(status::|status:|S:)(todo|doing|blocked|blocked-on-[A-Za-z]+|parked|wontfix|duplicate|invalid|archived)$") or IN("parked","wontfix","duplicate","invalid","archived"))) | join(","))"
