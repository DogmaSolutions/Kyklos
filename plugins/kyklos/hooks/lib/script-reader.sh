#!/usr/bin/env bash
# script-reader.sh -- the one reader of the local scripts a command runs, shared by the guards that judge what a script
# would do as if it stood on the command line (the raw-note guard, the auto-merge coverage guard).
#
# Only a script the agent may have written is read: a file git tracks unmodified (committed code, reviewed with its
# repository) is not, while an untracked or modified file, or one outside any repository (a temporary or scratch
# folder), is. So running a committed tool or test suite whose text holds API calls as data is never judged as making
# them, and a script written for this command is.
#
# Source it; it defines functions only. Callers own their shell options.
#
#   script_reader_files <splitter> <mode> <cmd> <cwd>
#       -> the path of each script the command runs that is to be read, one per line. <splitter> is the caller's
#          function that splits a command into statements, one per line, in order; <mode> is "shell" (shell scripts:
#          bash|sh|dash|zsh|ksh <file>, source|. <file>, <file> run by its path, a shell reading `< file`) or "any"
#          (also python|python3|node <file>). Wrappers before the program are skipped (timeout N, env [-u N] [VAR=v],
#          sudo [-u U], nice [-n N], flock [-o|-w N] <lock>, xargs [opts], nohup, exec, command, time, stdbuf, setsid,
#          ionice, doas); a shell's option that
#          takes an argument (-o, -O, +o, +O, --rcfile, --init-file) never names the file; `cd <dir>` moves where later
#          relative names are read; a bare shell right after `cat <file>...` (cat x.sh | bash) reads those files. rc 0; rc 2 (nothing printed) when the command runs more than SCRIPT_READER_MAX_FILES
#          scripts to read: the caller refuses, since it would not judge them all.
#   script_reader_text <file>...
#       -> the first SCRIPT_READER_MAX_BYTES bytes of each file, whole-line comments dropped and backslash-newline
#          continuations joined, one pass per file (no per-line loop).
#
# [CySec] CWE-184 (Incomplete List of Disallowed Inputs): a call moved into a script the command runs is still judged.
SCRIPT_READER_MAX_BYTES=65536
SCRIPT_READER_MAX_FILES=8

# _script_reader_wanted <file> -> rc 0 when the file is a readable regular text file the agent may have written. Only a
# file its repository tracks and that is the same as at the fork point of HEAD with the remote trunk (origin/develop,
# else origin/main, else origin/master) is skipped: committed repository code the branch did not touch. A script the
# branch added or changed (committed or not), an untracked one, one outside any repository, and any file of a repository
# whose remote trunk cannot be resolved are read. A nested repository (a companion's Repo/) is judged against its own
# remote trunk, since git answers for the repository that holds the file.
_script_reader_wanted() {
    local f="$1" dir t base=""
    [ -f "$f" ] && [ -r "$f" ] || return 1
    LC_ALL=C grep -qI . -- "$f" 2>/dev/null || return 1
    dir="$(dirname -- "$f")"
    git -C "$dir" ls-files --error-unmatch -- "$f" >/dev/null 2>&1 || return 0
    for t in origin/develop origin/main origin/master; do
        git -C "$dir" rev-parse --verify -q "${t}^{commit}" >/dev/null 2>&1 || continue
        base="$(git -C "$dir" merge-base HEAD "$t" 2>/dev/null)" && [ -n "$base" ] && break
        base=""
    done
    [ -n "$base" ] || return 0
    # unchanged since the fork point, in the work tree and the index alike: reviewed with its repository
    git -C "$dir" diff --quiet "$base" -- "$f" 2>/dev/null && git -C "$dir" diff --quiet --cached "$base" -- "$f" 2>/dev/null && return 1
    return 0
}

