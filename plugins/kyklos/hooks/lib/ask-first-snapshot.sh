#!/usr/bin/env bash
# ask-first-snapshot.sh (Kyklos hook lib) - the BACKSTOP of Ask First: one BASELINE of each watched settings file,
# which only a confirmed Ask First change moves, compared with the file at every pre and post step.
#
# The first layer (lib/ask-first.sh) reads a command or an edit before it runs and asks the user about a change that
# loosens a workflow control. A static reading can never know every spelling of a write, so this layer looks at the
# RESULT: the bytes of every watched settings file are kept as a baseline in a private state folder, and at every pre
# and post step the file is compared with it, both read by the hooks' own parser (lib/standards-env.sh). A change that
# loosens nothing (another key, a tighter value) simply becomes the new baseline. A loosening moves the baseline only
# when the user confirmed it (the call Ask First asked about has come back), and only for the switches that question
# named; any other loosening is put back from the baseline and the guard answers loudly. Because the baseline belongs to
# the workspace, not to a call, a harmless call that overlaps a confirmed one never undoes the confirmed change, and a
# change made between two calls (after a post step) is compared with the baseline at the next step instead of becoming
# the new reference.
#
#   af_baseline_ensure <cwd>     take the baseline of every watched file that has none yet; rc 1 and a reason on stdout
#                                when it cannot be written (the guard then refuses the call)
#   af_baseline_changed <cwd>    rc 0 when a watched file differs from its baseline (a byte compare, no parsing)
#   af_baseline_check <cwd>      one line per loosening, for the files that differ:
#                                  loosened<TAB><path><TAB><switch><TAB><old><TAB><new>
#                                only the lines that name a switch are parsed, so a large file costs little
#   af_baseline_accept <cwd>     make the current file the baseline (a harmless or a confirmed change)
#   af_baseline_restore_names <cwd> <switch>...  put ONLY the named switches back to their baseline lines, keep every
#                                other line, and check with the parser that each reads its baseline value again
#   af_baseline_accept_except <cwd> <switch>...  the same, then make the result the new baseline (a confirmed call's
#                                post step: the named switches are the loosenings its question did not name)
#   af_baseline_restore <cwd>    put every changed file back from its baseline (a file that had none is removed, a link
#                                put in place of the file or the folder is undone); prints
#                                  restore-failed<TAB><path><TAB><why>   for a file that could not be put back
#
# The watched files: .claude/standards.env in the working folder, at the top of its git repository, in
# CLAUDE_PROJECT_DIR and at the top of that repository. The baselines live in ${KYKLOS_STATE_DIR}/ask-first/baseline,
# a folder only this user can read, outside the workspace.
# KNOWN LIMITS (a baseline held by the host bridge, out of the agent's reach, is the planned fix for both): a command
# that deliberately rewrites this state folder can move the baseline itself; and a writer left running in the
# background that changes the file after the post step is caught only at the next pre or post step.
# [CySec] CWE-15 (External Control of System or Configuration Setting) / CWE-693 (Protection Mechanism Failure): a
# protection the agent loosened by a route no static reading foresaw is restored, never left in place silently.

_AFS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib/standards-env.sh
. "$_AFS_LIB_DIR/standards-env.sh"

_afs_root() { printf '%s/ask-first/baseline' "${KYKLOS_STATE_DIR:-/tmp/kyklos-state}"; }

# _afs_watched <cwd> -> the settings files to watch, one per line, without repeats.
_afs_watched() {
    local d top
    for d in "${1:-}" "${CLAUDE_PROJECT_DIR:-}"; do
        [ -n "$d" ] && [ -d "$d" ] || continue
        printf '%s/.claude/standards.env\n' "$d"
        top="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)" && printf '%s/.claude/standards.env\n' "$top"
    done | awk '!seen[$0]++'
}

# _afs_dir <path> -> the baseline folder of one watched file.
_afs_dir() { printf '%s/%s' "$(_afs_root)" "$(printf '%s' "$1" | cksum | cut -d' ' -f1)"; }

# _afs_record <path> <dir> -> write the current state of <path> as its baseline (bytes, presence, links).
_afs_record() {
    local f="$1" dir="$2" tmp
    tmp="$dir.new.$$"
    rm -rf -- "${tmp:?}" 2>/dev/null
    mkdir -p -- "$tmp" 2>/dev/null || return 1
    printf '%s' "$f" > "$tmp/path" || return 1
    readlink -- "$(dirname -- "$f")" > "$tmp/dlink" 2>/dev/null || : > "$tmp/dlink"
    readlink -- "$f" > "$tmp/flink" 2>/dev/null || : > "$tmp/flink"
    if [ -e "$f" ] || [ -L "$f" ]; then
        [ -f "$f" ] && [ -r "$f" ] && cat -- "$f" > "$tmp/bytes" 2>/dev/null || return 1
        printf 'present' > "$tmp/state" || return 1
    else
        : > "$tmp/bytes"; printf 'absent' > "$tmp/state" || return 1
    fi
    rm -rf -- "${dir:?}" 2>/dev/null
    mv -- "$tmp" "$dir" 2>/dev/null
}

