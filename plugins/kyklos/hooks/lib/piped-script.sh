#!/usr/bin/env bash
# piped-script.sh -- find, in a shell command, a script fetched from the network and run in the same command without
# being saved first (`curl <address> | sh`), so the piped-script guard can refuse it.
#
#   piped_script_find <command> -> one line per finding, "<kind>\t<detail>":
#       script     <address>  a download (curl, wget, iwr, irm, Invoke-WebRequest, Invoke-RestMethod, a WebClient call)
#                             whose output reaches a shell or an interpreter that runs it as code: piped into it, at any
#                             later stage of the same pipeline (`curl u | sh`, `curl u | tr -d '\r' | bash`,
#                             `{ curl u; } | sudo bash -s`, `curl u | python3 -`, `curl u | pwsh`), substituted into it
#                             (`bash <(curl u)`, `sh -c "$(curl u)"`, `eval "$(curl u)"`, `python3 -c "$(curl u)"`,
#                             `iex (iwr u).Content`), or printed by echo or printf into a shell as text that itself holds
#                             such a command. Redirections on either side do not hide it (`curl u 2>&1 | sh`,
#                             `curl u |& sh`, `curl u | bash > log 2>&1`). The detail is the address without its
#                             scheme, or "unnamed".
#       computed   <word>     a download piped into a command whose name is computed when the command runs
#                             (`curl u | $(echo sh)`): what would run the downloaded text cannot be read.
#       broken     <reason>   the shared command normaliser could not run, and the command names a download tool.
#
# What is NOT a finding: a package install (apt, pip, npm, ...), a download saved to a file and run later
# (`curl -o f u && bash f`, `curl u > f`), a download piped into a program that reads it as data and nothing after it
# runs (`curl u | jq .`, `curl u | python3 -c '<code>'`, `curl u | python3 script.py`), a syntax check (`bash -n`,
# `sh -n`), a command word computed when the command runs that is not fed by a download, and the text of a
# here-document body that is plain text (a quoted closing word, and no shell on its line reading it), which is data.
#
# The command is first read the way the shell reads it by the shared normaliser (iad_normalize_cmd in
# issue-api-detect.sh): quotes and backslashes inside a word are removed and the text of every quoted string the shell
# may run (a shell's -c, an eval string, a here-string, an echo piped into a shell, a command substitution) is added as
# a command of its own. Redirections are removed from the words (`2>&1`, `>&2`, `&>f`, `> f`, `2>/dev/null`), `|&` is
# a pipe, and a line ending in a pipe continues on the next line. The command word is read past wrappers, with or
# without a directory (sudo, doas, su -c, env, NAME=value, timeout, nice, nohup, setsid, chroot, flock, runuser -u,
# command, exec, eval, xargs, time, stdbuf, busybox, watch, strace, unshare, nsenter, a find -exec, GNU parallel), inside
# a shell's -c and inside PowerShell's -Command. The caller loads the normaliser first (through require_lib).

# _ps_words <segment> -> sets the array PS_WORDS to the segment's words, quotes removed and redirections dropped (a
# redirection operator with its target, attached or the next word); $IFS and ${IFS} split words like a blank.
_ps_words() {
    local s="${1//\"/ }" w drop=0
    local -a raw=()
    s="${s//\'/ }"
    s="${s//\$\{IFS\}/ }"
    while [[ "$s" =~ ^(.*)\$IFS([^A-Za-z0-9_].*)?$ ]]; do s="${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"; done
    read -r -a raw <<< "$s"
    PS_WORDS=()
    for w in "${raw[@]}"; do
        if [ "$drop" = 1 ]; then drop=0; continue; fi
        if [[ "$w" =~ ^[0-9]*(\<\<\<|\<\<-|\<\<|\<\>|\>\>|\>\||\>|\<)(.*)$ ]]; then
            [ -n "${BASH_REMATCH[2]}" ] || drop=1
            continue
        fi
        PS_WORDS+=("$w")
    done
}

# _ps_trim <text> -> <text> with its words separated by single spaces.
_ps_trim() { local a; read -r -a a <<< "$1"; printf '%s' "${a[*]}"; }

# _ps_in <word> <list...> -> rc 0 when <word> is one of <list>.
_ps_in() { local w="$1" o; shift; for o in "$@"; do [ "$w" = "$o" ] && return 0; done; return 1; }

# _ps_has <word...> -> rc 0 when PS_WORDS holds one of the words.
_ps_has() { local w; for w in "${PS_WORDS[@]}"; do _ps_in "$w" "$@" && return 0; done; return 1; }

