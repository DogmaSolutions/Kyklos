# ask-first.awk - the text scans of lib/ask-first.sh (Ask First), as one `awk -f` program so a coverage run reads
# them as awk, not as shell lines. Select the scan with -v mode=...:
#   assignments  (-v names=<ERE>) "<index>TAB<name>TAB<raw value token>" for each NAME=<token> of a switch, and
#                "<index>TAB<name>TAB-bare" for a switch named without an assignment
#   mark         (-v names=<ERE>) the text with each NAME= replaced by the marker word __ASKFIRST<index>__ (numbered as
#                the assignments scan numbers them)
#   markers      the index of every marker in an assignment position of a stripped command
#   words        the program word of every statement of a stripped command ("+c" appended when it passes -c)
#   sources      for a statement of placeholder text (quoted strings replaced by the word Q): every file it reads text
#                from, one per line - the file arguments of cat and sed, "-f" for a sed script file, and the file of an
#                input redirection (<) - so a write to a settings file whose text comes from another file is unclear
#   bare         (-v names=<ERE>) every switch a statement sets without a plain NAME=value: read NAME, printf -v NAME,
#                mapfile NAME, let, a nameref (declare -n r=NAME), export NAME
# [CySec] CWE-15 / CWE-693: these scans find the switch changes the user must confirm.
function assignments_end(   rest, m, lead, name, after, tok, n) {
    rest = buf; n = 0
    while (match(rest, re)) {
        m = substr(rest, RSTART, RLENGTH)
        lead = (m ~ /^[^A-Za-z0-9_]/) ? 1 : 0
        name = substr(m, 1 + lead); sub(/[^A-Za-z0-9_]$/, "", name)
        after = substr(rest, RSTART + lead + length(name))
        n++
        if (substr(after, 1, 1) == "=") {
            tok = substr(after, 2)
            if (match(tok, /[[:space:];&|)<>\/]/)) tok = substr(tok, 1, RSTART - 1)
            printf "%d\t%s\t%s\n", n, name, tok
        } else {
            printf "%d\t%s\t-bare\n", n, name
        }
        rest = after
    }
}
function mark_end(   rest, out, m, lead, name, after, n) {
    rest = buf; out = ""; n = 0
    while (match(rest, re)) {
        m = substr(rest, RSTART, RLENGTH)
        lead = (m ~ /^[^A-Za-z0-9_]/) ? 1 : 0
        name = substr(m, 1 + lead); sub(/[^A-Za-z0-9_]$/, "", name)
        n++
        out = out substr(rest, 1, RSTART - 1 + lead)
        after = substr(rest, RSTART + lead + length(name))
        if (substr(after, 1, 1) == "=") { out = out "__ASKFIRST" n "__ "; after = substr(after, 2) }
        else out = out name
        rest = after
    }
    printf "%s", out rest
}
# One statement per line: the caller splits the stripped command at ; & | ( ) { } and backticks.
function markers_line(   lead, assigner, i, m) {
    lead = 1; assigner = 0
    for (i = 1; i <= NF; i++) {
        if ($i ~ /^__ASKFIRST[0-9]+__$/) {
            if (lead || assigner) { m = $i; gsub(/[^0-9]/, "", m); print m }
            i++; continue
        }
        if ($i ~ /^(env|export|declare|local|readonly|typeset|sudo|doas)$/) { assigner = 1; continue }
        if ($i ~ /^(!|then|do|else|elif|if|while|until|time|command)$/ || $i ~ /^-/ || $i ~ /^[A-Za-z_][A-Za-z0-9_]*=/) continue
        lead = 0
    }
}
function words_line(   i, w, n, p, c, j) {
    i = 1
    while (i <= NF && ($i ~ /^(!|then|do|else|elif|if|while|until|time|sudo|env|command|exec|nohup|timeout|nice|xargs|export|declare|local|readonly|typeset)$/ || $i ~ /^-/ || $i ~ /^[0-9]*[<>]/ || $i ~ /^__ASKFIRST[0-9]+__$/ || $i ~ /^[A-Za-z_][A-Za-z0-9_]*=/)) {
        if ($i ~ /^__ASKFIRST[0-9]+__$/) i++   # the marker stands for NAME=; its value word follows
        i++
    }
    if (i > NF) return
    w = $i; n = split(w, p, "/"); w = p[n]
    # git is judged by its subcommand: git add or git diff only reads the file, git checkout or git restore writes it.
    if (w == "git") {
        for (j = i + 1; j <= NF; j++) {
            if ($j == "-c" || $j == "-C") { j++; continue }
            if ($j ~ /^-/) continue
            w = "git:" $j; break
        }
    }
    c = ""
    for (j = i + 1; j <= NF; j++) if ($j == "-c" || $j ~ /^-[a-z]*c$/) c = "+c"
    print w c
}
# The program word of a statement: the first field that is no keyword, wrapper, option, redirection or assignment.
function program_index(   i) {
    i = 1
    while (i <= NF && ($i ~ /^(!|then|do|else|elif|if|while|until|time|sudo|env|command|builtin|exec|nohup|timeout|nice|stdbuf|ionice|setsid)$/ || $i ~ /^-/ || $i ~ /^[0-9]*[<>]/ || $i ~ /^[A-Za-z_][A-Za-z0-9_]*=/)) {
        if ($i ~ /^[0-9]*(<|>|>>|>\||&>|&>>)$/) i++   # a bare redirection operator: its file is the next word
        i++
    }
    return i
}
function sources_line(   i, p, n, parts, script, j, w, prog) {
    p = program_index()
    if (p <= NF) { n = split($p, parts, "/"); prog = parts[n] } else prog = ""
    script = (prog == "sed") ? 0 : 1
    for (j = 1; j <= NF; j++) {
        w = $j
        if (w ~ /^[0-9]*<<-?$/) { j++; continue }                        # a here-document: its delimiter follows
        if (w ~ /^[0-9]*<<-?[^<]/) continue                                # a here-document with its delimiter attached
        if (w ~ /^[0-9]*<<</) { if (w ~ /^[0-9]*<<<$/) j++; continue }    # a here-string: literal text
        if (w ~ /^[0-9]*<\(/) { print "Q"; continue }                    # a process substitution: unreadable
        if (w ~ /^[0-9]*<>?$/) { if (j < NF) print $(j + 1); else print "Q"; j++; continue }
        if (w ~ /^[0-9]*<>?/) { sub(/^[0-9]*<>?/, "", w); print w; continue }
        if (w ~ /^[0-9]*(>|>>|>\||&>|&>>)$/) { j++; continue }             # an output redirection and its file
        if (w ~ /^[0-9]*(>|&>)/) continue
        if (j <= p || (prog != "cat" && prog != "sed")) continue
        if (prog == "sed") {
            if (w == "-f" || w == "--file" || w ~ /^--file=/ || w ~ /^-[A-Za-z]*f/) { print "-f"; continue }
            if (w == "--expression" || w ~ /^-[A-Za-z]*e$/) { script = 1; j++; continue }   # -e, -ne: the script follows
            if (w ~ /^--expression=/ || w ~ /^-[A-Za-z]*e./) { script = 1; continue }
            if (w ~ /^-/) continue
            if (!script) { script = 1; continue }                          # the first word is the sed script
            print w; continue
        }
        if (w ~ /^-./) continue                                            # cat: an option ("-" alone is stdin)
        if (w == "-") continue
        print w
    }
}
function bare_line(   j, setter, islet, v) {
    setter = 0; islet = 0
    for (j = 1; j <= NF; j++) {
        if ($j == "let") { islet = 1; continue }
        if ($j ~ /^(read|printf|mapfile|readarray|getopts|declare|typeset|local|export|readonly)$/) { setter = 1; continue }
        if (islet && match($j, "(" names ")")) { print substr($j, RSTART, RLENGTH); continue }   # let NAME=0, let NAME+=1
        if (!setter) continue
        if ($j ~ ("^(" names ")(\\[.*)?$")) { v = $j; sub(/\[.*/, "", v); print v; continue }
        if ($j ~ ("=(" names ")$")) { v = $j; sub(/^.*=/, "", v); print v }                    # a nameref: declare -n r=NAME
    }
}
BEGIN { re = "(^|[^A-Za-z0-9_])(" names ")([^A-Za-z0-9_]|$)" }
mode == "markers" { markers_line(); next }
mode == "words" { words_line(); next }
mode == "sources" { sources_line(); next }
mode == "bare" { bare_line(); next }
{ buf = buf (NR > 1 ? "\n" : "") $0 }
END {
    if (mode == "assignments") assignments_end()
    else if (mode == "mark") mark_end()
}
