# Externalized from ai-fix-loop.sh (inline multi-line jq = kcov phantom lines). Assemble the round
# summary object from the ranked findings ($f) + branch ($br) + MR iid ($mr).
{ branch:$br, mr_iid:($mr|tonumber?), count:($f|length),
  by_severity:( $f | group_by(.severity) | map({key:(.[0].severity//"?"), value:length}) | from_entries ),
  findings:$f }