af_baseline_ensure() {
    local root f dir
    root="$(_afs_root)"
    mkdir -p "$root" 2>/dev/null && chmod 700 "${root%/baseline}" "$root" 2>/dev/null
    [ -d "$root" ] && [ -w "$root" ] || { printf 'the state folder %s cannot be written' "$root"; return 1; }
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        dir="$(_afs_dir "$f")"
        [ -f "$dir/state" ] && continue
        _afs_record "$f" "$dir" || { printf 'the baseline of %s cannot be written to %s' "$f" "$root"; return 1; }
    done < <(_afs_watched "$1")
    return 0
}

# _afs_differs <dir> -> rc 0 when the watched file differs from its baseline (content, presence, or a link change).
_afs_differs() {
    local dir="$1" f
    f="$(cat -- "$dir/path")"
    [ "$(readlink -- "$f" 2>/dev/null)" = "$(cat -- "$dir/flink")" ] || return 0
    [ "$(readlink -- "$(dirname -- "$f")" 2>/dev/null)" = "$(cat -- "$dir/dlink")" ] || return 0
    if [ "$(cat -- "$dir/state")" = absent ]; then
        [ -e "$f" ] || [ -L "$f" ]
    else
        ! { [ -f "$f" ] && cmp -s -- "$dir/bytes" "$f"; }
    fi
}

# _afs_parser_text <file> -> the file as the hooks' parser (lib/standards-env.sh, a bash `read` loop) sees it: NUL bytes
# dropped. Every other byte, a carriage return included, reaches the parser unchanged, so it stays.
_afs_parser_text() { LC_ALL=C tr -d '\000' < "$1" 2>/dev/null; }

# _afs_control_digest <file> -> a digest of every line that holds a byte the parser does not expect (NUL, the other C0
# bytes except tab, line feed and carriage return, and DEL), the lines kept whole and sorted: a control byte added,
# removed, swapped for another or moved to another line changes it, a line added elsewhere does not.
_afs_control_digest() {
    if command -v perl >/dev/null 2>&1; then
        perl -ne 'print if /[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/' -- "$1" 2>/dev/null | LC_ALL=C sort | cksum
    else
        # Without perl: the position and value of every such byte (stricter: a line added above one moves it too).
        od -An -v -tu1 -w1 -- "$1" 2>/dev/null | awk '{ b = $1 + 0; if (b < 9 || b == 11 || b == 12 || (b > 13 && b < 32) || b == 127) print NR ":" b }' | cksum
    fi
}

# _afs_each_changed <cwd> -> the baseline folders of the watched files that differ from their baseline.
_afs_each_changed() {
    local f dir
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        dir="$(_afs_dir "$f")"
        [ -f "$dir/state" ] && [ -f "$dir/path" ] || continue
        _afs_differs "$dir" && printf '%s\n' "$dir"
    done < <(_afs_watched "$1")
}

af_baseline_changed() { [ -n "$(_afs_each_changed "$1")" ]; }

af_baseline_check() {
    local dir f names old new
    names="$(control_inventory_names_regex)"
    while IFS= read -r dir; do
        [ -n "$dir" ] || continue
        f="$(cat -- "$dir/path")"
        old="$dir/old.lines"; new="$dir/new.lines"
        # Only the lines that name a switch are read by the parser: the rest of a large file cannot change a control.
        # Text mode (-a, LC_ALL=C): a NUL or another control byte must not turn the file into "binary" for grep, which
        # would then print no line at all and hide the switch lines from the compare.
        # Both sides are first read the way the hooks' parser reads them (_afs_parser_text: NUL bytes dropped, as bash
        # read drops them), so a switch name split by a NUL is seen whole, exactly as the parser sees it.
        _afs_parser_text "$dir/bytes" | LC_ALL=C grep -aE "$names" > "$old" 2>/dev/null
        if [ -f "$f" ]; then _afs_parser_text "$f" | LC_ALL=C grep -aE "$names" > "$new" 2>/dev/null; else : > "$new"; fi
        _af_compare_settings "$old" "$new" "$f" | awk -F'\t' -v f="$f" '$1 == "change" { printf "loosened\t%s\t%s\t%s\t%s\n", f, $2, $3, $4 }'
        rm -f -- "$old" "$new"
        # A control byte the parser does not expect (NUL and the other C0 bytes except tab, line feed and carriage
        # return, or DEL) added, removed, moved or changed since the baseline is never trusted as a harmless change: the
        # whole file goes back to its baseline.
        # [CySec] CWE-158 (Improper Neutralization of Null Byte or NUL Character)
        if [ -f "$f" ] && [ "$(_afs_control_digest "$f")" != "$(_afs_control_digest "$dir/bytes")" ]; then
            printf 'loosened\t%s\t(the file itself)\ta text file\ta file holding control bytes (NUL or others)\n' "$f"
        fi
        # A link or a folder put in place of the settings file is never trusted as a harmless change.
        if [ "$(readlink -- "$f" 2>/dev/null)" != "$(cat -- "$dir/flink")" ] \
            || [ "$(readlink -- "$(dirname -- "$f")" 2>/dev/null)" != "$(cat -- "$dir/dlink")" ] \
            || { [ -e "$f" ] && [ ! -f "$f" ]; }; then
            printf 'loosened\t%s\t(the file itself)\ta file\ta link or a folder\n' "$f"
        fi
    done < <(_afs_each_changed "$1")
    return 0
}