# _ps_index_of <from> <word...> -> the index of the first word of PS_WORDS at or after <from> that is one of <word>.
_ps_index_of() {
    local j="$1"; shift
    while [ "$j" -lt "${#PS_WORDS[@]}" ]; do _ps_in "${PS_WORDS[$j]}" "$@" && { printf '%s' "$j"; return 0; }; j=$((j + 1)); done
}

# _ps_first_arg <from> <with-value options...> -> the first non-option word of PS_WORDS from <from>.
_ps_first_arg() {
    local from="$1"; shift
    local i="$from" w
    while [ "$i" -lt "${#PS_WORDS[@]}" ]; do
        w="${PS_WORDS[$i]}"; i=$((i + 1))
        case "$w" in
            --) continue ;;
            -*) _ps_in "$w" "$@" && i=$((i + 1)); continue ;;
        esac
        printf '%s' "$w"; return 0
    done
}

# _ps_is_pwsh <word> -> rc 0 when <word> (a command name without its directory) is PowerShell.
_ps_is_pwsh() { case "${1,,}" in pwsh|pwsh.exe|powershell|powershell.exe) return 0 ;; esac; return 1; }

# _ps_skip_wrappers -> sets PS_CI to the index of the command word of PS_WORDS (after a shell's -c, the first word of
# the -c string), PS_FED to 1 when the command runs text it is given (a shell's -c, su -c, eval or PowerShell's
# -Command with nothing after it: the text comes from a substitution that follows; or xargs handing each input line to
# sh -c '{}'), and PS_INNER to the code given to PowerShell's -Command (read again as a command of its own).
_ps_skip_wrappers() {
    local i=0 w vals j has_c positional
    PS_FED=0; PS_INNER=""
    while [ "$i" -lt "${#PS_WORDS[@]}" ]; do
        w="${PS_WORDS[$i]}"
        # A wrapper is known by its name without the directory (/usr/bin/env, /usr/bin/sudo); an assignment keeps its
        # value as written.
        [[ "$w" == *=* ]] || w="${w##*/}"
        vals=""; positional=0
        case "$w" in
            then|do|else|elif|if|while|until|'{'|'!'|builtin|nohup|command|setsid|busybox|corepack) ;;
            sudo) vals="-u -g -h -p -C -D -r -t -T -U --user --group --host --prompt --close-from --chdir --role --type --command-timeout --other-user" ;;
            doas) vals="-C -u" ;;
            su)
                # su [options] [user] -c <command> runs the command; su without -c runs a shell reading its input.
                j="$(_ps_index_of "$((i + 1))" -c --command)"
                [ -n "$j" ] || break
                i=$((j + 1))
                [ "$i" -lt "${#PS_WORDS[@]}" ] || PS_FED=1
                continue ;;
            env) vals="-u --unset -C --chdir -S --split-string" ;;
            nice) vals="-n --adjustment" ;;
            ionice) vals="-c -n -p -P -u --class --classdata --pid --pgid --uid" ;;
            exec) vals="-a" ;;
            chroot) vals="--userspec --groups"; positional=1 ;;
            flock) vals="-w --wait --timeout -E --conflict-exit-code"; positional=1 ;;
            runuser)
                _ps_has -u --user || break
                vals="-u -g -G -s -w --user --group --supp-group --shell --whitelist-environment" ;;
            xargs) vals="-I -n -P -d -a -E -L -s --max-args --max-procs --delimiter --arg-file --max-lines --max-chars --replace" ;;
            time) vals="-f -o --format --output" ;;
            stdbuf) vals="-i -o -e --input --output --error" ;;
            timeout) vals="-s -k --signal --kill-after"; positional=1 ;;
            watch) vals="-n --interval -q --equexit" ;;
            strace) vals="-a -b -e -E -I -o -O -p -P -s -S -u -U -X --trace --signal --status --output --attach --user --env --string-limit --summary-sort-by --detach-on" ;;
            unshare) vals="-S -G -R -w -l --setuid --setgid --root --wd --map-user --map-group --map-users --map-groups --propagation --setgroups --load-interp" ;;
            nsenter) vals="-t -S -G --target --setuid --setgid" ;;
            find)
                j="$(_ps_index_of "$((i + 1))" -exec -execdir -ok -okdir)"
                [ -n "$j" ] || break
                _ps_find_action "$((j + 1))"; i=0; continue ;;
            parallel) _ps_parallel "$((i + 1))"; i=0; continue ;;
            eval)
                i=$((i + 1))
                [ "$i" -lt "${#PS_WORDS[@]}" ] || PS_FED=1
                continue ;;
            *=*) [[ "$w" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] && { i=$((i + 1)); continue; }; break ;;
            sh|bash|dash|zsh|ksh)
                j=$((i + 1)); has_c=0
                while [ "$j" -lt "${#PS_WORDS[@]}" ]; do
                    w="${PS_WORDS[$j]}"
                    case "$w" in
                        -o|+o|-O|+O|--rcfile|--init-file) j=$((j + 2)); continue ;;
                        --) j=$((j + 1)); break ;;
                        --*) ;;
                        [-+]?*)
                            [[ "$w" =~ ^[-+][A-Za-z]*c[A-Za-z]*$ ]] && has_c=1
                            [[ "$w" =~ ^[-+][A-Za-z]*o$ ]] && j=$((j + 1)) ;;
                        *) break ;;
                    esac
                    j=$((j + 1))
                done
                [ "$has_c" = 1 ] || break
                i="$j"
                # Nothing after -c (a substitution follows), or the {} of xargs -I{} sh -c '{}' (each input line is run).
                { [ "$i" -lt "${#PS_WORDS[@]}" ] && [ "${PS_WORDS[$i]}" != '{}' ]; } || { PS_FED=1; i="${#PS_WORDS[@]}"; }
                continue ;;
            *)
                if _ps_is_pwsh "$w"; then
                    j=$((i + 1))
                    while [ "$j" -lt "${#PS_WORDS[@]}" ]; do
                        case "${PS_WORDS[$j],,}" in -c|-command|-commandwithargs|-cwa) break ;; esac
                        j=$((j + 1))
                    done
                    [ "$j" -lt "${#PS_WORDS[@]}" ] || break
                    j=$((j + 1))
                    # -Command - reads the code from the input: the caller judges that as an interpreter.
                    [ "${PS_WORDS[$j]:-}" = - ] && break
                    if [ "$j" -lt "${#PS_WORDS[@]}" ]; then
                        PS_INNER="${PS_WORDS[*]:$j}"; PS_INNER="${PS_INNER//$'\x1d'/|}"
                    else
                        PS_FED=1
                    fi
                    i="${#PS_WORDS[@]}"
                fi
                break ;;
        esac
        i=$((i + 1))
        while [ "$i" -lt "${#PS_WORDS[@]}" ] && [[ "${PS_WORDS[$i]}" == -* ]]; do
            # shellcheck disable=SC2086 # vals is a word list on purpose
            _ps_in "${PS_WORDS[$i]}" $vals && i=$((i + 1))
            i=$((i + 1))
        done
        i=$((i + positional))
    done
    PS_CI="$i"
}

