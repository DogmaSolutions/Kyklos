# sl-fix-class.awk — judge the "## Fix the class" section of a story body; prints one verdict word:
# OK | MISSING (no section) | PLACEHOLDER (an unfilled <FILL: ...> remains) | BOTH (invariant or sweep without text after its label).
# The same reading as the bridge's FixTheClassGate (fences and comments hidden, "real text" from real-text.awk); the
# cases in tests/fixtures/fix-class-cases.txt are read by both suites. Loaded with: awk -f real-text.awk -f this-file.
function key(t) { t = tolower(t); gsub(/[^a-z0-9]/, "", t); return t }

# The line without its HTML comments; an open comment carries over to the next line. Inline code keeps its words but its
# angle brackets are blanked, so it can neither open a comment nor carry a placeholder.
function visible(line,    out, e, code, pre) {
  out = ""
  while (match(line, /`[^`]*`/)) {
    pre = substr(line, 1, RSTART - 1); code = substr(line, RSTART, RLENGTH)
    line = substr(line, RSTART + RLENGTH)
    gsub(/[<>]/, " ", code)
    out = out pre code
  }
  line = out line
  out = ""
  while (length(line) > 0) {
    if (incomment) {
      e = index(line, "-->")
      if (e == 0) return out
      line = substr(line, e + 3); incomment = 0; continue
    }
    e = index(line, "<!--")
    if (e == 0) { out = out line; break }
    out = out substr(line, 1, e - 1); line = substr(line, e + 4); incomment = 1
  }
  return out
}

{
  raw = $0; gsub(/\r/, "", raw)
  if (!incomment && raw ~ /^ ? ? ?(```|~~~)/) { fenced = !fenced; next }
  if (fenced) next
  v = visible(raw)
  h = v; sub(/^ ? ? ?/, "", h); level = 0
  if (match(h, /^#+/) && RLENGTH <= 6 && (length(h) == RLENGTH || substr(h, RLENGTH + 1, 1) ~ /[ \t]/)) {
    level = RLENGTH; title = substr(h, RLENGTH + 1); sub(/[ \t#]*$/, "", title)
  }
  if (level > 0 && level <= 3 && substr(key(title), 1, 11) == "fixtheclass") { found = 1; insec = 1; seclevel = level; next }
  if (level > 0 && insec && level <= seclevel) insec = 0
  if (insec) { content = content v "\n"; if (index(v, "<FILL:") > 0) placeholder = 1 }
}

END {
  if (!found) { print "MISSING"; exit }
  if (placeholder) { print "PLACEHOLDER"; exit }
  lc = tolower(content); n = 0; p = 1
  while (p <= length(lc)) {
    rest = substr(lc, p)
    if (!match(rest, /(invariants?[ \t\n]+violated|invariants?|sweep|call[- ]sites?|choke-?point)/)) break
    st = p + RSTART - 1; ln = RLENGTH
    before = (st > 1) ? substr(lc, st - 1, 1) : " "; after = substr(lc, st + ln, 1)
    if (before ~ /[a-z0-9]/ || after ~ /[a-z0-9]/) { p = st + 1; continue }
    # A word is a label only where a record starts: at the start of a line (after list, quote and emphasis marks) or
    # followed by a colon; the same word inside a sentence ("see the invariant above") labels nothing.
    ls = st; while (ls > 1 && substr(lc, ls - 1, 1) != "\n") ls--
    lead = substr(lc, ls, st - ls); gsub(/[][ \t>*+_#.)0-9~-]/, "", lead)
    if (lead != "" && substr(lc, st + ln) !~ /^[*_]*[ \t]*:/) { p = st + 1; continue }
    n++; S[n] = st; L[n] = ln; T[n] = (substr(lc, st, 3) == "inv") ? "I" : "S"
    p = st + ln
  }
  for (i = 1; i <= n; i++) {
    from = S[i] + L[i]; to = (i < n) ? S[i + 1] : length(lc) + 1
    m = split(substr(lc, from, to - from), piece, "\n"); written = 0
    for (j = 1; j <= m; j++) if (rt_real_text(piece[j]) && rt_key(piece[j]) !~ /^(na|tbd|todo|none)$/) written = 1
    if (written && T[i] == "I") inv = 1
    if (written && T[i] == "S") swp = 1
  }
  print (inv && swp) ? "OK" : "BOTH"
}
