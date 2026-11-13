#!/usr/bin/env bash
# run-bound.sh - which test runners a shell command starts, and whether a `timeout <limit>` bounds each one.
# Shared by the bounded test-run guard (PreToolUse Bash) and the test-host reaper (Stop). Source it; it defines
# functions only and never runs the command text.
#
#   test_runner_kind <word>...      -> prints "<kind>\t<label>" when the words start a test runner, nothing otherwise.
#                                      kind "host": a process that runs tests itself (dotnet test / vstest, the .NET test
#                                      host, vstest.console, npm test, vitest, pytest, Pester); kind "suite": a shell
#                                      battery (the plugin's run-all.sh, a CI shell suite under ci/tests/).
#   test_run_bound_find <command>   -> one line per test runner started without a bound, "<label>\t<offset>": <offset>
#                                      is where `timeout <limit> ` belongs in the command text, or -1 when that place is
#                                      not a literal part of the text (a shell's -c string, an eval argument).
#   test_run_bound_correct <command> <limit> <findings>
#                                   -> the command with `timeout <limit> ` put before every unbounded runner, or nothing
#                                      when a place is unknown (the caller then names the runner instead).
#   test_run_timeout_bounds <word>... -> rc 0 when the words are `timeout <duration>` (duration > 0) starting a command.
#   test_run_limit_parse <value>    -> the limit as seconds when <value> is "<n>s", "<n>m" or "<n>h" with n > 0; rc 1 otherwise.
#
# Bounded means a `timeout <duration>` (duration > 0; `timeout 0` never ends anything) wraps the runner: before it in
# the same simple command, past wrappers (sudo, env, nice, nohup, flock, xargs, ...), or around the shell whose -c
# string starts it. A runner named only as text (an echo or grep argument, a quoted message, a heredoc body) is not
# started and is not judged.
# [RiskMitigation RA-02] A test run with no bound once hung for about 20 hours at full CPU and slowed every agent on the
# machine; the rule keeps each run's own end in the command that starts it.

_TRB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$_TRB_DIR/cmd-strip.sh"    # _cmd_strip_heredocs: heredoc bodies are data
. "$_TRB_DIR/shell-scan.sh"   # shell_scan: the simple commands of the text, words unquoted

# shellcheck disable=SC2034  # read by the guard and the reaper that source this file
readonly TRB_DEFAULT_LIMIT=60m

test_run_limit_parse() {
    [[ "${1:-}" =~ ^([0-9]+)([smh])$ ]] || return 1
    local n=$((10#${BASH_REMATCH[1]}))
    [ "$n" -gt 0 ] || return 1
    case "${BASH_REMATCH[2]}" in s) printf '%s' "$n" ;; m) printf '%s' $((n * 60)) ;; h) printf '%s' $((n * 3600)) ;; esac
}

# _trb_base <word> -> the word without its directory, lower case.
# Invoke-Pester where a PowerShell command starts: at the start, or after ; | { ( & or a new line, optionally called with &.
_TRB_PESTER_RE=$'(^|[;|{(&\n])[[:space:]]*(&[[:space:]]*)?invoke-pester([[:space:];|})]|$)'
_trb_base() { local b="${1##*/}"; printf '%s' "${b,,}"; }