# _ps_find_action <from> -> PS_WORDS becomes the command of a find action starting at <from>, up to its closing ; or +.
_ps_find_action() {
    local i="$1" w prev="" action_words=()
    while [ "$i" -lt "${#PS_WORDS[@]}" ]; do
        w="${PS_WORDS[$i]}"; i=$((i + 1))
        case "$w" in
            ';'|"\\;"|"\\") break ;;
            +) [ "$prev" = '{}' ] && break ;;
        esac
        prev="$w"; action_words+=("$w")
    done
    PS_WORDS=("${action_words[@]}")
}

# _ps_parallel <from> -> PS_WORDS becomes the command GNU parallel runs: its options skipped, the words before the first
# ::: (or :::+, ::::, ::::+) with each {...} replacement string dropped.
_ps_parallel() {
    local i="$1" w action_words=()
    local vals="-j --jobs -S --sshlogin -I --replace -n --max-args -N --max-replace-args --colsep -d --delimiter --joblog --results --tmpdir -E --eof --timeout --delay --tag-string --sshloginfile -l --max-lines -L --load --memfree -a --arg-file"
    while [ "$i" -lt "${#PS_WORDS[@]}" ] && [[ "${PS_WORDS[$i]}" == -* ]]; do
        # shellcheck disable=SC2086 # vals is a word list on purpose
        _ps_in "${PS_WORDS[$i]}" $vals && i=$((i + 1))
        i=$((i + 1))
    done
    while [ "$i" -lt "${#PS_WORDS[@]}" ]; do
        w="${PS_WORDS[$i]}"; i=$((i + 1))
        case "$w" in :::|:::+|::::|::::+) break ;; esac
        [[ "$w" =~ ^\{[^}]*\}$ ]] || action_words+=("$w")
    done
    PS_WORDS=("${action_words[@]}")
}

