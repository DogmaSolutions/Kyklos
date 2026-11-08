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
# Out of scope BY DESIGN: a download saved to a file and run later (`curl -o f u && bash f`, `curl u > f`,
# `curl u | tee f; bash f`, a filter that writes a file the command later runs). Saving first is the remedy this guard
# asks for: the file can be read before it runs. Only a download handed to a runner in the same pipeline is judged.
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

# _ps_unmask <text> -> <text> with the characters _ps_prepare masked as plain text turned back (| ( ) ; & backtick).
_ps_unmask() {
    local t="${1//$'\x1d'/|}"
    t="${t//$'\x02'/(}"; t="${t//$'\x03'/)}"; t="${t//$'\x04'/;}"; t="${t//$'\x05'/&}"; t="${t//$'\x06'/\`}"
    printf '%s' "$t"
}

# _ps_in <word> <list...> -> rc 0 when <word> is one of <list>.
_ps_in() { local w="$1" o; shift; for o in "$@"; do [ "$w" = "$o" ] && return 0; done; return 1; }

# _ps_has <word...> -> rc 0 when PS_WORDS holds one of the words.
_ps_has() { local w; for w in "${PS_WORDS[@]}"; do _ps_in "$w" "$@" && return 0; done; return 1; }

# _ps_index_of <from> <word...> -> the index of the first word of PS_WORDS at or after <from> that is one of <word>.
_ps_index_of() {
    local j="$1"; shift
    while [ "$j" -lt "${#PS_WORDS[@]}" ]; do _ps_in "${PS_WORDS[$j]}" "$@" && { printf '%s' "$j"; return 0; }; j=$((j + 1)); done
}

# _ps_is_pwsh <word> -> rc 0 when <word> (a command name without its directory) is PowerShell.
_ps_is_pwsh() { case "${1,,}" in pwsh|pwsh.exe|powershell|powershell.exe) return 0 ;; esac; return 1; }

# _ps_skip_wrappers -> sets PS_CI to the index of the command word of PS_WORDS (after a shell's -c, the first word of
# the -c string), PS_FED to 1 when the command runs text it is given (a shell's -c, su -c, eval or PowerShell's
# -Command with nothing after it: the text comes from a substitution that follows; or xargs handing each input line to
# sh -c '{}'), and PS_INNER to the code given to PowerShell's -Command (read again as a command of its own).
_ps_skip_wrappers() {
    local i=0 w vals j has_c positional
    PS_FED=0; PS_INNER=""; PS_VIA_RUNNER=0
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
                PS_VIA_RUNNER=1
                i=$((j + 1))
                [ "$i" -lt "${#PS_WORDS[@]}" ] || PS_FED=1
                continue ;;
            env)
                # -S / --split-string carries the command itself (env -S bash, env -S"bash -e", env -Sbash): its value
                # is read as the command, never skipped as an option value.
                vals="-u --unset -C --chdir"
                j=$((i + 1))
                while [ "$j" -lt "${#PS_WORDS[@]}" ] && [[ "${PS_WORDS[$j]}" == -* ]]; do
                    if [[ "${PS_WORDS[$j]}" =~ ^-[iv0]*S(.+)$ ]] || [[ "${PS_WORDS[$j]}" =~ ^--split-string=(.+)$ ]]; then
                        PS_WORDS[$j]="${BASH_REMATCH[1]}"; break
                    fi
                    _ps_in "${PS_WORDS[$j]}" -u --unset -C --chdir && j=$((j + 1))
                    j=$((j + 1))
                done ;;
            nice) vals="-n --adjustment" ;;
            ionice) vals="-c -n -p -P -u --class --classdata --pid --pgid --uid" ;;
            exec) vals="-a" ;;
            chroot) vals="--userspec --groups"; positional=1 ;;
            flock) vals="-w --wait --timeout -E --conflict-exit-code"; positional=1 ;;
            runuser)
                _ps_has -u --user || break
                vals="-u -g -G -s -w --user --group --supp-group --shell --whitelist-environment" ;;
            xargs) PS_VIA_RUNNER=1; vals="-I -n -P -d -a -E -L -s --max-args --max-procs --delimiter --arg-file --max-lines --max-chars --replace" ;;
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
                PS_VIA_RUNNER=1
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
                PS_VIA_RUNNER=1
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
                        PS_INNER="$(_ps_unmask "${PS_WORDS[*]:$j}")"
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
        [[ "$w" =~ ^[A-Za-z][A-Za-z0-9+.-]*://(.+)$ ]] && { _ps_unmask "${BASH_REMATCH[1]}"; return 0; }
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
    local i="$1" c="$2" j w stdin=0 implicit=0
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
            --eval|--command|--print) [ "$j" -lt "${#PS_WORDS[@]}" ] || return 0; _ps_code_runs_input "$j" "$implicit"; return ;;
            -*) case "$c" in perl|ruby) [[ "$w" =~ ^-[A-Za-z]*[np] ]] && implicit=1 ;; esac
                if [[ "$w" =~ ^-[A-Za-z]*[ceEmp]$ ]]; then [ "$j" -lt "${#PS_WORDS[@]}" ] || return 0; _ps_code_runs_input "$j" "$implicit"; return; fi
                [[ "$w" =~ ^-[A-Za-z]*[ceEp] ]] && return 1
                continue ;;
            *) _ps_is_stdin_file "$w"; return ;;
        esac
    done
    return 0
}

