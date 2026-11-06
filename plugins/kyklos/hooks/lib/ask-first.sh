#!/usr/bin/env bash
# ask-first.sh (Kyklos hook lib) - ASK FIRST: find the changes in one tool call that would switch a workflow control
# off, weaken it, or switch a grant on, so the guard (kyklos-ask-first-guard.sh) can hand them to the user for
# confirmation in Claude Code's own permission dialog.
#
# Findings, one per line, tab separated:
#   change<TAB><switch><TAB><old value><TAB><new value><TAB><where>    a control loosened (where: the file, or "inline")
#   unclear<TAB><what><TAB><why>                                       a change this library cannot read for certain
# An "unclear" finding asks too: a change that cannot be read is never let through silently (fail hard).
#
#   ask_first_bash_findings <command> <cwd>     a Bash tool command
#   ask_first_edit_findings <tool-input-json>   an Edit, Write or MultiEdit tool input (needs jq)
#
# What a Bash command is checked for:
#   (1) an assignment of a control in a command the shell runs: `NAME=0 story close`, `export NAME=off`, also inside
#       `bash -c '...'`, `eval`, a string piped into a shell (the payloads lib/cmd-strip.sh extracts). An assignment in
#       quoted data (an echo, a commit message) or a here-document body is data, not an assignment.
#   (2) a write to a settings file the hooks or the shell read at start: .claude/standards.env, .claude/settings*.json,
#       and the shell profiles (.bashrc, .bash_profile, .profile, .zshrc, .zshenv, .envrc, /etc/environment). The
#       written text is read only when every program of the command is one whose writes are literal text (echo,
#       printf, cat, tee, sed, mkdir, touch; git add, diff, commit and other subcommands that only read) and the text
#       expands nothing ($VAR, $(...), backticks); any other program
#       (cp, mv, python, perl, git checkout, ...) or an expansion makes the change unclear, and it asks. So does text
#       taken from another file (cat or sed reading it, an input redirection, sed -f), an escape sequence other than \n
#       and \t, a printf format other than %s\n, and a switch name assembled from quoted pieces. sed -i on
#       .claude/standards.env is judged by its effect: the program runs on a copy (sed --sandbox) and the switches before
#       and after are compared; a program that cannot run there (r, w, e) is unclear.
#   (3) a switch set without a plain NAME=value: read NAME, printf -v NAME, let, a nameref, export of a bare name,
#       ${NAME:=value}, NAME+=value; and a switch named in a command that runs code this reading cannot follow (an
#       interpreter such as python, perl, node or awk, another shell such as ksh or busybox, a runner such as xargs,
#       find, ssh, docker or env -S). Both are unclear, and ask.
#
# Known limits (static reading of one command; every one of them that changes the settings file during the call is
# caught after it by the backstop, lib/ask-first-snapshot.sh, which puts the file back and blocks the turn): a file path built at run time (a glob such as `stand*.env`, a variable
# assembled from pieces, an encoded name) is not recognised as a settings file, though writing a switch to such a path
# asks; a script written now and run later
# (the assignment sits in that file, and running it shows only `bash run.sh`); an Edit or Write of any file other than
# the settings files above, or of a link made to one under another name. A switch named only by a guard's own inline
# variable that is not read through kyklos_control_off (STORY_ALLOW_JUNK_SLUG=1 story new) is no derived control and
# is not judged; a bulk rewrite over files listed at run time that names neither the settings file nor the .claude
# folder (git ls-files | xargs sed -i ...); whole-tree git and patch commands that can bring in another version of the
# settings file (git checkout <branch>, merge, cherry-pick, rebase, stash pop, reset --hard, git apply or patch of a
# patch file), whose other version is not read; a shell started with BASH_ENV or ENV naming a file written earlier.
# Threshold settings (a coverage floor, a CRAP ceiling) are numbers, not switches, and are
# not judged.
# [CySec] CWE-15 (External Control of System or Configuration Setting) / CWE-693 (Protection Mechanism Failure): an
# agent may not switch off a protection that guards its own work without the user's confirmation.

_AF_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib/control-inventory.sh
. "$_AF_LIB_DIR/control-inventory.sh"
# shellcheck source=lib/cmd-strip.sh
. "$_AF_LIB_DIR/cmd-strip.sh"
# shellcheck source=lib/standards-env.sh
. "$_AF_LIB_DIR/standards-env.sh"

# The settings files a write to which is read for control assignments (ERE, matched in the command text).
ASK_FIRST_TARGET_RE='(standards\.env([^.A-Za-z0-9_]|$)|\.claude/settings[A-Za-z0-9_.-]*\.json|\.bashrc|\.bash_profile|(^|[^A-Za-z0-9_])\.profile|\.zshrc|\.zshenv|\.envrc|/etc/environment)'
# Programs whose writes are literal text this library can read; and programs that only read.
_AF_LITERAL_WRITERS=" echo printf cat tee sed mkdir touch "
_AF_READERS=" git:add git:diff git:log git:show git:status git:commit git:blame git:ls-files git:grep cat grep egrep fgrep rg head tail less more wc diff cmp ls stat file test [ [[ true false : cd pwd echo printf uniq cut jq md5sum sha256sum basename dirname realpath readlink "
_AF_SHELLS=" bash sh dash zsh "

# _af_blank_free_text <command> -> the command with commit messages, titles and other free-text option values emptied
# (lib/free-text-blank.pl), so a message that mentions a switch is not read as a change. Without perl, unchanged.
_af_blank_free_text() {
    local out
    if command -v perl >/dev/null 2>&1; then
        out="$(printf '%s' "$1" | perl "$_AF_LIB_DIR/free-text-blank.pl" 2>/dev/null)" && [ -n "$out" ] && { printf '%s' "$out"; return 0; }
    fi
    printf '%s' "$1"
}

