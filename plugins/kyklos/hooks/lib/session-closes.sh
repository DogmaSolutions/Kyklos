#!/usr/bin/env bash
# session-closes.sh -- the closes this session made with `story close`, the only closes the Stop-time proof check judges.
#
# A closed story is never re-judged at Stop: a story closed by anyone else, by hand in GitLab, through another tool, or in
# an earlier session is not this session's to answer for (the close itself is gated where it happens: `story close`, the
# close guard and the bridge's story_close). `story close` records each close it made here; the Stop-time check reads the
# records of this session only, and judges each close once per proof (the judged latch below).
#
# Records live in the volatile state folder (KYKLOS_STATE_DIR, default /tmp/kyklos-state), one file per close; a caller
# that reads a project's settings afterwards pins the folder first (SESSION_CLOSES_DIR, a shell variable), so a setting
# cannot move the records away from where `story close` wrote them:
#   session-closes/<scope>--<id>            the close's time (seconds since the epoch)
#   session-closes/<scope>--<id>.judged-<h> the latch: the proof with hash <h> was judged once
# <scope> names the tracker the close was made in (a GitLab project, or a local Stories folder), so a close in another
# project is never judged against this one.
# A record is this session's when it is not older than the session's start (the stamp the SessionStart hook writes) and
# not older than KYKLOS_SESSION_WINDOW_SECONDS (18 hours by default). An extra record can only make the check judge a close
# it would otherwise skip (the strict side); a start stamp in the future is unreadable and never hides a record.
# Sourced; no side effect on load.

# session_closes_dir -> the folder of the records: SESSION_CLOSES_DIR when a caller pinned it, else under KYKLOS_STATE_DIR.
session_closes_dir() { printf '%s' "${SESSION_CLOSES_DIR:-${KYKLOS_STATE_DIR:-/tmp/kyklos-state}/session-closes}"; }

# session_closes_pin -> pin the records' folder (and the session start stamp beside it) to the state folder as it is now.
session_closes_pin() { SESSION_CLOSES_DIR="$(session_closes_dir)"; }

# _session_close_word TEXT -> TEXT with every character outside letters, digits, dot, dash and underscore replaced by an
# underscore, so a record name never holds a path separator.
_session_close_word() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

# session_close_scope_gitlab PROJECT -> the scope of a close in GitLab project PROJECT (id or path; a path in lower case,
# as GitLab resolves paths without regard to case). One project has two spellings (its numeric id and its path), so a
# reader asks for every spelling it knows (session_close_ids_any).
session_close_scope_gitlab() { printf 'gl-%s' "$(_session_close_word "$(printf '%s' "$1" | tr 'A-Z' 'a-z')")"; }

# session_close_ids_any SCOPE... -> the ids this session closed under any of the scopes (one project's spellings), one per
# line, sorted, each once.
session_close_ids_any() {
    local sc
    for sc in "$@"; do [ -n "$sc" ] && session_close_ids "$sc"; done | sort -uV
}

# session_close_has_other_gitlab SCOPE -> rc 0 when a record of this session exists under a GitLab scope other than SCOPE
# (the same project may have been named by its other spelling), so a reader only looks the spellings up when needed.
session_close_has_other_gitlab() {
    local f n
    for f in "$(session_closes_dir)"/gl-*; do
        [ -f "$f" ] || continue
        case "$f" in *.judged-*) continue ;; esac
        n="${f##*/}"
        [ "${n%%--*}" = "$1" ] || return 0
    done
    return 1
}

# session_close_scope_fs STORIES-DIR -> the scope of a close in the local Stories folder STORIES-DIR (its real path, as a
# checksum, so the CLI and the hook name the same folder the same way).
session_close_scope_fs() {
    local real
    real="$(cd "$1" 2>/dev/null && pwd -P)" || real="$1"
    printf 'fs-%s' "$(printf '%s' "$real" | cksum | cut -d' ' -f1)"
}

# session_close_record SCOPE ID -> record that this session closed item ID of SCOPE now. Never fails the caller.
session_close_record() {
    local dir
    [ -n "$1" ] && [ -n "$2" ] || return 0
    dir="$(session_closes_dir)"
    mkdir -p "$dir" 2>/dev/null || return 0
    date +%s > "$dir/$1--$(_session_close_word "$2")" 2>/dev/null || true
    return 0
}

# _session_close_start -> the session's start (seconds since the epoch) from the SessionStart stamp; 0 when it is missing,
# unreadable, or in the future beyond a minute of clock skew.
_session_close_start() {
    local s now
    s="$(cat "$(dirname "$(session_closes_dir)")/session-start-epoch" 2>/dev/null || true)"
    case "$s" in ''|*[!0-9]*) printf '0'; return 0 ;; esac
    now="$(date +%s)"
    [ "$s" -gt $((now + 60)) ] && s=0
    printf '%s' "$s"
}

# session_close_is_this_session SCOPE ID -> rc 0 when this session recorded a close of item ID of SCOPE.
session_close_is_this_session() {
    local f at start now win
    f="$(session_closes_dir)/$1--$(_session_close_word "$2")"
    at="$(cat "$f" 2>/dev/null || true)"
    case "$at" in ''|*[!0-9]*) return 1 ;; esac
    start="$(_session_close_start)"; now="$(date +%s)"
    win="${KYKLOS_SESSION_WINDOW_SECONDS:-64800}"
    case "$win" in ''|*[!0-9]*) win=64800 ;; esac
    [ "$at" -ge "$start" ] || return 1
    [ $((now - at)) -lt "$win" ] || return 1
    return 0
}

# session_close_ids SCOPE -> the ids of the items of SCOPE this session closed with `story close`, one per line, sorted.
session_close_ids() {
    local dir f id
    dir="$(session_closes_dir)"
    [ -d "$dir" ] || return 0
    for f in "$dir/$1--"*; do
        [ -f "$f" ] || continue
        case "$f" in *.judged-*) continue ;; esac
        id="${f##*/}"; id="${id#"$1--"}"
        session_close_is_this_session "$1" "$id" && printf '%s\n' "$id"
    done | sort -V
}

# session_close_judged SCOPE ID HASH -> rc 0 when the proof with HASH of item ID was already judged this session.
session_close_judged() { [ -f "$(session_closes_dir)/$1--$(_session_close_word "$2").judged-$(_session_close_word "$3")" ]; }

# session_close_mark_judged SCOPE ID HASH -> latch: the proof with HASH of item ID is judged (once per proof).
session_close_mark_judged() {
    local dir
    dir="$(session_closes_dir)"; mkdir -p "$dir" 2>/dev/null || return 0
    : > "$dir/$1--$(_session_close_word "$2").judged-$(_session_close_word "$3")" 2>/dev/null || true
    return 0
}

# session_close_unmark_judged SCOPE ID HASH -> undo the latch when no judgement was made (the judge did not answer).
session_close_unmark_judged() {
    local f
    f="$(session_closes_dir)/$1--$(_session_close_word "$2").judged-$(_session_close_word "$3")"
    [ -f "$f" ] && rm -f -- "$f"
    return 0
}
