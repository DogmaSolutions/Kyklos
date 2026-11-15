#!/usr/bin/env bash
# session-health.sh (Kyklos hook lib) - the session-start health checks the doctor surface runs itself, and the one text each
# of them gives, shared with the hook each used to be (kyklos-api-scope-surface.sh, kyklos-story-mirror-refresh.sh), so the
# doctor and the old path say the same thing.
#
#   kyklos_api_scope_message <rc> <output>  -> the warning for the exit code of lib/api-scope-check.sh (nothing for 0)
#   kyklos_health_api_scope                 -> runs the token-scope check with its own time limit (KYKLOS_DOCTOR_TOKEN_CHECK_SECONDS,
#                                              default 30, at most 30) and prints its warning; a check that runs out of time gives
#                                              the "check failed (exit 124)" warning, never silence
#   kyklos_mirror_stale_text                -> the stale-story-mirror warning
#   kyklos_health_story_mirror <project-dir> -> prints that warning when the mirror is marked stale (read directly, no waiting)
# shellcheck source=control-switch.sh
. "$(dirname "${BASH_SOURCE[0]}")/control-switch.sh" 2>/dev/null || true

# kyklos_doctor_on -> rc 0 when the doctor surface is on. The ONE decision for the doctor, the token hook and the mirror
# refresh: from the environment the hook was started with (read before any hook loads standards.env), default on.
kyklos_doctor_on() { ! kyklos_control_off "${KYKLOS_DOCTOR_SURFACE:-}"; }

kyklos_api_scope_message() {
    local rc="$1" out="${2:-}" head
    case "$rc" in
        0) return 0 ;;
        1) head="[kyklos] API TOKEN NOTICE at session start: the agent can read a GitLab token that can call the API." ;;
        2) head="[kyklos] API TOKEN ERROR at session start: either this project is declared host-only (KYKLOS_API_TOKEN_STATE) yet the agent can read a GitLab token that can call the API, or KYKLOS_API_TOKEN_STATE holds an invalid value (the details follow). Tell the owner of this project's launcher configuration; do not use the token." ;;
        3) head="[kyklos] API TOKEN CHECK could not run at session start." ;;
        *) head="[kyklos] API TOKEN CHECK failed at session start (exit $rc)." ;;
    esac
    printf '%s' "$head $(printf '%s' "$out" | tr '\n' ';' | sed 's/;$//')"
}

kyklos_health_api_scope() {
    kyklos_control_off "${KYKLOS_API_SCOPE_SURFACE:-}" && return 0
    local limit="${KYKLOS_DOCTOR_TOKEN_CHECK_SECONDS:-30}" out rc
    case "$limit" in ''|*[!0-9]*) limit=30 ;; esac
    [ "$limit" -gt 30 ] && limit=30
    [ "$limit" -lt 1 ] && limit=1
    out="$(timeout "$limit" bash "$(dirname "${BASH_SOURCE[0]}")/api-scope-check.sh" 2>&1)"; rc=$?
    kyklos_api_scope_message "$rc" "$out"
}

kyklos_mirror_stale_text() {
    printf '%s' "[kyklos] Story store: GitLab, the source of truth for the stories, could not be reached when the local Stories/ mirror was last refreshed, so the mirror may lag it. Re-run the story tool's refresh when it is reachable."
}

# kyklos_health_project_dir -> the folder holding Stories/ and .claude/ (a nested source resolves to its companion root).
kyklos_health_project_dir() {
    local dir="${CLAUDE_PROJECT_DIR:-$(pwd)}" root
    root="$( . "$(dirname "${BASH_SOURCE[0]}")/repo-role.sh" 2>/dev/null && repo_companion_root "$dir" 2>/dev/null )"
    printf '%s' "${root:-$dir}"
}

kyklos_health_story_mirror() {
    [ -f "${1:-}/Stories/.mirror-stale" ] && kyklos_mirror_stale_text
    return 0
}

# The red-result record: what the doctor found "no" at this session's start, kept for the continue guard (which allows a stop
# while a reported red finding stands). Written only by the doctor hook, keyed by the session id of the hook input, one check
# identifier per line; a green or an unavailable doctor clears it. Never read across sessions: the file name is the session.
#   kyklos_doctor_record_path <session-id>        -> the record's path (empty without a usable session id)
#   kyklos_doctor_record_write <session-id> <checks> -> writes the record (one check identifier per line)
#   kyklos_doctor_record_clear <session-id>       -> removes it
kyklos_doctor_record_path() {
    local id
    id="$(printf '%s' "${1:-}" | tr -c 'A-Za-z0-9_-' '_')"
    [ -n "$id" ] || return 0
    printf '%s' "${KYKLOS_STATE_DIR:-/tmp/kyklos-state}/doctor-result/$id.red"
}

kyklos_doctor_record_write() {
    local path; path="$(kyklos_doctor_record_path "$1")"
    [ -n "$path" ] || return 0
    mkdir -p "$(dirname "$path")" 2>/dev/null || return 0
    printf '%s\n' "$2" > "$path" 2>/dev/null
    return 0
}

kyklos_doctor_record_clear() {
    local path; path="$(kyklos_doctor_record_path "$1")"
    [ -n "$path" ] && [ -f "$path" ] && rm -f "$path" 2>/dev/null
    return 0
}