# _ps_code_runs_input <from> [<implicit>] -> rc 0 when the inline program in PS_WORDS from <from> runs its own input as code: it
# reads the standard input (stdin, open(0), /dev/stdin, readFileSync(0), <STDIN>, ARGF) and hands text to an
# evaluator or a command runner (exec, eval, compile, Function, runInThisContext, loadstring, instance_eval, system,
# popen, spawn, execSync, qx). <implicit> 1: the program loops over the input itself (perl or ruby -n / -p). Reading
# the input as data (json.load(sys.stdin)) is not running it.
_ps_code_runs_input() {
    local code
    code="$(_ps_unmask "${PS_WORDS[*]:$1}")"
    [ "${2:-0}" = 1 ] || [[ "$code" =~ (stdin|STDIN|open\(0|/dev/stdin|fd/0|readFileSync\(0|ARGF|\$_) ]] || return 1
    [[ "$code" =~ (^|[^.A-Za-z0-9_])(exec|eval|compile|Function|loadstring|instance_eval|system|popen|spawn|spawnSync|execSync|qx)[[:space:]]*[\(\<\$\{] ]] && return 0
    [[ "$code" =~ run(InThis|InNew)?Context[[:space:]]*\( ]]
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
        sh|bash|dash|zsh|ksh|source|.|node|nodejs|perl|ruby|php|lua|luajit) _ps_runs_stdin "$i" "$c"; return ;;
        # deno runs the program it is given as - (its input); awk runs a program file named - or /dev/stdin.
        deno) _ps_has - /dev/stdin /dev/fd/0; return ;;
        awk|gawk|mawk|nawk) _ps_awk_reads_program_from_input "$i"; return ;;
        python|python[0-9]*) [[ "$c" =~ ^python[0-9.]*$ ]] && _ps_runs_stdin "$i" "$c"; return ;;
    esac
    _ps_is_pwsh "$c" && _ps_runs_stdin "$i" "$c"
}

# _ps_awk_reads_program_from_input <index of the command word> -> rc 0 when awk's -f (also -f- or --file) names the
# standard input as its program file.
_ps_awk_reads_program_from_input() {
    local j=$(($1 + 1)) w
    while [ "$j" -lt "${#PS_WORDS[@]}" ]; do
        w="${PS_WORDS[$j]}"; j=$((j + 1))
        case "$w" in
            -f|--file) _ps_in "${PS_WORDS[$j]:-}" - /dev/stdin /dev/fd/0 /proc/self/fd/0 && return 0; j=$((j + 1)) ;;
            -f*|--file=*) _ps_in "${w#-f}" - /dev/stdin /dev/fd/0 && return 0; _ps_in "${w#--file=}" - /dev/stdin /dev/fd/0 && return 0 ;;
        esac
    done
    return 1
}

