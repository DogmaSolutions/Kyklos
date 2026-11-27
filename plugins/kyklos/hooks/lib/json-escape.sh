#!/usr/bin/env bash
# json-escape.sh - the ONE escaper for text a hook puts inside a JSON string (a refusal reason, a context message, a
# value of a request body it builds by hand). A hook answer that is not valid JSON is not read as a refusal, so a gate
# whose reason holds a raw tab, carriage return or other control character (echoed from a commit subject, a branch name
# or a command) would let the call through. Every hook escapes through this function, never with its own replacements.
#
# Contract - source this file, then:
#   kyklos_json_escape <text>   prints <text> escaped for the inside of a JSON string (no surrounding quotes):
#                               backslash and double quote escaped, newline, carriage return and tab as \n \r \t, every
#                               other control character U+0001 to U+001F as \u00XX, and bytes that are not valid UTF-8
#                               dropped (when iconv is present), so the result is always a valid JSON string body.
# A site that cannot load this file prints an empty text instead (the function is missing), which keeps its answer
# valid JSON: the refusal still blocks, only without its reason.
#
# [CySec] Prevents CWE-116 "Improper Encoding or Escaping of Output" / CWE-636 "Not Failing Securely": untrusted text
# echoed in a guard's answer can never turn a refusal into unreadable output that the agent's runner ignores.

[ -n "${_KYKLOS_JSON_ESCAPE_LOADED:-}" ] && return 0
_KYKLOS_JSON_ESCAPE_LOADED=1

kyklos_json_escape() {
    local s="${1-}" c i t
    # Bytes that are not valid UTF-8 would make the whole answer unreadable as JSON: drop them first. iconv -c exits
    # non-zero when it dropped something, so its output is taken whenever it printed one (the trailing dot keeps
    # trailing newlines through the command substitution).
    if command -v iconv >/dev/null 2>&1; then
        t="$(printf '%s.' "$s" | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null)"
        [ -n "$t" ] && s="${t%.}"
    fi
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    for i in 1 2 3 4 5 6 7 8 11 12 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31; do
        printf -v c "\\x$(printf '%02x' "$i")"
        case "$s" in *"$c"*) s="${s//"$c"/\\u00$(printf '%02x' "$i")}" ;; esac
    done
    printf '%s' "$s"
}