# _ps_url -> the first address in PS_WORDS without its scheme, or "unnamed".
_ps_url() {
    local w
    for w in "${PS_WORDS[@]}"; do
        [[ "$w" =~ ^[A-Za-z][A-Za-z0-9+.-]*://(.+)$ ]] && { printf '%s' "${BASH_REMATCH[1]}"; return 0; }
    done
    printf 'unnamed'
}

# _ps_is_stdout <file name> -> rc 0 when the name stands for the standard output.
_ps_is_stdout() { _ps_in "$1" - /dev/stdout /dev/fd/1 /proc/self/fd/1; }

# _ps_saves_to_file <from> <tool> -> rc 0 when the download from index <from> writes to a named file, not to its
# standard output: curl -o <file> / --output <file> / -O / --remote-name (also in a flag cluster such as -fsSLo <file>
# or -fsSLO), wget -O <file> / --output-document=<file> (also -qO <file>, -qO<file>). "-" and /dev/stdout are the
# standard output.
_ps_saves_to_file() {
    local i="$1" tool="$2" w v
    while [ "$i" -lt "${#PS_WORDS[@]}" ]; do
        w="${PS_WORDS[$i]}"; i=$((i + 1)); v=""
        case "$tool:$w" in
            curl:--remote-name|curl:--remote-name-all) return 0 ;;
            curl:--output|wget:--output-document) v="${PS_WORDS[$i]:-}"; i=$((i + 1)) ;;
            curl:--output=*|wget:--output-document=*) v="${w#*=}" ;;
            curl:--*|wget:--*) continue ;;
            curl:-[A-Za-z]*)
                [[ "$w" =~ ^-[A-Za-z]*O$ ]] && return 0
                [[ "$w" =~ ^-[A-Za-z]*o$ ]] || continue
                v="${PS_WORDS[$i]:-}"; i=$((i + 1)) ;;
            wget:-[A-Za-z]*)
                if [[ "$w" =~ ^-[A-Za-z]*O$ ]]; then v="${PS_WORDS[$i]:-}"; i=$((i + 1))
                elif [[ "$w" =~ ^-[A-Za-np-zA-NP-Z]*O(.+)$ ]]; then v="${BASH_REMATCH[1]}"
                else continue; fi ;;
            *) continue ;;
        esac
        [ -n "$v" ] && ! _ps_is_stdout "$v" && return 0
    done
    return 1
}

# _ps_runs_stdin <index of the command word> <command> -> rc 0 when the shell or interpreter at that index runs as code
# the text it is given (its standard input or a substitution that follows), not a named script, code of its own, or a
# syntax check.
_ps_runs_stdin() {
    local i="$1" c="$2" j w stdin=0
    j=$((i + 1))
    case "$c" in
        sh|bash|dash|zsh|ksh|source|.)
            while [ "$j" -lt "${#PS_WORDS[@]}" ]; do
                w="${PS_WORDS[$j]}"; j=$((j + 1))
                case "$w" in
                    -o|+o|-O|+O|--rcfile|--init-file) j=$((j + 1)) ;;
                    -) return 0 ;;
                    --) w="${PS_WORDS[$j]:-}"; [ "$stdin" = 1 ] || [ -z "$w" ] || [ "$w" = - ] || _ps_is_stdin_file "$w"; return ;;
                    --*) ;;
                    -*)
                        # -n reads without running (a syntax check); s reads the script from the input; a cluster
                        # ending in o (-euo pipefail) takes the next word as its value.
                        [[ "$w" =~ ^-[A-Za-z]*n ]] && return 1
                        [[ "$w" =~ ^-[A-Za-z]*s ]] && stdin=1
                        [[ "$w" =~ ^-[A-Za-z]*o$ ]] && j=$((j + 1)) ;;
                    +*) [[ "$w" =~ ^\+[A-Za-z]*o$ ]] && j=$((j + 1)) ;;
                    *) [ "$stdin" = 1 ] || _ps_is_stdin_file "$w"; return ;;
                esac
            done
            return 0 ;;
    esac
    if _ps_is_pwsh "$c"; then
        # PowerShell runs its input with no script file and no -Command code, or with -Command - / -File -.
        while [ "$j" -lt "${#PS_WORDS[@]}" ]; do
            w="${PS_WORDS[$j]}"; j=$((j + 1))
            case "${w,,}" in
                -) return 0 ;;
                -f|-file|-c|-command) [ "${PS_WORDS[$j]:-}" = - ]; return ;;
                -executionpolicy|-ep|-ex|-workingdirectory|-wd|-configurationname|-outputformat|-of|-inputformat|-if|-windowstyle|-w|-settingsfile|-psconsolefile) j=$((j + 1)) ;;
                -*) ;;
                *) return 1 ;;
            esac
        done
        return 0
    fi
    # An interpreter (python, node, perl, ruby, php): code given on the command line (-c, -e, -E, -m, -p, --eval, or a
    # flag cluster ending in one of them) or a named script means its standard input is data; nothing, or "-", means
    # it runs its standard input. An option that takes code with nothing after it takes the code from a substitution.
    while [ "$j" -lt "${#PS_WORDS[@]}" ]; do
        w="${PS_WORDS[$j]}"; j=$((j + 1))
        case "$c:$w" in
            python*:-W|python*:-X|node*:-r|node*:--require|node*:--import|ruby:-r|ruby:-I) j=$((j + 1)); continue ;;
        esac
        case "$w" in
            -) return 0 ;;
            --) [ "$j" -lt "${#PS_WORDS[@]}" ] || return 0; [ "${PS_WORDS[$j]}" = - ]; return ;;
            --eval|--command|--print) [ "$j" -lt "${#PS_WORDS[@]}" ] && return 1; return 0 ;;
            -*) if [[ "$w" =~ ^-[A-Za-z]*[ceEmp]$ ]]; then [ "$j" -lt "${#PS_WORDS[@]}" ] && return 1; return 0; fi
                [[ "$w" =~ ^-[A-Za-z]*[ceEp] ]] && return 1
                continue ;;
            *) _ps_is_stdin_file "$w"; return ;;
        esac
    done
    return 0
}