# _ps_long_option_values <option> <shortest abbreviation length> -> rc 0 when PS_WORDS holds the GNU long option (also
# abbreviated to at least that many characters, --comp for --compress-program), printing each value on a line: the part
# after = or, without one, the next word.
_ps_long_option_values() {
    local opt="$1" min="$2" i=0 w name found=1
    while [ "$i" -lt "${#PS_WORDS[@]}" ]; do
        w="${PS_WORDS[$i]}"; i=$((i + 1))
        [[ "$w" == --* ]] || continue
        name="${w%%=*}"
        if [ "${#name}" -lt "$min" ] || [[ "$opt" != "$name"* ]]; then continue; fi
        if [[ "$w" == *=* ]]; then printf '%s\n' "${w#*=}"; else printf '%s\n' "${PS_WORDS[$i]:-}"; fi
        found=0
    done
    return "$found"
}

# _ps_option_has_value <option> <shortest abbreviation length> -> rc 0 when the GNU long option is given a non-empty value.
_ps_option_has_value() {
    local v
    while IFS= read -r v; do
        [ -z "$v" ] || return 0
    done < <(_ps_long_option_values "$1" "$2")
    return 1
}

# _ps_is_compressor <value> -> rc 0 when <value> is exactly the name of a known compressor (no directory, no arguments).
_ps_is_compressor() {
    case "$1" in gzip|pigz|bzip2|xz|zstd|lz4|lzop|lzma|compress) return 0 ;; esac
    return 1
}

# _ps_option_programs_are_compressors <option> <shortest abbreviation length> -> rc 0 when every value of the GNU long
# option is a known compressor (or the option is absent). A tool that runs the program named there on its data (sort's
# --compress-program, tar's --use-compress-program) runs a shell or interpreter named there on the download.
# [CySec] CWE-78 (OS Command Injection) / CWE-494: a program named by an option executes on the downloaded data.
_ps_option_programs_are_compressors() {
    local v
    while IFS= read -r v; do
        _ps_is_compressor "$v" || return 1
    done < <(_ps_long_option_values "$1" "$2")
    return 0
}

# _ps_tar_runs_program <index of the command word> -> rc 0 when the tar command line names a program that tar runs
# on its data: --to-command, --info-script, --new-volume-script, --checkpoint-action, --rsh-command (any value), a
# --use-compress-program that is not a known compressor, or the short options -I (compress program, a known compressor
# allowed) and -F (info script) anywhere in a group of short options, also the old style without a dash (tar xI sh).
# Long options count when abbreviated to their shortest unambiguous prefix (--to-c, --use, --info, --new-v,
# --checkpoint-a).
# [CySec] CWE-78 (OS Command Injection) / CWE-494: a program named by an option executes on the downloaded data.
_ps_tar_runs_program() {
    local spec k=$(($1 + 1)) first=1 w cluster v
    for spec in to-command:6 info-script:6 new-volume-script:7 checkpoint-action:14 rsh-command:5; do
        if _ps_long_option_values "--${spec%%:*}" "${spec##*:}" >/dev/null; then return 0; fi
    done
    _ps_option_programs_are_compressors --use-compress-program 5 || return 0
    while [ "$k" -lt "${#PS_WORDS[@]}" ]; do
        w="${PS_WORDS[$k]}"; k=$((k + 1))
        if [[ "$w" =~ ^-[A-Za-z0-9]+$ ]] || { [ "$first" = 1 ] && [[ "$w" =~ ^[A-Za-z0-9]+$ ]]; }; then
            cluster="${w#-}"
            [[ "$cluster" == *F* ]] && return 0
            if [[ "$cluster" == *I* ]]; then
                v="${cluster#*I}"
                [ -n "$v" ] || v="${PS_WORDS[$k]:-}"
                _ps_is_compressor "$v" || return 0
            fi
        fi
        first=0
    done
    return 1
}

