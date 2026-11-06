#!/usr/bin/env bash
# cmd-strip.sh — shared command normalization for the mention-vs-invocation detectors (git-cmd-detect,
# dotnet-cmd-detect). ONE source of truth for "remove the parts of a shell command that are DATA, not
# executable command positions", so a subcommand that appears inside a HEREDOC body or a QUOTED substring is
# never mis-read as an invocation.
#
# WHY ("Strip-Before-Match"): a command-position matcher runs line-oriented `grep`, so `^` anchors to
# the start of EVERY line — including a heredoc-body line that happens to start with `git commit`; and a shell
# separator (`;`/`&&`/`|`) INSIDE a quoted argument (`'foo && git commit'`) looks like a real separator. Stripping
# heredoc bodies + quoted substrings BEFORE matching removes both whole classes of false-positive. Extracted from
# the proven dotnet-cmd-detect strip so git + dotnet detectors cannot drift on the rule.
#
# Contract — source this file, then:
#   cmd_strip "<command-string>"  -> echoes the command with heredoc bodies + single/double-quoted substrings removed,
#   followed by the strings the command hands to a shell to run (sh -c, eval, a string piped into a shell, a
#   substitution inside double quotes), each stripped the same way, as extra lines.
#
# Design note: prefer NEVER false-blocking a mention over catching a rare quoted/heredoc'd REAL invocation (CI is
# the backstop). The strip is pure string ops (awk + sed), no subprocess per token — cheap enough for every Bash eval.

# Directory of THIS lib, so the co-located `awk -f` program resolves whether the file is sourced or run.
_CMD_STRIP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Drop heredoc bodies: each `<<[-] DELIM` start marker the shell reads (not one inside quoted text or a comment) + every
# line up to and including the matching terminator (leading tabs tolerated for `<<-`); an unquoted body keeps only its
# $(...) / `...` substitutions, which the shell runs (see cmd-strip-heredocs.awk). Heredoc bodies are NOT quoted, so the
# quote-strip alone misses them.
# The awk program lives in cmd-strip-heredocs.awk (an `awk -f` file), NOT inline: an inline multi-line awk is
# mis-parsed by kcov's bash coverage as bash-executable lines (awk source that bash never runs -> permanently 0-hit),
# which zeroed this whole file's line coverage. Externalized, the caller is one instrumentable bash statement and the
# awk logic is independently testable.
_cmd_strip_heredocs() {
    awk -f "$_CMD_STRIP_DIR/cmd-strip-heredocs.awk"
}

# cmd_drop_comments <command-string> -> the command with its shell COMMENTS removed and nothing else changed (quoted
# text, heredoc operators and heredoc bodies kept as written). A comment is found the way the shell finds one: an
# unquoted # that starts a word, outside a heredoc body. The ONE step every guard that reads push options (the push
# refspec parser, the merge-request hands-off guard, the auto-merge coverage guard and its merged-result check) runs
# before it reads a command, so a trailing note (`git push ... origin x # open it`) can neither add an option, a
# refspec or an arm, nor remove one. The scan is cmd-strip-heredocs.awk's, in its uncomment mode.
# [CySec] [RiskMitigation RA-01] CWE-184: words the shell never runs must not change what a guard judges.
cmd_drop_comments() {
    printf '%s\n' "$1" | awk -v uncomment=1 -f "$_CMD_STRIP_DIR/cmd-strip-heredocs.awk"
}

# Drop quoted text the way the shell reads it: '...', "...", $'...', and everything nested inside a double-quoted run
# (a $(...) with quotes of its own), plus comments; join backslash-newline continuations. The rules live in
# cmd-strip-quotes.awk (see its header); two flat regexes used to pair the wrong quote characters and leave fake
# command words behind. Optional $1 = the awk mode (strip | payloads | both).
_cmd_strip_quotes() {
    awk -v mode="${1:-strip}" -f "$_CMD_STRIP_DIR/cmd-strip-quotes.awk"
}

