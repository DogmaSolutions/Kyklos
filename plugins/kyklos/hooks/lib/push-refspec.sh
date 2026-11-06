#!/usr/bin/env bash
# push-refspec.sh — resolve WHICH ref a `git push` command actually pushes, from its REFSPEC, so a push guard
# judges the branch going to the remote rather than the checked-out HEAD. A guard that keys off HEAD misjudges
# `git push origin feature/x` issued while HEAD is on a trunk.
#
# Model: `git push [options] [<remote>] [<refspec>...]`. After the `push` subcommand, the FIRST positional is the
# remote and the SECOND is the first refspec (git always treats a lone positional as the remote). A refspec is
# `[+]<src>[:<dst>]`; the DEST decides "is this a feature/hotfix push" and the SRC decides "what content SHA".
# NO explicit refspec => the current branch is pushed (caller falls back to HEAD). Pure string parsing; on any
# ambiguity the callers fail-open (never a false block). Sourced, not executed; no `set -e` (greps are predicates).

# Options that CONSUME the next token as a value (so that token is NOT a positional). All other `-*` are flags.
_PR_VALUE_OPTS_RE='^(--repo|--exec|--receive-pack)$'
# Commands that can only print their words: a `git push` written among them is text, not a push.
_PR_PRINTERS=' echo printf true false : cat grep '

# Directory of THIS lib, so the co-located `awk -f` program resolves whether the file is sourced or run.
_PR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=git-cmd-detect.sh
. "$_PR_DIR/git-cmd-detect.sh"   # _gtd_drop_message_text: heredoc bodies + message text are data, not the push

# push_positionals <push-cmd> — emit the positional args (remote, then refspec(s)) one per line, in order, after
# the `push` subcommand, skipping options and any value they consume. Word-split on whitespace (git remotes/
# refspecs do not contain spaces in any realistic invocation).
# The awk program lives in push-positionals.awk (`awk -f`), not inline: an inline multi-line awk is
# mis-parsed by kcov's bash coverage as 0-hit bash phantom lines. Behaviour is byte-identical.
push_positionals() {
    _pr_command_text "$1" | awk -v vopts="$_PR_VALUE_OPTS_RE" -v printers="$_PR_PRINTERS" -f "$_PR_DIR/push-positionals.awk"
}

# _pr_command_text <push-cmd> — the command as the push parser reads it: heredoc bodies and commit-message text
# dropped (the shared _gtd_drop_message_text), every quoted text holding a space replaced by ONE placeholder word
# (`echo "git push origin main"` is data; `-o 'title=a b'` is one option value), and the payload of a
# `bash -c "..."` appended as its own line (that one IS command text). A quoted single word (`"feature/x"`) stays,
# and the parser unquotes it. So a `git push` written inside text is never read as the push. Shell comments are gone
# from both (cmd_drop_comments): `git push origin x # open it` sends one refspec, not four.
# _pr_quoted_as_one_word: every quoted text holding a space becomes ONE placeholder word (stdin -> stdout).
_pr_quoted_as_one_word() {
    # Quotes are paired left to right, each with its own closing quote: a pattern match would also pair the closing quote
    # of one word with the opening quote of the next (`-o "a" -o "b"` read as one quoted text " -o ").
    awk -v sq="'" '{
        out = ""; n = length($0); i = 1
        while (i <= n) {
            c = substr($0, i, 1)
            if (c == "\\") { out = out substr($0, i, 2); i += 2; continue }
            if (c == "\"" || c == sq) {
                j = i + 1
                while (j <= n && substr($0, j, 1) != c) {
                    if (c == "\"" && substr($0, j, 1) == "\\") j++
                    # inside double quotes a `$(...)` is one unit, its own quotes included (`"a $(b "c d")"`)
                    else if (c == "\"" && substr($0, j, 2) == "$(") {
                        d = 1; j += 2
                        while (j <= n && d > 0) { x = substr($0, j, 1); if (x == "(") d++; else if (x == ")") d--; if (d > 0) j++ }
                    }
                    j++
                }
                q = substr($0, i, j - i + 1)
                out = out ((q ~ /[[:space:]]/) ? "__QUOTED__" : q); i = j + 1; continue
            }
            # An unquoted control operator glued to a word (`git status;git push`, `cd R&&git push`, `echo|git push`)
            # ends the command there, as the shell reads it: it becomes a word of its own. A redirection (`2>&1`,
            # `&>f`, `>|f`, `<&3`) is not an operator. [CySec] CWE-436: the guards split commands where the shell does.
            if (c == ";" || c == "&" || c == "|") {
                p = substr($0, i - 1, 1); nx = substr($0, i + 1, 1)
                if ((c != ";" && (p == ">" || p == "<")) || (c == "&" && nx == ">")) { out = out c; i++; continue }
                op = c
                if ((c == ";" && nx == ";") || (c == "&" && nx == "&") || (c == "|" && (nx == "|" || nx == "&"))) op = c nx
                out = out " " op " "; i += length(op); continue
            }
            out = out c; i++
        }
        print out
    }'
}
_pr_command_text() {
    local payload cmd
    cmd="$(cmd_join_splices "$1")"
    payload="$(_cmd_extract_shell_c "$cmd")"
    _gtd_drop_message_text "$cmd" | tr -d '\000' | _pr_quoted_as_one_word
    # The payload is command text read the same way.
    [ -z "$payload" ] || printf '\n%s\n' "$(cmd_drop_comments "$payload")" | _pr_quoted_as_one_word
}