# _af_drop_sed_patterns <text> -> the text with the PATTERN half of every sed s-command removed (s/NAME=0/NAME=1/ ->
# s//NAME=1/), so the old value a substitution matches is not read as the value it writes.
_af_drop_sed_patterns() {
    local t="$1" d re
    for d in / '|' '#' ',' : @ ! %; do
        re="(^|[^A-Za-z0-9_])s[$d]([^$d]+)[$d]"
        while [[ $t =~ $re ]]; do
            t="${t/"${BASH_REMATCH[0]}"/"${BASH_REMATCH[1]}s$d$d"}"
        done
    done
    printf '%s' "$t"
}

# _af_value <raw token> -> the value a token writes, quotes removed, cut at a written line break (\n, \t); rc 1 when
# it cannot be read for certain (an unbalanced quote, an expansion, another backslash escape).
_af_value() {
    local tok="$1" sq dq
    # The closing quote of a quoted argument (echo "NAME=on") ends the token: one unpaired quote at its end is that one.
    sq="${tok//[!\']/}"; dq="${tok//[!\"]/}"
    if [ $(( ${#sq} % 2 )) -eq 1 ] && [ "${tok: -1}" = "'" ]; then tok="${tok%\'}"; sq="${sq%\'}"; fi
    if [ $(( ${#dq} % 2 )) -eq 1 ] && [ "${tok: -1}" = '"' ]; then tok="${tok%\"}"; dq="${dq%\"}"; fi
    [ $(( ${#sq} % 2 )) -eq 0 ] && [ $(( ${#dq} % 2 )) -eq 0 ] || return 1
    tok="${tok//\'/}"; tok="${tok//\"/}"
    tok="${tok%%\\n*}"; tok="${tok%%\\t*}"
    case "$tok" in *'$'*|*'`'*|*'\'*) return 1 ;; esac
    printf '%s' "$tok"
}

# _af_assignments <text> <names-regex> -> "<index><TAB><name><TAB><raw token>" for every NAME=<token> of a switch,
# and "<index><TAB><name><TAB>" plus a third field "-bare" for a switch named without an assignment.
_af_assignments() {
    printf '%s' "$1" | awk -v mode=assignments -v names="$2" -f "$_AF_LIB_DIR/ask-first.awk"
}

# _af_mark_assignments <text> <names-regex> -> the text with each NAME= of a switch replaced by a marker word
# __ASKFIRST<index>__ (numbered as _af_assignments numbers them), so the command strip shows which ones the shell runs.
_af_mark_assignments() {
    printf '%s' "$1" | awk -v mode=mark -v names="$2" -f "$_AF_LIB_DIR/ask-first.awk"
}

# _af_assigned_markers <stripped text> -> the index of every marker in an ASSIGNMENT position: the start of a statement
# (after keywords, options and other assignments), or anywhere after a word that makes assignments for the command it
# runs: env, export, declare, local, readonly, typeset, sudo, doas (timeout 5 env NAME=0 cmd). A marker anywhere else
# is a plain argument (echo NAME=off), not an assignment the shell makes.
_af_assigned_markers() {
    _af_statements "$1" | awk -v mode=markers -f "$_AF_LIB_DIR/ask-first.awk"
}

# _af_command_words <stripped text> -> the program word of every statement, one per line, with a trailing "+c" when the
# statement passes -c (a shell given a command string, which the strip has already extracted as a payload).
_af_command_words() {
    _af_statements "$1" | awk -v mode=words -f "$_AF_LIB_DIR/ask-first.awk"
}

# _af_statements <text> -> one statement per line: the text split at ; & | ( ) { } and backticks, after the
# redirections that hold one of those characters (2>&1, >&2, &>, &>>, >|) are rewritten as plain ones, so a
# redirection never splits a statement or reads as a program of its own.
_af_statements() {
    printf '%s\n' "$1" | sed -E 's/([0-9]*)>&([0-9-]+)/\1>\2/g; s/&>(>?)/>\1/g; s/>\|/>/g' | tr ';&|(){}`' '\n\n\n\n\n\n\n\n'
}

# _af_placeholder_text <command> -> the command with here-document bodies removed and each quoted string replaced by
# its text when that is a plain word (a file name such as '.claude/standards.env'), else by the word Q, so the
# sources scan sees every argument, quoted or not. Without perl the quotes stay, and a quoted source reads as unknown.
_af_placeholder_text() {
    local t
    t="$(printf '%s\n' "$1" | _cmd_strip_heredocs)"
    if command -v perl >/dev/null 2>&1; then
        # shellcheck disable=SC2016
        printf '%s' "$t" | perl -0777 -pe 's/\x27([^\x27]*)\x27|"((?:\\.|[^"\\])*)"/ my $c = defined $1 ? $1 : $2; $c =~ m{\A[A-Za-z0-9_.\/~+-]+\z} ? $c : "Q" /ge'
        return 0
    fi
    printf '%s' "$t"
}

# Programs that run code or a command string this check cannot read: a control named anywhere in a command that runs
# one of them may be set there (python os.environ, perl system, ksh -c, xargs sh -c, find -exec, ssh, docker exec).
_af_is_opaque_runner() {
    case "$1" in
        python*|perl*|ruby*|node|nodejs|deno|bun|php*|lua*|tclsh*|wish*|pwsh|powershell|awk|gawk|mawk|nawk|busybox) return 0 ;;
        ksh|ksh93|mksh|ash|yash|fish|csh|tcsh|osascript|expect|groovy|jshell|Rscript|julia) return 0 ;;
        xargs|find|parallel|watch|ssh|su|runuser|docker|podman|kubectl|script|nsenter|chroot|unshare|flock|make) return 0 ;;
    esac
    return 1
}

# _af_old_value <name> <cwd> -> the value the workspace settings file gives <name> now, else the environment, else "unset".
_af_old_value() {
    local name="$1" dir="${2:-.}" top f v
    top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || top="$dir"
    for f in "$dir/.claude/standards.env" "$top/.claude/standards.env"; do
        [ -f "$f" ] || continue
        v="$(standards_env_value "$f" "$name")"
        [ -n "$v" ] && { printf '%s' "$v"; return 0; }
    done
    [ -n "${!name:-}" ] && { printf '%s' "${!name}"; return 0; }
    printf 'unset'
}

# _af_same <a> <b> -> rc 0 when both values read the same (case and blanks ignored): writing it again changes nothing.
_af_same() {
    [ "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d ' ')" = "$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]' | tr -d ' ')" ]
}

# _af_report_change <name> <new value> <where> <cwd> -> a change finding, unless the switch already has that value.
_af_report_change() {
    local old; old="$(_af_old_value "$1" "$4")"
    _af_same "$old" "$2" && return 0
    printf 'change\t%s\t%s\t%s\t%s\n' "$1" "$old" "$2" "$3"
}

# _af_is_workspace_settings <path> <cwd> -> rc 0 when <path> (relative to <cwd>) is the .claude/standards.env of <cwd>
# or of the top of its git repository.
_af_is_workspace_settings() {
    local p="$1" cwd="${2:-.}" top
    case "$p" in /*) ;; *) p="$cwd/$p" ;; esac
    p="$(realpath -m -- "$p" 2>/dev/null)" || return 1
    [ "$p" = "$(realpath -m -- "$cwd/.claude/standards.env" 2>/dev/null)" ] && return 0
    top="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || return 1
    [ "$p" = "$(realpath -m -- "$top/.claude/standards.env" 2>/dev/null)" ]
}

# _af_names_workspace_claude <command> <cwd> -> rc 0 when a word of the command names the WORKSPACE's own .claude folder
# (or a path in it): the .claude of <cwd> or of the top of its git repository. A relative path is read against <cwd>,
# ~ against $HOME. The user-level folders (~/.claude/projects, the plugin cache) hold no settings file the hooks read
# as standards.env, so a command working there is not judged by this rule (a ~/.claude/settings*.json is named by the
# settings-file rule anyway).
_af_names_workspace_claude() {
    local check="$1" cwd="${2:-.}" w p own top ownt found=0
    own="$(realpath -m -- "$cwd/.claude" 2>/dev/null)"
    top="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" && ownt="$(realpath -m -- "$top/.claude" 2>/dev/null)"
    while IFS= read -r w; do
        [ -n "$w" ] || continue
        p="${w%%.claude*}.claude"
        case "$p" in
            '~'*) p="$HOME${p#\~}" ;;
            /*) ;;
            *) p="$cwd/$p" ;;
        esac
        p="$(realpath -m -- "$p" 2>/dev/null)" || return 0
        [ "$p" = "$own" ] || { [ -n "${ownt:-}" ] && [ "$p" = "$ownt" ]; } && return 0
        found=1
    done < <(printf '%s\n' "$check" | tr ' \t;&|()<>"'"'"'=' '\n' | grep -E '(^|/)\.claude([^A-Za-z0-9_-]|$)')
    # A .claude folder from elsewhere, in a command that also names the workspace itself (cp -a prep/.claude .), may be
    # put in place of the workspace's own.
    [ "${found:-0}" = 1 ] || return 1
    while IFS= read -r w; do
        [ -n "$w" ] || continue
        case "$w" in '~'*) p="$HOME${w#\~}" ;; /*) p="$w" ;; *) p="$cwd/$w" ;; esac
        p="$(realpath -m -- "$p" 2>/dev/null)" || continue
        [ "$p" = "$(dirname -- "$own")" ] || { [ -n "${top:-}" ] && [ "$p" = "$(realpath -m -- "$top")" ]; } && return 0
    done < <(printf '%s\n' "$check" | tr ' \t;&|()<>"'"'"'=' '\n')
    return 1
}

# _af_indirection <command> -> the first indirection the command runs another command through (a shell's -c string,
# a string piped or fed into a shell, eval, source, xargs, parallel, find -exec, env -S, su -c, ssh, docker or kubectl
# exec, watch, flock, nsenter, chroot, unshare, runuser), or nothing.
_af_indirection() {
    local sh='([^[:space:];&|]*/)?(bash|sh|dash|zsh|ksh|ksh93|mksh|ash|yash|fish|csh|tcsh)'
    printf '%s\n' "$1" | grep -oE -m1 \
        -e "(^|[^A-Za-z0-9_./-])$sh([[:space:]]+-[A-Za-z]+)*[[:space:]]+-[A-Za-z]*c([[:space:]]|$)" \
        -e "\|[[:space:]]*(sudo[[:space:]]+)?$sh([[:space:]]|$)" \
        -e "(^|[^A-Za-z0-9_./-])$sh([[:space:]]+-[A-Za-z]+)*[[:space:]]*<<" \
        -e '(^|[^A-Za-z0-9_./-])(eval|source|xargs|parallel|watch|ssh|runuser|nsenter|chroot|unshare|flock|busybox)([[:space:]]|$)' \
        -e '(^|[^A-Za-z0-9_./-])find[[:space:]].*-(exec|execdir|ok|okdir)([[:space:]]|$)' \
        -e '(^|[^A-Za-z0-9_./-])su[[:space:]].*-c' \
        -e '(^|[^A-Za-z0-9_./-])(docker|podman|kubectl)[[:space:]]+([a-z-]+[[:space:]]+)?exec' \
        -e '(^|[^A-Za-z0-9_./-])env([[:space:]]+-[A-Za-z]+)*[[:space:]]+(-[A-Za-z]*S|--split-string)' \
        | head -n1 | sed -E 's/^[^A-Za-z.\/|]+//; s/[[:space:]]+$//'
}

# _af_compare_settings <old file> <new file> <path shown> -> a change finding for every control the new text loosens
# (both read by the hooks' own parser). Removing a switch, or blanking it, returns it to the code default: on.
_af_compare_settings() {
    local f_old="$1" f_new="$2" path="$3" name ov nv
    for name in $CONTROL_INVENTORY_CONTROLS $CONTROL_INVENTORY_GRANTS; do
        ov="$(standards_env_value "$f_old" "$name")"; nv="$(standards_env_value "$f_new" "$name")"
        [ "$ov" = "$nv" ] && continue
        [ -z "$(printf '%s' "$nv" | tr -d ' ')" ] && continue      # removed or blank: the code default, on
        control_inventory_loosens "$name" "$nv" || continue
        control_inventory_loosens "$name" "$ov" && [ -n "$ov" ] && continue   # already loosened before this change
        printf 'change\t%s\t%s\t%s\t%s\n' "$name" "${ov:-unset}" "$nv" "$path"
    done
}

# _af_sed_findings <command> <cwd> -> findings for every sed statement of the command that touches a settings file.
# The statement is read by lib/ask-first-sed.py (the shell's own quoting rules, nothing run); its program then runs on
# a COPY of the file with sed --sandbox, which refuses the commands that run a command or read or write another file,
# and the switches of the copy before and after are compared. A program that cannot be repeated this way is unclear.
# [CySec] CWE-693 (Protection Mechanism Failure): a sed program is judged by its effect, not by how it is spelled, so
# s/=1/=0/, y/1/0/ or a partial name cannot slip past a reading of its text.
_af_sed_findings() {
    local check="$1" cwd="$2" json line f p rc
    local -a files redirs opts scripts eargs
    local -A copy=() orig=()
    if ! command -v python3 >/dev/null 2>&1; then
        printf 'unclear\tsed\tpython3 is missing, so the sed program on a settings file cannot be read\n'; return 0
    fi
    json="$(printf '%s' "$check" | python3 -I "$_AF_LIB_DIR/ask-first-sed.py" 2>/dev/null)" \
        || { printf 'unclear\tsed\tthe sed statement reader failed\n'; return 0; }
    # The command runs sed (its words say so): a reader that finds no sed statement, or answers anything but one JSON
    # object per line, has not read it, and the change cannot be judged.
    if [ -z "$json" ]; then
        printf 'unclear\tsed\tthe command runs sed in a form the sed statement reader does not find\n'; return 0
    fi
    while IFS= read -r line; do
        [ "$(jq -r 'type' <<<"$line" 2>/dev/null)" = object ] \
            || { printf 'unclear\tsed\tthe sed statement reader gave an answer that cannot be read\n'; return 0; }
    done <<< "$json"
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        p="$(jq -r '.unclear // ""' <<<"$line")"
        if [ -n "$p" ]; then printf 'unclear\tsed\t%s, and the command names a settings file\n' "$p"; continue; fi
        mapfile -t files < <(jq -r '.files[]' <<<"$line")
        mapfile -t redirs < <(jq -r '.redirects[]' <<<"$line")
        for f in "${redirs[@]}"; do
            grep -cE "$ASK_FIRST_TARGET_RE" <<<"$f" >/dev/null \
                && printf 'unclear\t%s\tsed output is redirected into %s, so the written text cannot be read\n' "$f" "$f"
        done
        if [ "$(jq -r '.inplace' <<<"$line")" != true ]; then
            # sed prints a settings file: a read, unless the command writes a settings file too (sed ... f | tee f).
            for f in "${files[@]}"; do
                grep -cE "$ASK_FIRST_TARGET_RE" <<<"$f" >/dev/null || continue
                if printf '%s' "$check" | grep -cE "(^|[^A-Za-z0-9_-])tee([[:space:]]|$)|>[|>]?[[:space:]]*[\"']?[^[:space:];&|]*($ASK_FIRST_TARGET_RE)" >/dev/null; then
                    printf 'unclear\t%s\tsed prints %s and the command writes a settings file, so the printed text may be written back\n' "$f" "$f"
                fi
            done
            continue
        fi
        mapfile -t opts < <(jq -r '.opts[]' <<<"$line")
        mapfile -d '' -t scripts < <(jq -j '.scripts[] | (., "\u0000")' <<<"$line")
        eargs=()
        for f in "${scripts[@]}"; do eargs+=(-e "$f"); done
        for f in "${files[@]}"; do
            grep -cE "$ASK_FIRST_TARGET_RE" <<<"$f" >/dev/null || continue
            if ! _af_is_standards_env "$f" && [ "$(basename -- "$f")" != standards.env ]; then
                printf 'unclear\t%s\tsed -i rewrites %s, whose switches this check does not read\n' "$f" "$f"; continue
            fi
            case "$f" in
                /*) p="$f" ;;
                *)  if printf '%s' "$check" | grep -cE '(^|[^A-Za-z0-9_-])(cd|pushd)([[:space:]]|$)' >/dev/null; then
                        printf 'unclear\t%s\tthe command changes folder before sed -i rewrites %s, so the file cannot be found for certain\n' "$f" "$f"; continue
                    fi
                    p="$cwd/$f" ;;
            esac
            if [ ! -f "$p" ]; then
                printf 'unclear\t%s\tsed -i would rewrite %s, which cannot be read here\n' "$f" "$f"; continue
            fi
            if [ -z "${copy[$p]:-}" ]; then
                orig[$p]="$(mktemp)"; copy[$p]="$(mktemp)"
                cat -- "$p" > "${orig[$p]}" 2>/dev/null; cat -- "$p" > "${copy[$p]}" 2>/dev/null
            fi
            timeout 10 sed --sandbox "${opts[@]}" "${eargs[@]}" -i -- "${copy[$p]}" >/dev/null 2>&1; rc=$?
            if [ "$rc" -ne 0 ]; then
                printf 'unclear\t%s\tthe sed program cannot be repeated on a copy of %s (it runs a command, reads or writes another file, or does not parse)\n' "$f" "$f"
            fi
        done
    done <<< "$json"
    for p in "${!copy[@]}"; do
        _af_compare_settings "${orig[$p]}" "${copy[$p]}" "$p"
        rm -f -- "${orig[$p]}" "${copy[$p]}"
    done
    return 0
}

ask_first_bash_findings() {
    local cmd="$1" cwd="${2:-.}" check names marked stripped idx name tok val words w writes=0 target
    check="$(_af_blank_free_text "$cmd")"
    names="$(control_inventory_names_regex)"
    [ -n "$names" ] || { printf 'unclear\tthe command\tthe plugin control inventory is empty, so no change can be judged\n'; return 0; }

    # (1) assignments the shell runs.
    marked="$(_af_mark_assignments "$check" "$names")"
    stripped="$(cmd_strip "$marked")"
    local -A executed=()
    for idx in $(_af_assigned_markers "$stripped"); do executed[$idx]=1; done
    while IFS=$'\t' read -r idx name tok; do
        [ -n "$idx" ] && [ -n "${executed[$idx]:-}" ] || continue
        [ "$tok" = "-bare" ] && continue
        if [ -z "$tok" ]; then continue; fi            # NAME= cmd: set to empty, which the reader treats as on
        if ! val="$(_af_value "$tok")" || [ -z "$val" ]; then
            printf 'unclear\t%s\tthe value given inline (%s) cannot be read for certain\n' "$name" "$tok"; continue
        fi
        control_inventory_loosens "$name" "$val" && _af_report_change "$name" "$val" inline "$cwd"
    done < <(_af_assignments "$check" "$names")

    # A switch set without a plain NAME=value the shell runs: read NAME, printf -v NAME, let, a nameref, export NAME,
    # ${NAME:=value}, NAME+=value, NAME[i]=value. Its value cannot be read here.
    for name in $(_af_statements "$stripped" | awk -v mode=bare -v names="$names" -f "$_AF_LIB_DIR/ask-first.awk" | sort -u) \
        $(printf '%s' "$check" | grep -oE "\\\$\\{($names):?=|(^|[^A-Za-z0-9_])($names)(\\[[^]]*\\])?\\+=|(^|[^A-Za-z0-9_])($names)\\[[^]]*\\]=" \
            | grep -oE "$names" | sort -u) \
        $(printf '%s' "$check" | grep -oE "(^|[^A-Za-z0-9_-])let[[:space:]][^;&|]*" | grep -oE "$names" | sort -u); do
        printf 'unclear\t%s\t%s is set in a form whose value cannot be read here (read, printf -v, let, a nameref, export of a bare name, ${NAME:=...}, +=)\n' "$name" "$name"
    done
    # A control named in a command that runs code this check cannot read (an interpreter, another shell, a command
    # runner such as xargs or ssh): it may be set there.
    local runner
    for w in $(_af_command_words "$stripped"); do
        w="${w%+c}"
        _af_is_opaque_runner "$w" || continue
        printf '%s' "$check" | grep -cE "(^|[^A-Za-z0-9_])($names)([^A-Za-z0-9_]|$)" >/dev/null || break
        runner="$w"; break
    done
    # A runner that is skipped as a prefix word when the program is read (xargs sh -c '...', find -exec, timeout).
    if [ -z "${runner:-}" ]; then
        w="$(printf '%s\n' "$stripped" | grep -oE '(^|[[:space:];&|(])(xargs|find|parallel|watch|ssh|su|runuser|docker|podman|kubectl|nsenter|chroot|unshare|flock)[[:space:]]' | head -n1 | tr -d ' \t;&|(')"
        [ -n "$w" ] && printf '%s' "$check" | grep -cE "(^|[^A-Za-z0-9_])($names)([^A-Za-z0-9_]|$)" >/dev/null && runner="$w"
    fi
    if [ -z "${runner:-}" ] && printf '%s' "$check" | grep -cE '(^|[^A-Za-z0-9_-])env([[:space:]]+-[A-Za-z]+)*[[:space:]]+(-[A-Za-z]*S|--split-string)' >/dev/null \
        && printf '%s' "$check" | grep -cE "(^|[^A-Za-z0-9_])($names)([^A-Za-z0-9_]|$)" >/dev/null; then
        runner="env -S"
    fi
    if [ -n "${runner:-}" ]; then
        name="$(printf '%s' "$check" | grep -oE "(^|[^A-Za-z0-9_])($names)([^A-Za-z0-9_]|$)" | grep -oE "$names" | head -n1)"
        printf 'unclear\t%s\tthe command runs %s, whose code or command string names %s and may set it in a way that cannot be read here\n' "$name" "$runner" "$name"
    fi

    # (2) a write to a settings file.
    # A program that copies, moves, links, unpacks, patches or edits files in place, run on the .claude folder or a path
    # under it (cp -r prep/. .claude/, rsync -a prep/ .claude/, tar -xf p.tar -C .claude, unzip -d .claude), may put a
    # prepared settings file in place without naming it: it asks.
    # [CySec] CWE-15 (External Control of System or Configuration Setting)
    local bulk
    if _af_names_workspace_claude "$check" "$cwd"; then
        bulk="$(_af_command_words "$(cmd_strip "$check")" | sed 's/+c$//' \
            | grep -xE 'cp|mv|rsync|scp|tar|bsdtar|unzip|7z|7za|cpio|install|ln|dd|patch|git:apply|git:am|git:checkout|git:restore|git:checkout-index|git:reset|git:stash|truncate|perl|ruby|awk|gawk|ed|ex|vi|vim|nvim|python[0-9.]*|node' | head -n1)"
        # sed on a pattern under the folder (sed -i ... .claude/stand*) is not simulated: the file is not named.
        if [ -z "$bulk" ] && printf '%s' "$check" | grep -cE '\.claude/[^[:space:];&|]*[][*?{]' >/dev/null \
            && _af_command_words "$(cmd_strip "$check")" | grep -cx sed >/dev/null; then
            bulk="sed on a file pattern"
        fi
        if [ -n "$bulk" ]; then
            printf 'unclear\t.claude\tthe command runs %s on the .claude folder, which may put a prepared settings file in place\n' "${bulk#git:}"
            return 0
        fi
    fi
    # A command that reaches a settings file (its name, the .claude folder, or a pattern that may match it) through an
    # indirection - a shell's -c string, a string piped or fed into a shell, eval, xargs, find -exec, env -S, or a
    # runner such as ssh or docker exec - asks: the inner command is never judged from the outer text.
    # [CySec] CWE-693 (Protection Mechanism Failure): a sed or a write hidden behind another command must not escape the
    # check that the same command run directly gets.
    local reach indirect
    reach="$(printf '%s' "$check" | grep -oE "$ASK_FIRST_TARGET_RE|\.claude([/[:space:]\"']|$)|standards|[^[:space:]]*[*?][^[:space:]]*env" | head -n1)"
    if [ -n "$reach" ]; then
        indirect="$(_af_indirection "$check")"
        if [ -n "$indirect" ]; then
            printf 'unclear\t%s\tthe command reaches %s through %s, whose inner command is not judged here\n' "$reach" "$reach" "$indirect"
            return 0
        fi
    fi
    # A switch written to a file whose name is built at run time (a glob, a brace list, an expansion) may be written to
    # a settings file this reading cannot name.
    if printf '%s' "$check" | grep -cE '(>[|>]?|(^|[^A-Za-z0-9_-])tee([[:space:]]+-[A-Za-z]+)*)[[:space:]]*[^[:space:];&|<>]*[][{}*?$`]' >/dev/null \
        && printf '%s' "$check" | grep -cE "(^|[^A-Za-z0-9_])($names)([^A-Za-z0-9_]|$)" >/dev/null; then
        printf 'unclear\ta file named at run time\tthe command writes a switch to a file whose name is a pattern or an expansion, which may be a settings file\n'
        return 0
    fi
    target="$(printf '%s' "$check" | grep -oE "$ASK_FIRST_TARGET_RE" | head -n1)"
    [ -n "$target" ] || return 0
    target="$(printf '%s' "$target" | sed -E 's/^[^.\/A-Za-z]//; s/[^A-Za-z0-9_.]$//')"
    words="$(_af_command_words "$(cmd_strip "$check")")"
    local unknown="" stmts
    # Judged per statement: only a statement that names a settings file (or writes one through a redirection or tee)
    # must run a program whose writes are literal text, or one that only reads; a statement that names no settings file
    # (git branch, git push, base64, story, ...) changes none and is not judged. A real change of the file by any
    # route is caught after the call by the backstop (lib/ask-first-snapshot.sh). Without the statement reader
    # (python3), every program of the command is judged, as before.
    local rows=""
    if stmts="$(printf '%s' "$check" | python3 -I "$_AF_LIB_DIR/ask-first-sed.py" --statements "$ASK_FIRST_TARGET_RE" 2>/dev/null)" \
        && [ -n "$stmts" ] && ! grep -c '"unclear"' <<<"$stmts" >/dev/null \
        && rows="$(jq -r '[.program, (.names | tostring), (.writes | tostring)] | @tsv' <<<"$stmts" 2>/dev/null)" && [ -n "$rows" ]; then
        while IFS=$'\t' read -r w nm wr; do
            [ "$nm" = true ] || [ "$wr" = true ] || continue
            [ "$wr" = true ] && writes=1
            [ -n "$w" ] || continue
            case "$_AF_LITERAL_WRITERS$_AF_READERS" in *" $w "*) : ;; *) unknown="${unknown:+$unknown, }$w" ;; esac
            case "$w" in tee|sed|mkdir|touch) writes=1 ;; esac
        done <<< "$rows"
    else
        while IFS= read -r w; do
            [ -n "$w" ] || continue
            case "$w" in *+c) case "$_AF_SHELLS" in *" ${w%+c} "*) continue ;; esac ;; esac
            case "$_AF_LITERAL_WRITERS$_AF_READERS" in *" $w "*) : ;; *) unknown="${unknown:+$unknown, }$w" ;; esac
            case "$w" in tee|sed|mkdir|touch) writes=1 ;; esac
        done <<< "$words"
    fi
    # A redirection into the settings file, or a here-document fed to cat, writes it.
    printf '%s' "$check" | grep -cE ">[|>]?[[:space:]]*[\"']?[^[:space:];&|]*${target//./\\.}" >/dev/null && writes=1
    if [ -n "$unknown" ]; then
        printf 'unclear\t%s\tthe command runs %s, which may change %s in a way that cannot be read here\n' "$target" "$unknown" "$target"
        return 0
    fi
    [ "$writes" -eq 1 ] || return 0                      # only programs that read: no change
    # sed without an in-place flag only prints: no write unless redirected (already counted above).
    if printf '%s' "$check" | grep -cE '\$[A-Za-z_{(]|`' >/dev/null; then
        printf 'unclear\t%s\tthe text written to %s expands a variable or a command, so its value cannot be read\n' "$target" "$target"
        return 0
    fi
    # Text that comes from another file (cat or sed reading it, an input redirection, a sed script file) cannot be read.
    local src
    while IFS= read -r src; do
        [ -n "$src" ] || continue
        # Only the settings file of this workspace itself (sed -i on it, cat of it) is not another source: a file of the
        # same name elsewhere (/tmp/prep/standards.env) is.
        _af_is_workspace_settings "$src" "$cwd" && continue
        case "$src" in
            Q)  src="a quoted or generated source" ;;
            -f) src="a sed script file" ;;
        esac
        printf 'unclear\t%s\tthe text written to %s comes from %s, which cannot be read here\n' "$target" "$target" "$src"
        return 0
    done < <(_af_statements "$(_af_placeholder_text "$check")" | awk -v mode=sources -f "$_AF_LIB_DIR/ask-first.awk")
    # A pipeline that writes a settings file (a redirection or tee into it) may only hold programs whose output is the
    # literal text read here (echo, printf, cat of a here-document, sed, tee): git show, sort, head, jq or any other
    # program writes text this check never sees.
    local pl pw
    while IFS= read -r pl || [ -n "$pl" ]; do
        printf '%s' "$pl" | grep -cE ">[|>]?[[:space:]]*[^[:space:];&|]*${target//./\\.}|(^|[^A-Za-z0-9_-])tee([[:space:]]+-[A-Za-z-]+)*[[:space:]]+[^;&|]*${target//./\\.}" >/dev/null || continue
        for pw in $(_af_command_words "$pl"); do
            case "${pw%+c}" in
                echo|printf|cat|sed|tee) ;;
                *) printf 'unclear\t%s\tthe text written to %s comes from %s, which this check cannot read\n' "$target" "$target" "${pw#git:}"; return 0 ;;
            esac
        done
    done < <(_af_placeholder_text "$check" | sed -E 's/&&|\|\||;/\n/g')
    # sed on a settings file is judged by what it does: the same program runs on a copy and the switches before and
    # after are compared (_af_sed_findings). When sed is the only program writing, the text scan below is not needed.
    local sed_only=0
    if printf '%s\n' "$words" | grep -cx sed >/dev/null; then
        _af_sed_findings "$check" "$cwd"
        sed_only=1
        printf '%s\n' "$words" | grep -cxE 'echo|printf|cat|tee' >/dev/null && sed_only=0
        _af_statements "$(cmd_strip "$check")" | awk '!/(^|[[:space:]])sed([[:space:]]|$)/' \
            | grep -cE ">[|>]?[[:space:]]*[^[:space:]]*${target//./\\.}" >/dev/null && sed_only=0
        [ "$sed_only" -eq 1 ] && return 0
    fi
    # A line written in pieces: echo -n, a printf whose format does not end the line, or an append to a file whose last
    # line has no line break, joins text with the next write and may assemble a switch across writes.
    if printf '%s' "$check" | grep -cE '(^|[^A-Za-z0-9_-])echo[[:space:]]+(-[A-Za-z]*n[A-Za-z]*[[:space:]]+)' >/dev/null; then
        printf 'unclear\t%s\techo -n writes part of a line to %s, which the next write completes\n' "$target" "$target"
        return 0
    fi
    local fmt
    while IFS= read -r fmt; do
        [ -n "$fmt" ] || continue
        fmt="${fmt%\'}"; fmt="${fmt%\"}"
        if [[ $fmt != *'\n' ]]; then
            printf 'unclear\t%s\ta printf format that does not end the line writes part of a line to %s\n' "$target" "$target"
            return 0
        fi
    done < <(printf '%s' "$check" | grep -oE "(^|[^A-Za-z0-9_-])printf[[:space:]]+('[^']*'|\"[^\"]*\"|[^[:space:];&|]+)" | sed -E 's/^[^p]*printf[[:space:]]+//')
    local tpath
    tpath="$(printf '%s' "$check" | grep -oE "[^[:space:];&|<>\"']*${target//./\\.}" | head -n1)"
    case "$tpath" in /*) ;; *) tpath="$cwd/$tpath" ;; esac
    if [ -s "$tpath" ] && [ "$(tail -c1 -- "$tpath" | od -An -c | tr -d ' ')" != '\n' ] \
        && printf '%s' "$check" | grep -cE ">>|(^|[^A-Za-z0-9_-])tee[[:space:]]+(-[A-Za-z]*a|--append)" >/dev/null; then
        printf 'unclear\t%s\t%s does not end with a line break, so the appended text joins its last line\n' "$target" "$target"
        return 0
    fi
    # The text written by echo, printf or cat: a line break or tab written as \n or \t starts a new line; any other
    # escape (\x41, \101, \u, an ANSI $'...' string) and any printf directive other than %s\n may assemble a name or a
    # value this reading cannot see.
    if printf '%s' "$check" | grep -cE "\\\$'|\\\\[^nt]" >/dev/null; then
        printf 'unclear\t%s\tthe text written to %s holds an escape sequence that may build a switch name or value\n' "$target" "$target"
        return 0
    fi
    if printf '%s\n' "$words" | grep -cx printf >/dev/null && printf '%s' "$check" | sed 's/%s\\n//g; s/%%//g' | grep -c '%' >/dev/null; then
        printf 'unclear\t%s\tprintf assembles the text written to %s from a format, so the result cannot be read\n' "$target" "$target"
        return 0
    fi
    check="$(printf '%s' "$check" | sed 's/\\[nt]/\n/g')"
    # A switch name assembled from quoted pieces (NAME_GR""EEN=0, 'NAME_'"GREEN=0") is written whole: read the text
    # with its quotes removed too, and a switch only that reading finds is unclear.
    local quoted dequoted
    quoted="$(_af_assignments "$check" "$names" | cut -f2 | sort -u)"
    dequoted="$(_af_assignments "${check//[\"\']/}" "$names" | cut -f2 | sort -u)"
    for name in $(comm -13 <(printf '%s\n' "$quoted") <(printf '%s\n' "$dequoted")); do
        printf 'unclear\t%s\t%s is assembled from quoted pieces in the text written to %s\n' "$name" "$name" "$target"
    done
    # A switch the command names only in the pattern a sed substitution matches (s/^\(NAME=\).*/\1off/) is changed to
    # a value this reading cannot see: every switch named must also be written as a plain NAME=value.
    local before after
    before="$(_af_assignments "$check" "$names" | cut -f2 | sort -u)"
    after="$(_af_assignments "$(_af_drop_sed_patterns "$check")" "$names" | cut -f2 | sort -u)"
    for name in $(comm -23 <(printf '%s\n' "$before") <(printf '%s\n' "$after")); do
        printf 'unclear\t%s\t%s is matched by a sed pattern whose replacement does not spell out NAME=value\n' "$name" "$name"
    done
    while IFS=$'\t' read -r idx name tok; do
        [ -n "$idx" ] || continue
        if [ "$tok" = "-bare" ]; then
            printf 'unclear\t%s\t%s is named in a write to %s without a plain NAME=value the change can be read from\n' "$name" "$name" "$target"; continue
        fi
        if ! val="$(_af_value "$tok")" || [ -z "$val" ]; then
            printf 'unclear\t%s\tthe value written to %s (%s) cannot be read for certain\n' "$name" "$target" "${tok:-empty}"; continue
        fi
        control_inventory_loosens "$name" "$val" && _af_report_change "$name" "$val" "$target" "$cwd"
    done < <(_af_assignments "$(_af_drop_sed_patterns "$check")" "$names")
    return 0
}

# _af_is_standards_env <path> -> rc 0 for a workspace settings file .claude/standards.env.
_af_is_standards_env() { case "$1" in */.claude/standards.env|.claude/standards.env) return 0 ;; esac; return 1; }

ask_first_edit_findings() {
    local input="$1" path tool names old_text new_text n i o r all f_old f_new name ov nv
    path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
    tool="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)"
    [ -n "$path" ] || return 0
    names="$(control_inventory_names_regex)"
    if ! _af_is_standards_env "$path"; then
        # Another settings file the hooks or the shell read: every switch it names must be a plain, readable
        # NAME=value that does not loosen.
        printf '%s' "$path" | grep -cE "$ASK_FIRST_TARGET_RE" >/dev/null || return 0
        new_text="$(printf '%s' "$input" | jq -r '[.tool_input.content // empty, .tool_input.new_string // empty, (.tool_input.edits // [] | .[].new_string)] | join("\n")' 2>/dev/null)"
        while IFS=$'\t' read -r i name r; do
            [ -n "$i" ] || continue
            if [ "$r" = "-bare" ]; then printf 'unclear\t%s\t%s is named in %s in a form whose value cannot be read here\n' "$name" "$name" "$path"; continue; fi
            if ! nv="$(_af_value "$r")" || [ -z "$nv" ]; then printf 'unclear\t%s\tthe value written to %s (%s) cannot be read for certain\n' "$name" "$path" "${r:-empty}"; continue; fi
            control_inventory_loosens "$name" "$nv" && printf 'change\t%s\t%s\t%s\t%s\n' "$name" "?" "$nv" "$path"
        done < <(_af_assignments "$new_text" "$names")
        return 0
    fi
    # The workspace settings file: the old and the new text are both read by the hooks' own parser.
    if [ -f "$path" ]; then
        # Read whole, trailing line breaks kept, so an edit whose text ends with one still matches.
        old_text="$(cat -- "$path" 2>/dev/null && printf x)" || { printf 'unclear\t%s\tthe current file cannot be read\n' "$path"; return 0; }
        old_text="${old_text%x}"
    elif [ -e "$path" ]; then
        printf 'unclear\t%s\tthe current file cannot be read\n' "$path"; return 0
    else
        old_text=""
    fi
    case "$tool" in
        Write) new_text="$(printf '%s' "$input" | jq -r '.tool_input.content // empty')" ;;
        Edit|MultiEdit)
            new_text="$old_text"
            n="$(printf '%s' "$input" | jq -r 'if .tool_input.edits then (.tool_input.edits | length) else 1 end')"
            for ((i = 0; i < n; i++)); do
                o="$(printf '%s' "$input" | jq -r --argjson i "$i" 'if .tool_input.edits then .tool_input.edits[$i].old_string else .tool_input.old_string end // empty')"
                r="$(printf '%s' "$input" | jq -r --argjson i "$i" 'if .tool_input.edits then .tool_input.edits[$i].new_string else .tool_input.new_string end // empty')"
                all="$(printf '%s' "$input" | jq -r --argjson i "$i" 'if .tool_input.edits then .tool_input.edits[$i].replace_all else .tool_input.replace_all end // false')"
                if [ -z "$o" ] || [[ $new_text != *"$o"* ]]; then
                    printf 'unclear\t%s\tthe edit text is not found in the current file, so the result cannot be read\n' "$path"; return 0
                fi
                if [ "$all" = true ]; then new_text="${new_text//"$o"/"$r"}"; else new_text="${new_text/"$o"/"$r"}"; fi
            done ;;
        *) printf 'unclear\t%s\tthe %s tool change cannot be read\n' "$path" "${tool:-unknown}"; return 0 ;;
    esac
    f_old="$(mktemp)"; f_new="$(mktemp)"
    printf '%s\n' "$old_text" > "$f_old"; printf '%s\n' "$new_text" > "$f_new"   # a last line without a line break is read too
    _af_compare_settings "$f_old" "$f_new" "$path"
    rm -f -- "$f_old" "$f_new"
    return 0
}

# ask_first_edit_reason <tool-input-json> <switch> -> the comment the new text gives on the switch's line, if any.
ask_first_edit_reason() {
    printf '%s' "$1" | jq -r '[.tool_input.content // empty, .tool_input.new_string // empty, (.tool_input.edits // [] | .[].new_string)] | join("\n")' 2>/dev/null \
        | grep -E "^[[:space:]]*$2=" | sed -nE 's/.*[[:space:]]#[[:space:]]*(.*)$/\1/p' | head -n1
}
