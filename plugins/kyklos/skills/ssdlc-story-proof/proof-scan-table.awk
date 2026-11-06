# proof-scan-table.awk — classify+count Proof-table verdicts (UN/PR/NP); exit 2 => malformed/unknown row. Externalized from proof-dimensions.sh: an inline multi-line awk is mis-counted
# by kcov as 0-hit bash phantom lines. Vars are passed with awk -v. Behaviour byte-identical to the inline form.
    function trim(s){ gsub(/^[ \t]+|[ \t]+$/,"",s); return s }
    # classify a Verdict cell -> UN | PR | NP | "" (unknown). UNPROVEN is checked BEFORE PROVEN (it contains it).
    function classify(cell,   u){
      u=toupper(cell); gsub(/[^A-Z_]/,"",u)                       # keep only A-Z and _ (drops emoji/space/digits)
      if (u ~ /UNPROVEN/)                              return "UN"
      if (u ~ /NOT_?PERTINENT/ || u=="NA" || u=="NP")  return "NP"
      if (u ~ /PROVEN/)                                return "PR"
      return ""
    }
    /^[[:space:]]*\|/ {
      line=$0
      if (line ~ /^[[:space:]]*\|[-:| ]*$/) next                 # separator row  |---|---|---|
      n=split(line, c, "|")
      # Header row: the Verdict-column label (2nd content cell == "Verdict") or the canonical dimension header (1st
      # content cell == "Quality Dimension"). It establishes the table WIDTH every data row must match, then is itself
      # skipped. Only the first cell is compared: a data row whose evidence merely MENTIONS the words must still count.
      if (tolower(trim(c[3]))=="verdict" || trim(c[2])=="Quality Dimension") { if (!hdrnf) { hdrnf=n; for (i=2; i<n; i++) if (!evcol && tolower(trim(c[i]))=="evidence") evcol=i } next }
      # Data row. The Verdict is ALWAYS the 2nd content cell (awk field 3) whether the table is 2- or 3-column;
      # baseline the expected cell count from the header (else the first data row). A row whose cell count differs
      # is MALFORMED — that is how a stray | (which splits the row into extra cells and SHIFTS the verdict out of
      # field 3) is caught — and a field-3 that does not classify is an UNKNOWN verdict. Either FAILS HARD, so a
      # malformed / bogus row can never be miscounted as clean.
      if (!width) width = (hdrnf ? hdrnf : n)
      if (n != width) { printf("proof: MALFORMED Proof row (%d cells, expected %d — a stray | shifts the Verdict out of its column): %s\n", n-2, width-2, line) > "/dev/stderr"; bad=1; next }
      v=classify(trim(c[3]))
      if (v == "") { printf("proof: UNKNOWN verdict (the 2nd cell must be PROVEN / NOT_PERTINENT / UNPROVEN): %s\n", line) > "/dev/stderr"; bad=1; next }
      # The evidence rule (the bridge's ProofEvidenceRule; tests/fixtures/proof-evidence-cases.txt is read by both): a
      # PROVEN or NOT_PERTINENT row needs real evidence text in the column the HEADER labels "Evidence" (any column count
      # or order), not empty, a dash, markup, invisible characters, a bare n/a / TBD / todo / none or a placeholder. A table
      # without an Evidence column cannot carry it, so such a row is refused. Fails hard like a malformed row, naming the dimension.
      if (v != "UN") {
        why = ""
        if (!evcol) why = "the table has no Evidence column"
        else if (c[evcol] ~ /<FILL:/ || !rt_real_text(c[evcol]) || rt_key(c[evcol]) ~ /^(na|tbd|todo|none)$/) why = "its evidence is empty, a dash, a placeholder or filler"
        if (why != "") {
          printf("proof: EMPTY evidence for '%s' (a %s row needs evidence text: %s): %s\n", trim(c[2]), (v=="PR" ? "PROVEN" : "NOT_PERTINENT"), why, line) > "/dev/stderr"; bad=1; next
        }
      }
      if (v=="UN") un++; else if (v=="NP") np++; else pr++
    }
    END { if (bad) exit 2; printf("UN=%d PR=%d NP=%d\n", un+0, pr+0, np+0) }
