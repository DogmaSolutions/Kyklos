#!/usr/bin/env bash
# shell-scan.sh - split shell command text into its simple commands, the way the shell reads them, and hand each one,
# with its words unquoted, to a judge. Shared by the guards that judge what a command runs (the rm critical-path guard,
# the bounded test-run guard). Source it; it defines functions only, and never evaluates or runs the text.
#
#   shell_scan <text> <depth> <base-offset>
#       Calls the function named by SHELL_SCAN_SIMPLE once per simple command, as `<judge> <depth> <word>...`, with the
#       words unquoted and redirections removed. Before each call SHELL_SCAN_OFFSETS holds, per word, the byte offset of
#       the word's first character in the top-level text, or -1 when the word comes from text that is not a literal
#       part of it (a shell's -c string, an eval argument); a judge that recurses copies the array first. <base-offset>
#       is the offset of <text> in the top-level text (0 for the top level, -1 when unknown). The bodies of ( ... )
#       subshells, $( ... ) and `...` substitutions are scanned at <depth>+1; a judge scans a -c string or an eval
#       argument itself, by calling shell_scan again with base -1. Nesting stops at SHELL_SCAN_MAX_DEPTH (default 8).
#       When SHELL_SCAN_STOP_VAR names a variable, the scan stops as soon as that variable is not empty.
#       SHELL_SCAN_HERESTRINGS holds, per call, the unquoted words the simple command reads as a here-string (`<<< word`),
#       which a judge may read as the standard input of the command (a shell runs it).
#       SHELL_SCAN_PIPE_IN holds the words of the simple command piped into this one (`a | b`: a's words when b is
#       judged; empty when none), and SHELL_SCAN_STDIN_FILE the file a plain `< file` redirects into it (empty when none).
#   shell_scan_match_close <text> <index-of-opening-char> <open> <close>
#       SHELL_SCAN_POS = the index of the matching close character (quotes and nesting respected), or the text length
#       when the text is unbalanced.
#
# Heredoc bodies are not removed here: the caller strips them first (cmd-strip.sh, _cmd_strip_heredocs), because they
# are data. The caller sets LC_ALL=C so that offsets are byte offsets.
# [CySec] CWE-436 (Interpretation Conflict): a guard reads the command words the way the shell does, quotes and
# substitutions included. [RiskMitigation RA-01] The text is only read as a string (CWE-78); nesting is bounded (CWE-674).

_SHELL_SCAN_PLAIN_RUN_RE=$'^[^\'"\\\\$`[:space:];|&<>(){}#]+'
_SHELL_SCAN_DQ_RUN_RE=$'^[^"\\\\$`]+'

shell_scan_match_close() {
    local s="$1" i=$(($2 + 1)) open="$3" close="$4" n=${#1} depth=1 c
    while (( i < n )); do
        c="${s:i:1}"
        case "$c" in
            \\) i=$((i + 2)); continue ;;
            "'") if [ "$open" != '`' ]; then local rest="${s:i+1}" ; local k="${rest%%\'*}"; i=$((i + ${#k} + 2)); continue; fi ;;
            '"') local j=$((i + 1))
                 while (( j < n )); do
                     case "${s:j:1}" in \\) j=$((j + 2)); continue ;; '"') break ;; esac
                     j=$((j + 1))
                 done
                 i=$((j + 1)); continue ;;
        esac
        if [ "$c" = "$close" ]; then
            depth=$((depth - 1)); (( depth == 0 )) && { SHELL_SCAN_POS=$i; return 0; }
        elif [ "$c" = "$open" ] && [ "$open" != "$close" ]; then
            depth=$((depth + 1))
        fi
        i=$((i + 1))
    done
    SHELL_SCAN_POS=$n
}

# _shell_scan_stopped -> rc 0 when the caller asked the scan to stop.
_shell_scan_stopped() { [ -n "${SHELL_SCAN_STOP_VAR:-}" ] && [ -n "${!SHELL_SCAN_STOP_VAR:-}" ]; }

