# unquote-words.awk - read a command line the way the shell splits and unquotes it, for inspection. Read by
# iad_normalize_cmd in issue-api-detect.sh. The input is one record (RS is the SOH character).
#
# Output: the command with each word that mixes quoted and unquoted pieces or holds an unquoted backslash ("c"url,
# c'u'rl, "cu"'rl', c\url, \c\u\r\l) written as the one word the shell makes from it, then, each after a STX character,
# the unquoted text of every quoted word that holds a quote, a backslash or a blank (the body of bash -c '...', an eval
# string, a here-string, an ssh command, ...) so that the caller can normalise it as a command line of its own. Words are
# split as the shell splits them: single quotes are literal, double quotes resolve a backslash before a double quote, a
# dollar sign, a backtick or a backslash, adjacent pieces concatenate ('c'"'"'u'"'"'rl'), and an unquoted backslash
# escapes the next character.
#
# A word is written out joined only when the joined text holds none of: a blank, an operator, an expansion, a quote or a
# backslash, so the structure the other detectors read never changes; every other word, and any quote that is never
# closed, is left exactly as written. A quoted text is passed on only where the shell may run it: the arguments of a
# command that only reads text (echo, printf, git, grep, cat, a client's own data flags, ...) are passed on only when the
# same statement also runs a shell, eval, source or ssh (echo '...' | bash, source <(echo '...')). That keeps a commit
# message or an echoed example from being read as a command. A shell behind a wrapper (sudo, env, command, exec,
# timeout, nohup, time, nice, setsid, stdbuf, busybox, xargs, a brace group), a computed command word ($SHELL) and an
# interpreter that reads code from its input (python, node, perl, ruby) count as running code too. The text of a command
# substitution ($(...) or backticks) inside a double-quoted word is ALWAYS passed on, whatever the outer command is,
# because the shell runs it before the outer command sees it. Text a statement writes to a file (tee, a redirection) is
# passed on when any statement of the command runs a shell, since the shell may run that file (... | tee run.sh; sh run.sh).
# [CySec] CWE-436 (Interpretation Conflict): the guards read a program name the way the shell does.
function base(w,   n, a) { n = split(w, a, "/"); return a[n] }
function newcmd() { havecmd = 0; cw = ""; wrapped = 0 }
# cmdsubs(t): pass on the text of every $(...) and `...` inside the double-quoted text t.
function cmdsubs(t,   m, q, c, d, depth, j, st) {
    m = length(t); q = 1
    while (q <= m) {
        c = substr(t, q, 1)
        if (c == "\\") { q += 2; continue }
        if (c == "$" && substr(t, q + 1, 1) == "(") {
            depth = 1; st = q + 2; j = st
            while (j <= m && depth > 0) {
                d = substr(t, j, 1)
                if (d == "\\") { j += 2; continue }
                if (d == "(") depth++
                else if (d == ")") depth--
                j++
            }
            if (depth == 0) { extras = extras "\002" substr(t, st, j - st - 1); q = j; continue }
        } else if (c == "`") {
            st = q + 1; j = st
            while (j <= m && substr(t, j, 1) != "`") { if (substr(t, j, 1) == "\\") j++; j++ }
            if (j <= m) { extras = extras "\002" substr(t, st, j - st); q = j + 1; continue }
        }
        q++
    }
}
function stmtend(   i) {
    if (hasexec) anyexec = 1
    for (i = 1; i <= nc; i++) {
        if (hasexec || (candcw[i] != "" && !(candcw[i] in TEXT))) extras = extras "\002" cand[i]
        else if (filewrite && nd < 60) { nd++; dcand[nd] = cand[i] }     # text written to a file that a later statement may run
    }
    nc = 0; hasexec = 0; filewrite = 0; newcmd()
}
function endword(   hold) {
    if (raw == "") return
    if (((pieces >= 2 && quoted) || esc) && val ~ /^[A-Za-z0-9_.\/=:@%+,-]+$/) out = out val
    else out = out raw
    hold = 0
    if (!havecmd && raw ~ /^[A-Za-z_][A-Za-z0-9_]*=/) hold = 1          # an assignment is not the command word
    else if (!havecmd) {
        havecmd = 1; cw = base(val); hold = 2
        if ((cw in EXEC) || (cw in INTERP) || raw ~ /^\$/) hasexec = 1
        if (cw in WRAP) wrapped = 1
        if (cw == "tee") filewrite = 1
    }
    else if (wrapped && ((base(val) in EXEC) || (base(val) in INTERP) || raw ~ /^\$/)) hasexec = 1
    # git runs some of its quoted words (core.sshCommand=..., submodule foreach '...', --exec=...), but a message, a
    # pattern or a format given to it is text.
    if (cw == "git" && (prevval ~ /^(-m|-am|--message|-F|--grep|--author|--format|--pretty|--since|--until|-S|-G)$/ || raw ~ /^--(message|grep|author|format|pretty|since|until)=/)) hold = 3
    if (hold < 2 && (quoted || esc) && val ~ /[ \t\n'"\\]/ && nc < 60) { nc++; cand[nc] = val; candcw[nc] = cw }
    prevval = val
    raw = ""; val = ""; pieces = 0; quoted = 0; esc = 0; kind = ""
}
# A new piece starts when the kind of text changes (plain, single-quoted, double-quoted) and for every quoted piece.
function piece(k) {
    if (k != kind || k != "p") pieces++
    kind = k
    if (k != "p") quoted = 1
}
BEGIN {
    RS = "\001"; ORS = ""
    split("bash sh dash zsh ksh eval source . ssh su", e, " "); for (k in e) EXEC[e[k]] = 1
    split("sudo env command exec timeout nohup time nice setsid stdbuf busybox xargs {", w, " "); for (k in w) WRAP[w[k]] = 1
    split("python python3 node perl ruby", ip, " "); for (k in ip) INTERP[ip[k]] = 1
    split("echo printf grep egrep fgrep rg cat story agent-msg sed awk jq tr tee head tail wc ls cd mkdir rm cp mv touch test [ [[ true false diff sort uniq cut date basename dirname readlink realpath stat pwd glab curl wget http https xh python python3 node ruby perl pwsh deno bun", t, " ")
    for (k in t) TEXT[t[k]] = 1
}
{
    s = $0; n = length(s); out = ""; extras = ""; raw = ""; val = ""; pieces = 0; quoted = 0; esc = 0; kind = ""; i = 1
    nc = 0; hasexec = 0; filewrite = 0; anyexec = 0; nd = 0; prevval = ""; newcmd()
    while (i <= n) {
        c = substr(s, i, 1)
        if (c == "'") {
            j = index(substr(s, i + 1), "'")
            if (j == 0) { raw = raw substr(s, i); val = val "'"; break }
            piece("s"); raw = raw substr(s, i, j + 1); val = val substr(s, i + 1, j - 1); i += j + 1; continue
        }
        if (c == "\"") {
            k = i + 1; body = ""
            while (k <= n) {
                d = substr(s, k, 1)
                if (d == "\\" && k < n && substr(s, k + 1, 1) ~ /["$`\\]/) { body = body substr(s, k + 1, 1); k += 2; continue }
                if (d == "\"") break
                body = body d; k++
            }
            if (k > n) { raw = raw substr(s, i); val = val "\""; break }
            cmdsubs(substr(s, i + 1, k - i - 1))
            piece("d"); raw = raw substr(s, i, k - i + 1); val = val body; i = k + 1; continue
        }
        if (c ~ /[ \t\n;|&()<>`]/) {
            endword()
            if (c == "&" && (substr(s, i - 1, 1) == "|" || substr(s, i - 1, 1) == ">" || substr(s, i - 1, 1) == "<" || substr(s, i + 1, 1) == ">")) newcmd()   # |& , >& , <& , &>
            else if (c == "\n" || c == ";" || c == "&") stmtend()
            else if (c == ">" && substr(s, i + 1, 1) != "&" && substr(s, i - 1, 1) != "&") { filewrite = 1 }
            else if (c == "|") { if (substr(s, i + 1, 1) == "|") stmtend(); else newcmd() }
            else if (c == "(" || c == ")" || c == "`") newcmd()
            out = out c; i++; continue
        }
        piece("p")
        if (c == "\\") {
            nx = substr(s, i + 1, 1)
            if (nx == "") { raw = raw c; val = val c; i++; continue }
            raw = raw c nx; val = val nx; esc = 1; i += 2; continue
        }
        raw = raw c; val = val c; i++
    }
    endword(); stmtend()
    if (anyexec) for (i = 1; i <= nd; i++) extras = extras "\002" dcand[i]
    print out extras
}