# cmd_join_splices <cmd> -> <cmd> with every backslash-newline outside single quotes removed, as bash joins them before
# it splits words (`merge_request.cre\<newline>ate` is one word, `merge_request.create`). Every reader of a command's
# words starts from this text. [CySec] Mitigates CWE-184: a line splice cannot hide a word from the guards.
cmd_join_splices() {
    printf '%s' "$1" | awk -v sq="'" 'BEGIN { RS = "\001" } {
        out = ""; n = length($0); q = ""
        for (i = 1; i <= n; i++) {
            c = substr($0, i, 1)
            if (q == sq) { out = out c; if (c == sq) q = ""; continue }
            if (c == "\\" && substr($0, i + 1, 1) == "\n") { i++; continue }
            if (c == "\\") { out = out c substr($0, i + 1, 1); i++; continue }
            if (c == sq && q == "") q = sq
            else if (c == "\"") q = (q == "\"") ? "" : "\""
            out = out c
        }
        printf "%s", out
    }'
}

# _pr_first_refspec <push-cmd> — the SECOND positional (the first refspec), or empty.
_pr_first_refspec() { push_positionals "$1" | awk 'NR==2 { print; exit }'; }

# push_refspec_src <push-cmd> — the SOURCE ref of the first refspec ('+' stripped, part before ':' , or whole
# token). Empty => no explicit refspec (=> the caller uses HEAD).
push_refspec_src() {
    local rs; rs="$(_pr_first_refspec "$1")"; [ -n "$rs" ] || return 0
    rs="${rs#+}"; printf '%s' "${rs%%:*}"
}

# push_refspec_dest <push-cmd> — the DESTINATION branch of the first refspec ('+' and a leading refs/heads/
# stripped; the part after ':' , or the whole token when there is no ':'). Empty => no explicit refspec.
push_refspec_dest() {
    local rs; rs="$(_pr_first_refspec "$1")"; [ -n "$rs" ] || return 0
    rs="${rs#+}"
    case "$rs" in *:*) rs="${rs##*:}" ;; esac
    printf '%s' "${rs#refs/heads/}"
}

# push_refspec_dests <push-cmd> — the DESTINATION branch of EVERY refspec of the push, one per line, read like
# push_refspec_dest, so a guard can judge each branch a push sends (`git push origin main feature/x` sends both).
push_refspec_dests() {
    local rs
    push_positionals "$1" | awk 'NR > 1' | while IFS= read -r rs; do
        rs="${rs#+}"
        case "$rs" in *:*) rs="${rs##*:}" ;; esac
        printf '%s\n' "${rs#refs/heads/}"
    done
}

# push_sends_every_branch <cmd> — rc 0 when a push of the text sends a set of branches its text does not list (--all,
# --branches, --mirror): which branches it sends then depends on the repository, not on the command.
push_sends_every_branch() {
    _pr_command_text "$1" | awk -v vopts="$_PR_VALUE_OPTS_RE" -v printers="$_PR_PRINTERS" -v want=options -v allpushes=1 -f "$_PR_DIR/push-positionals.awk" \
        | grep -cxE -e '--all|--branches|--mirror' >/dev/null
}

# push_positionals_all <cmd> — the positionals of EVERY push of the text, each push introduced by a line `@@push`.
push_positionals_all() {
    _pr_command_text "$1" | awk -v vopts="$_PR_VALUE_OPTS_RE" -v printers="$_PR_PRINTERS" -v allpushes=1 -f "$_PR_DIR/push-positionals.awk"
}

# push_refspec_dests_all <cmd> — the destination branch of every refspec of every push of the text (the remote, each
# push's first positional, skipped), so a guard judges every branch every push sends, including a push inside a
# substitution.
push_refspec_dests_all() {
    local rs n=0
    push_positionals_all "$1" | while IFS= read -r rs; do
        [ "$rs" = "@@push" ] && { n=0; continue; }
        n=$((n + 1)); [ "$n" -gt 1 ] || continue
        rs="${rs#+}"
        case "$rs" in *:*) rs="${rs##*:}" ;; esac
        printf '%s\n' "${rs#refs/heads/}"
    done
}

# push_positional_unknown_all <cmd> — push_positional_unknown over every push of the text.
push_positional_unknown_all() {
    push_positionals_all "$1" | grep -v '^@@push$' | grep -cE '[$`*?{}[]|__QUOTED__' >/dev/null
}

# push_options <push-cmd> — the option tokens of the `git push` command itself (not of a command chained after it),
# one per line, in order.
push_options() {
    _pr_command_text "$1" | awk -v vopts="$_PR_VALUE_OPTS_RE" -v printers="$_PR_PRINTERS" -v want=options -f "$_PR_DIR/push-positionals.awk"
}