# _ps_is_stdin_file <file name> -> rc 0 when a script named so is the standard input.
_ps_is_stdin_file() { _ps_in "$1" /dev/stdin /dev/fd/0 /proc/self/fd/0; }

# _ps_runs_input <index of the command word> -> rc 0 when the command at that index (in PS_WORDS, after
# _ps_skip_wrappers) runs as code the text it is given: a shell, an interpreter or PowerShell reading its input, su
# without -c, iex, or a shell's -c / eval fed by what follows.
_ps_runs_input() {
    local i="$1" c
    [ "$PS_FED" = 1 ] && return 0
    c="${PS_WORDS[$i]:-}"; c="${c##*/}"
    case "${c,,}" in
        iex|invoke-expression|su) return 0 ;;
        sh|bash|dash|zsh|ksh|source|.|node|nodejs|perl|ruby|php) _ps_runs_stdin "$i" "$c"; return ;;
        python|python[0-9]*) [[ "$c" =~ ^python[0-9.]*$ ]] && _ps_runs_stdin "$i" "$c"; return ;;
    esac
    _ps_is_pwsh "$c" && _ps_runs_stdin "$i" "$c"
}

# Depth to which text printed into a shell, or PowerShell -Command code, is read again.
_PS_MAX_DEPTH=4

piped_script_find() {
    local cmd="$1" depth="${2:-0}" norm
    # [CySec] CWE-636 "Not Failing Securely": a command that cannot be normalised is not read as written; when it names a
    # download tool it is reported, so the guard refuses it naming the broken install.
    { declare -F iad_normalize_cmd >/dev/null && norm="$(iad_normalize_cmd "$cmd")"; } || {
        if [[ "${cmd,,}" =~ (curl|wget|iwr|irm|invoke-webrequest|invoke-restmethod|downloadstring|downloadfile|webclient) ]]; then
            printf 'broken\tthe command normaliser (issue-api-detect.sh, unquote-words.awk) could not run, so a command that downloads cannot be read\n'
        fi
        return 0
    }
    local found line own
    local -a own_lines=()
    local -A seen=()
    mapfile -t own_lines <<< "$(_IAD_NORM_DEPTH=3 iad_normalize_cmd "$cmd")"
    own=${#own_lines[@]}
    found="$(_ps_find_normalized "$norm" "$depth" "$own")"
    while IFS= read -r line; do
        [ -n "$line" ] && [ -z "${seen[$line]:-}" ] || continue
        seen[$line]=1; printf '%s\n' "$line"
    done <<< "$found"
}

# _ps_line_feeds_shell <line> -> rc 0 when a command on the line is a shell (or su, eval, source, PowerShell, iex) that
# would run a here-document handed to it as shell code. An interpreter of another language (python, node, ...) reads
# the body as its own code, never as shell commands, so it does not count.
_ps_line_feeds_shell() {
    local seg c
    while IFS= read -r seg; do
        [[ "$seg" == $'\x1f'[SPODBC]* ]] && seg="${seg:2}"
        _ps_words "$seg"
        [ "${#PS_WORDS[@]}" -gt 0 ] || continue
        _ps_skip_wrappers
        [ "$PS_FED" = 1 ] && return 0
        c="${PS_WORDS[$PS_CI]:-}"; c="${c##*/}"
        case "${c,,}" in
            eval|su|iex|invoke-expression) return 0 ;;
            sh|bash|dash|zsh|ksh|source|.) _ps_runs_stdin "$PS_CI" "$c" && return 0 ;;
            *) _ps_is_pwsh "$c" && _ps_runs_stdin "$PS_CI" "$c" && return 0 ;;
        esac
    done < <(printf '%s\n' "$1" | _ps_split)
    return 1
}