# _ps_tool_env_variables <command> -> the environment variables the tool reads as options or as a program to run, so an
# assignment of one in the same command turns a data reader into a runner of the download.
_ps_tool_env_variables() {
    case "$1" in
        tar|bsdtar) printf 'TAR_OPTIONS' ;;
        rg) printf 'RIPGREP_CONFIG_PATH' ;;
        grep|egrep|fgrep) printf 'GREP_OPTIONS' ;;
        zgrep|zegrep|zfgrep) printf 'GREP GREP_OPTIONS' ;;
        less) printf 'LESSOPEN LESSCLOSE LESSKEYIN PAGER' ;;
        more) printf 'PAGER' ;;
    esac
}

# _ps_env_assigned_for_tool <command> -> rc 0 and PS_ENV_NOTE set when the whole command names a variable the tool reads
# as options or as a program (TAR_OPTIONS for tar, ...) anywhere in its text, or sources a file (source or . in command
# position), which can set one. The name alone is enough: a variable can be set in more ways than can be listed (a
# prefix assignment, export, declare, printf -v, read, a name reference, a computed name, a sourced file), so the class
# is closed by refusing the name, never by recognising each way of assigning it.
# [CySec] CWE-78 (OS Command Injection) / CWE-454 (External Initialization of Trusted Variables): an environment
# variable can make a data reader run the download as code.
_ps_env_assigned_for_tool() {
    local v
    PS_ENV_NOTE=""
    for v in $(_ps_tool_env_variables "$1"); do
        if [[ "$_PS_ALL_TEXT" =~ (^|[^A-Za-z0-9_])"$v"([^A-Za-z0-9_]|$) ]]; then PS_ENV_NOTE=" (its $v variable is named in this command)"; return 0; fi
    done
    [ -n "$(_ps_tool_env_variables "$1")" ] || return 1
    local source_re=$'(^|[;&|({\n])[[:space:]]*(source|\\.)[[:space:]]+[^[:space:]]'
    if [[ "$_PS_ALL_TEXT" =~ $source_re ]]; then
        PS_ENV_NOTE=" (this command sources a file, which can set the variables it reads)"; return 0
    fi
    # A name built when the command runs cannot be read from its text. Anything that can build one, in a command that
    # feeds a download to such a tool, is refused: eval, an expansion where the name of a variable stands (also joined to
    # letters: ${v}OPTIONS=, TAR$(...)=), the name of a declaring builtin followed by an expansion, and an escape
    # sequence (\x54, \124, \u0054) that printf turns into letters.
    local word='[^A-Za-z0-9_]' ex='(\$\{[^}]*\}|\$\([^)]*\)|`[^`]*`|\$[A-Za-z_][A-Za-z0-9_]*)'
    local eval_re="(^|$word)eval($word|\$)"
    local expansion_name_re="${ex}[A-Za-z0-9_]*="
    local joined_name_re="[A-Za-z_][A-Za-z0-9_]*${ex}[A-Za-z0-9_]*="
    local declaring_re="(^|$word)(export|env|declare|typeset|readonly|local)([[:space:]]+-[A-Za-z-]+)*[[:space:]]+[\"']?[\$\`]"
    local escape_re='\\(x[0-9A-Fa-f]|[0-7]{3}|u[0-9A-Fa-f])'
    if [[ "$_PS_ALL_TEXT" =~ $eval_re || "$_PS_ALL_TEXT" =~ $expansion_name_re || "$_PS_ALL_TEXT" =~ $joined_name_re \
          || "$_PS_ALL_TEXT" =~ $declaring_re || "$_PS_RAW_TEXT" =~ $escape_re ]]; then
        PS_ENV_NOTE=" (this command can build a variable name when it runs, which this check cannot follow)"; return 0
    fi
    return 1
}