test_runner_kind() {
    local -a a=("$@")
    local n=${#a[@]} cmd j w
    (( n )) || return 0
    cmd="$(_trb_base "${a[0]}")"
    case "$cmd" in
        dotnet|dotnet.exe)
            for (( j = 1; j < n; j++ )); do
                w="$(_trb_base "${a[j]}")"
                case "$w" in
                    test|vstest) [ "$j" = 1 ] && { printf 'host\tdotnet %s\n' "$w"; return 0; } ;;
                    testhost.dll|testhost.*.dll|vstest.console.dll) printf 'host\tdotnet %s\n' "$w"; return 0 ;;
                esac
            done ;;
        testhost|testhost.exe|testhost.*.exe|vstest.console|vstest.console.exe)
            printf 'host\t%s\n' "$cmd"; return 0 ;;
        npm|npm.cmd)
            # npm [options] test | t | tst | run test... | run-script test...
            for (( j = 1; j < n; j++ )); do
                w="${a[j]}"
                case "$w" in
                    --prefix|-C|--workspace|-w) j=$((j + 1)); continue ;;
                    -*) continue ;;
                    test|t|tst) printf 'host\tnpm test\n'; return 0 ;;
                    run|run-script) (( j + 1 < n )) && [[ "${a[j+1]}" == test* ]] && { printf 'host\tnpm run %s\n' "${a[j+1]}"; return 0; }; return 0 ;;
                    *) return 0 ;;
                esac
            done ;;
        npx|pnpm|yarn|bunx)
            for (( j = 1; j < n; j++ )); do
                w="$(_trb_base "${a[j]}")"
                case "$w" in -*|exec|dlx) continue ;; vitest) printf 'host\t%s vitest\n' "$cmd"; return 0 ;; test) [ "$cmd" != npx ] && { printf 'host\t%s test\n' "$cmd"; return 0; }; return 0 ;; *) return 0 ;; esac
            done ;;
        node|node.exe)
            # node <script> ...: the runner is the script node runs (npm, vitest)
            for (( j = 1; j < n; j++ )); do
                [[ "${a[j]}" == -* ]] && continue
                case "$(_trb_base "${a[j]}")" in
                    npm|npm-cli.js) test_runner_kind npm "${a[@]:j+1}"; return 0 ;;
                    vitest|vitest.mjs|vitest.js) printf 'host\tvitest\n'; return 0 ;;
                esac
                return 0
            done ;;
        vitest|vitest.cmd)
            printf 'host\tvitest\n'; return 0 ;;
        bun|cargo|go|bun.exe|cargo.exe|go.exe)
            # <tool> [options] test ...: the first word that is not an option (or a cargo +toolchain) names the command
            for (( j = 1; j < n; j++ )); do
                w="${a[j]}"
                [[ "$w" == -* || "$w" == +* ]] && continue
                [ "$w" = test ] && printf 'host\t%s test\n' "${cmd%.exe}"
                return 0
            done ;;
        pytest|py.test|pytest.exe)
            printf 'host\tpytest\n'; return 0 ;;
        python|python3|python3.*|py|python.exe)
            for (( j = 1; j < n; j++ )); do
                if [ "${a[j]}" = -m ] && (( j + 1 < n )) && [ "${a[j+1]}" = pytest ]; then printf 'host\tpython -m pytest\n'; return 0; fi
                case "$(_trb_base "${a[j]}")" in pytest|py.test) printf 'host\tpytest\n'; return 0 ;; esac
                [[ "${a[j]}" == -* ]] || return 0
            done ;;
        pwsh|pwsh.exe|powershell|powershell.exe)
            # The code PowerShell runs: the -Command string (or the words after it, or the bare words), never a -File
            # script, which cannot be read here. Invoke-Pester counts only where a command starts, so a mention
            # (`echo Invoke-Pester`, a string) is not a run.
            local code="" seen_command=0
            for (( j = 1; j < n; j++ )); do
                w="${a[j],,}"
                if (( seen_command )); then code+=" ${a[j]}"; continue; fi
                case "$w" in
                    -f|-fi|-fil|-file) return 0 ;;
                    -c|-co|-com|-comm|-comma|-comman|-command) seen_command=1 ;;
                    -encodedcommand|-e|-ec|-en|-enc) return 0 ;;
                    -executionpolicy|-ex|-ep|-configurationname|-workingdirectory|-wd|-settingsfile|-inputformat|-outputformat|-if|-of|-custompipename|-version|-v|-psconsolefile) j=$((j + 1)) ;;
                    -*) ;;
                    *) code+=" ${a[j]}" ;;
                esac
            done
            [[ "${code,,}" =~ $_TRB_PESTER_RE ]] \
                && { printf 'host\tPester (Invoke-Pester)\n'; return 0; } ;;
        run-all.sh)
            printf 'suite\t%s\n' "${a[0]}"; return 0 ;;
        bash|sh|zsh|dash|ksh)
            # bash [options] <script> runs the script: a battery or a CI shell suite is a test runner
            for (( j = 1; j < n; j++ )); do
                w="${a[j]}"
                # -c runs a string (judged by the caller); -n only checks the syntax: neither runs the script
                case "$w" in -c|-*c*|-n|-*n*) [[ "$w" == --* ]] || return 0 ;; esac
                [[ "$w" == -* ]] && continue
                test_runner_kind "$w"; return 0
            done ;;
        *)
            [[ "/${a[0]}" =~ /ci/tests/[^/]+\.sh$ ]] && { printf 'suite\t%s\n' "${a[0]}"; return 0; } ;;
    esac
    return 0
}

