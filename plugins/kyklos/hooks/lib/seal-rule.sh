#!/usr/bin/env bash
# seal-rule.sh - the ONE rule that keeps a test shell away from live systems (the bridge, the tracker, the secret
# store). Source it; it defines functions only.
#
#   kyklos_test_sealed            -> rc 0 when the shell runs a test that must never reach a live system: one of
#                                      KYKLOS_TEST_SEALED, STORY_GL_STUB_DIR or CI_ACCESS_STUB_DIR is set
#   kyklos_url_host <url>         -> the URL's host as the network stack reads it: the authority is the text after
#                                      "scheme://" up to the first / ? or #, without any userinfo before its last "@";
#                                      a bracketed IPv6 host keeps its brackets; the port is dropped
#   kyklos_url_is_loopback <url>  -> rc 0 when that host is localhost, [::1] or a dotted 127.0.0.0/8 address whose
#                                      four parts are decimal numbers 0-255 (no other spelling is accepted)
#   kyklos_curl_is_standin        -> rc 0 when the `curl` this shell would run is a test's own stand-in (a shell
#                                      function, or an executable outside the system folders /usr /bin /sbin /snap
#                                      /opt), which cannot reach the network itself
#   kyklos_seal_refuses <who> <arg...>
#                                   -> rc 0 (refuse) when the shell is sealed, the curl that would run is the system
#                                      one, and an argument that is an http(s) URL is not loopback (or no argument is
#                                      an http(s) URL); prints why on stderr. rc 1 (allow) otherwise.
#
# The invariant: a sealed test shell never sends a request over the real network to anything but loopback. A suite
# that puts its own curl first on PATH answers its requests itself, so its made-up host names stay usable.
#
# Why: a story-tool test stubs the tracker, yet a fallback reached the LIVE bridge, which wrote the real tracker with
# the host's token. Every client that reaches the bridge or GitLab asks this one rule before it sends anything.

kyklos_test_sealed() {
    [ -n "${KYKLOS_TEST_SEALED:-}" ] || [ -n "${STORY_GL_STUB_DIR:-}" ] || [ -n "${CI_ACCESS_STUB_DIR:-}" ]
}

kyklos_url_host() {
    local rest="$1" authority host
    case "$rest" in *://*) rest="${rest#*://}" ;; esac
    authority="${rest%%[/?#]*}"
    host="${authority##*@}"
    case "$host" in
        \[*\]*) host="${host%%]*}]" ;;
        *) host="${host%%:*}" ;;
    esac
    printf '%s' "$host"
}

# _kyklos_octet <text> -> rc 0 when text is a decimal number 0-255 written without a leading zero.
_kyklos_octet() {
    [[ "$1" =~ ^(0|[1-9][0-9]{0,2})$ ]] && [ "$1" -le 255 ]
}

kyklos_url_is_loopback() {
    local host a b c d
    host="$(kyklos_url_host "$1")"
    [ "${host,,}" = localhost ] && return 0
    [ "$host" = "[::1]" ] && return 0
    [[ "$host" =~ ^([^.]+)\.([^.]+)\.([^.]+)\.([^.]+)$ ]] || return 1
    a="${BASH_REMATCH[1]}"; b="${BASH_REMATCH[2]}"; c="${BASH_REMATCH[3]}"; d="${BASH_REMATCH[4]}"
    [ "$a" = 127 ] && _kyklos_octet "$b" && _kyklos_octet "$c" && _kyklos_octet "$d"
}

kyklos_curl_is_standin() {
    local p
    p="$(command -v curl 2>/dev/null)" || return 1
    case "$p" in
        "") return 1 ;;
        /usr/*|/bin/*|/sbin/*|/snap/*|/opt/*) return 1 ;;
        *) return 0 ;;   # a function (no path) or a test's own executable
    esac
}

kyklos_seal_refuses() {
    local who="$1" a found=0
    shift
    kyklos_test_sealed || return 1
    kyklos_curl_is_standin && return 1
    # [CySec] CWE-668 (exposure of a resource to the wrong sphere): fail-closed, a request with no address this rule
    # can judge is refused too.
    for a in "$@"; do
        case "${a,,}" in
            http://*|https://*)
                found=1
                if ! kyklos_url_is_loopback "$a"; then
                    echo "$who: refusing to reach $(kyklos_url_host "$a") from a sealed test shell (KYKLOS_TEST_SEALED / STORY_GL_STUB_DIR / CI_ACCESS_STUB_DIR is set): a test may only reach a loopback stand-in it started itself. Nothing was sent." >&2
                    return 0
                fi ;;
        esac
    done
    if [ "$found" -eq 0 ]; then
        echo "$who: refusing a request with no http(s) address from a sealed test shell: nothing to judge, nothing was sent." >&2
        return 0
    fi
    return 1
}