shell_scan() {
    local s="$1" depth="$2" base="${3:--1}"
    (( depth > ${SHELL_SCAN_MAX_DEPTH:-8} )) && return 0
    local -a words=() offs=() heres=() pipein=()
    local w="" inw=0 i=0 n=${#1} c nx body end skipnext=0 wstart=0 herenext=0 stdinnext=0 stdinfile="" piping=0
    _flush_word() {
        if (( inw )); then
            if (( skipnext )); then
                skipnext=0; (( herenext )) && heres+=("$w"); (( stdinnext )) && stdinfile="$w"; herenext=0; stdinnext=0
            else words+=("$w"); offs+=($(( base < 0 ? -1 : base + wstart ))); fi
        fi
        w=""; inw=0
    }
    _flush_cmd() {
        _flush_word
        if (( ${#words[@]} )); then
            # shellcheck disable=SC2034  # read by the judge
            SHELL_SCAN_OFFSETS=("${offs[@]}")
            # shellcheck disable=SC2034  # read by the judge
            SHELL_SCAN_HERESTRINGS=("${heres[@]}")
            # shellcheck disable=SC2034  # read by the judge
            SHELL_SCAN_PIPE_IN=("${pipein[@]}")
            # shellcheck disable=SC2034  # read by the judge
            SHELL_SCAN_STDIN_FILE="$stdinfile"
            "$SHELL_SCAN_SIMPLE" "$depth" "${words[@]}"
            if (( piping )); then pipein=("${words[@]}"); else pipein=(); fi
        fi
        piping=0
        words=(); offs=(); heres=(); stdinfile=""
    }
    while (( i < n )); do
        _shell_scan_stopped && return 0
        c="${s:i:1}"; nx="${s:i+1:1}"
        if (( ! inw )); then
            case "$c" in ' '|$'\t'|$'\r'|';'|'|'|$'\n'|'&'|'<'|'>'|'('|')'|'{'|'}'|'#') ;; *) wstart=$i ;; esac
        fi
        case "$c" in
            "'")
                local rest="${s:i+1}"; local lit="${rest%%\'*}"
                w+="$lit"; inw=1; i=$((i + ${#lit} + 2)) ;;
            '"')
                inw=1; i=$((i + 1))
                while (( i < n )); do
                    c="${s:i:1}"
                    case "$c" in
                        \\) case "${s:i+1:1}" in '"'|'\'|'$'|'`') w+="${s:i+1:1}" ;; *) w+="\\${s:i+1:1}" ;; esac; i=$((i + 2)) ;;
                        '"') i=$((i + 1)); break ;;
                        '$') if [ "${s:i+1:1}" = '(' ]; then
                                 shell_scan_match_close "$s" $((i + 1)) '(' ')'; end=$SHELL_SCAN_POS; body="${s:i+2:end-i-2}"
                                 shell_scan "$body" $((depth + 1)) $(( base < 0 ? -1 : base + i + 2 )); w+="\$($body)"; i=$((end + 1))
                             elif [ "${s:i+1:1}" = '{' ]; then
                                 shell_scan_match_close "$s" $((i + 1)) '{' '}'; w+="${s:i:SHELL_SCAN_POS-i+1}"; i=$((SHELL_SCAN_POS + 1))
                             else w+='$'; i=$((i + 1)); fi ;;
                        '`') shell_scan_match_close "$s" "$i" '`' '`'; end=$SHELL_SCAN_POS; body="${s:i+1:end-i-1}"
                             shell_scan "$body" $((depth + 1)) $(( base < 0 ? -1 : base + i + 1 )); w+="\$($body)"; i=$((end + 1)) ;;
                        *) if [[ "${s:i:512}" =~ $_SHELL_SCAN_DQ_RUN_RE ]]; then w+="${BASH_REMATCH[0]}"; i=$((i + ${#BASH_REMATCH[0]}))
                           else w+="$c"; i=$((i + 1)); fi ;;
                    esac
                done ;;
            \\)
                if [ "$nx" = $'\n' ]; then i=$((i + 2)); else w+="$nx"; inw=1; i=$((i + 2)); fi ;;
            '$')
                if [ "$nx" = '(' ]; then
                    shell_scan_match_close "$s" $((i + 1)) '(' ')'; end=$SHELL_SCAN_POS; body="${s:i+2:end-i-2}"
                    shell_scan "$body" $((depth + 1)) $(( base < 0 ? -1 : base + i + 2 )); w+="\$($body)"; inw=1; i=$((end + 1))
                elif [ "$nx" = '{' ]; then
                    shell_scan_match_close "$s" $((i + 1)) '{' '}'; w+="${s:i:SHELL_SCAN_POS-i+1}"; inw=1; i=$((SHELL_SCAN_POS + 1))
                else w+='$'; inw=1; i=$((i + 1)); fi ;;
            '`')
                shell_scan_match_close "$s" "$i" '`' '`'; end=$SHELL_SCAN_POS; body="${s:i+1:end-i-1}"
                shell_scan "$body" $((depth + 1)) $(( base < 0 ? -1 : base + i + 1 )); w+="\$($body)"; inw=1; i=$((end + 1)) ;;
            ' '|$'\t'|$'\r')
                _flush_word; i=$((i + 1)) ;;
            ';'|'|'|$'\n')
                # A single | pipes this command's output into the next one (|| is a logical or).
                [ "$c" = '|' ] && [ "$nx" != '|' ] && [ "${s:i-1:1}" != '|' ] && piping=1
                _flush_cmd; i=$((i + 1)) ;;
            '&')
                if [ "$nx" = '>' ]; then _flush_word; skipnext=1; i=$((i + 2)); [ "${s:i:1}" = '>' ] && i=$((i + 1))
                else _flush_cmd; i=$((i + 1)); fi ;;
            '<'|'>')
                # A redirection: the word before it (a file descriptor number) and the word after it (the target) are
                # not arguments. `>&2` / `2>&1` carry their target in the same token.
                [[ "$w" =~ ^[0-9]*$ ]] && { w=""; inw=0; }
                _flush_word
                [ "${s:i:3}" = '<<<' ] && herenext=1
                [ "$c" = '<' ] && [[ "$nx" != [\<\>\&] ]] && stdinnext=1
                i=$((i + 1))
                while [[ "${s:i:1}" == [\<\>\&\|] ]]; do i=$((i + 1)); done
                skipnext=1
                while [ "${s:i:1}" = ' ' ]; do i=$((i + 1)); done ;;
            '(')
                if (( inw )); then w+="$c"; i=$((i + 1))
                else
                    _flush_cmd
                    shell_scan_match_close "$s" "$i" '(' ')'; end=$SHELL_SCAN_POS; body="${s:i+1:end-i-1}"
                    shell_scan "$body" $((depth + 1)) $(( base < 0 ? -1 : base + i + 1 )); i=$((end + 1))
                fi ;;
            ')'|'{'|'}')
                if (( inw )) && [ "$c" != ')' ]; then w+="$c"; i=$((i + 1)); else _flush_cmd; i=$((i + 1)); fi ;;
            '#')
                if (( inw )); then w+="$c"; i=$((i + 1))
                else local rest="${s:i}"; local cm="${rest%%$'\n'*}"; i=$((i + ${#cm})); fi ;;
            *)
                # Take the whole run of ordinary characters at once (a per-character loop is slow on long commands).
                if [[ "${s:i:512}" =~ $_SHELL_SCAN_PLAIN_RUN_RE ]]; then w+="${BASH_REMATCH[0]}"; i=$((i + ${#BASH_REMATCH[0]}))
                else w+="$c"; i=$((i + 1)); fi
                inw=1 ;;
        esac
    done
    _flush_cmd
    return 0
}
