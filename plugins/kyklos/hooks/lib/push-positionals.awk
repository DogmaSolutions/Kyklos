# push-positionals.awk — emit the positional args (remote, then refspec(s)) of a `git push`, skipping options and
# the value each value-consuming option eats. Externalized from push-refspec.sh: an inline multi-line awk
# is mis-counted by kcov's bash coverage as bash lines (awk source, never bash-run -> 0-hit phantoms). `vopts` is
# passed with `awk -v`. [CySec] see push-refspec.sh.
#
# Only the `git push` command itself is read. `push` counts only as the SUBCOMMAND of a `git` word (git's own
# options and their values, `-C <dir>` and `-c <k=v>`, may sit between them), so a `push` inside other text is
# not taken for the push. The scan stops at the first shell control operator after it (`&&`, `||`, `|`, `|&`, `;`,
# `&`, a token ending in `;`) and at the end of its line (unless the line ends with a `\` continuation), and a
# redirection (`2>&1`, `>out`, `2> /dev/null`) is skipped with its target. Otherwise the words of the NEXT command
# (`git push 2>&1 | tail -5`, `git push && git status`) would be read as the remote and the refspec, and a push gate
# would judge a destination that is not a branch at all. The text it reads is prepared by _pr_command_text (quoted
# text with spaces is one placeholder word, a `bash -c` payload is its own line); a quoted single word
# (`"feature/x"`) is unquoted here. [CySec] Hardens the push gates' refspec parsing against a misread destination
# (CWE-693).
#
# `want=options` prints the option tokens of the push instead of its positionals (push_is_delete reads those);
# `want=pushoptions` prints the values of its push options, one per line, so a guard reads the options of the push
# itself and never an option-like word of another command. The options are read the way git parses them: `-o X`,
# `-oX`, bundled short flags ending in `o` (`-uo X`, `-qoX`), `--push-option X`/`=X` and every unique abbreviation of
# it (`--pu X`, `--push-opt=X`), and git's own `-c push.pushOption=X` before the subcommand. A source of options the
# text cannot show prints one line starting with `?unknown ` naming it: a GIT_CONFIG_* variable, `-c include.path`,
# `-c includeIf.*`, `-c alias.*` (an alias may push with any option) or `--config-env`. [CySec] One parser for every
# push-option decision, so no guard reads a spelling git accepts as "no option" (CWE-184, CWE-693).

# `allpushes=1` (pushoptions only) reads every push of the text instead of the first, printing `@@git` at each `git`
# word and `@@seen` at its `push` subcommand, so a push's own git options (`git -c push.pushOption=X push`) belong to it
# and a git command that is not a push can be told apart (push_option_values_all keeps only the pushes).
#
# Every word is read the way the shell reads it (unq): quotes and backslashes are removed wherever they sit in the word
# (`merge_request.creat"e"`, `fea''ture/x`, `g\it`, `git "push"`), so a spelling the shell turns into the same word
# is the same word here. An expansion (`$x`, `$(...)`, a backtick) stays visible, so a caller reads it as unknown.
# [CySec] Mitigates CWE-184 (incomplete list of disallowed inputs): no quoting variant of a word escapes the reader.
function endpush() { seen = 0; sawgit = 0; gitval = 0; skipval = 0; pushval = 0; skipredir = 0; ticks = 0; sdepth = 0; btin = 0 }

# unq(w) -> the word w as the shell passes it on: single quotes keep everything literal, double quotes let a backslash
# escape only $ ` " \, and outside quotes a backslash escapes the next character.
function unq(w,  out, n, j, c, q) {
    out = ""; n = length(w); q = ""
    for (j = 1; j <= n; j++) {
        c = substr(w, j, 1)
        if (q == "'") { if (c == "'") q = ""; else out = out c; continue }
        if (q == "\"") {
            if (c == "\"") { q = ""; continue }
            if (c == "\\" && j < n && index("$`\"\\", substr(w, j + 1, 1))) { j++; out = out substr(w, j, 1); continue }
            out = out c; continue
        }
        if (c == "'" || c == "\"") { q = c; continue }
        if (c == "\\" && j < n) { j++; out = out substr(w, j, 1); continue }
        out = out c
    }
    return out
}

