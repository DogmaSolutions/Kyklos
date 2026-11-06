# proof-row-index.awk — the Dimension column of every DATA row of a proof table: <line-number><TAB><dimension>.
# Run with -F'|'. A data row has at least three cells; the header ("Quality Dimension") and the |---| separator
# are skipped; emphasis markers and backticks are stripped and the name is trimmed.
NF >= 3 {
  d = $2
  gsub(/[`*_]/, "", d); gsub(/^[ \t\r]+|[ \t\r]+$/, "", d)
  if (d == "" || d == "Quality Dimension") next
  if (d ~ /^:?-+:?$/) next
  print NR "\t" d
}
