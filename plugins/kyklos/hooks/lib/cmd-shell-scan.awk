# cmd-shell-scan.awk - a quote-aware scan of a shell command string, for the "is this text or a call" matcher in
# mr-hands-off.sh. It follows the shell's own quoting (none, '...', "...", $'...') and heredocs, so it can tell what the
# shell will EXECUTE from what it only passes on as text.
#
#   awk -v mode=subst -f cmd-shell-scan.awk   -> prints "1" when the shell would run a command substitution or a
#                                                process substitution ($(...), `...`, <(...), >(...)) outside single
#                                                quotes and outside a heredoc with a quoted delimiter; else nothing.
#   awk -v mode=bodies -f cmd-shell-scan.awk  -> prints "<command><TAB><line>" for every heredoc body line, where
#                                                <command> is the command the heredoc feeds, up to the << marker.
#
# [CySec] A double-quoted "$(curl ...)" or an unquoted heredoc body runs its command even though the quote strip
# removes it from view; reporting it keeps a call from passing as text (CWE-184, incomplete list of disallowed inputs).
# Kept as an awk -f file for the same reason as cmd-strip-heredocs.awk (bash coverage tooling misreads inline awk).
BEGIN { st = 0; nq = 0; inbody = 0 }
function found() { if (mode == "subst") { print "1"; exit 0 } }
{
    line = $0
    if (inbody) {
        t = line; if (bdash) sub(/^\t+/, "", t)
        if (t == bdelim) {
            inbody = 0
            # the next heredoc queued on the same start line, if any
            if (qh < nq) { qh++; bdelim = qdelim[qh]; bquoted = qquoted[qh]; bdash = qdash[qh]; bword = qword[qh]; inbody = 1 }
            else { nq = 0; qh = 0 }
            next
        }
        if (mode == "bodies") { print bword "\t" line; next }
        if (!bquoted) {
            n = length(line)
            for (i = 1; i <= n; i++) {
                c = substr(line, i, 1)
                if (c == "\\") { i++; continue }
                if (c == "`" || substr(line, i, 2) == "$(") found()
            }
        }
        next
    }
    n = length(line); seg = 1
    if (st == 0) seg = 1
    for (i = 1; i <= n; i++) {
        c = substr(line, i, 1); c2 = substr(line, i, 2)
        if (st == 1) { if (c == "'") st = 0; continue }
        if (st == 3) { if (c == "\\") { i++; continue }; if (c == "'") st = 0; continue }
        if (st == 2) {
            if (c == "\\") { i++; continue }
            if (c == "\"") { st = 0; continue }
            if (c == "`" || c2 == "$(") found()
            continue
        }
        # st == 0: unquoted
        if (c == "\\") { i++; continue }
        if (c2 == "$'") { st = 3; i++; continue }
        if (c == "'") { st = 1; continue }
        if (c == "\"") { st = 2; continue }
        if (c == "`" || c2 == "$(" || c2 == "<(" || c2 == ">(") found()
        if (c == ";" || c == "&" || c == "|" || c == "(" || c == ")" || c == "{" || c == "}") { seg = i + 1; continue }
        if (c2 == "<<" && substr(line, i + 2, 1) != "<") {
            word = substr(line, seg, i - seg); gsub(/\t/, " ", word); sub(/^[[:space:]]+/, "", word)
            j = i + 2; dash = 0
            if (substr(line, j, 1) == "-") { dash = 1; j++ }
            while (substr(line, j, 1) ~ /[[:space:]]/) j++
            q = substr(line, j, 1); quoted = 0
            if (q == "'" || q == "\"") { quoted = 1; j++ } else q = ""
            if (substr(line, j, 1) == "\\") { quoted = 1; j++ }
            d = ""
            while (j <= n && substr(line, j, 1) ~ /[A-Za-z0-9_.-]/) { d = d substr(line, j, 1); j++ }
            if (q != "" && substr(line, j, 1) == q) j++
            if (d != "") { nq++; qdelim[nq] = d; qquoted[nq] = quoted; qdash[nq] = dash; qword[nq] = word }
            i = j - 1
            continue
        }
    }
    if (nq > 0 && st == 0) { qh = 1; bdelim = qdelim[1]; bquoted = qquoted[1]; bdash = qdash[1]; bword = qword[1]; inbody = 1 }
}
