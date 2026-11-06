# cmd-strip-quotes.awk - remove the QUOTED text of a shell command, following the shell's own quoting rules, so the
# command-position matchers in cmd-strip.sh see only what the shell reads as command words; and, in the same pass,
# collect the quoted strings the command hands to a shell to RUN (they are command text, not data).
#
# Contract: stdin = command text (heredoc bodies already removed), stdout = the same lines with every quoted run
# removed: '...', "...", $'...', and everything nested inside a double-quoted run ($(...) and `...` with their own
# quotes, to any depth). A backslash escapes the next character outside single quotes. A comment (an unquoted # that
# starts a word) is dropped to the end of its line. Line count is preserved; a quote left open at the end of a line
# continues on the next line, as it does in the shell. An unquoted backslash at the very end of a line is a line
# continuation: the shell removes the backslash and the newline, so the next line is joined onto this one (`git \`
# then `push` on the next line is one `git push`), and an empty line is printed after the joined line for each
# continuation, so the line count still matches the input.
#
# mode (awk -v): "strip" (default) prints only the stripped lines; "payloads" prints only the payloads; "both" prints
# the stripped lines, then each payload after a line holding only the marker character (byte 1). A payload is a quoted
# string a statement hands to a shell to run: `sh -c "<p>"`, `eval "<p>"` (eval's words joined, as eval does),
# `bash <<< "<p>"`, `echo "<p>" | bash` / `printf '<p>' | sh` (the printed string piped into a shell that reads
# its standard input), and a $(...) or `...` inside a double-quoted run (`out="$(git push 2>&1)"` runs the push). A statement starts at the start of the text or after an UNQUOTED ; & | ( ) or backtick, and
# runner or keyword words before the launcher (sudo, env, command, exec, nohup, then, do, !, {, VAR=x, ...) are
# skipped. Because the scan follows the quoting, a separator or a launcher written INSIDE quoted text, a comment or a
# heredoc body never starts a statement, so a mention is never read as a payload.
#
# Why not two flat regexes (s/'[^']*'//; s/"[^"]*"//): they pair the wrong quote characters as soon as a double-quoted
# argument holds a command substitution with quotes of its own ("Basic $(printf 'a:%s' "$(tok X)" | base64)"), and
# leave pieces of the argument behind as fake command words; the push in `git -c "<that>" push` was then never found.
# [CySec] [RiskMitigation RA-01] CWE-184 (incomplete list of disallowed inputs): a quoting shape the strip cannot follow must not hide a real
# git subcommand from the guards that gate it.
# [CySec] [RiskMitigation RA-01] CWE-184: a backslash-newline between git and its subcommand must not split the command
# into two lines the command-position matchers read separately, and a command handed to a shell as a quoted string is
# still a command.
# Kept as an awk -f file, like cmd-strip-heredocs.awk: bash coverage tooling misreads inline awk as bash lines.
function push(s) { sp++; st[sp] = s; pd[sp] = 0 }
function pop() { if (sp > 0) sp-- }
# count_q(s): how many quoted-run placeholders s holds.
function count_q(s,    k, t) { t = s; k = gsub(Q, "", t); return k }
# fill(s, first): s with its placeholders replaced, in order, by the quoted runs numbered from first+1.
function fill(s, first,    r, k, j) {
    r = ""; j = first
    while ((k = index(s, Q)) > 0) { j++; r = r substr(s, 1, k - 1) qs[j]; s = substr(s, k + 1) }
    return r s
}
# lead_words(p): p without the runner / keyword / assignment words a launcher may sit behind. A runner may be named
# by path (/usr/bin/env) and carry options (sudo -E, sudo -u <user>, env -i, time -p).
function lead_words(p) {
    sub(/^[[:space:]]+/, "", p)
    while (match(p, /^([^[:space:]]*\/)?(sudo|doas|command|builtin|exec|nice|nohup|time|stdbuf|env)([[:space:]]+(-[ugCDn][[:space:]]+[^-[:space:]][^[:space:]]*|-[^[:space:]]+))*([[:space:]]+|$)/) \
        || match(p, /^(then|do|else|elif|if|while|until|!|[{]|timeout([[:space:]]+-[^[:space:]]+)*[[:space:]]+[^[:space:]]+|[A-Za-z_][A-Za-z0-9_]*=([^[:space:]\\]|\\.)*)([[:space:]]+|$)/))
        p = substr(p, RLENGTH + 1)
    return p
}
# runs_nothing(opts): the shell options include -n (read and check the syntax only), so nothing is run.
function runs_nothing(opts) { return (" " opts " ") ~ /[[:space:]]-[A-Za-z]*n[A-Za-z]*[[:space:]]/ }
# reads_stdin(rest): the words after a shell name only select options or redirections (or follow -s), so the shell
# runs the text piped into it; a first plain word is a script file, which it runs instead. `-n` runs nothing.
function reads_stdin(rest,    n, w, k, sflag, skip) {
    n = split(rest, w, /[[:space:]]+/); sflag = 0; skip = 0
    for (k = 1; k <= n; k++) {
        if (skip) { skip = 0; continue }
        if (w[k] == "" || w[k] == "-") continue
        if (w[k] ~ /^[0-9]*(<|>|>>|&>|&>>|>&|<&)$/) { skip = 1; continue }   # a redirection whose target is the next word
        if (w[k] ~ /^[0-9]*[<>&]/) continue
        if (w[k] == "--") { if (sflag) return 1; continue }
        if (w[k] ~ /^[-+][oO]$/) { skip = 1; continue }                     # -o pipefail, +O extglob
        if (w[k] ~ /^--/) continue
        if (w[k] ~ /^-[A-Za-z]*n/) return 0
        if (w[k] ~ /^-[A-Za-z]*s/) { sflag = 1; continue }
        if (w[k] ~ /^[-+]/) continue
        return sflag
    }
    return 1
}
function add_payload(s) { if (s != "") { np++; pl[np] = s } }
# open_subst(start): a substitution begins at start; capture it unless an outer one is already being captured.
function open_subst(start) { if (!substcap) { substcap = 1; ssp = sp; sstart = start; scap = "" } }
# close_subst(endpos): the outermost $(...) or `...` inside a double-quoted run ended at endpos (its closing
# character); its text is a command the shell runs (`out="$(git push 2>&1)"`), so it is a payload.
function close_subst(endpos) {
    add_payload(scap substr(line, sstart, endpos - sstart)); scap = ""; substcap = 0
}
# end_stmt(sep): judge the statement just read (pre = its unquoted text with Q for each quoted run, qs = the runs).
function end_stmt(sep,    p, off, rest, k, shell, opts, t) {
    if (pre ~ /^[[:space:]]*$/) { pre = ""; return }   # `|&`, `&&`, a pipe continued on the next line: nothing to judge
    p = lead_words(pre); off = count_q(pre) - count_q(p)
    shell = "^([^[:space:]]*/)?(sh|bash|dash|zsh)([[:space:]]|$)"
    opts = "([[:space:]]+(--?[A-Za-z][-A-Za-z]*|[-+][oO][[:space:]]+[A-Za-z]+))*"
    if (p ~ shell) {
        if (match(p, "^([^[:space:]]*/)?(sh|bash|dash|zsh)" opts "[[:space:]]+-[A-Za-z]*c[A-Za-z]*[[:space:]]+(--[[:space:]]+)?" Q)) {
            if (!runs_nothing(substr(p, 1, RLENGTH))) add_payload(qs[off + count_q(substr(p, 1, RLENGTH))])
        } else if (match(p, "^([^[:space:]]*/)?(sh|bash|dash|zsh)" opts "[[:space:]]*<<<[[:space:]]*" Q)) {
            if (!runs_nothing(substr(p, 1, RLENGTH))) add_payload(qs[off + count_q(substr(p, 1, RLENGTH))])
        } else if (piped != "") {
            rest = p; sub(/^[^[:space:]]+/, "", rest)
            if (reads_stdin(rest)) add_payload(piped)
        }
    } else if (p ~ /^eval([[:space:]]|$)/) {
        rest = substr(p, 5); sub(/^[[:space:]]+(--([[:space:]]+|$))?/, "", rest)
        add_payload(fill(rest, off))
    }
    piped = ""
    if (sep == "|" && p ~ /^(echo|printf)([[:space:]]|$)/) {
        rest = p; sub(/^[^[:space:]]+/, "", rest)
        if (p ~ /^echo/) { sub(/^([[:space:]]+-[A-Za-z]+)*[[:space:]]*/, "", rest); piped = fill(rest, off) }
        else for (k = off + 1; k <= off + count_q(p); k++) { t = qs[k]; gsub(/\\n/, "\n", t); piped = piped (piped == "" ? "" : "\n") t }
    }
    pre = ""; nq = 0; delete qs
}
# close_quote(endpos): the top-level quoted run ended at endpos (its closing quote); keep its text.
function close_quote(endpos,    t) {
    t = cap substr(line, qstart, endpos - qstart)
    if (qkind == "D") { gsub(/\\"/, "\"", t); gsub(/\\\\/, "\\", t) }
    nq++; qs[nq] = t; cap = ""; capturing = 0
}
# reset_all(): forget every scan state, as at the start of the text.
function reset_all() {
    sp = 0; out = ""; joined = 0; pre = ""; nq = 0; piped = ""; capturing = 0; substcap = 0; pending = 0; delete qs
}
BEGIN {
    sp = 0; st[0] = "U"; out = ""; joined = 0; pre = ""; nq = 0; np = 0; piped = ""; capturing = 0; substcap = 0; pending = 0
    Q = sprintf("%c", 1); if (mode == "") mode = "strip"
}
# reset=1 (awk -v): a line holding only the marker byte separates independent command texts (cmd-strip.sh strips all
# the shell-run strings of one command in a single pass): the text before it is finished as at the end of the input,
# the marker line is printed as an empty line, and the scan starts afresh, so an open quote never swallows the next.
reset && $0 == Q {
    if (pending && mode != "payloads") { print out; for (; joined > 1; joined--) print "" }
    end_stmt("\n"); reset_all(); if (mode != "payloads") print ""
    next
}
{
    # The placeholder / marker byte is reserved: one in the input must never split the output early. [RiskMitigation RA-01]
    line = $0; gsub(Q, "", line); n = length(line); cont = 0; esc = 0
    if (capturing) qstart = 1
    if (substcap) sstart = 1
    for (i = 1; i <= n; i++) {
        if (substcap && sp < ssp) close_subst(i - 1)
        if (capturing && sp == 0) close_quote(i - 1)
        c = substr(line, i, 1); s = st[sp]
        if (s == "U") {
            if (c == "\\" && i == n) { cont = 1; break }
            if (c == "\\") { out = out substr(line, i, 2); pre = pre substr(line, i, 2); i++; esc = i; continue }
            # A comment starts a word: an escaped blank before the # (`a\ #b`) keeps it inside the word, as in the shell.
            if (c == "#" && (i == 1 || (substr(line, i - 1, 1) ~ /[[:space:];&|(]/ && esc != i - 1))) break
            if (c == "'") { push("S"); capturing = 1; qkind = "S"; qstart = i + 1; cap = ""; pre = pre Q; continue }
            if (c == "$" && substr(line, i + 1, 1) == "'") { push("A"); i++; capturing = 1; qkind = "A"; qstart = i + 1; cap = ""; pre = pre Q; continue }
            if (c == "\"") { push("D"); capturing = 1; qkind = "D"; qstart = i + 1; cap = ""; pre = pre Q; continue }
            out = out c
            # `2>&1`, `<&3`, `&>file` are redirections, not the & that ends a statement.
            if (c == "&" && (substr(line, i - 1, 1) ~ /[<>]/ || substr(line, i + 1, 1) == ">")) { pre = pre c; continue }
            if (c == "|" || c == ";" || c == "&" || c == "(" || c == ")" || c == "`") {
                # `||` starts a statement that reads no pipe; a single | (or |&) pipes into the next one.
                if (c == "|" && substr(line, i + 1, 1) == "|") { end_stmt("||"); out = out "|"; i++; continue }
                end_stmt(c)
                continue
            }
            pre = pre c
            continue
        }
        if (s == "S") { if (c == "'") pop(); continue }
        if (s == "A") { if (c == "\\") { i++; continue }; if (c == "'") pop(); continue }
        if (s == "D") {
            if (c == "\\") { i++; continue }
            if (c == "\"") { pop(); continue }
            if (c == "$" && substr(line, i + 1, 1) == "(") { push("C"); pd[sp] = 1; i++; open_subst(i + 1); continue }
            if (c == "`") { push("B"); open_subst(i + 1); continue }
            continue
        }
        if (s == "B") { if (c == "\\") { i++; continue }; if (c == "`") pop(); continue }
        # s == "C": a command substitution inside a double-quoted run; its own quotes nest, its parentheses balance.
        if (c == "\\") { i++; continue }
        if (c == "'") { push("S"); continue }
        if (c == "\"") { push("D"); continue }
        if (c == "(") { pd[sp]++; continue }
        if (c == ")") { pd[sp]--; if (pd[sp] == 0) pop(); continue }
    }
    if (substcap && sp < ssp) close_subst(i - 1)
    if (capturing && sp == 0) close_quote(i - 1)
    if (capturing) cap = cap substr(line, qstart) "\n"
    if (substcap) scap = scap substr(line, sstart) "\n"
    # A continuation, or a quote still open at the end of the line, joins the next line onto this one: the shell reads
    # them as one command (`git -c "a=b` newline `c" push` is one push).
    pending = (cont || sp > 0)
    if (pending) { joined++; next }
    end_stmt("\n")
    if (mode != "payloads") { print out; for (; joined > 0; joined--) print "" }
    joined = 0; out = ""
}
END {
    if (pending && mode != "payloads") { print out; for (; joined > 1; joined--) print "" }
    if (substcap) { add_payload(scap); substcap = 0 }   # a substitution left open at the end of the text
    end_stmt("\n")
    # In "both" mode each payload follows its own marker line, so a caller strips each one on its own: an open quote
    # or a heredoc start in one payload must never swallow the next.
    if (mode != "strip") for (k = 1; k <= np; k++) { if (mode == "both") print Q; print pl[k] }
}
