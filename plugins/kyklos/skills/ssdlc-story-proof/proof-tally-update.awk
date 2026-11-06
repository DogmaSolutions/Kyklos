# Externalized from proof_apply_verdict (inline multi-line awk = kcov phantom lines). Rewrite the
# `**Tally:**` line to `pr` PROVEN / `np` NOT_PERTINENT (middot U+00B7), plus `un` UNPROVEN whenever it is above zero
# so a partial proof never reads as complete; pass everything else through unchanged.
/^\*\*Tally:/ {
  if (pr == "" || np == "") { print; next }
  if (un + 0 > 0) printf "**Tally: %d PROVEN \xc2\xb7 %d NOT_PERTINENT \xc2\xb7 %d UNPROVEN**\n", pr, np, un
  else            printf "**Tally: %d PROVEN \xc2\xb7 %d NOT_PERTINENT**\n", pr, np
  next
}
{ print }
