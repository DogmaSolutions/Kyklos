#!/usr/bin/env bash
# gitlab-curl.sh - the ONE way a Kyklos script sends an authenticated GitLab request.
#
# A token must never appear where a shell trace (bash -x), a process listing or a log can see it. Passing the
# header through curl's stdin is not enough on its own: under `bash -x` the command that BUILDS the header line, and
# any `tok="$(...)"` assignment, are traced with their values. So callers never hold the token at all: they pass the
# NAME of the setting that holds it, and this helper switches tracing off, resolves the value through the shared
# secret resolver, hands curl the header as a config line on stdin (-K -), and restores tracing afterwards.
#
# Usage (after sourcing this file):
#   gitlab_token_present "$STORY_GITLAB_TOKEN_ENV" || exit 0   # is a token available? (never prints it)
#   resp="$(gitlab_curl "$token_setting_name" -s --max-time 12 "$api/projects/505/issues/1")"
# gitlab_curl passes every argument after the name to curl unchanged and returns curl's exit code, or 2 when the
# name is invalid, no token is available, or the value is not a plain token (it could otherwise inject curl config).

. "$(dirname "${BASH_SOURCE[0]}")/secret-value.sh"   # kyklos_secret: the one way to read a named secret
. "$(dirname "${BASH_SOURCE[0]}")/seal-rule.sh"      # kyklos_seal_refuses: a test shell reaches only loopback stand-ins

# Per-process cache of resolved values, keyed by setting name. It is written and read only while tracing is off, so
# a trace never shows it; it saves one secret lookup (a bridge round-trip in bridge mode) per request.
declare -gA _GITLAB_CURL_CACHE 2>/dev/null || true

# _gitlab_curl_fill <setting-name> -> resolves the value into the cache (in THIS shell, not a subshell, so it
# persists). Call ONLY while tracing is off.
_gitlab_curl_fill() {
    if [ -z "${_GITLAB_CURL_CACHE[$1]+set}" ]; then
        _GITLAB_CURL_CACHE[$1]="$(kyklos_secret "$1")"
    fi
}

# gitlab_token_present <setting-name> -> rc 0 when a token is available under that name, 1 otherwise. Prints nothing.
gitlab_token_present() {
    { local _gt_xt="$-"; set +x; } 2>/dev/null
    local _gt_rc=1
    if [[ "${1:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        _gitlab_curl_fill "$1"
        [ -n "${_GITLAB_CURL_CACHE[$1]}" ] && _gt_rc=0
    fi
    case "$_gt_xt" in *x*) set -x ;; esac
    return "$_gt_rc"
}

# gitlab_curl <setting-name> <curl args...> -> curl's output and exit code; the PRIVATE-TOKEN header goes via stdin.
gitlab_curl() {
    # [CySec] Prevents CWE-532 "Insertion of Sensitive Information into Log File" and CWE-214 "Invocation of Process
    # Using Visible Sensitive Information": tracing is off while the token is in scope, and the header reaches curl
    # through its stdin config, never as an argument.
    { local _gc_xt="$-"; set +x; } 2>/dev/null
    local _gc_name="${1:-}" _gc_value="" _gc_rc=0
    [ "$#" -gt 0 ] && shift
    # [CySec] CWE-668: a sealed test shell sends nothing to a non-loopback host, and does not even resolve the token.
    if kyklos_seal_refuses "gitlab-curl" "$@"; then
        _gc_rc=7
    elif ! [[ "$_gc_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        printf 'kyklos: gitlab_curl needs the NAME of the setting that holds the token.\n' >&2
        _gc_rc=2
    else
        _gitlab_curl_fill "$_gc_name"
        _gc_value="${_GITLAB_CURL_CACHE[$_gc_name]}"
        if [ -z "$_gc_value" ]; then
            printf 'kyklos: no GitLab token is available under %s.\n' "$_gc_name" >&2
            _gc_rc=2
        elif ! [[ "$_gc_value" =~ ^[A-Za-z0-9._~+/=:-]+$ ]]; then
            # [CySec] Prevents CWE-88 "Argument Injection": a quote, backslash or newline in the value could add
            # curl configuration lines, so anything but a plain token is refused.
            printf 'kyklos: the value of %s is not a plain token; refusing to send it.\n' "$_gc_name" >&2
            _gc_rc=2
        else
            # The result is curl's own exit code (PIPESTATUS[1]), never the pipeline's: under pipefail a curl that
            # exits before the header line is written (it already answered, or failed) breaks the pipe, and the
            # writer's SIGPIPE (141) would turn a good answer into a failed request, at random under load.
            # [RiskMitigation RA-02] A request curl completed is never reported as failed, and a failed one keeps
            # curl's code (CWE-754).
            printf 'header = "PRIVATE-TOKEN: %s"\n' "$_gc_value" | curl -K - "$@" || _gc_rc="${PIPESTATUS[1]}"
        fi
    fi
    _gc_value=""
    case "$_gc_xt" in *x*) set -x ;; esac
    return "$_gc_rc"
}

# gitlab_pick_token <out-variable> <setting-name>... -> stores in <out-variable> the first NAME whose setting holds
# a token (empty when none does). Runs in the current shell, so the value cache is kept for later requests.
gitlab_pick_token() {
    local _gp_out="$1" _gp_name
    shift
    [[ "$_gp_out" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
    printf -v "$_gp_out" '%s' ""
    for _gp_name in "$@"; do
        [ -n "$_gp_name" ] || continue
        if gitlab_token_present "$_gp_name"; then
            printf -v "$_gp_out" '%s' "$_gp_name"
            return 0
        fi
    done
    return 1
}

# gitlab_request <setting-name-or-empty> <curl args...> -> an authenticated request when a name is given, else an
# anonymous one (for callers that also work without a token, e.g. reads on a public project).
gitlab_request() {
    local _gr_name="${1:-}"
    [ "$#" -gt 0 ] && shift
    if [ -n "$_gr_name" ]; then
        gitlab_curl "$_gr_name" "$@"
    else
        kyklos_seal_refuses "gitlab-curl" "$@" && return 7
        curl "$@"
    fi
}
