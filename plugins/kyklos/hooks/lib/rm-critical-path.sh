#!/usr/bin/env bash
# rm-critical-path.sh - decides whether a shell command runs rm/rmdir on a "critical path", the forms Claude Code's
# built-in "Dangerous rm operation on critical path" check asks about. Source it; it defines functions only.
#
# Why: that check cannot be turned off (bypass mode, allow rules, hooks and the sandbox all leave it on). Unattended,
# it waits two minutes and denies; after three such denials every later one is denied at once. A guard that refuses
# the same forms IMMEDIATELY, naming the safe alternative, turns a stall into a fast, actionable failure. The guard
# errs on the side of refusing: it must never let through a form the built-in check would stop on.
#
# Contract:
#   rm_critical_check <command>   rc 0 = refused (the reason is in RMC_REASON); rc 1 = nothing critical found.
# Context (read at call time, each optional):
#   RMC_CWD          the shell's working directory (default: $PWD)
#   RMC_PROJECT_DIR  the session's project directory (also a working directory)
#   RMC_HOME         the home directory (default: $HOME)
#   RMC_EXTRA_DIRS   additional working directories, one per line
#
# What is analysed: every simple command of the text, including the bodies of ( ... ) subshells, $( ... ) and
# `...` substitutions, `bash|sh|zsh|dash|ksh -c '<script>'` payloads and `eval` arguments, through wrappers such as
# sudo, env, command, nohup, time and xargs. Heredoc bodies and quoted arguments of other commands are data and are
# never read as commands (so a script fed to a shell on stdin, `bash <<EOF ... EOF`, is not judged). Nesting is
# bounded (RMC_MAX_DEPTH).

_RMC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$_RMC_DIR/cmd-strip.sh"   # _cmd_strip_heredocs: heredoc bodies are data
. "$_RMC_DIR/shell-scan.sh"  # shell_scan: the simple commands of the text, words unquoted

readonly RMC_MAX_DEPTH=8
# Names a variable is commonly followed by when it points at a system root (e.g. "$PREFIX/usr").
readonly RMC_TOP_LEVEL_NAMES=' bin boot dev etc home lib lib32 lib64 libx32 media mnt opt proc root run sbin srv sys tmp usr var Users Library System Applications Volumes private Windows '
readonly RMC_VAR_RE='\$([A-Za-z_][A-Za-z0-9_]*|[0-9@*]|\{[#!]?([A-Za-z_][A-Za-z0-9_]*|[0-9]+)([:]?[-?=+%#/^,][^}]*)?\})'

RMC_REASON=""
declare -A RMC_CWD_VARS=()

# _rmc_match_close <text> <index-of-opening-char> <open> <close> -> RMC_POS = index of the matching close char
# (quotes and nesting respected), or the text length when unbalanced. The shared scanner does the reading.
_rmc_match_close() { shell_scan_match_close "$@"; RMC_POS=$SHELL_SCAN_POS; }

# _rmc_scan <text> <depth> - split <text> into simple commands (lib/shell-scan.sh) and judge each with _rmc_simple.
# Stops at the first refusal (RMC_REASON set).
_rmc_scan() {
    SHELL_SCAN_SIMPLE=_rmc_simple SHELL_SCAN_STOP_VAR=RMC_REASON SHELL_SCAN_MAX_DEPTH=$RMC_MAX_DEPTH shell_scan "$1" "$2" -1
}

# _rmc_is_cwd_source <value> -> rc 0 when an assigned value is the working directory: $(pwd), $(git rev-parse
# --show-toplevel), $PWD.
_rmc_is_cwd_source() {
    local v="$1"
    [[ "$v" =~ ^\$\([[:space:]]*(builtin[[:space:]]+)?pwd([[:space:]]+-[LP])?[[:space:]]*\)$ ]] && return 0
    [[ "$v" =~ ^\$\([[:space:]]*git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+rev-parse[[:space:]]+--show-toplevel[[:space:]]*\)$ ]] && return 0
    [[ "$v" =~ ^\$(PWD|\{PWD\})$ ]] && return 0
    return 1
}