# The long options of `git push` that take a value, written in full or as any unique abbreviation git accepts.
function is_pushopt(n)  { return n ~ /^--pu(s(h(-(o(p(t(i(on?)?)?)?)?)?)?)?)?$/ }
function is_valueopt(n) { return n ~ /^--(rep(o)?|exe(c)?|rece(i(v(e(-(p(a(ck?)?)?)?)?)?)?)?)$/ }
# emit(v): a push-option value. A value that is not fully literal after unquoting (an expansion, a substitution, a
# brace list or a glob: { } $ ` * ? [) is printed as `?unknown option <v>` instead: the shell decides what git
# receives, so no guard may read it as "not the option". [CySec] One rule for every spelling the shell builds
# (CWE-184, incomplete list of disallowed inputs).
function literal(v)     { return v !~ /[{}$`*?[]/ }
function emit(v)        { if (want != "pushoptions") return; gsub(/^["']+|["']+$/, "", v); if (v == "" && allpushes) print "@@empty"; else if (literal(v)) print v; else print "?unknown option " v }
# cfgvalue(v): a value `git config` writes to push.pushOption on the line. Only ONE literal, non-empty add or set is
# read (`?config <v>`): a second write, a replace, an unset, a section removal or an empty value changes the list in a
# way the reader does not track, so the configured list is unknown. [CySec] fail closed (CWE-636).
function cfgvalue(v) {
    if (want != "pushoptions") return
    cfgwrites++
    if (cfgop != "") print "?unknown option git config " cfgop " push.pushOption"
    else if (v == "" || !literal(v) || cfgwrites > 1) print "?unknown option git config push.pushOption changed more than once or emptied"
    else print "?config " v
}
# cfgemit(v): a value of git's push.pushOption setting given on the command (-c). In allpushes mode it is marked
# `?cfg <v>`, because git sends it only when the push has no -o of its own.
function cfgemit(v)     { if (want != "pushoptions") return; if (!literal(v)) { print "?unknown option " v; return }; if (allpushes) print "?cfg " v; else print v }
function unknown(why)   { if (want == "pushoptions") print "?unknown " why }
# A `-c <key>=<value>` git option: push.pushOption values are push options; config sources the text cannot show are unknown.
function git_config(kv,  k) {
    kv = unq(kv); k = tolower(kv)
    if (k !~ /=/ || substr(k, 1, index(k, "=")) ~ /[$`]/) { if (k ~ /[$`]/) unknown("git -c " k) }   # a computed KEY may be any setting
    else if (k ~ /^push\.pushoption=/) { sub(/^[^=]*=/, "", kv); cfgemit(kv) }
    else if (k ~ /^(include\.|includeif\.|alias\.)/) unknown("git -c " k)
}
# `printers` (passed with -v) lists the commands that can only print their words (" echo printf ... "): the words of
# such a command are text, so a `git push` among them (`echo git push -o x`) is not a push.
BEGIN { cmdstart = 1 }
{
    for (i = 1; i <= NF; i++) {
        tok = $i
        u = unq(tok)                                           # the word as the shell passes it on
        if (!seen) {                                           # find `git [git-options] push`
            if (tok ~ /(^|[^A-Za-z0-9_])GIT_CONFIG[A-Z0-9_]*=/) unknown("GIT_CONFIG variable " tok)
            # `git config push.pushOption x;`: the value is read before the `;` ends the command.
            if (cfgmode && cfgkey != "" && tok ~ /[^;];+$/) { u = tok; sub(/;+$/, "", u); cfgvalue(unq(u)) }
            if (tok ~ /^(&&|\|\||\||\|&|;|;;|&)$/ || tok ~ /;$/) { sawgit = 0; cmdstart = 1; printing = 0; cfgmode = 0; continue }
            if (cfgmode) {                                     # `git config [opts] push.pushOption <value>`
                if (cfgskip) { cfgskip = 0; continue }
                if (u ~ /^-/) {
                    if (u ~ /^(-f|--file|--blob|--type|--default|--comment)$/) cfgskip = 1
                    else if (u ~ /^--(get|get-all|get-regexp|get-urlmatch|list|show-origin|show-scope)/) cfgmode = 0
                    else if (u ~ /^--(replace-all|unset|unset-all|remove-section|rename-section)/) cfgop = u
                    continue
                }
                if (cfgkey == "") {
                    cfgkey = tolower(u)
                    if (cfgkey !~ /^push(\.pushoption)?$/) { cfgmode = 0; continue }
                    # an unset or a section change takes no value: the configured list is changed here
                    if (cfgop ~ /unset|section/ || cfgkey == "push") { if (cfgop != "" && want == "pushoptions") print "?unknown option git config " cfgop " " cfgkey; cfgmode = 0 }
                    continue
                }
                cfgvalue(u)
                cfgmode = 0; continue
            }
            if (cmdstart) {                                    # the command word: a printer's words are only text
                w = u; sub(/^(\$\(|\(|`|\{|!)+/, "", w)
                if (w != "" && w !~ /^[A-Za-z_][A-Za-z0-9_]*=/) { cmdstart = 0; if (index(printers, " " w " ")) printing = 1 }
            }
            # A substitution among a printer's words runs a command of its own (echo `git push origin x`): read it.
            if (printing && tok ~ /\$\(|`/) { printing = 0; w = u; sub(/^.*(\$\(|`)/, "", w); if (index(printers, " " w " ")) printing = 1 }
            if (printing) continue
            if (sawgit) {
                if (tok == "\\") continue                     # a line continuation between git and its subcommand
                if (gitval) {                                  # the value of a git option (-C <dir>, -c <k=v>)
                    if (gitcfg) { git_config(tok); gitcfg = 0 }
                    # One shell word may span blanks: an escaped blank (`x=a\ b`) or a process / command
                    # substitution with blanks inside (`x=<(echo a)`, `x=\`tok a\``). Keep eating until the word is complete.
                    depth += gsub(/\(/, "(", tok) - gsub(/\)/, ")", tok)
                    ticks = (ticks + gsub(/`/, "`", tok)) % 2               # an open backtick substitution
                    if (depth <= 0 && ticks == 0 && tok !~ /(^|[^\\])(\\\\)*\\$/) { gitval = 0; depth = 0 }
                    continue
                }
                if (u ~ /^-/) {
                    if (u ~ /^--config-env/) unknown("git --config-env")
                    if (u ~ /^-c./) git_config(substr(u, 3))           # `-ckey=value`
                    if (u ~ /^(-C|-c|--git-dir|--work-tree|--namespace|--exec-path|--config-env)$/) { gitval = 1; depth = 0; gitcfg = (u == "-c") }
                    continue
                }
                if (u == "config") { sawgit = 0; cfgmode = 1; cfgkey = ""; cfgskip = 0; cfgop = ""; continue }
                if (u == "push") { if (allpushes && want != "pushoptions") print "@@push"; seen = 1; sdepth = 0; btin = 0; if (allpushes && want == "pushoptions") print "@@seen"; continue }
                sawgit = 0                                     # another git subcommand: not a push
            }
            if (u ~ /^(.*[\/(`])?git$/) { sawgit = 1; if (allpushes && want == "pushoptions") print "@@git" }   # git, /usr/bin/git, $(git, `git, "git", g\it
            continue
        }
        if (tok ~ /^(&&|\|\||\||\|&|;|;;|&)$/) { if (allpushes) { endpush(); continue }; exit }   # a control operator ends the push
        if (tok == "\\") continue                              # a line continuation, not an argument
        last = 0
        if (tok ~ /;$/) { sub(/;+$/, "", tok); last = 1 }        # `git push origin x;` -> x, then stop (or the next push)
        # `r=$(git push origin x)` / `` r=`git push origin x` ``: the substitution, and the push with it, ends here. A
        # substitution opened inside the push (`git push origin $(echo x)`, `` git push origin `echo x` -o y ``) is
        # one of its words instead: it stays in the word, so the caller reads that positional as unknown.
        np = gsub(/\(/, "(", tok); nc = gsub(/\)/, ")", tok); nb = gsub(/`/, "`", tok)
        sdepth += np - nc
        outer = 0
        if (sdepth < 0) outer = 1
        else if (nb % 2) {
            if (btin) btin = 0
            else if (tok ~ /`$/ && tok !~ /^`/) outer = 1
            else btin = 1
        }
        if (outer) { sub(/[)`]+$/, "", tok); last = 1; if (tok == "") { if (allpushes) { endpush(); continue }; exit } }
        tok = unq(tok)                                         # the word as the shell passes it on
        if (skipredir) { skipredir = 0; if (last) { if (allpushes) { endpush(); continue }; exit }; continue }       # the target of a bare redirection
        if (tok ~ /^[0-9]*(<|>|&>)/) {                           # a redirection, not an argument
            if (tok ~ /^[0-9]*(<<?|>>?|&>>?|>&|<&)$/) skipredir = 1  # the target is the NEXT word
            if (last) { if (allpushes) { endpush(); continue }; exit }
            continue
        }
        if (skipval) {                                        # this token is a prior option value
            skipval = 0
            if (pushval) emit(tok)                            # the value of `-o X` / `--push-option X`
            pushval = 0
        }
        else if (tok ~ /^-/) {
            if (want == "options") print tok
            if (tok ~ /^--/) {                                 # a long option, maybe abbreviated, maybe `=value`
                n = tok; v = ""; eq = index(tok, "=")
                if (eq) { n = substr(tok, 1, eq - 1); v = substr(tok, eq + 1) }
                if (is_pushopt(n)) { if (eq) emit(v); else { skipval = 1; pushval = 1 } }
                else if (!eq && (tok ~ vopts || is_valueopt(n))) { skipval = 1; pushval = 0 }
            } else if (tok != "-") {                           # short flags, maybe bundled: `-o X`, `-uo X`, `-qoX`
                f = substr(tok, 2)
                for (k = 1; k <= length(f); k++) {
                    if (substr(f, k, 1) != "o") continue
                    if (k < length(f)) emit(substr(f, k + 1)); else { skipval = 1; pushval = 1 }
                    break
                }
            }
        }
        else if (want != "options" && want != "pushoptions" && tok != "") print tok
        # a positional the shell computes or expands may hold options too: the push cannot be fully read
        else if (want == "pushoptions" && allpushes && tok ~ /[$`*?{}[]|__QUOTED__/) print "?positional " tok
        if (last) { if (allpushes) { endpush(); continue }; exit }
    }
    if (seen && $NF != "\\") { if (allpushes) endpush(); else exit }   # the push command ended with its line
    if (!seen && $NF != "\\") { sawgit = 0; gitval = 0; cmdstart = 1; printing = 0; cfgmode = 0 }   # a new line is a new command
}