# _ps_inline_json_reader <index of the command word> <command> -> rc 0 when the command is python or node given a small
# inline program (-c / -e / --eval) that only parses the JSON on its input: python imports nothing but json and sys and
# calls json.load(sys.stdin) or json.loads(sys.stdin.read()); node uses only process.stdin events and JSON.parse. A
# program that mentions anything able to run code or reach the system (exec, eval, compile, getattr, open, input, os,
# subprocess, require, import, Function, child_process, a dunder name, ...) is not a reader and stays refused, so
# is every program that does not match: the rule admits one narrow, readable shape and nothing else.
# [CySec] CWE-94 (Code Injection) / CWE-494: only an inline program that can be read as pure JSON parsing receives a download.
_ps_inline_json_reader() {
    local i="$1" c="${2,,}" j w prog flag_re
    case "$c" in
        python|python[0-9]*) [[ "$c" =~ ^python[0-9.]*$ ]] || return 1; flag_re='^-[A-Za-z]*c$' ;;
        node|nodejs) flag_re='^(-[A-Za-z]*e|--eval)$' ;;
        *) return 1 ;;
    esac
    j=$((i + 1))
    local found=0
    while [ "$j" -lt "${#PS_WORDS[@]}" ]; do
        w="${PS_WORDS[$j]}"; j=$((j + 1))
        if [[ "$w" =~ $flag_re ]]; then found=1; break; fi
        [[ "$w" == -* ]] || return 1
    done
    [ "$found" = 1 ] || return 1
    [ "$j" -lt "${#PS_WORDS[@]}" ] || return 1
    prog="$(_ps_unmask "${PS_WORDS[*]:$j}")"
    # shellcheck disable=SC2016 # a regular expression, nothing to expand
    local bad='(^|[^A-Za-z0-9_])(exec|eval|compile|getattr|setattr|delattr|globals|locals|vars|open|input|os|subprocess|system|popen|spawn|fork|importlib|runpy|builtins|ctypes|socket|urllib|http|requests|pty|sys\.modules|require|import|from|Function|constructor|child_process|process\.(binding|mainModule|env|exit|kill)|global|globalThis|fetch|XMLHttpRequest|WebSocket|Worker|vm|fs|net)([^A-Za-z0-9_]|$)'
    case "$c" in
        python*)
            local rest="${prog//import json, sys/}"
            rest="${rest//import json,sys/}"; rest="${rest//import sys, json/}"; rest="${rest//import sys,json/}"
            rest="${rest//import json/}"; rest="${rest//import sys/}"
            [[ "$prog" == *"json.load(sys.stdin)"* || "$prog" == *"json.loads(sys.stdin.read())"* ]] || return 1
            [[ "$rest" == *__* ]] && return 1
            [[ "$rest" =~ $bad ]] && return 1
            return 0 ;;
        *)
            [[ "$prog" == *"process.stdin"* && "$prog" == *"JSON.parse"* ]] || return 1
            [[ "$prog" == *__* ]] && return 1
            [[ "$prog" =~ $bad ]] && return 1
            return 0 ;;
    esac
}

# _ps_safe_consumer <index of the command word> <command> -> rc 0 when the command is known to read a download on
# its input only as data: a filter (jq, grep, head, tail, cut, tr, wc, sort, uniq, ...), a checksum or archive tool
# writing files, a pager, tee, or a shell's read (whose variables are then followed: eval "$l" runs the download).
# Every interpreter and shell is refused, except a small inline program that only parses JSON (_ps_inline_json_reader),
# because whether a program runs its input cannot be decided from its text (exec(input()), eval <STDIN>, os.system, sh -c 'cat | sh'); so are sed and awk, which are
# programmable (sed's e command runs a shell command); so is a command reached through
# a runner (a shell's -c, su -c, eval, xargs, PowerShell -Command), an unknown program and a variable command word.
_ps_safe_consumer() {
    local i="$1" c="${2,,}" code
    PS_ENV_NOTE=""
    [ "${PS_VIA_RUNNER:-0}" = 1 ] && return 1
    _ps_env_assigned_for_tool "$c" && return 1
    _ps_inline_json_reader "$i" "$c" && return 0
    case "$c" in
        jq|gojq|yq|grep|egrep|fgrep|zgrep|head|tail|wc|uniq|cut|tr|cat|tac|nl|fold|fmt|column|paste|rev|less|more|tee|\
        base64|base32|sha1sum|sha224sum|sha256sum|sha384sum|sha512sum|md5sum|b2sum|cksum|gunzip|gzip|zcat|xz|unxz|\
        xzcat|bzip2|bunzip2|bzcat|zstd|unzstd|od|xxd|hexdump|strings|file|iconv|dos2unix|unix2dos|diff|cmp|comm|\
        read|echo|printf|true|false|:|dd|gpg|gpgv|xmllint)
            return 0 ;;
        sort) _ps_option_programs_are_compressors --compress-program 4; return ;;
        # split --filter hands every piece to a shell command.
        split) ! _ps_long_option_values --filter 3 >/dev/null; return ;;
        # ripgrep passes every searched file, standard input included, to the --pre command.
        rg) ! _ps_option_has_value --pre 5; return ;;
        tar|bsdtar) ! _ps_tar_runs_program "$i"; return ;;
    esac
    return 1
}

