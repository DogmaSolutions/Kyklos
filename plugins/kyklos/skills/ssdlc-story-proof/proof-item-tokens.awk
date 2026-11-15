# proof-item-tokens.awk -- the one spec-item token rule of the shell proof code, the same as the bridge's
# (SpecItemCoverage.ItemForms): an exact upper-case R<n>, UC<n>, FM<n>, AC<n>, RA-<n>, FAIL-OPEN or FAIL-HARD with no
# letter or digit touching it on either side ('_', '-' and punctuation do not touch). Prints each token found, one per
# line, in order. A hash or an advisory id (9fp8-r4x6, abcR4, R4x) names nothing.
{
    rest = $0
    before = ""
    while (match(rest, /(UC|FM|AC|R)[0-9]+|RA-[0-9]+|FAIL-(OPEN|HARD)/)) {
        token = substr(rest, RSTART, RLENGTH)
        prev = RSTART > 1 ? substr(rest, RSTART - 1, 1) : substr(before, length(before), 1)
        next_char = substr(rest, RSTART + RLENGTH, 1)
        if (prev !~ /[A-Za-z0-9]/ && next_char !~ /[A-Za-z0-9]/) {
            print token
            before = before substr(rest, 1, RSTART + RLENGTH - 1)
            rest = substr(rest, RSTART + RLENGTH)
        } else {
            # Not a token here: move one character past where this candidate started and look again.
            before = before substr(rest, 1, RSTART)
            rest = substr(rest, RSTART + 1)
        }
    }
}