# The longest timeout the reaper accepts as a test host's bound: the longest allowed run (a whole-solution run of 90
# minutes) fits under it. A longer timeout, or one whose time has passed without ending the host, is no bound.
# shellcheck disable=SC2034  # read by the reaper that sources this file
readonly TRB_BOUND_CEILING_SECONDS=7200

# _trb_timeout_words <word>... (the words start with timeout) -> TRB_TIMEOUT_BOUNDS=1 when they give a duration above
# zero (`timeout 0` never ends anything), TRB_TIMEOUT_SECONDS = that duration in whole seconds (rounded up), and
# TRB_TIMEOUT_NEXT = the index of the command timeout runs.
_trb_timeout_words() {
    local -a a=("$@")
    local k=1 n=$#
    TRB_TIMEOUT_BOUNDS=0; TRB_TIMEOUT_SECONDS=0
    while (( k < n )) && [[ "${a[k]}" == -* ]]; do
        [ "${a[k]}" = -- ] && { k=$((k + 1)); break; }
        # An option that takes a value takes the next word when nothing follows it in the same word: --signal and
        # --kill-after without "=", and a cluster of short options ending in s or k (-s, -k, -vk); -k5 or -vs9 carry it.
        [[ "${a[k]}" =~ ^--(signal|kill-after)$ || "${a[k]}" =~ ^-[A-Za-z]*[sk]$ ]] && k=$((k + 1))
        k=$((k + 1))
    done
    if (( k < n )); then
        if [[ "${a[k]}" =~ ^[0-9]*\.?[0-9]+[smhd]?$ ]] && [[ "${a[k]}" =~ [1-9] ]]; then
            TRB_TIMEOUT_BOUNDS=1
            # shellcheck disable=SC2034  # read by the reaper
            TRB_TIMEOUT_SECONDS="$(awk -v d="${a[k]}" 'BEGIN { u = substr(d, length(d)); m = 1
                if (u == "m") m = 60; else if (u == "h") m = 3600; else if (u == "d") m = 86400
                if (u ~ /[smhd]/) d = substr(d, 1, length(d) - 1); s = d * m; printf "%d", (s == int(s)) ? s : int(s) + 1 }')"
        fi
        k=$((k + 1))
    fi
    TRB_TIMEOUT_NEXT=$k
}

# test_run_timeout_bounds <word>... -> rc 0 when the words are a `timeout <duration>` command with a duration above zero:
# what it runs ends at that limit on its own.
test_run_timeout_bounds() {
    [ "$(_trb_base "${1:-}")" = timeout ] || return 1
    _trb_timeout_words "$@"
    [ "$TRB_TIMEOUT_BOUNDS" = 1 ]
}

