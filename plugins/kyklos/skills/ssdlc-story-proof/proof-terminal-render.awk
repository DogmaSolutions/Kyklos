# proof-terminal-render.awk — the TERMINAL form of a stored Proof table: one numbered entry per dimension row (verdict
# glyph, bold dimension name, verdict word), its evidence as indented lines and each metric as a bullet, then the tally
# computed from the rows. No table, no HTML: a terminal shows <br>, <kbd> and long table rows badly. The stored
# markdown table stays the single source of truth; this only re-presents it, row for row, nothing dropped.
# The bridge implements the SAME transform (ProofTableTerminalRenderer); a shared fixture holds both to one output.
# The heading names no story: the agent names the story in its own words before showing the render, so the tool's
# output alone never reads as the reply having shown it.
# Nothing is dropped: a markdown-escaped pipe (\|) stays text inside its cell, a row without its closing pipe keeps its
# last cell, a cell past the Metrics column is kept as one more bullet, and any other line of the stored proof (a
# user's Proof-Override line, a note) is printed as written after the entries; only the section heading and the stored
# tally line (recounted from the rows) are left out.
function trim(s) { gsub(/^[ \t\r]+|[ \t\r]+$/, "", s); return s }
# The cell text as plain lines: the pipe entity back to a pipe, keyboard tags dropped, every <br> a line break.
# [RiskMitigation RA-02] Cell text is only printed as data (never passed to awk -v, a shell or an evaluator).
function plain(s) {
  gsub(/&#124;/, "|", s)
  gsub(/<\/?[Kk][Bb][Dd]>/, "", s)
  gsub(/<[Bb][Rr][ \t]*\/?>/, "\n", s)
  return s
}
# Print each non-empty line of s, indented; bullet = the prefix in front of each line ("" or "- ").
function emit(s, bullet,    n, i, L, line) {
  n = split(plain(s), L, "\n")
  for (i = 1; i <= n; i++) { line = trim(L[i]); if (line != "") out = out "   " bullet line "\n" }
}
# A stored line outside the dimension rows, kept for the block printed after the entries.
function keep(s,    n, i, L, line) {
  n = split(plain(s), L, "\n")
  for (i = 1; i <= n; i++) { line = trim(L[i]); if (line != "") other = other line "\n" }
}
function classify(cell,   u) {
  u = toupper(cell); gsub(/[^A-Z_]/, "", u)
  if (u ~ /UNPROVEN/) return "UNPROVEN"
  if (u ~ /NOT_?PERTINENT/ || u == "NA" || u == "NP") return "NOT_PERTINENT"
  if (u ~ /PROVEN/) return "PROVEN"
  return ""
}
{ gsub(/\r/, "") }
/^[ \t]*\|/ {
  line = $0
  if (line ~ /^[ \t]*\|[-:| ]*$/) next
  # A markdown-escaped pipe is cell text, not a column border: park it on a unit separator while the row is split.
  gsub(/\\\|/, "\037", line)
  n = split(line, c, "|")
  for (i = 1; i <= n; i++) gsub(/\037/, "|", c[i])
  # A row written without its closing pipe still ends in a content cell: give it the empty cell a closing pipe makes.
  if (trim(c[n]) != "") c[++n] = ""
  if (n < 4) { keep($0); next }
  dim = trim(c[2])
  if (dim == "Quality Dimension" || tolower(trim(c[3])) == "verdict") next
  v = classify(c[3])
  if (v == "") v = trim(c[3])
  glyph = (v == "PROVEN") ? "✅" : (v == "NOT_PERTINENT") ? "∅" : "❌"
  if (v == "PROVEN") pr++; else if (v == "NOT_PERTINENT") np++; else un++
  rows++
  out = out "\n" rows ". " glyph " **" dim "** — " v "\n"
  ev = trim(c[4])
  before = length(out)
  emit(ev, "")
  if (length(out) == before) out = out "   (no evidence)\n"
  if (n >= 6) { mx = trim(c[5]); if (mx != "—") emit(mx, "- ") }
  for (i = 6; i < n; i++) emit(c[i], "- ")
  next
}
# Any other line of the stored proof, except the section heading and the stored tally, is kept as written.
/^[ \t]*#+[ \t]+Proof[ \t]*$/ || /^[ \t]*\*\*Tally:/ { next }
{ keep($0) }
END {
  if (rows == 0) exit 1
  printf "**Proof** — %d Quality Dimensions (terminal form of the stored table)\n", rows
  printf "%s", out
  if (other != "") printf "\n%s", other
  tally = "**Tally: " (pr + 0) " PROVEN · " (np + 0) " NOT_PERTINENT"
  if (un + 0 > 0) tally = tally " · " un " UNPROVEN"
  printf "\n%s**\n", tally
}