# _ps_heredoc_openers <line> -> sets PS_HD_ENDS to one entry per here-document the line opens, "<strip><word>", and
# PS_HD_TEXT to 1 when every body is plain text: each closing word is quoted and no shell on the line reads it
# (_ps_line_feeds_shell). A << counts only outside quotes and comments and attached to a command. A here-string (<<<)
# is not an opener.
_ps_heredoc_openers() {
    local s="$1" n=${#1} k=0 ch q="" seg_cmd=0 at_word=1 word quoted strip attached rest
    PS_HD_ENDS=(); PS_HD_TEXT=1
    while [ "$k" -lt "$n" ]; do
        ch="${s:$k:1}"
        if [ "$q" = "'" ]; then [ "$ch" = "'" ] && q=""; k=$((k + 1)); continue; fi
        if [ "$q" = '"' ]; then
            case "$ch" in "\\") k=$((k + 1)) ;; '"') q="" ;; esac
            k=$((k + 1)); continue
        fi
        case "$ch" in
            "\\") k=$((k + 2)); seg_cmd=1; at_word=0; continue ;;
            "'"|'"') q="$ch"; seg_cmd=1; at_word=0 ;;
            ' '|$'\t') at_word=1 ;;
            ';'|'&'|'|'|'('|')'|'`') seg_cmd=0; at_word=1 ;;
            '#') [ "$at_word" = 1 ] && break; at_word=0 ;;
            '<')
                if [ "${s:$k:2}" = '<<' ] && [ "${s:$((k + 2)):1}" != '<' ]; then
                    k=$((k + 2)); strip=0
                    [ "${s:$k:1}" = - ] && { strip=1; k=$((k + 1)); }
                    while [[ "${s:$k:1}" == [[:blank:]] ]]; do k=$((k + 1)); done
                    word=""; quoted=0
                    while [ "$k" -lt "$n" ]; do
                        ch="${s:$k:1}"
                        case "$ch" in
                            ' '|$'\t'|';'|'&'|'|'|'('|')'|'<'|'>'|'`') break ;;
                            "'"|'"') quoted=1 ;;
                            "\\") quoted=1; k=$((k + 1)); word+="${s:$k:1}" ;;
                            *) word+="$ch" ;;
                        esac
                        k=$((k + 1))
                    done
                    attached="$seg_cmd"
                    if [ "$attached" = 0 ]; then
                        rest="${s:$k}"; rest="${rest#"${rest%%[![:blank:]]*}"}"
                        [ -n "$rest" ] && [[ "${rest:0:1}" != [\;\&\|\)\#] ]] && attached=1
                    fi
                    if [ -n "$word" ] && [ "$attached" = 1 ]; then
                        PS_HD_ENDS+=("$strip$word")
                        [ "$quoted" = 1 ] || PS_HD_TEXT=0
                    fi
                    at_word=1; continue
                fi
                at_word=0 ;;
            *) seg_cmd=1; at_word=0 ;;
        esac
        k=$((k + 1))
    done
    [ "${#PS_HD_ENDS[@]}" -gt 0 ] && [ "$PS_HD_TEXT" = 1 ] && _ps_line_feeds_shell "$s" && PS_HD_TEXT=0
    return 0
}