# Commands whose words are names, patterns, text or packages, never a command line they start: a runner named after one
# of them (`which pytest`, `pip install pytest`, `ls vitest`) is not a run. Any other command is read as a possible
# wrapper (numactl, chrt, unbuffer, systemd-run, ...): a runner among its later words is judged as that runner. A list of
# wrappers can never be complete; this list of commands that take no command line is the smaller, closed side.
readonly TRB_DATA_COMMANDS=" echo printf grep egrep fgrep rg ag sed awk gawk cat tac less more head tail wc sort uniq cut tr
 diff cmp file stat ls dir tree which whereis type man info help apropos whatis hash alias unalias complete compgen kill
 pkill pgrep killall pidof readlink realpath basename dirname touch mkdir rm rmdir cp mv ln chmod chown install tee git gh
 glab pip pip3 pipx apt apt-get dpkg dnf yum rpm brew conda mamba gem choco winget scoop for case in select function local
 export declare readonly typeset unset set shift return exit test [ [[ cd pushd popd source . read mapfile printenv wget
 curl fd fdfind ack "
# Tools with subcommands: only the subcommands that run a command name one (docker run IMAGE CMD, kubectl exec POD -- CMD,
# uv run CMD); every other subcommand's words are data (docker pull pytest, uv add pytest, kubectl logs pytest).
readonly TRB_SUBCOMMAND_TOOLS=" docker podman nerdctl kubectl oc uv poetry pdm pipenv hatch helm "

# _trb_subcommand_start <k> -> TRB_SUB_AT = the index of the command a subcommand tool at a[k] runs, or -1 when it runs
# none. Options of the tool and of the subcommand are skipped with their values: a long option takes the next word
# unless it is written with "=" or is a known switch; a short cluster takes it unless it is made only of switch letters.
_trb_subcommand_start() {
    local k="$1" tool sub j w positional=0 want=0
    tool="$(_trb_base "${a[k]}")"
    TRB_SUB_AT=-1
    # the subcommand: the first word that is not an option (global options with a value are skipped with it)
    j=$((k + 1))
    while (( j < n )) && [[ "${a[j]}" == -* ]]; do
        [[ "${a[j]}" == *=* || "${a[j]}" =~ ^--(debug|verbose|quiet|no-.*)$ ]] || [[ ! "${a[j]}" =~ ^(-[cHlnsC]|--context|--host|--namespace|--kubeconfig|--log-level|--config|--directory|--project)$ ]] || j=$((j + 1))
        j=$((j + 1))
    done
    (( j < n )) || return 0
    sub="${a[j]}"
    case "$tool:$sub" in
        docker:run|docker:exec|podman:run|podman:exec|nerdctl:run|nerdctl:exec) want=1 ;;   # IMAGE or CONTAINER first
        kubectl:exec|oc:exec) want=1 ;;                                                     # POD first, or after --
        uv:run|poetry:run|pdm:run|pipenv:run|hatch:run) want=0 ;;                          # the command at once
        *) return 0 ;;
    esac
    for (( j = j + 1; j < n; j++ )); do
        w="${a[j]}"
        if [ "$w" = -- ]; then
            # kubectl exec POD -- CMD; docker run ... -- is rare: what follows is the command
            (( j + 1 < n )) && TRB_SUB_AT=$((j + 1))
            return 0
        fi
        if [[ "$w" == -* ]]; then
            # uv run -m pytest / python -m: the module is the command
            if [ "$w" = -m ] || [ "$w" = --module ]; then (( j + 1 < n )) && { a[j]=python; TRB_SUB_AT=$j; }; return 0; fi
            [[ "$w" == *=* ]] && continue
            if [[ "$w" == --* ]]; then
                [[ "$w" =~ ^--(rm|init|privileged|interactive|tty|detach|read-only|no-healthcheck|quiet|verbose|frozen|locked|isolated|no-sync|no-project|offline|no-dev|all-extras|all-packages|active|no-cache|script|stdin)$ ]] || j=$((j + 1))
            else
                [[ "$w" =~ ^-[itdqvP]+$ ]] || j=$((j + 1))
            fi
            continue
        fi
        if (( positional < want )); then positional=$((positional + 1)); continue; fi
        TRB_SUB_AT=$j
        return 0
    done
}
# The tools that ARE runners (or run one through a subcommand): their own words are judged by test_runner_kind only.
readonly TRB_RUNNER_TOOLS=" dotnet dotnet.exe npm npm.cmd npx pnpm yarn bunx bun bun.exe cargo cargo.exe go go.exe node node.exe
 vitest vitest.cmd pytest py.test pytest.exe python python3 py python.exe pwsh pwsh.exe powershell powershell.exe testhost
 testhost.exe vstest.console vstest.console.exe run-all.sh "