af_baseline_accept() {
    local dir f
    while IFS= read -r dir; do
        [ -n "$dir" ] || continue
        f="$(cat -- "$dir/path")"
        _afs_record "$f" "$dir" || printf 'accept-failed\t%s\tthe new baseline cannot be written\n' "$f"
    done < <(_afs_each_changed "$1")
    return 0
}

af_baseline_accept_except() { _afs_restore_names record "$@"; }
af_baseline_restore_names() { _afs_restore_names norecord "$@"; }

# _afs_restore_names <record|norecord> <cwd> <switch>... -> put ONLY the named switches back to their baseline lines
# and keep every other line of the current file; then check with the hooks' parser that each named switch reads its
# baseline value again. With "record" the result becomes the new baseline (the rest of the change was confirmed).
_afs_restore_names() {
    local mode="$1" cwd="$2" dir f d tmp re n bad
    shift 2
    re=""
    for n in "$@"; do re="${re:+$re|}$n"; done
    [ -n "$re" ] || return 0
    while IFS= read -r dir; do
        [ -n "$dir" ] || continue
        f="$(cat -- "$dir/path")"; d="$(dirname -- "$f")"
        tmp="$d/.standards.env.askfirst.$$"
        {
            [ -f "$f" ] && LC_ALL=C grep -avE "(^|[^A-Za-z0-9_])($re)([^A-Za-z0-9_]|$)" -- "$f"
            LC_ALL=C grep -aE "(^|[^A-Za-z0-9_])($re)([^A-Za-z0-9_]|$)" -- "$dir/bytes"
        } > "$tmp" 2>/dev/null
        if ! mv -f -- "$tmp" "$f" 2>/dev/null; then
            rm -f -- "$tmp" 2>/dev/null
            printf 'restore-failed\t%s\tthe file cannot be written back\n' "$f"; continue
        fi
        bad=""
        for n in "$@"; do
            [ "$(standards_env_value "$f" "$n")" = "$(standards_env_value "$dir/bytes" "$n")" ] || bad="$bad $n"
        done
        if [ -n "$bad" ]; then printf 'restore-failed\t%s\t%s do not read their baseline value again\n' "$f" "${bad# }"; continue; fi
        [ "$mode" = record ] || continue
        _afs_record "$f" "$dir" || printf 'restore-failed\t%s\tthe new baseline cannot be written\n' "$f"
    done < <(_afs_each_changed "$cwd")
    return 0
}

# _afs_relink <path> <link target in the baseline, or empty> -> undo a link change at <path>.
_afs_relink() {
    local p="$1" was="$2" now
    now="$(readlink -- "$p" 2>/dev/null)" || now=""
    [ "$now" = "$was" ] && return 0
    if [ -n "$now" ]; then rm -f -- "$p" 2>/dev/null; fi
    if [ -n "$was" ] && [ ! -e "$p" ] && [ ! -L "$p" ]; then ln -s -- "$was" "$p" 2>/dev/null; fi
    return 0
}

af_baseline_restore() {
    local dir f d tmp
    while IFS= read -r dir; do
        [ -n "$dir" ] || continue
        f="$(cat -- "$dir/path")"
        d="$(dirname -- "$f")"
        _afs_relink "$d" "$(cat -- "$dir/dlink" 2>/dev/null)"
        _afs_relink "$f" "$(cat -- "$dir/flink" 2>/dev/null)"
        if [ "$(cat -- "$dir/state")" = absent ]; then
            rm -f -- "$f" 2>/dev/null
            if [ -e "$f" ] || [ -L "$f" ]; then printf 'restore-failed\t%s\tthe file created since the baseline cannot be removed\n' "$f"; fi
            continue
        fi
        mkdir -p -- "$d" 2>/dev/null
        tmp="$d/.standards.env.askfirst.$$"
        if cat -- "$dir/bytes" > "$tmp" 2>/dev/null && mv -f -- "$tmp" "$f" 2>/dev/null && cmp -s -- "$dir/bytes" "$f"; then
            continue
        fi
        rm -f -- "$tmp" 2>/dev/null
        printf 'restore-failed\t%s\tthe baseline cannot be written back\n' "$f"
    done < <(_afs_each_changed "$1")
    return 0
}
