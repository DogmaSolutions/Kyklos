# proof-declaring-lines.awk -- the declaring part of each line of a spec section, the same rule as the bridge's
# StoryBodyItems.DeclaredIn: a line declares only the id, range of ids (R2-R4, R2 to R4) or list of them (R3, R4;
# R3/R4; R3 and R4) it OPENS with, after optional indentation, quote marks (>), a heading (###), a bullet (-, *, +), a
# list number (1. or 1)) or a table pipe, a checklist box ([ ] or [x]), emphasis or code marks (*, _, `) and a label
# word (Requirement, Use case, Failure mode, Acceptance criterion, Criterion, Risk). Prints that span with the marks
# removed (for example "R2-R4" or "R3, R4"), one per declaring line, for proof-item-tokens.awk -v ranges=1 to read; a
# line that does not open with an id prints nothing. An id later in a line is a reference (often to another story's
# item, as in "(was R54 of an earlier story)") and declares nothing.
# The numbered prefixes are the bridge's one list (SpecItemCoverage.NumberedPrefixes); a bridge test holds this file to
# it. Shared cases: plugins/kyklos/tests/fixtures/spec-item-declaration-cases.txt.
BEGIN {
    en_dash = "\342\200\223"; em_dash = "\342\200\224"
    id = "(UC|FM|AC|RA-|R)[0-9]+"
}
{
    line = $0
    sub(/\r$/, "", line)
    sub(/^[ \t]*/, "", line)
    while (match(line, /^>[ \t]*/)) line = substr(line, RLENGTH + 1)
    if (match(line, /^#+[ \t]+/)) line = substr(line, RLENGTH + 1)
    if (match(line, /^[-*+][ \t]+/) || match(line, /^[0-9]+[.)][ \t]+/) || match(line, /^\|[ \t]*/)) line = substr(line, RLENGTH + 1)
    if (match(line, /^\[[ xX]\][ \t]+/)) line = substr(line, RLENGTH + 1)
    line = substr(line, marks_length(line) + 1)
    if (match(tolower(line), /^(requirement|use[ \t]+case|failure[ \t]+mode|acceptance[ \t]+criterion|criterion|risk)[ \t]+/)) {
        labelled = substr(line, RLENGTH + 1)
        labelled = substr(labelled, marks_length(labelled) + 1)
        if (item_length(labelled) > 0) line = labelled
    }
    total = item_length(line)
    if (total == 0) next
    while (1) {
        rest = substr(line, total + 1)
        sep = list_separator_length(rest)
        if (sep == 0) break
        more = item_length(substr(rest, sep + 1))
        if (more == 0) break
        total += sep + more
    }
    span = substr(line, 1, total)
    gsub(/[*_`]/, "", span)
    print span
}

# marks_length(s) -> how many emphasis or code marks (*, _, `) s opens with.
function marks_length(s) {
    return match(s, /^[*_`]+/) ? RLENGTH : 0
}

# id_length(s) -> the length of the id s opens with, when no letter or digit follows it; else 0.
function id_length(s,    n) {
    if (!match(s, "^" id)) return 0
    n = RLENGTH
    return substr(s, n + 1, 1) ~ /[A-Za-z0-9]/ ? 0 : n
}

# item_length(s) -> the length of the id or range of ids s opens with; else 0.
function item_length(s,    n, tail, m, sep, after, k) {
    n = id_length(s)
    if (n == 0) return 0
    tail = substr(s, n + 1)
    m = marks_length(tail)
    sep = range_separator_length(substr(tail, m + 1))
    if (sep == 0) return n
    after = substr(tail, m + sep + 1)
    k = marks_length(after)
    after = substr(after, k + 1)
    return id_length(after) > 0 ? n + m + sep + k + id_length(after) : n
}

# range_separator_length(s) -> the length of a range separator s opens with (a dash with optional spaces or tabs
# around it, or " to " / " through "), else 0. The dashes are found with index() on their bytes, so the length is right
# whether awk counts bytes or characters.
function range_separator_length(s,    lead, body, dash) {
    match(s, /^[ \t]*/)
    lead = RLENGTH
    body = substr(s, lead + 1)
    dash = substr(body, 1, 1) == "-" ? 1 : index(body, en_dash) == 1 ? length(en_dash) : index(body, em_dash) == 1 ? length(em_dash) : 0
    if (dash > 0) {
        match(substr(body, dash + 1), /^[ \t]*/)
        return lead + dash + RLENGTH
    }
    if (lead == 0 || !match(body, /^(to|through)[ \t]+/)) return 0
    return lead + RLENGTH
}

# list_separator_length(s) -> the length of a list separator s opens with, marks included (", ", "/", " & ", "; ",
# " and "), else 0.
function list_separator_length(s,    m, body, k) {
    m = marks_length(s)
    body = substr(s, m + 1)
    if (match(body, /^[ \t]*[,\/&;][ \t]*/) || match(body, /^[ \t]+and[ \t]+/)) {
        k = RLENGTH
        return m + k + marks_length(substr(body, k + 1))
    }
    return 0
}