# _trb_value_word <word> -> rc 0 for a word a wrapper takes as an option or option value rather than its command: an
# option, `--`, a number, a CPU list or mask, an assignment.
_trb_value_word() { [[ "$1" == -* || "$1" =~ ^[0-9][0-9a-fA-Fx,.:-]*$ || "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; }

# _trb_simple <depth> <word>... - the shell_scan judge: records each runner the simple command starts without a bound.
# Context (dynamic): _TRB_BOUNDED (1 when an enclosing command bounds this text), _TRB_ANCHOR (the offset where an
# enclosing shell's command word starts, for a runner inside its -c string).
_trb_simple() {
    local depth="$1"; shift
    local -a a=() offs=() heres=("${SHELL_SCAN_HERESTRINGS[@]}") bodies=() pipein=("${SHELL_SCAN_PIPE_IN[@]}")
    local stdinfile="${SHELL_SCAN_STDIN_FILE:-}" n w i=0
    # A heredoc marker word (byte 3, "HD", its number, byte 3; see test_run_bound_find) is the shell's standard input,
    # not an argument: it is set aside with its body, and the words keep their offsets.
    for w in "$@"; do
        if [[ "$w" =~ ^$'\003'HD([0-9]+)$'\003'$ ]]; then bodies+=("${TRB_HEREDOC[${BASH_REMATCH[1]}]:-}")
        else a+=("$w"); offs+=("${SHELL_SCAN_OFFSETS[i]:--1}"); fi
        i=$((i + 1))
    done
    n=${#a[@]}
    local k=0
    while (( k < n )) && [[ "${a[k]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do k=$((k + 1)); done
    _trb_judge "$k" "${_TRB_BOUNDED:-0}"
}

# _trb_stdin_code -> the code a shell reading its standard input runs, as far as it can be read before the command
# runs: here-strings, heredoc bodies, the text an echo or printf pipes into it, and the files a `< file` or a piped cat
# names (read when they are regular files of at most 256 KiB; relative to TRB_CWD). Prints one piece per NUL.
_trb_stdin_code() {
    local w f
    for w in "${heres[@]}" "${bodies[@]}"; do printf '%s\0' "$w"; done
    if (( ${#pipein[@]} )); then
        case "$(_trb_base "${pipein[0]}")" in
            echo) printf '%s\0' "${pipein[*]:1}" ;;
            printf) printf '%b\0' "${pipein[*]:1}" ;;
            cat) for f in "${pipein[@]:1}"; do [[ "$f" == -* ]] || _trb_read_file "$f"; done ;;
        esac
    fi
    [ -n "$stdinfile" ] && _trb_read_file "$stdinfile"
    return 0
}
_trb_read_file() {
    local f="$1"
    [[ "$f" == /* ]] || f="${TRB_CWD:-$PWD}/$f"
    [ -f "$f" ] && [ -r "$f" ] && [ "$(wc -c < "$f" 2>/dev/null)" -le 262144 ] 2>/dev/null || return 0
    cat -- "$f" 2>/dev/null; printf '\0'
}

# _trb_judge <k> <bounded> - judge the words a[k..] (the caller's arrays a, offs, heres, bodies, pipein): skip the
# wrappers that are understood exactly, then a shell, eval, a runner, or any other command read as a possible wrapper.
_trb_judge() {
    local k="$1" bounded="$2" cmd kind label at j w code
    while (( k < n )); do
        cmd="${a[k]##*/}"
        case "$cmd" in
            sudo|doas|builtin|exec|nohup|time|nice|ionice|stdbuf|setsid|xargs|then|do|else|elif|if|while|until|'!')
                k=$((k + 1))
                while (( k < n )) && [[ "${a[k]}" == -* ]]; do
                    [[ "$cmd:${a[k]}" =~ ^(sudo|doas):-[ugCDhprtU]$|^xargs:-[IndPLsEa]$|^(nice:-n|ionice:-[cnp]|stdbuf:-[ioe])$ ]] && k=$((k + 1))
                    k=$((k + 1))
                done ;;
            command)
                # command -v / -V only looks a name up
                (( k + 1 < n )) && [[ "${a[k+1]}" =~ ^-[pvV]*[vV] ]] && return 0
                k=$((k + 1))
                while (( k < n )) && [[ "${a[k]}" == -* ]]; do k=$((k + 1)); done ;;
            env)
                k=$((k + 1))
                while (( k < n )) && { [[ "${a[k]}" == -* ]] || [[ "${a[k]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; }; do
                    [[ "${a[k]}" =~ ^(-u|--unset|-C|--chdir)$ ]] && k=$((k + 1))
                    k=$((k + 1))
                done ;;
            timeout)
                _trb_timeout_words "${a[@]:k}"
                [ "$TRB_TIMEOUT_BOUNDS" = 1 ] && bounded=1
                k=$((k + TRB_TIMEOUT_NEXT)) ;;
            taskset)
                # taskset [options] <mask|list> <command...>; with -p it changes a running process and starts nothing
                k=$((k + 1))
                while (( k < n )) && [[ "${a[k]}" == -* ]]; do
                    [[ "${a[k]}" =~ ^-[a-z]*p|^--pid$ ]] && return 0
                    k=$((k + 1))
                done
                k=$((k + 1)) ;;
            watch)
                # watch [options] <command...>: the words are run again and again by a shell, so they are read as code
                k=$((k + 1))
                while (( k < n )) && [[ "${a[k]}" == -* ]]; do
                    [[ "${a[k]}" =~ ^(-n|--interval|-q|--equexit)$ ]] && k=$((k + 1))
                    k=$((k + 1))
                done
                (( k < n )) && _TRB_BOUNDED="$bounded" _TRB_ANCHOR="${offs[k]:--1}" shell_scan "${a[*]:k}" $((depth + 1)) -1
                return 0 ;;
            flock)
                # flock [options] <file> <command...> | flock [options] <file> -c <command string>
                k=$((k + 1))
                while (( k < n )) && [[ "${a[k]}" == -* ]]; do
                    [[ "${a[k]}" =~ ^(-w|--wait|--timeout|-E|--conflict-exit-code)$ ]] && k=$((k + 1))
                    k=$((k + 1))
                done
                k=$((k + 1))
                if (( k + 1 < n )) && [[ "${a[k]}" =~ ^(-c|--command)$ ]]; then
                    _TRB_BOUNDED="$bounded" _TRB_ANCHOR="${offs[0]:--1}" shell_scan "${a[k+1]}" $((depth + 1)) -1
                    return 0
                fi ;;
            *) break ;;
        esac
    done
    (( k < n )) || return 0
    at="${offs[k]:--1}"; (( at < 0 )) && at="${_TRB_ANCHOR:--1}"
    cmd="$(_trb_base "${a[k]}")"
    case "$cmd" in
        bash|sh|zsh|dash|ksh)
            local stdin_mode=1
            for (( j = k + 1; j < n; j++ )); do
                if [[ "${a[j]}" =~ ^-[A-Za-z]*c[A-Za-z]*$ ]]; then
                    (( j + 1 < n )) && _TRB_BOUNDED="$bounded" _TRB_ANCHOR="$at" shell_scan "${a[j+1]}" $((depth + 1)) -1
                    return 0
                fi
                [[ "${a[j]}" =~ ^-[A-Za-z]*n[A-Za-z]*$ ]] && return 0   # a syntax check runs nothing
                [[ "${a[j]}" =~ ^-[A-Za-z]*s[A-Za-z]*$ ]] && break       # -s: the commands come from standard input
                [[ "${a[j]}" == -* ]] || { stdin_mode=0; break; }
            done
            # No script and no -c: the shell runs its standard input (a here-string, a heredoc, a pipe, a < file).
            if (( stdin_mode )); then
                local any=0
                while IFS= read -r -d '' code; do
                    any=1
                    _TRB_BOUNDED="$bounded" _TRB_ANCHOR="$at" shell_scan "$code" $((depth + 1)) -1
                done < <(_trb_stdin_code)
                (( any )) && return 0
            fi ;;
        eval)
            _TRB_BOUNDED="$bounded" _TRB_ANCHOR="$at" shell_scan "${a[*]:k+1}" $((depth + 1)) -1
            return 0 ;;
    esac
    IFS=$'\t' read -r kind label < <(test_runner_kind "${a[@]:k}")
    if [ -n "${kind:-}" ]; then
        [ "$bounded" = 1 ] || TRB_FINDINGS+="${label}"$'\t'"${at}"$'\n'
        return 0
    fi
    # Not a runner itself: a runner tool or a command that takes no command line ends here; any other command may be a
    # wrapper, so its first word that is not an option or a value is judged as a command of its own, and a -c /
    # --command value as shell code (su -c "...", runuser -c "...").
    # The lists are written over several lines: a line break separates names like a blank.
    local names=" $TRB_RUNNER_TOOLS $TRB_DATA_COMMANDS "; names="${names//$'\n'/ }"
    case "$names" in *" $cmd "*|*" ${a[k]} "*) return 0 ;; esac
    case "$TRB_SUBCOMMAND_TOOLS" in
        *" $cmd "*)
            _trb_subcommand_start "$k"
            (( TRB_SUB_AT >= 0 )) && _TRB_ANCHOR="$at" _trb_judge "$TRB_SUB_AT" "$bounded"
            return 0 ;;
    esac
    if [ "$cmd" = ssh ]; then
        # ssh [options] HOST [command...]: the host comes first; the command words are joined and run by a remote shell
        for (( j = k + 1; j < n; j++ )); do
            if [[ "${a[j]}" == -* ]]; then
                [[ "${a[j]}" =~ ^-[A-Za-z]*[bcDEeFIiJLlmOopQRSWw]$ ]] && j=$((j + 1))
                continue
            fi
            (( j + 1 < n )) && _TRB_BOUNDED="$bounded" _TRB_ANCHOR="$at" shell_scan "${a[*]:j+1}" $((depth + 1)) -1
            return 0
        done
        return 0
    fi
    for (( j = k + 1; j < n; j++ )); do
        if [[ "${a[j-1]}" =~ ^(-[A-Za-z]*c|--command|--session-command)$ ]]; then
            _TRB_BOUNDED="$bounded" _TRB_ANCHOR="$at" shell_scan "${a[j]}" $((depth + 1)) -1
            return 0
        fi
        _trb_value_word "${a[j]}" && continue
        # A runner word after a wrapper is a runner; a suite path is only a script when a shell or the path itself runs.
        IFS=$'\t' read -r kind label < <(test_runner_kind "${a[@]:j}")
        [ "${kind:-}" = suite ] && return 0
        _TRB_ANCHOR="$at" _trb_judge "$j" "$bounded"
        return 0
    done
}

