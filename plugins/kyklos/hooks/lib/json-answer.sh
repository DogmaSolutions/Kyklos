#!/usr/bin/env bash
# json-answer.sh - the ONE reader for checking a JSON answer (a GitLab or bridge reply, a file, a value built in the
# shell). jq 1.6 `-e` exits 0 when its input is empty or blank: no value is read, so no false or null is printed, and a
# check such as `printf '%s' "$reply" | jq -e 'type=="array"'` passes when a request returned nothing at all. A missing
# answer is then judged as a readable one. These two functions read the answer explicitly and refuse it unless it is
# exactly one readable JSON value, so an empty, blank, truncated or multi-value answer is never accepted.
#
# Contract - source this file, then pipe (or redirect) the answer in:
#   json_test <filter> [jq options...]   0 when the answer is one readable JSON value and the filter's last output is
#                                        neither false nor null; non-zero otherwise (1 for a false or null result, 2+
#                                        for an unreadable, empty or multi-value answer). Prints nothing.
#   json_read <filter> [jq options...]   prints the filter's raw (-r) output and answers like json_test.
# The jq options (--arg, --argjson, ...) go AFTER the filter. An error-field check is written as the negation of an
# error-free test, `! json_test '(.error != null) | not'`, so an empty or truncated reply also counts as an error.
# Every other place calls jq without an exit-status flag. A script that cannot load this file (a CI script, a tool baked
# into an image) reads strictly with `jq -n '[inputs] as $a | if ($a | length) != 1 then error(...) else ... end'`.
# hooks/tests/test-empty-answer-refused.sh (J8, with hooks/tests/lib/jq-exit-flag-scan.py) fails when an exit-status
# check appears outside this file, in the plugin, ci/ or launcher/. Every hook that loads this file, directly or through a
# library, carries the [json-answer-required] block at its top and refuses by name when it did not load
# (hooks/tests/test-reader-required.sh), so a missing reader can never open a gate through a check that exited 127.
#
# [CySec] Prevents CWE-20 "Improper Input Validation" / CWE-636 "Not Failing Securely": a gate never reads a missing or
# cut answer as a valid one.

[ -n "${_JSON_ANSWER_LOADED:-}" ] && return 0
_JSON_ANSWER_LOADED=1

# _json_answer_program <filter> -> the jq program that reads all inputs and applies the filter to the only one.
_json_answer_program() {
    printf '[inputs] as $__all | if ($__all | length) != 1 then error("not exactly one JSON value") else ($__all[0] | (%s)) end' "$1"
}

json_test() {
    local filter="$1"; shift
    jq -e -n "$@" "$(_json_answer_program "$filter")" >/dev/null 2>&1
}

json_read() {
    local filter="$1"; shift
    jq -e -r -n "$@" "$(_json_answer_program "$filter")" 2>/dev/null
}
