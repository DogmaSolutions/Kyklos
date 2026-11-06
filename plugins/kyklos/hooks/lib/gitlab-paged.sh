#!/usr/bin/env bash
# gitlab-paged.sh - the ONE rule for reading a GitLab list endpoint completely. GitLab answers a list (issues, notes,
# label events, branches, jobs, ...) one page at a time, 20 items when the caller asks for nothing. A check that judges
# such a list from its first page alone misses everything after it: the close gate once read 20 of an issue's 37 label
# events, so a phase walk looked like a jump and the owner's override label was never seen. Every caller that must
# judge a whole list reads it through gitlab_paged_walk.
#
# Contract - source this file, then:
#   gitlab_paged_walk <fetch-function> <path(+query)>
#     Calls "<fetch-function> <path>?...&per_page=100&page=<n>" for n = 1, 2, ... and prints ONE JSON array holding
#     every element of every page. The fetch function prints the page body and returns 0 on success, non-zero on
#     failure (the transport is the caller's: the story tool's gl_api, a direct gitlab_curl, a bridge read).
#     It stops at the first EMPTY page. A short page does not end the walk: GitLab can answer fewer than 100 elements
#     before the last page (a filtered answer), and the bridge's read verbs give the body only, not the X-Next-Page
#     header, so the empty page is the one end marker every transport shows. The cost is one extra read per list.
#     A page that fails is asked once more before the walk gives up, so one transient error does not fail a check.
#   rc 0 : the whole list.
#   rc 1 : a page could not be read twice in a row (a failed fetch, or an answer that is not a list). On the first page
#          the answer is printed as it came, so a caller can still tell "the API failed" from "an empty list ([])"; on
#          a later page a message names the page and '{}' is printed: a partial list is never answered as if it were
#          whole.
#   rc 4 : the list is longer than the page cap (GITLAB_PAGE_CAP pages of 100, default 50; a list of exactly that
#          many elements is complete). A message says so and '{}' is printed; the caller fails CLOSED, because a list
#          cut at the cap is exactly the partial answer this rule exists to prevent.
#   rc 5 : the walk ran out of time (GITLAB_PAGED_DEADLINE seconds for the whole walk, default 60), so a slow
#          GitLab cannot hold a hook for a page timeout per page. A message says so and '{}' is printed.
#
# [CySec] Prevents CWE-863 "Incorrect Authorization": an owner-authority check (the override label's latest event) or
# a phase-history check never decides on a truncated history.
# [RiskMitigation RA-01] every page is read, or the reader says it could not and the caller refuses to judge.

# shellcheck source=lib/json-answer.sh
. "$(dirname "${BASH_SOURCE[0]}")/json-answer.sh"   # json_test / json_read: an empty or cut answer is never valid
GITLAB_PAGE_SIZE=100

# gitlab_page_cap -> the page cap in force: GITLAB_PAGE_CAP when it is a positive number, else 50. It bounds the reads
# one check makes on a long list. [RiskMitigation RA-03]
gitlab_page_cap() {
    case "${GITLAB_PAGE_CAP:-}" in
        ''|*[!0-9]*|0) printf '50' ;;
        *) printf '%s' "$GITLAB_PAGE_CAP" ;;
    esac
}

# gitlab_paged_deadline -> the time limit of one walk in seconds: GITLAB_PAGED_DEADLINE when it is a positive number,
# else 60. [RiskMitigation RA-03]
gitlab_paged_deadline() {
    case "${GITLAB_PAGED_DEADLINE:-}" in
        ''|*[!0-9]*|0) printf '60' ;;
        *) printf '%s' "$GITLAB_PAGED_DEADLINE" ;;
    esac
}

# _gitlab_paged_fetch <fetch-function> <url> -> the page body; asks a second time when the first answer fails or is
# not a list. rc 0 a list, rc 1 two failures (the second answer is printed).
_gitlab_paged_fetch() {
    local fetch="$1" url="$2" body rc try
    for try in 1 2; do
        rc=0
        body="$("$fetch" "$url")" || rc=$?
        if [ "$rc" -eq 0 ] && printf '%s' "$body" | json_test 'type == "array"'; then
            printf '%s' "$body"; return 0
        fi
        [ "$try" -eq 1 ] && printf 'gitlab: %s failed once; asking again.\n' "$url" >&2
    done
    printf '%s' "$body"; return 1
}

gitlab_paged_walk() {
    local fetch="$1" path="$2" cap deadline start page=1 acc='[]' body n sep
    cap="$(gitlab_page_cap)"; deadline="$(gitlab_paged_deadline)"; start=$SECONDS
    case "$path" in *\?*) sep='&' ;; *) sep='?' ;; esac
    while :; do
        if [ "$page" -gt 1 ] && [ $((SECONDS - start)) -ge "$deadline" ]; then
            printf 'gitlab: reading the list %s took longer than its time limit of %s s (page %s); refusing a partial answer.\n' \
                "$path" "$deadline" "$page" >&2
            printf '{}'; return 5
        fi
        if ! body="$(_gitlab_paged_fetch "$fetch" "${path}${sep}per_page=${GITLAB_PAGE_SIZE}&page=${page}")"; then
            if [ "$page" -eq 1 ]; then printf '%s' "$body"; return 1; fi
            printf 'gitlab: page %s of the list %s could not be read; refusing to answer the first %s pages as the whole list.\n' \
                "$page" "$path" "$((page - 1))" >&2
            printf '{}'; return 1
        fi
        n="$(printf '%s' "$body" | jq 'length' 2>/dev/null)" || n=0
        [ "${n:-0}" -eq 0 ] && break
        if [ "$page" -gt "$cap" ]; then
            printf 'gitlab: the list %s has more than %s pages of %s; refusing a partial answer (raise GITLAB_PAGE_CAP to read it whole).\n' \
                "$path" "$cap" "$GITLAB_PAGE_SIZE" >&2
            printf '{}'; return 4
        fi
        acc="$(printf '%s\n%s' "$acc" "$body" | jq -cs '.[0] + .[1]')"
        page=$((page + 1))
    done
    printf '%s' "$acc"
}