# Depth to which text printed into a shell, or PowerShell -Command code, is read again.
_PS_MAX_DEPTH=4

piped_script_find() {
    local cmd="$1" depth="${2:-0}" norm
    _PS_RAW_TEXT="$cmd"
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
        if [ -z "$line" ] || [ -n "${seen[$line]:-}" ]; then continue; fi
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
#   - a comment (a # that starts a word outside quotes) ends the line: the shell ignores it, so it is dropped and can
#     hide nothing before it (`curl u | bash # run`);
#   - every | ( ) ; & and backtick that the shell reads as plain text (inside single quotes, inside $'...', inside
#     double quotes outside a $(...) or backtick substitution) becomes a control character (| becomes
#     0x1D, the others 0x02 to 0x06; _ps_unmask turns them back), so x="curl u | sh", a commit message, an address
#     holding & or the program of python3 -c '...' never splits a command (a quoted string the shell may run is read
#     again on its own line by the normaliser, unmasked);
#   - the & of a redirection is dropped, so it is never read as a command separator: 2>&1 and >&2 become 2>1 and >2,
#     &>f becomes >f, and |& (a pipe that also carries the error output) becomes |;
#   - a quoted string that goes on over a line end is one word, as the shell reads it: its lines are joined into one
#     (`python3 -c '<newline><program>'` keeps its program as the -c value, so the interpreter is not read as running
#     its input). A quote that never closes is a syntax error that runs nothing; its lines are then read one by one;
#   - a command line that ends in a pipe is joined with the next line (the pipeline continues there), unless that line
#     is a plain-text here-document body.
_ps_prepare() {
    awk '
    # lit(ch) -> ch masked when it is plain text: | becomes 0x1D, ( ) ; & and the backtick become 0x02 to 0x06.
    function lit(ch) {
        if (ch == "|") return "\035"
        if (ch == "(") return "\002"
        if (ch == ")") return "\003"
        if (ch == ";") return "\004"
        if (ch == "&") return "\005"
        if (ch == "`") return "\006"
        return ch
    }
    # proc(s, qin, sdin, btin) -> s prepared, starting inside the quote qin ("" outside, "\047", "\"" or "$\047");
    # QOUT, SDOUT and BTOUT hold the state at its end.
    function proc(s, qin, sdin, btin,    out, q, sub_depth, bt, n, k, ch, p, nx) {
        out = ""; q = qin; sub_depth = sdin; bt = btin; n = length(s)
        for (k = 1; k <= n; k++) {
            ch = substr(s, k, 1)
            if (q == "\047") {
                if (ch == "\047") q = ""; else ch = lit(ch)
            } else if (q == "$\047") {
                if (ch == "\\") { out = out ch lit(substr(s, k + 1, 1)); k++; continue }
                if (ch == "\047") q = ""; else ch = lit(ch)
            } else if (q == "\"") {
                if (ch == "\\") { out = out ch substr(s, k + 1, 1); k++; continue }
                if (ch == "$" && substr(s, k + 1, 1) == "(") sub_depth++
                else if (ch == "`") bt = !bt
                else if (ch == ")" && sub_depth > 0) sub_depth--
                else if (ch == "\"" && sub_depth == 0 && !bt) q = ""
                else if (sub_depth == 0 && !bt && ch != "`") ch = lit(ch)
            } else {
                if (ch == "\\") { out = out ch substr(s, k + 1, 1); k++; continue }
                p = substr(out, length(out), 1)
                if (ch == "$" && substr(s, k + 1, 1) == "\047") { q = "$\047"; out = out "$\047"; k++; continue }
                if (ch == "\047" || ch == "\"") { q = ch; sub_depth = 0; bt = 0 }
                else if (ch == "#" && (out == "" || p ~ /[ \t;&|()]/)) break
                else if (ch == "&") {
                    nx = substr(s, k + 1, 1)
                    if (p == ">" || p == "<" || nx == ">") ch = ""
                    else if (p == "|" && substr(out, length(out) - 1, 1) != "|") ch = ""
                }
            }
            out = out ch
        }
        QOUT = q; SDOUT = sub_depth; BTOUT = bt
        return out
    }
    # emit(out, body) -> prints a prepared line, joining a line that ends in a pipe with the next one.
    function emit(out, body,    t) {
        if (held != "") {
            if (body) print held; else out = held " " out
            held = ""
        }
        t = out; sub(/[ \t]+$/, "", t)
        if (!body && (t ~ /(^|[^|])\|$/)) { held = t; return }
        print out
    }
    # flush_open() -> the lines of a quote that never closed, each read on its own.
    function flush_open(    j) {
        for (j = 0; j < nopen; j++) emit(fresh[j], 0)
        nopen = 0; joined = ""
    }
    {
        body = (substr($0, 1, 1) == "\036")
        if (nopen > 0 && body) flush_open()
        if (nopen > 0) {
            joined = joined " " proc($0, oq, osd, obt)
            oq = QOUT; osd = SDOUT; obt = BTOUT
            fresh[nopen++] = proc($0, "", 0, 0)
            if (oq == "") { emit(joined, 0); nopen = 0; joined = "" }
            next
        }
        out = proc($0, "", 0, 0)
        if (!body && QOUT != "") { joined = out; fresh[0] = out; nopen = 1; oq = QOUT; osd = SDOUT; obt = BTOUT; next }
        emit(out, body)
    }
    END { if (nopen > 0) flush_open(); if (held != "") print held }'
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
    _PS_ALL_TEXT="$1"
    local cmd="$1" depth="$2" own="${3:-}" line sep link="S" i c role prev_role="" prev_text="" text fetched=""
    local cur_word=0 b_open=0 trailing in_body=0 prev_raw="" out_sub=0 assign="" raw_c reported=0 w first_word
    local -a stack=()
    # dl_vars: names of variables assigned a download (x=$(curl u)), so running "$x" later is running the download.
    local -A dl_vars=()
    while IFS= read -r line; do
        case "$line" in
            $'\x1f'[SPODBC]*) sep="${line:1:1}"; line="${line:2}" ;;
            $'\x1e'*) sep=S; in_body=1; line="${line:1}" ;;
            *) sep=S; in_body=0 ;;
        esac
        # out_sub: this text opens an output process substitution (tee >(sh)), which receives what the pipeline
        # carries. assign: the variable a substitution opened here is assigned to (x=$(...)).
        out_sub=0; assign=""
        [ "$sep" = O ] && [[ "$prev_raw" =~ \>[[:space:]]*$ ]] && out_sub=1
        { [ "$sep" = D ] || { [ "$sep" = B ] && [ "$b_open" = 0 ]; }; } && [[ "$prev_raw" =~ (^|[[:space:]])([A-Za-z_][A-Za-z0-9_]*)=[[:space:]]*[\"]?[[:space:]]*$ ]] && assign="${BASH_REMATCH[2]}"
        prev_raw="$line"
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
                    text="$(_ps_unmask "$text")"
                    printf 'computed\t%s\n' "$text"
                fi
                stack+=("$cur_word"); cur_word=0 ;;
            C)
                if [ "${#stack[@]}" -gt 0 ]; then cur_word="${stack[-1]}"; unset 'stack[-1]'; else cur_word=0; fi
                # Text after a closing ) or backtick inside a command that already has its command word is more of
                # that command's words (curl -H "X: $(cat t)" <address> | ...): it neither starts a pipeline nor
                # forgets the download flowing through it.
                [ "$cur_word" = 1 ] && continue ;;
        esac
        _ps_words "$line"
        [ "${#PS_WORDS[@]}" -gt 0 ] || continue
        # The closing brace of a group ({ curl u; } | sh) ends nothing: what the group printed flows on.
        [ "${#PS_WORDS[@]}" = 1 ] && [ "${PS_WORDS[0]}" = '}' ] && continue
        # fetched: the address of a download whose output flows through the current pipeline. A new command that is not
        # joined by a pipe or a substitution starts a new pipeline.
        [ "$link" = S ] && fetched=""
        first_word="${PS_WORDS[0]}"
        _ps_skip_wrappers
        i="$PS_CI"
        raw_c="${PS_WORDS[$i]:-}"
        c="$raw_c"; c="${c##*/}"
        trailing="${line%\"}"; trailing="${trailing%\'}"
        # A command word that is a variable: a download piped into it ($SHELL, ${RUNNER}) runs where the reader cannot
        # see; a variable assigned a download and then run (eval "$x", sh -c "$x") runs the download.
        reported=0
        if [[ "$raw_c" =~ ^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?$ ]]; then
            if [ -n "${dl_vars[${BASH_REMATCH[1]}]:-}" ]; then
                printf 'script\t%s\n' "${dl_vars[${BASH_REMATCH[1]}]}"
            elif [ "$link" = P ] && [ -n "$fetched" ]; then
                printf 'computed\t%s\n' "$raw_c"; reported=1
            fi
        fi
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
        [ "$role" = F ] && { text="$(_ps_url)"; fetched="$text"; [ -n "$assign" ] && dl_vars[$assign]="$text"; }
        [ "$role" = E ] && text="$(_ps_printed_text "$((i + 1))" "$c")"
        if [ "$link" = P ] && [ "$role" = X ]; then
            # Any earlier stage of the pipeline downloaded: its output (filtered or not) is run.
            if [ -n "$fetched" ]; then
                printf 'script\t%s\n' "$fetched"
            elif [ "$prev_role" = E ] && [ "$depth" -lt "$_PS_MAX_DEPTH" ]; then
                (piped_script_find "$prev_text" "$((depth + 1))")
            fi
        elif [ "$link" = P ] && [ -n "$fetched" ] && [ "$c" = read ] && [ "${PS_VIA_RUNNER:-0}" = 0 ] \
             && ! _ps_in "$first_word" while until if for case select '{'; then
            # read l puts the download in l: a later eval "$l" or sh -c "$l" runs it.
            for w in "${PS_WORDS[@]:$((i + 1))}"; do
                [[ "$w" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && dl_vars[$w]="$fetched"
            done
        elif [ "$link" = P ] && [ -n "$fetched" ] && [ "$reported" = 0 ] && _ps_in "$first_word" while until if for case select '{'; then
            # A compound command fed a download: every command inside it may read the download.
            printf 'unread\t%s\n' "the compound command $first_word"
        elif [ "$link" = P ] && [ -n "$fetched" ] && [ "$role" != F ] && [ "$reported" = 0 ] && ! _ps_safe_consumer "$i" "$c"; then
            # [CySec] CWE-494: an allow-list, not a deny-list: a download reaches only programs known to read it as
            # data; any other program (or a variable command word) may be an interpreter the reader does not know.
            printf 'unread\t%s%s\n' "$raw_c" "${PS_ENV_NOTE:-}"
        elif [ "$link" = O ] && [ "$role" = X ] && [ "$out_sub" = 1 ] && [ -n "$fetched" ]; then
            printf 'script\t%s\n' "$fetched"
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
    _ps_unmask "$out"
}