_rmc_note_assignment() {
    local a="$1" name="${1%%=*}" val="${1#*=}"
    _rmc_is_cwd_source "$val" && RMC_CWD_VARS["$name"]=1
}

# _rmc_simple <depth> <word>... - judge one simple command (words already unquoted).
_rmc_simple() {
    local depth="$1"; shift
    local -a a=("$@")
    local k=0 n=${#a[@]} cmd
    # leading assignments
    while (( k < n )) && [[ "${a[k]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do _rmc_note_assignment "${a[k]}"; k=$((k + 1)); done
    # wrappers
    while (( k < n )); do
        cmd="${a[k]##*/}"
        case "$cmd" in
            sudo|doas|command|builtin|exec|nohup|time|nice|ionice|stdbuf|timeout|xargs|then|do|else|elif|if|while|until|'!')
                k=$((k + 1))
                while (( k < n )) && [[ "${a[k]}" == -* ]]; do
                    # An option that takes the next word as its value (sudo -u root, xargs -I {}, timeout -s KILL).
                    [[ "$cmd:${a[k]}" =~ ^(sudo|doas):-[ugCDhprtU]$|^xargs:-[IndPLsEa]$|^(timeout:-[sk]|nice:-n|ionice:-[cnp])$ ]] && k=$((k + 1))
                    k=$((k + 1))
                done
                [ "$cmd" = timeout ] && (( k < n )) && [[ "${a[k]}" =~ ^[0-9.]+[smhd]?$ ]] && k=$((k + 1)) ;;
            env)
                k=$((k + 1))
                while (( k < n )) && { [[ "${a[k]}" == -* ]] || [[ "${a[k]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; }; do
                    [[ "${a[k]}" == -* ]] || _rmc_note_assignment "${a[k]}"; k=$((k + 1)); done ;;
            *) break ;;
        esac
    done
    (( k < n )) || return 0
    cmd="${a[k]##*/}"
    case "$cmd" in
        export|local|declare|typeset|readonly)
            local j
            for (( j = k + 1; j < n; j++ )); do [[ "${a[j]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] && _rmc_note_assignment "${a[j]}"; done ;;
        rm|rmdir)
            _rmc_rm_args "$cmd" "${a[@]:k+1}" ;;
        bash|sh|zsh|dash|ksh)
            local j
            for (( j = k + 1; j < n; j++ )); do
                if [[ "${a[j]}" =~ ^-[A-Za-z]*c[A-Za-z]*$ ]]; then
                    (( j + 1 < n )) && _rmc_scan "${a[j+1]}" $((depth + 1))
                    break
                fi
                [[ "${a[j]}" == -* ]] || break
            done ;;
        eval)
            _rmc_scan "${a[*]:k+1}" $((depth + 1)) ;;
    esac
    return 0
}

# _rmc_rm_args <rm|rmdir> <arg>... - split options from targets and judge each target.
_rmc_rm_args() {
    local tool="$1"; shift
    local recursive=0 endopts=0 t
    local -a targets=()
    for t in "$@"; do
        if (( ! endopts )) && [ "$t" = -- ]; then endopts=1; continue; fi
        if (( ! endopts )) && [[ "$t" == --* ]]; then [ "$t" = --recursive ] && recursive=1; continue; fi
        if (( ! endopts )) && [[ "$t" == -?* ]]; then [[ "$t" == *[rR]* ]] && recursive=1; continue; fi
        targets+=("$t")
    done
    for t in "${targets[@]}"; do
        _rmc_target "$tool" "$recursive" "$t" && return 0
    done
    return 1
}

# _rmc_norm <absolute path> -> the path with //, /./ and /../ resolved lexically, no trailing slash ("/" for root).
_rmc_norm() {
    local p="$1" seg out=""
    local IFS=/
    local -a parts=()
    for seg in $p; do
        case "$seg" in ''|.) ;; ..) (( ${#parts[@]} )) && unset 'parts[${#parts[@]}-1]' ;; *) parts+=("$seg") ;; esac
    done
    for seg in "${parts[@]}"; do out+="/$seg"; done
    printf '%s' "${out:-/}"
}

# _rmc_is_within <path> <dir> -> rc 0 when <path> is <dir> or inside it (both normalised).
_rmc_is_within() { [ "$1" = "$2" ] || [ "$2" = / ] || [[ "$1" == "$2"/* ]]; }

# _rmc_protected_dir <normalised path> -> prints why the directory itself must not be removed; rc 1 when it may.
_rmc_protected_dir() {
    local p="$1" d
    [ "$p" = / ] && { printf 'the filesystem root'; return 0; }
    [[ "$p" =~ ^/[^/]+$ ]] && { printf 'a direct child of the filesystem root'; return 0; }
    [ -n "$RMC_HOME_N" ] && [ "$p" = "$RMC_HOME_N" ] && { printf 'the home directory'; return 0; }
    for d in "${RMC_WORK_DIRS[@]}"; do
        _rmc_is_within "$d" "$p" && { [ "$d" = "$p" ] && printf 'the working directory' || printf 'a parent of the working directory %s' "$d"; return 0; }
    done
    for d in "${RMC_EXTRA_N[@]}"; do
        _rmc_is_within "$d" "$p" && { [ "$d" = "$p" ] && printf 'an additional working directory' || printf 'a parent of the additional working directory %s' "$d"; return 0; }
    done
    return 1
}

# _rmc_literal <rm|rmdir> <path text with no variables or substitutions> -> rc 0 (RMC_REASON set) when critical.
_rmc_literal() {
    local tool="$1" t="$2" raw="$2" abs why
    case "$t" in
        '~') t="$RMC_HOME_N" ;;
        '~/'*) t="$RMC_HOME_N/${t#\~/}" ;;
        '~'*) return 1 ;;   # another user's home: not judged
    esac
    case "$t" in /*) abs="$t" ;; *) abs="$RMC_CWD_N/$t" ;; esac
    if [[ "$abs" == *[\*\?\[]* ]]; then
        # A glob: judge the directory the first globbed component lives in.
        local pre="${abs%%[\*\?\[]*}" parent
        parent="$(_rmc_norm "${pre%/*}")"; [[ "$pre" == */ ]] && parent="$(_rmc_norm "$pre")"
        [ -n "${pre%/*}" ] || parent=/
        local d
        for d in "${RMC_EXTRA_N[@]}"; do
            _rmc_is_within "$parent" "$d" && { RMC_REASON="'$raw' is a glob under the additional working directory $d"; return 0; }
        done
        why="$(_rmc_protected_dir "$parent")" && { RMC_REASON="'$raw' is a glob directly under $why"; return 0; }
        return 1
    fi
    abs="$(_rmc_norm "$abs")"
    if why="$(_rmc_protected_dir "$abs")"; then
        RMC_REASON="'$raw' is $why"; [ "$abs" = "$raw" ] || RMC_REASON="'$raw' resolves to $abs, $why"
        return 0
    fi
    return 1
}

# _rmc_target <rm|rmdir> <recursive 0|1> <target, unquoted> -> rc 0 (RMC_REASON set) when critical.
_rmc_target() {
    local tool="$1" rec="$2" t="$3" name rest first
    [ -n "$t" ] || return 1
    # A substitution: only-substitution output under a recursive rm is refused; a working-directory substitution is
    # read as that directory; any other leading substitution is judged like a variable.
    if [[ "$t" == '$('* ]]; then
        _rmc_match_close "$t" 1 '(' ')'
        local sub="${t:0:RMC_POS+1}"; rest="${t:RMC_POS+1}"
        if _rmc_is_cwd_source "$sub"; then t="$RMC_CWD_N$rest"
        else
            if [ -z "$rest" ] && (( rec )); then RMC_REASON="'$t' removes, recursively, whatever a command substitution prints"; return 0; fi
            t="\$__SUBST__$rest"
        fi
    fi
    if [[ "$t" =~ ^$RMC_VAR_RE ]]; then
        local ref="${BASH_REMATCH[0]}"
        rest="${t:${#ref}}"
        name="${ref#\$}"; name="${name#\{}"; name="${name%\}}"; name="${name%%[:?=+%#/^,-]*}"; name="${name#[#!]}"
        if [ "$name" = HOME ]; then _rmc_literal "$tool" "$RMC_HOME_N$rest"; return; fi
        if [ "$name" = PWD ] || [ -n "${RMC_CWD_VARS[$name]:-}" ]; then
            _rmc_literal "$tool" "$RMC_CWD_N$rest" && { RMC_REASON="${RMC_REASON} (the variable \$$name holds the working directory)"; return 0; }
            return 1
        fi
    fi
    # Any variable (or substitution) followed by a trailing slash, a glob, or a common top-level name.
    local scan="$t"
    while [[ "$scan" =~ ($RMC_VAR_RE|\$__SUBST__)(.*)$ ]]; do
        rest="${BASH_REMATCH[${#BASH_REMATCH[@]}-1]}"
        local after="${rest#/}"
        if [ "$after" != "$rest" ]; then
            after="${after##/}"
            first="${after%%/*}"
            if [ -z "$first" ]; then RMC_REASON="'$3' ends in a slash directly under a shell variable (an empty variable makes it the filesystem root)"; return 0; fi
            if [[ "$first" == *[\*\?\[]* ]]; then RMC_REASON="'$3' is a glob directly under a shell variable"; return 0; fi
            if [[ "$RMC_TOP_LEVEL_NAMES" == *" $first "* ]]; then RMC_REASON="'$3' is a shell variable followed by the common top-level name '$first'"; return 0; fi
        fi
        scan="$rest"
        [[ "$scan" == *'$'* ]] || break
    done
    [[ "$t" == *'$'* ]] && return 1   # a variable we cannot resolve: its own forms were judged above
    _rmc_literal "$tool" "$t"
}

# [CySec] Refuses deletion of critical filesystem paths named by agent-supplied command text (CWE-73, external control
# of a file path; CWE-1286). [RiskMitigation RA-01] The command text is only ever read as a string: nothing in it is
# evaluated or executed, and nesting is bounded by RMC_MAX_DEPTH (CWE-78, CWE-674).
rm_critical_check() {
    local LC_ALL=C   # byte offsets: substring access stays cheap on long commands; only ASCII characters split words
    RMC_REASON=""; RMC_CWD_VARS=()
    local text="$1" d
    # Cheap pre-filter: no rm/rmdir word at all -> nothing to judge.
    [[ "$text" =~ (^|[^A-Za-z0-9_.-])(rm|rmdir)([^A-Za-z0-9_.-]|$) ]] || return 1
    RMC_HOME_N=""; [ -n "${RMC_HOME:-${HOME:-}}" ] && RMC_HOME_N="$(_rmc_norm "${RMC_HOME:-$HOME}")"
    RMC_CWD_N="$(_rmc_norm "${RMC_CWD:-$PWD}")"
    RMC_WORK_DIRS=("$RMC_CWD_N")
    [ -n "${RMC_PROJECT_DIR:-}" ] && RMC_WORK_DIRS+=("$(_rmc_norm "$RMC_PROJECT_DIR")")
    RMC_EXTRA_N=()
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        case "$d" in '~') d="$RMC_HOME_N" ;; '~/'*) d="$RMC_HOME_N/${d#\~/}" ;; /*) : ;; *) d="$RMC_CWD_N/$d" ;; esac
        RMC_EXTRA_N+=("$(_rmc_norm "$d")")
    done <<< "${RMC_EXTRA_DIRS:-}"
    text="$(printf '%s\n' "$text" | _cmd_strip_heredocs)"
    _rmc_scan "$text" 0
    [ -n "$RMC_REASON" ]
}
