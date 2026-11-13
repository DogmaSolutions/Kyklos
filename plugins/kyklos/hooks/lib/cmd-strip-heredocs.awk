# cmd-strip-heredocs.awk — drop heredoc bodies from a shell command string. Externalized from cmd-strip.sh
#an inline multi-line awk program is mis-parsed by kcov's bash coverage as bash-executable lines
# (they are awk source, never bash-run -> eternally 0-hit), zeroing the whole file's coverage. As an `awk -f`
# file the bash caller is a single instrumentable statement AND this program is independently testable.
# [CySec] see cmd-strip.sh.
#
# A heredoc starts only where the shell starts one: a `<<` or `<<-` (not the `<<<` here-string) that is not inside
# quoted text or a comment, followed by its delimiter word. Inside a command substitution the shell reads commands
# again, so a heredoc inside "$(...)" or `...` starts one too (`git commit -m "$(cat <<'EOF'` with an apostrophe in
# the body is the usual commit shape). A `<<X` written inside quoted text (`echo '<<X'; git push`) or a comment is text,
# and must not swallow the commands after it. Only the operator and its delimiter word are removed from the line: the
# rest of the line is still command text (`cat <<X && git push`, the body following on the next lines, runs the push).
# Several heredocs on one line are read in order. Quote state carries across lines, as in the shell.
# The delimiter is one shell word (EOF, 'EOF', "EOF", \EOF, END.); any quoting in it makes the body plain text.
# Without quoting, the shell still runs the $(...) and `...` substitutions of the body, so those are kept as command
# text (one line for each body line that has any), and the rest of the body is dropped.
# [CySec] [RiskMitigation RA-01] CWE-184: text that only looks like a heredoc start must not hide the commands after it,
# and a substitution the shell runs from a heredoc body is a command.
#
# reset=1 (awk -v): a line holding only byte 1 separates independent command texts; a heredoc or quote opened in one
# never swallows the next (cmd-strip.sh strips all the shell-run strings of a command in one pass this way).
#
# uncomment=1 (awk -v): the same scan drops COMMENTS instead, and keeps everything else as written: quoted text, every
# heredoc operator with its delimiter, and every heredoc body line. A comment is an unquoted # that starts a word,
# outside a heredoc body, up to the end of its line; the shell never reads it, so it is neither an option, a refspec
# nor an arm. (cmd-strip.sh's cmd_drop_comments: the one step every guard runs before it reads a command.)
# [CySec] [RiskMitigation RA-01] CWE-184: text the shell never runs must not add or remove what a guard judges.
#
# bodyfile=<path> (awk -v): each heredoc operator with its delimiter is replaced by a marker word (byte 3, "HD", its
# number, byte 3), and every body line is written whole to <path> as "<number><TAB><line>", so a caller can read the
# body a shell is fed on its standard input as the commands it is (lib/run-bound.sh).
BEGIN { SEP = sprintf("%c", 1); reset_all() }
function reset_all() { nd = 0; cur = 0; sp = 0; st[0] = "U"; pd[0] = 0; delete dq; delete dl }
function push(s) { sp++; st[sp] = s; pd[sp] = 0 }
function pop() { if (sp > 0) sp-- }
# no_trailing_blanks(t): t without the blanks a dropped comment leaves behind (an escaped blank is part of a word).
function no_trailing_blanks(t) { if (match(t, /[ \t]+$/) && substr(t, RSTART - 1, 1) != "\\") t = substr(t, 1, RSTART - 1); return t }
# delim_word(rest): rest starts at a delimiter word; sets DW (the word as written), DV (its value), DQ (quoted).
function delim_word(rest,    i, n, c, k) {
    DW = ""; DV = ""; DQ = 0; n = length(rest)
    for (i = 1; i <= n; i++) {
        c = substr(rest, i, 1)
        if (c ~ /[[:space:];&|<>()]/) break
        if (c == "\\") { DQ = 1; DV = DV substr(rest, i + 1, 1); i++; continue }
        if (c == "'" || c == "\"") {
            DQ = 1; k = index(substr(rest, i + 1), c)
            if (k == 0) { DV = DV substr(rest, i + 1); i = n + 1; break }
            DV = DV substr(rest, i + 1, k - 1); i += k; continue
        }
        DV = DV c
    }
    DW = substr(rest, 1, i - 1)
}
# scan(line): the line with every heredoc operator the shell reads and its delimiter word removed; each delimiter is
# queued with whether its body is plain text (a quoted delimiter).
function scan(line,    i, n, c, s, out, rest, m) {
    out = ""; n = length(line); esc = 0
    for (i = 1; i <= n; i++) {
        c = substr(line, i, 1); s = st[sp]
        if (s == "S") { out = out c; if (c == "'") pop(); continue }
        if (s == "A") { out = out c; if (c == "\\") { out = out substr(line, i + 1, 1); i++; continue }; if (c == "'") pop(); continue }
        if (s == "D") {
            out = out c
            if (c == "\\") { out = out substr(line, i + 1, 1); i++; continue }
            if (c == "\"") { pop(); continue }
            if (c == "$" && substr(line, i + 1, 1) == "(") { out = out "("; i++; push("C"); pd[sp] = 1; continue }
            if (c == "`") push("B")
            continue
        }
        # U (unquoted), C (a substitution inside double quotes) and B (backticks inside double quotes) read commands.
        if (c == "\\") { out = out substr(line, i, 2); i++; esc = i; continue }   # esc: an escaped character ends at i
        if (s == "B" && c == "`") { out = out c; pop(); continue }
        if (s == "C" && c == "(") { pd[sp]++; out = out c; continue }
        if (s == "C" && c == ")") { pd[sp]--; out = out c; if (pd[sp] == 0) pop(); continue }
        # A comment starts a word: an escaped blank before the # (`a\ #b`) keeps it inside the word, as in the shell.
        if (c == "#" && (i == 1 || (substr(line, i - 1, 1) ~ /[[:space:];&|(]/ && esc != i - 1))) { if (!uncomment) out = out substr(line, i); else out = no_trailing_blanks(out); break }
        if (c == "'") { push("S"); out = out c; continue }
        if (c == "$" && substr(line, i + 1, 1) == "'") { push("A"); out = out "$'"; i++; continue }
        if (c == "\"") { push("D"); out = out c; continue }
        if (c == "<" && substr(line, i, 3) == "<<<") { out = out "<<<"; i += 2; continue }
        if (c == "<" && substr(line, i + 1, 1) == "<") {
            rest = substr(line, i + 2); m = 2
            if (substr(rest, 1, 1) == "-") { rest = substr(rest, 2); m++ }
            match(rest, /^[[:space:]]*/); m += RLENGTH; rest = substr(rest, RLENGTH + 1)
            delim_word(rest)
            if (DV != "" || DQ) {
                nd++; dq[nd] = DQ; dl[nd] = DV
                if (uncomment) out = out substr(line, i, m + length(DW))   # kept: only the comments go
                else if (bodyfile != "") { hdn++; hdno[nd] = hdn; out = out " " sprintf("%cHD%d%c", 3, hdn, 3) " " }
                i += m + length(DW) - 1; continue
            }
        }
        out = out c
    }
    return out
}
# substs(line): the $(...) and `...` substitutions of an unquoted heredoc body line, joined by "; ".
function substs(line,    i, n, c, r, k, d, j) {
    r = ""; n = length(line)
    for (i = 1; i <= n; i++) {
        c = substr(line, i, 1)
        if (c == "\\") { i++; continue }
        if (c == "$" && substr(line, i + 1, 1) == "(") {
            d = 0
            for (j = i + 1; j <= n; j++) { k = substr(line, j, 1); if (k == "(") d++; else if (k == ")" && --d == 0) break }
            if (j > n) j = n
            r = r (r == "" ? "" : "; ") substr(line, i, j - i + 1); i = j; continue
        }
        if (c == "`") {
            k = index(substr(line, i + 1), "`"); j = (k ? i + k : n)
            r = r (r == "" ? "" : "; ") substr(line, i, j - i + 1); i = j; continue
        }
    }
    return r
}
{
    if (reset && $0 == SEP) { reset_all(); print; next }
    if (cur > 0) {                                   # inside a heredoc body: drop the line, end at its delimiter
        t = $0; sub(/^\t+/, "", t)
        if (uncomment) print                         # a body line is data, never a comment: kept as written
        if (bodyfile != "" && t != dl[cur]) print hdno[cur] "\t" $0 >> bodyfile
        if (t == dl[cur]) { cur++; if (cur > nd) { cur = 0; nd = 0; delete dq; delete dl } }
        else if (!dq[cur] && !uncomment) { t = substs($0); if (t != "") print t }
        next
    }
    print scan($0)
    if (nd > 0) cur = 1                              # the bodies start on the next line
}