# _ps_mark_heredoc_bodies <command> [<lines of the command itself>] -> the command, one line per line, each line of a
# here-document body that is plain text (its closing word included) prefixed with the character 0x1E. Only the command's
# own lines (not the quoted strings the normaliser appends) can open or close a body; an unterminated body, or one that
# is not plain text, is printed unmarked and read as command lines.
_ps_mark_heredoc_bodies() {
    local -a lines=()
    local total own k e spec probe found
    mapfile -t lines <<< "$1"
    total=${#lines[@]}; own="${2:-$total}"; [ "$own" -le "$total" ] || own="$total"
    k=0
    while [ "$k" -lt "$total" ]; do
        printf '%s\n' "${lines[$k]}"; k=$((k + 1))
        [ "$k" -le "$own" ] || continue
        _ps_heredoc_openers "${lines[$((k - 1))]}"
        [ "${#PS_HD_ENDS[@]}" -gt 0 ] || continue
        e="$k"; found=1
        for spec in "${PS_HD_ENDS[@]}"; do
            found=0
            while [ "$e" -lt "$own" ]; do
                probe="${lines[$e]}"; e=$((e + 1))
                [ "${spec:0:1}" = 1 ] && probe="${probe#"${probe%%[!$'\t']*}"}"
                [ "$probe" = "${spec:1}" ] && { found=1; break; }
            done
            [ "$found" = 1 ] || break
        done
        [ "$found" = 1 ] || continue
        while [ "$k" -lt "$e" ]; do
            if [ "$PS_HD_TEXT" = 1 ]; then printf '\x1e%s\n' "${lines[$k]}"; else printf '%s\n' "${lines[$k]}"; fi
            k=$((k + 1))
        done
    done
}

# _ps_prepare (filter) -> each line made ready for splitting, outside quotes as the shell reads it:
#   - every | that the shell reads as plain text (inside single quotes, or inside double quotes outside a $(...) or
#     backtick substitution) becomes the character 0x1D, so x="curl u | sh" or a commit message is never a pipe (a
#     quoted string the shell may run is read again on its own line by the normaliser, unmasked);
#   - the & of a redirection is dropped, so it is never read as a command separator: 2>&1 and >&2 become 2>1 and >2,
#     &>f becomes >f, and |& (a pipe that also carries the error output) becomes |;
#   - a command line that ends in a pipe is joined with the next line (the pipeline continues there), unless that line
#     is a plain-text here-document body.
# Quotes are followed within one line.
_ps_prepare() {
    awk '{
        out = ""; q = ""; sub_depth = 0; bt = 0; n = length($0)
        for (k = 1; k <= n; k++) {
            ch = substr($0, k, 1)
            if (q == "\047") {
                if (ch == "\047") q = ""; else if (ch == "|") ch = "\035"
            } else if (q == "\"") {
                if (ch == "\\") { out = out ch substr($0, k + 1, 1); k++; continue }
                if (ch == "$" && substr($0, k + 1, 1) == "(") sub_depth++
                else if (ch == "`") bt = !bt
                else if (ch == ")" && sub_depth > 0) sub_depth--
                else if (ch == "\"" && sub_depth == 0 && !bt) q = ""
                else if (ch == "|" && sub_depth == 0 && !bt) ch = "\035"
            } else {
                if (ch == "\\") { out = out ch substr($0, k + 1, 1); k++; continue }
                if (ch == "\047" || ch == "\"") { q = ch; sub_depth = 0; bt = 0 }
                else if (ch == "&") {
                    p = substr(out, length(out), 1); nx = substr($0, k + 1, 1)
                    if (p == ">" || p == "<" || nx == ">") ch = ""
                    else if (p == "|" && substr(out, length(out) - 1, 1) != "|") ch = ""
                }
            }
            out = out ch
        }
        body = (substr($0, 1, 1) == "\036")
        if (held != "") {
            if (body) print held; else out = held " " out
            held = ""
        }
        t = out; sub(/[ \t]+$/, "", t)
        if (!body && (t ~ /(^|[^|])\|$/)) { held = t; next }
        print out
    }
    END { if (held != "") print held }'
}

# _ps_split (filter) -> the prepared command split into simple commands, each line prefixed with the kind of separator
# before it: S (; & && || newline), P (a pipe), O (an opening ( or <(), D (an opening $(), B (a backtick, opening or
# closing), C (a closing parenthesis).
_ps_split() {
    _ps_prepare | sed -E $'s/(\\&\\&|\\|\\||[;&])/\\\n\x1fS/g; s/\\)/\\\n\x1fC/g; s/\\|/\\\n\x1fP/g; s/\\$\\(/\\\n\x1fD/g; s/<\\(/\\\n\x1fO/g; s/\\(/\\\n\x1fO/g; s/`/\\\n\x1fB/g'
}

