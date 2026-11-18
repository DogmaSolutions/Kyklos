# proof-item-tokens.awk -- the one spec-item token rule of the shell proof code, the same as the bridge's
# (SpecItemCoverage.ItemForms): an exact upper-case R<n>, UC<n>, FM<n>, AC<n>, RA-<n>, FAIL-OPEN or FAIL-HARD with no
# letter or digit touching it on either side ('_', '-' and punctuation do not touch). Prints each token found, one per
# line, in order. A hash or an advisory id (9fp8-r4x6, abcR4, R4x) names nothing.
# With -v ranges=1 (evidence: what a proof cites) a range also names every item inside it, as the bridge's SpecItemRange
# reads it: two tokens of the same prefix on one line joined by a hyphen, an en dash or an em dash (spaces or tabs around
# it allowed) or by the word "to" or "through" between spaces, ascending, at most 50 items (R1 to R4, UC5-UC8, RA-01 to
# RA-04; a zero-padded start keeps its width). A reversed, wider or mixed-prefix span, or an end above 2147483647 (the
# bridge reads the ends as an int), names only its two ends; the ends are checked as text before any arithmetic, so no
# digit run can make the loop run away. Without it (a test's identity: a check label) a range names only its two ends.
# The numbered prefixes are the bridge's one list (SpecItemCoverage.NumberedPrefixes); a bridge test holds this file to it.
# Shared cases: plugins/kyklos/tests/fixtures/spec-item-range-cases.txt.
BEGIN { max_span = 50; max_end = "2147483647"; en_dash = "\342\200\223"; em_dash = "\342\200\224" }
{
    rest = $0
    before = ""
    while (match(rest, /(UC|FM|AC|RA-|R)[0-9]+|FAIL-(OPEN|HARD)/)) {
        start = RSTART; len = RLENGTH
        token = substr(rest, start, len)
        prev = start > 1 ? substr(rest, start - 1, 1) : substr(before, length(before), 1)
        next_char = substr(rest, start + len, 1)
        if (prev !~ /[A-Za-z0-9]/ && next_char !~ /[A-Za-z0-9]/) {
            print token
            consumed = start + len - 1
            if (ranges == 1 && token !~ /^FAIL-/) {
                consumed += range_tail(token, substr(rest, start + len))
            }
            before = before substr(rest, 1, consumed)
            rest = substr(rest, consumed + 1)
        } else {
            # Not a token here: move one character past where this candidate started and look again.
            before = before substr(rest, 1, start)
            rest = substr(rest, start + 1)
        }
    }
}

# range_tail(token, tail) -> when tail opens with a separator and the closing token of a valid range, prints the items
# after token up to and including the closing one and returns how many characters of tail the range used; else 0.
function range_tail(token, tail,    prefix, from, sep, after, digits, last, width, n, fmt) {
    match(token, /[0-9]+$/)
    prefix = substr(token, 1, RSTART - 1)
    from = substr(token, RSTART)
    sep = separator_length(tail)
    if (sep == 0) return 0
    after = substr(tail, sep + 1)
    if (substr(after, 1, length(prefix)) != prefix) return 0
    if (!match(substr(after, length(prefix) + 1), /^[0-9]+/)) return 0
    digits = substr(after, length(prefix) + 1, RLENGTH)
    if (substr(after, length(prefix) + length(digits) + 1, 1) ~ /[A-Za-z0-9]/) return 0
    if (!fits_int(from) || !fits_int(digits)) return 0
    last = digits + 0
    if (last < from + 0 || last - from >= max_span) return 0
    width = (length(from) > 1 && substr(from, 1, 1) == "0") ? length(from) : 1
    fmt = "%s%0" width "d\n"
    for (n = from + 1; n <= last; n++) printf fmt, prefix, n
    return sep + length(prefix) + length(digits)
}

# separator_length(tail) -> the length of the range separator tail opens with (a dash with optional spaces or tabs around
# it, or " to " / " through " with spaces or tabs), else 0. The dashes are found with index() on their bytes, so the
# length is right whether awk counts bytes (C locale) or characters (a UTF-8 locale).
function separator_length(tail,    lead, body, dash) {
    match(tail, /^[ \t]*/)
    lead = RLENGTH
    body = substr(tail, lead + 1)
    dash = substr(body, 1, 1) == "-" ? 1 : index(body, en_dash) == 1 ? length(en_dash) : index(body, em_dash) == 1 ? length(em_dash) : 0
    if (dash > 0) {
        match(substr(body, dash + 1), /^[ \t]*/)
        return lead + dash + RLENGTH
    }
    if (lead == 0 || !match(body, /^(to|through)[ \t]+/)) return 0
    return lead + RLENGTH
}

# fits_int(digits) -> 1 when the digit string is at most 2147483647, judged on the text (leading zeros ignored), so a long
# run of digits is refused before it becomes a number awk cannot count with.
function fits_int(digits,    d) {
    d = digits
    sub(/^0+/, "", d)
    if (length(d) < length(max_end)) return 1
    if (length(d) > length(max_end)) return 0
    return d <= max_end
}