# Leading VAR=VALUE assignment words before a command name hide it from position-anchored
# matchers (`KYKLOS_ALLOW_PUSH=1 git push` would evade the push detector). Drop assignment words at each
# command position (start of line / after ; & |) so the real command name lands where the matchers look.
# A value is read as one shell word: an escaped blank (`A=a\ b`) stays inside it, and a value that opens a command
# substitution (`r=$(git push 2>&1)`, ``r=`git push` ``) is never dropped, because the command it runs starts inside
# it; dropping `r=$(git ` as one word used to remove the git that the matchers look for.
# [CySec] [RiskMitigation RA-01] CWE-184: an assignment whose value runs a command must not hide that command.
_cmd_strip_env_prefix() {
    sed -E ':a; s/(^|[;&|][[:space:]]*)([A-Za-z_][A-Za-z0-9_]*=([^[:space:]()`\\]|\\.)*[[:space:]]+)+/\1/; ta'
}

# A `sh -c "<string>"` / `bash -c '<string>'` payload IS command text (a plain quote strip would erase
# `sh -c "git push ..."` entirely, hiding the push), unlike ordinary quoted DATA; so are the other ways a quoted string
# is handed to a shell to run: `eval "<string>"`, a string printed into a shell (`echo "<string>" | bash`,
# `printf '<string>' | sh`) and a here-string fed to a shell (`bash <<< "<string>"`). The quote scan in
# cmd-strip-quotes.awk collects them, ONE level deep, at real statement starts only: it runs after heredoc bodies are
# removed and continued lines joined, and a separator or launcher inside quoted text never starts a statement, so a
# MENTION (`echo "use: sh -c 'git push'"`, `git commit -m "a; eval 'git push'"`, a heredoc body, a string piped into
# grep) is never extracted (never false-block a mention). Wrappers-inside-wrappers (docker exec ... bash -c) and
# interpreters (perl/python system calls) remain a documented static-detection limit; the hard controls
# (credentials, protected branches) are the backstop there.
# _cmd_extract_shell_c <command-string> -> the payloads, one block per payload, as written (quotes inside kept).
_cmd_extract_shell_c() {
    printf '%s\n' "$1" | _cmd_strip_heredocs | _cmd_strip_quotes payloads
}

cmd_strip() {
    # One quote-aware scan strips heredoc bodies + quoted substrings + comments and collects the payloads handed to a
    # shell; env-assignment prefixes are then dropped at command positions. The payloads are then stripped the same
    # way, each ON ITS OWN (one level: its own quoted text is data; an open quote or heredoc in one payload never
    # swallows the next, because the marker line between two payloads resets both scans), in ONE more pass for all of
    # them, and appended as additional scannable command text. One pass, not one per payload: a long script holds
    # hundreds of payloads, and three processes for each made every command check take seconds.
    # The text is split at the first marker line by awk, not by bash pattern removal (${x%%"$m"*}), which is
    # quadratic in the text length and took a quarter of a second on a long script.
    local _all _rest _mark
    _mark="$(printf '\001')"
    _all="$(printf '%s' "$1" | _cmd_strip_heredocs | _cmd_strip_quotes both)"
    printf '%s\n' "$_all" | awk -v Q="$_mark" '$0 == Q { exit } { print }' | _cmd_strip_env_prefix
    _rest="$(printf '%s\n' "$_all" | awk -v Q="$_mark" 'f || $0 == Q { f = 1; print }')"
    [ -n "$_rest" ] || return 0
    printf '%s\n' "$_rest" | awk -v reset=1 -f "$_CMD_STRIP_DIR/cmd-strip-heredocs.awk" \
        | awk -v mode=strip -v reset=1 -f "$_CMD_STRIP_DIR/cmd-strip-quotes.awk" | _cmd_strip_env_prefix
    return 0
}