# _ps_find_normalized <normalised command> <depth> [<lines of the command itself>] -> the findings, one per line,
# possibly repeated.
_ps_find_normalized() {
    local cmd="$1" depth="$2" own="${3:-}" line sep link="S" i c role prev_role="" prev_text="" text fetched=""
    local cur_word=0 b_open=0 trailing in_body=0
    local -a stack=()
    while IFS= read -r line; do
        case "$line" in
            $'\x1f'[SPODBC]*) sep="${line:1:1}"; line="${line:2}" ;;
            $'\x1e'*) sep=S; in_body=1; line="${line:1}" ;;
            *) sep=S; in_body=0 ;;
        esac
        # A plain-text here-document body is data handed to a command, never a command line.
        if [ "$in_body" = 1 ]; then link=S; prev_role=""; fetched=""; cur_word=0; continue; fi
        if [ "$sep" = B ]; then
            if [ "$b_open" = 1 ]; then b_open=0; sep=C; else b_open=1; fi
        fi
        case "$sep" in
            S|C) link=S ;;
            P) link=P ;;
            *) [ "$link" = P ] || link=O ;;
        esac
        # cur_word: whether the command this text belongs to already has its command word. A substitution where the
        # command word stands computes the command's name when it runs; that alone is never a finding, only when a
        # download is piped into it.
        case "$sep" in
            S|P) cur_word=0 ;;
            D|B|O)
                if [ "$sep" != O ] && [ "$cur_word" = 0 ] && [ "$link" = P ] && [ -n "$fetched" ]; then
                    if [ "$sep" = D ]; then text="\$($(_ps_trim "$line"))"; else text="\`$(_ps_trim "$line")\`"; fi
                    printf 'computed\t%s\n' "$text"
                fi
                stack+=("$cur_word"); cur_word=0 ;;
            C)
                if [ "${#stack[@]}" -gt 0 ]; then cur_word="${stack[-1]}"; unset 'stack[-1]'; else cur_word=0; fi ;;
        esac
        _ps_words "$line"
        [ "${#PS_WORDS[@]}" -gt 0 ] || continue
        # The closing brace of a group ({ curl u; } | sh) ends nothing: what the group printed flows on.
        [ "${#PS_WORDS[@]}" = 1 ] && [ "${PS_WORDS[0]}" = '}' ] && continue
        # fetched: the address of a download whose output flows through the current pipeline. A new command that is not
        # joined by a pipe or a substitution starts a new pipeline.
        [ "$link" = S ] && fetched=""
        _ps_skip_wrappers
        i="$PS_CI"
        c="${PS_WORDS[$i]:-}"; c="${c##*/}"
        trailing="${line%\"}"; trailing="${trailing%\'}"
        { [ -n "$c" ] || [ "$PS_FED" = 1 ] || [ -n "$PS_INNER" ] || [[ "$trailing" == *= ]]; } && cur_word=1
        # PowerShell -Command code is read again as a command of its own.
        if [ -n "$PS_INNER" ]; then
            [ "$depth" -lt "$_PS_MAX_DEPTH" ] && (piped_script_find "$PS_INNER" "$((depth + 1))")
            prev_role=""; prev_text=""; link=S; continue
        fi
        # Only wrappers (sudo, env, ...) before a substitution: the command is still to come, so the link and the
        # previous command stay as they are.
        [ -n "$c" ] || [ "$PS_FED" = 1 ] || continue

        role=""; text=""
        # Command names are matched without regard to case (PowerShell); options are not (curl -o and -O differ).
        case "${c,,}" in
            curl|wget|iwr|irm|invoke-webrequest|invoke-restmethod) _ps_saves_to_file "$((i + 1))" "${c,,}" || role=F ;;
            echo|printf) role=E ;;
        esac
        [[ "${line,,}" =~ (downloadstring|downloadfile|webclient) ]] && role=F
        [ -z "$role" ] && _ps_runs_input "$i" && role=X
        [ "$role" = F ] && { text="$(_ps_url)"; fetched="$text"; }
        [ "$role" = E ] && text="$(_ps_printed_text "$((i + 1))" "$c")"
        if [ "$link" = P ] && [ "$role" = X ]; then
            # Any earlier stage of the pipeline downloaded: its output (filtered or not) is run.
            if [ -n "$fetched" ]; then
                printf 'script\t%s\n' "$fetched"
            elif [ "$prev_role" = E ] && [ "$depth" -lt "$_PS_MAX_DEPTH" ]; then
                (piped_script_find "$prev_text" "$((depth + 1))")
            fi
        elif [ "$link" = O ] && [ "$prev_role" = X ]; then
            case "$role" in
                F) printf 'script\t%s\n' "$text" ;;
                E) [ "$depth" -lt "$_PS_MAX_DEPTH" ] && (piped_script_find "$text" "$((depth + 1))") ;;
            esac
        fi
        prev_role="$role"; prev_text="$text"; link=S
    done < <(_ps_mark_heredoc_bodies "$cmd" "$own" | _ps_split)
}

# _ps_printed_text <from> <echo|printf> -> the text echo or printf would print from the words at <from> (options
# dropped; each printf argument on a line of its own), so text fed into a shell can be read as a command.
_ps_printed_text() {
    local i="$1" c="$2" out=""
    if [ "$c" = printf ]; then
        [ "${PS_WORDS[$i]:-}" = -v ] && i=$((i + 2))
        while [ "$i" -lt "${#PS_WORDS[@]}" ]; do out+="${PS_WORDS[$i]}"$'\n'; i=$((i + 1)); done
    else
        while [ "$i" -lt "${#PS_WORDS[@]}" ] && [[ "${PS_WORDS[$i]}" =~ ^-[neE]+$ ]]; do i=$((i + 1)); done
        out="${PS_WORDS[*]:$i}"
    fi
    printf '%s' "${out//$'\x1d'/|}"
}