script_reader_files() {
    local splitter="$1" mode="$2" cmd="$3" cwd="${4:-$PWD}" seg file name w i k n=0 found="" catted="" prevcat=""
    local -a words
    local -; set -f   # names are never glob-expanded (`ls *.sh` reads nothing); restored when the function returns
    while IFS= read -r seg || [ -n "$seg" ]; do
        [ -n "$seg" ] || continue
        # a pipe inside a statement starts another command (the splitter may keep it)
        seg="${seg//|/ ; }"
        read -r -a words <<< "${seg//[\"\']/}" 2>/dev/null || continue
        i=0
        while [ "$i" -lt "${#words[@]}" ]; do
            # one simple command: words[i] up to the next ';'
            file=""
            while [ "$i" -lt "${#words[@]}" ] && { [ "${words[$i]}" = ";" ] || [[ ${words[$i]} =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; }; do i=$((i + 1)); done
            [ "$i" -lt "${#words[@]}" ] || break
            # wrappers that run the rest of their line
            while [ "$i" -lt "${#words[@]}" ]; do
                name="${words[$i]##*/}"
                case "$name" in
                    timeout) i=$((i + 1)); while [[ ${words[$i]:-} == -* ]]; do case "${words[$i]}" in -s|-k|--signal|--kill-after) i=$((i + 1)) ;; esac; i=$((i + 1)); done; i=$((i + 1)) ;;
                    env) i=$((i + 1)); while [[ ${words[$i]:-} == -* || ${words[$i]:-} =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do case "${words[$i]}" in -u|-C|--unset|--chdir) i=$((i + 1)) ;; esac; i=$((i + 1)); done ;;
                    sudo|doas) i=$((i + 1)); while [[ ${words[$i]:-} == -* ]]; do case "${words[$i]}" in -u|-g|-C|-D|-h|-p|-U|-r|-t) i=$((i + 1)) ;; esac; i=$((i + 1)); done ;;
                    nice|ionice) i=$((i + 1)); while [[ ${words[$i]:-} == -* ]]; do case "${words[$i]}" in -n|-c) i=$((i + 1)) ;; esac; i=$((i + 1)); done ;;
                    stdbuf|setsid) i=$((i + 1)); while [[ ${words[$i]:-} == -* ]]; do i=$((i + 1)); done ;;
                    flock) i=$((i + 1)); while [[ ${words[$i]:-} == -* ]]; do case "${words[$i]}" in -w|-E|--timeout|--conflict-exit-code) i=$((i + 1)) ;; -c|--command) break ;; esac; i=$((i + 1)); done
                           [[ ${words[$i]:-} == -c || ${words[$i]:-} == --command ]] || i=$((i + 1)) ;;   # the lock file or folder
                    xargs) i=$((i + 1)); while [[ ${words[$i]:-} == -* ]]; do case "${words[$i]}" in -I|-L|-n|-P|-s|-d|-E|-a|--max-args|--max-procs|--delimiter|--arg-file) i=$((i + 1)) ;; esac; i=$((i + 1)); done ;;
                    nohup|exec|command|time) i=$((i + 1)) ;;
                    *) break ;;
                esac
            done
            [ "$i" -lt "${#words[@]}" ] || break
            w="${words[$i]}"; name="${w##*/}"
            prevcat="$catted"; catted=""
            case "$name" in
                cat)
                    for ((k = i + 1; k < ${#words[@]}; k++)); do
                        case "${words[$k]}" in ";") break ;; -*) : ;; *) catted="$catted ${words[$k]}" ;; esac
                    done ;;
                cd)
                    if [ -n "${words[$((i + 1))]:-}" ] && [ "${words[$((i + 1))]}" != ";" ]; then
                        case "${words[$((i + 1))]}" in /*) cwd="${words[$((i + 1))]}" ;; *) cwd="$cwd/${words[$((i + 1))]}" ;; esac
                    fi ;;
                bash|sh|dash|zsh|ksh)
                    for ((k = i + 1; k < ${#words[@]}; k++)); do
                        case "${words[$k]}" in
                            ";") break ;;
                            -c) file=""; break ;;
                            -o|-O|+o|+O|--rcfile|--init-file) k=$((k + 1)) ;;
                            "<") file="${words[$((k + 1))]:-}"; break ;;
                            "<"*) file="${words[$k]#<}"; break ;;
                            -*|+*) : ;;
                            *) file="${words[$k]}"; break ;;
                        esac
                    done
                    # a bare shell reads its input: the files a `cat` piped into it
                    if [ -z "$file" ] && [ -n "$prevcat" ] && { [ -z "${words[$((i + 1))]:-}" ] || [ "${words[$((i + 1))]}" = ";" ]; }; then
                        file="${prevcat# }"
                    fi ;;
                source|.) file="${words[$((i + 1))]:-}"; [ "$file" = ";" ] && file="" ;;
                python|python3|node)
                    if [ "$mode" = any ]; then
                        for ((k = i + 1; k < ${#words[@]}; k++)); do
                            case "${words[$k]}" in ";"|-c|-m|-e) break ;; -*) : ;; *) file="${words[$k]}"; break ;; esac
                        done
                    fi ;;
                *) case "$w" in */*|*.sh|*.bash) file="$w" ;; *.py) [ "$mode" = any ] && file="$w" ;; esac ;;
            esac
            local one
            for one in $file; do
                case "$one" in /*) : ;; *) one="$cwd/$one" ;; esac
                _script_reader_wanted "$one" || continue
                case $'\n'"$found" in *$'\n'"$one"$'\n'*) continue ;; esac
                n=$((n + 1)); [ "$n" -le "$SCRIPT_READER_MAX_FILES" ] || return 2
                found="$found$one"$'\n'
            done
            # move to the next simple command of this statement
            while [ "$i" -lt "${#words[@]}" ] && [ "${words[$i]}" != ";" ]; do i=$((i + 1)); done
        done
    done < <("$splitter" "$cmd")
    printf '%s' "$found"
    return 0
}

script_reader_text() {
    local f
    for f in "$@"; do
        head -c "$SCRIPT_READER_MAX_BYTES" -- "$f" 2>/dev/null | sed -E -e ':a' -e '/\\$/{N;s/\\\n//;ba' -e '}' -e '/^[[:space:]]*#/d'
        printf '\n'
    done
}