# push_option_values <push-cmd> — the values of the `git push` command's own push options (-o / --push-option), one per
# line, in order; an option-like word of another command chained before or after it is never one of them.
# [CySec] Mitigates CWE-693: a guard that reads a push option (the merge request target) cannot be steered by text
# outside the push.
push_option_values() {
    _pr_command_text "$1" | awk -v vopts="$_PR_VALUE_OPTS_RE" -v printers="$_PR_PRINTERS" -v want=pushoptions -f "$_PR_DIR/push-positionals.awk"
}

# push_options_unknown <push-cmd> — rc 0 (and the reasons on stdout) when the push's options cannot all be read from
# the text: a GIT_CONFIG_* variable, `-c include.path`/`includeIf.*`/`alias.*`, `--config-env`, or an option value the
# shell computes (a variable, a substitution, a backslash or a quote left in it). A caller that decides anything from
# the options (the merge request target, an arm) must then treat them as unknown, never as absent.
# [CySec] Mitigates CWE-693: an option source the hook cannot see is never read as "no such option".
push_options_unknown() {
    local vals
    vals="$(push_option_values "$1")"
    printf '%s\n' "$vals" | grep -E '^\?unknown |[$`\\]' && return 0
    return 1
}

# push_positional_unknown <push-cmd> — rc 0 when a positional of the push (the remote or a refspec) is something the
# shell expands (a variable, a substitution) or a pattern that names several branches (a glob `feature/*`, a brace
# list `feature/{a,b}`): the text then cannot tell which word is the remote and which branches are sent, so the
# destination is unknown. `git push -o x $p origin feature/y` must not read as pushing to `origin`.
push_positional_unknown() {
    push_positionals "$1" | grep -cE '[$`*?{}[]|__QUOTED__' >/dev/null
}

# push_is_delete <push-cmd> — true if this push DELETES a remote ref (`--delete`/`-d` on the push itself, or a `:dst`
# with an empty src). A delete pushes no content, so a content gate must fail-open on it. Only the push's own options
# count: a `-d` of a chained command (`git push ... && git branch -d old`) must not turn a content push into a
# "delete" that skips the gate. [CySec] Hardens the push gates against a fail-open on a misread delete (CWE-693).
push_is_delete() {
    push_options "$1" | grep -cxE -e '--delete|-d' >/dev/null && return 0
    local rs; rs="$(_pr_first_refspec "$1")"; rs="${rs#+}"
    case "$rs" in :*) return 0 ;; esac
    return 1
}

# push_base <top> <remote> <dest> <sha> — the commit a push of <sha> is measured against: its merge base with the
# remote's copy of the destination branch <dest> when that exists (what the remote already has), else with the remote's
# default branch (HEAD, then main, master, develop). An empty <dest> skips the branch candidate. Prints the commit;
# rc 1 when no candidate resolves (no remote-tracking refs, a URL remote), so the caller picks its own fallback.
push_base() {
    local top="$1" remote="$2" dest="$3" sha="$4" ref
    local -a refs=()
    [ -n "$dest" ] && refs+=("refs/remotes/$remote/$dest")
    refs+=("refs/remotes/$remote/HEAD" "refs/remotes/$remote/main" "refs/remotes/$remote/master" "refs/remotes/$remote/develop")
    for ref in "${refs[@]}"; do
        git -C "$top" rev-parse --verify -q "$ref^{commit}" >/dev/null 2>&1 || continue
        git -C "$top" merge-base "$ref" "$sha" 2>/dev/null && return 0
    done
    return 1
}

# push_option_values_all <cmd> — the push-option values of EVERY `git push` in the text (not only the first), each push
# introduced by a line `@@push`, read by the same parser as push_option_values (`?unknown <why>` lines included). The
# whole line is read, so a push whose git options hold a command substitution (`git -c "x=$(...)" push -o ...`) keeps
# its options with it.
# Only the git commands that ARE pushes are kept (`git -c push.pushOption=x commit` sends no option); a source of
# options the reader cannot show (`?unknown ...`) is kept wherever it stands.
push_option_values_all() {
    _pr_command_text "$1" | awk -v vopts="$_PR_VALUE_OPTS_RE" -v printers="$_PR_PRINTERS" -v want=pushoptions -v allpushes=1 -f "$_PR_DIR/push-positionals.awk" \
        | awk '/^@@git$/ { if (seen) printf "%s", buf; buf = "@@push\n"; seen = 0; next }
               /^@@seen$/ { seen = 1; next }
               /^\?(unknown|config) / { print; next }
               { buf = buf $0 "\n" }
               END { if (seen) printf "%s", buf }'
}

# push_reader_sees_push <cmd> — rc 0 when the shared reader finds a `git push` in the text, however the shell spells
# the words (`"git" push`, `g\it push`, `git p\ush`), so a guard never needs a second way to find the push.
push_reader_sees_push() {
    push_option_values_all "$1" | grep -cx '@@push' >/dev/null
}