test_run_bound_find() {
    local LC_ALL=C
    local text="$1" stripped bodyfile num line
    TRB_FINDINGS=""
    # Heredoc bodies are set aside (each operator becomes a marker word), so a body fed to a shell can be read as code.
    declare -gA TRB_HEREDOC=()
    bodyfile="$(mktemp 2>/dev/null)" || bodyfile=""
    if [ -n "$bodyfile" ]; then
        stripped="$(printf '%s\n' "$text" | awk -v bodyfile="$bodyfile" -f "$_CMD_STRIP_DIR/cmd-strip-heredocs.awk")"
        while IFS=$'\t' read -r num line; do
            [ -n "$num" ] && TRB_HEREDOC[$num]+="$line"$'\n'
        done < "$bodyfile"
        rm -f -- "$bodyfile"
    else
        stripped="$(printf '%s\n' "$text" | _cmd_strip_heredocs)"
    fi
    _TRB_BOUNDED=0 _TRB_ANCHOR=-1 SHELL_SCAN_SIMPLE=_trb_simple SHELL_SCAN_STOP_VAR='' shell_scan "$stripped" 0 0
    # A heredoc body was removed: the offsets after it no longer point into the original text.
    if [ "$stripped" != "$text" ] && [ "$stripped" != "$text"$'\n' ]; then
        TRB_FINDINGS="$(printf '%s' "$TRB_FINDINGS" | awk -F'\t' -v OFS='\t' 'NF { $2 = -1; print }')"
        [ -n "$TRB_FINDINGS" ] && TRB_FINDINGS+=$'\n'
    fi
    printf '%s' "$TRB_FINDINGS"
}

test_run_bound_correct() {
    local LC_ALL=C
    local text="$1" limit="$2" findings="$3" label at
    local -a places=()
    while IFS=$'\t' read -r label at; do
        [ -n "$label" ] || continue
        (( at < 0 )) && return 0
        places+=("$at")
    done <<< "$findings"
    (( ${#places[@]} )) || return 0
    mapfile -t places < <(printf '%s\n' "${places[@]}" | sort -rnu)
    for at in "${places[@]}"; do text="${text:0:at}timeout ${limit} ${text:at}"; done
    printf '%s' "$text"
}
