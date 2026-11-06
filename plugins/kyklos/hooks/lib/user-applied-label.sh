#!/usr/bin/env bash
# user-applied-label.sh — shared authorization check: was a given issue label's CURRENT state set by a GitLab user
# OTHER than THIS agent? It is sourced by the guards that grant a label-keyed leniency the agent MUST NOT grant to
# itself (the owner-label names are fixed in lib/owner-labels.sh). The leniency is honored ONLY on positive proof of
# USER authorship; a label the agent applied to itself is ignored, so it can never self-exempt. Centralised here
# (Non-Duplication: one owner of the authorship rule) instead of duplicated inline in each guard. label_present (also
# here) answers only "is the label applied now", for a caller that deliberately does not need authorship.
#
# [CySec] Enforces CWE-863 "Incorrect Authorization": a self-applied label confers no privilege; only a label whose
# latest add-event was authored by a different GitLab user does.
#
# Contract — source this file (it sources resolve-agent-identity.sh itself), then:
#   label_user_applied "<project_id>" "<iid>" "<label>"
#     rc 0 : the label's LATEST resource_label_event is an `add` by a user whose username != this agent's identity.
#     rc 1 : NOT proven user-applied — FAIL-CLOSED on every uncertainty: empty label, jq missing, this agent's
#            identity unresolvable, events unfetchable, latest action is `remove`, or the add was by this agent.
#
# Reads: the bridge verb coordination_label_events (the bridge's own token); KYKLOS_ISSUES_API + the token named
# by KYKLOS_ISSUES_TOKEN_ENV only as the logged fallback for a bridge without the verb (dereferenced in-place —
# never on argv, never logged; [CySec] CWE-522). Test seam: KYKLOS_LABEL_EVENTS_TEST — a JSON object keyed "<project>#<iid>" ->
# the events array, so the authorship logic is exercised WITHOUT a network round-trip.
. "$(dirname "${BASH_SOURCE[0]}")/gitlab-curl.sh"   # gitlab_curl / gitlab_token_present: the token never leaves the helper
. "$(dirname "${BASH_SOURCE[0]}")/coordination-read.sh"   # coordination_read: the bridge reads the events with its own token
. "$(dirname "${BASH_SOURCE[0]}")/gitlab-paged.sh"   # gitlab_paged_walk: the one rule for reading a whole list

_ual_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=resolve-agent-identity.sh
. "$_ual_here/resolve-agent-identity.sh"

# label_events "<project_id>" "<iid>" -> the issue's resource_label_events JSON array (empty string on any error /
# when GitLab is not configured). Honors the KYKLOS_LABEL_EVENTS_TEST seam.
label_events() {   # $1=project_id $2=iid
    command -v jq >/dev/null 2>&1 || { printf ''; return 0; }
    if [ -n "${KYKLOS_LABEL_EVENTS_TEST+x}" ]; then
        printf '%s' "$KYKLOS_LABEL_EVENTS_TEST" | jq -c --arg k "$1#$2" '.[$k] // []' 2>/dev/null || printf ''
        return 0
    fi
    # The bridge reads the events with its own token; an unreadable answer is "unknown" (empty), and only a bridge
    # without the verb falls back to the direct token, logged.
    local out rc
    out="$(coordination_read coordination_label_events "$(jq -cn --arg p "$1" --arg i "$2" '{project:$p, iid:$i}')" 2>/dev/null)"; rc=$?
    if [ "$rc" = 0 ]; then
        [ "$(printf '%s' "$out" | jq -r 'type' 2>/dev/null || echo err)" = array ] && printf '%s' "$out" || printf ''
        return 0
    fi
    [ "$rc" = 4 ] || { printf ''; return 0; }
    local api="${KYKLOS_ISSUES_API:-}" tenv="${KYKLOS_ISSUES_TOKEN_ENV:-}"
    { [ -n "$api" ] && [ -n "$tenv" ] && command -v curl >/dev/null 2>&1; } || { printf ''; return 0; }
    coordination_read_fallback label-events "the bridge has no coordination_label_events verb"
    gitlab_token_present "$tenv" || { printf ''; return 0; }
    # Every page (the shared reader): the label's latest event may sit after the first 100. Any page that cannot be
    # read, or a history past the page cap, is "unknown" (empty), so the authorship check fails closed.
    # [RiskMitigation RA-01]
    local body
    body="$(_UAL_API="$api" _UAL_TENV="$tenv" gitlab_paged_walk _ual_page_get "projects/$1/issues/$2/resource_label_events")" \
        || { printf ''; return 0; }
    printf '%s' "$body"
}

# _ual_page_get <relative path> -> one page through the direct token; rc 1 unless GitLab answered 200.
_ual_page_get() {
    local resp code
    resp="$(gitlab_curl "$_UAL_TENV" -s --max-time 12 -w $'\n%{http_code}' "$_UAL_API/$1" 2>/dev/null || true)"
    code="$(printf '%s' "$resp" | tail -n1)"
    printf '%s' "$resp" | sed '$d'
    [ "$code" = 200 ]
}

# label_present "<project_id>" "<iid>" "<label>" -> rc 0 iff the label is CURRENTLY applied (its latest
# resource_label_event is an `add`), REGARDLESS of who applied it. Use this ONLY for a leniency where self-application
# is acceptable because the action is BOUNDED, VISIBLE and REVERSIBLE (the continue-guard's `parked` label: parking
# one story just defers it, the user sees every parked issue, unparking is trivial) — NEVER for an outward/irreversible
# leniency (proof-override, push/merge), which must stay `label_user_applied` (un-self-grantable). FAIL-CLOSED (rc 1)
# on every uncertainty (empty label, jq missing, events unfetchable, latest action is `remove`), so a fetch error
# never spuriously reports "present".
label_present() {   # $1=project_id $2=iid $3=label  -> rc 0 iff the label is currently applied (any author)
    local pid="$1" iid="$2" lbl="$3"
    [ -n "$lbl" ] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    local events; events="$(label_events "$pid" "$iid")"
    [ -n "$events" ] || return 1
    local verdict
    verdict="$(printf '%s' "$events" | jq -r --arg lbl "$lbl" '
        ([ .[] | select(.label.name == $lbl) ] | sort_by(.id) | last) as $e
        | if ($e != null and $e.action == "add") then "yes" else "no" end' 2>/dev/null || echo no)"
    [ "$verdict" = yes ]
}

label_user_applied() {   # $1=project_id $2=iid $3=label  -> rc 0 iff user-authored (see contract)
    local pid="$1" iid="$2" lbl="$3"
    [ -n "$lbl" ] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    local self; self="$(resolve_agent_identity 2>/dev/null || true)"
    [ -n "$self" ] || return 1                                   # cannot prove non-self authorship -> fail-closed
    local events; events="$(label_events "$pid" "$iid")"
    [ -n "$events" ] || return 1
    local verdict
    verdict="$(printf '%s' "$events" | jq -r --arg lbl "$lbl" --arg self "$self" '
        ([ .[] | select(.label.name == $lbl) ] | sort_by(.id) | last) as $e
        | if $e == null then "no"
          elif ($e.action == "add" and ($e.user.username // "") != "" and $e.user.username != $self) then "yes"
          else "no" end' 2>/dev/null || echo no)"
    [ "$verdict" = yes ]
}

# override_user_applied "<command-or-branch>" "<override-label>" -> rc 0 iff the text names a story branch
# (feature/story-<N>-…) AND a GitLab USER (not this agent) applied <override-label> to that story issue #N in
# KYKLOS_ISSUES_PROJECT. The UN-SELF-GRANTABLE equivalent of a `touch`-able state-dir marker
# for the OUTWARD push/merge overrides: a prompt-injected agent cannot self-grant a push/merge exception because it
# cannot author a label AS ANOTHER GitLab user (label_user_applied enforces that). FAIL-CLOSED on every uncertainty
# (no story number in the text, no issues project configured, jq missing) — the caller then falls back to the
# opt-in-deprecated legacy marker. The story number is read from the text (the push/merge command names the branch),
# so no HEAD/refspec resolution is needed here.
override_user_applied() {   # $1=command-or-branch  $2=override-label
    local hay="$1" lbl="$2" pid="${KYKLOS_ISSUES_PROJECT:-}" iid
    [ -n "$hay" ] && [ -n "$lbl" ] && [ -n "$pid" ] || return 1
    # The story is read only from a word that is a story branch in the one anchored form (story_num_from_branch:
    # feature/story-<N>[-slug] or hotfix/story-<N>[-slug]), after a refspec's 'src:' and a 'refs/heads/' prefix; a word
    # that only contains story-<N> (a message, docs/story-8, story/42) names no story. [CySec] CWE-863
    command -v story_num_from_branch >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/git-cmd-detect.sh" 2>/dev/null
    command -v story_num_from_branch >/dev/null 2>&1 || return 1
    local w words
    iid=""
    read -r -a words <<< "$(printf '%s' "$hay" | tr "'\"\n" '   ')"
    for w in "${words[@]}"; do
        w="${w##*:}"; w="${w#+}"; w="${w#refs/heads/}"
        iid="$(story_num_from_branch "$w" | sed -E 's/^0*([0-9])/\1/')"
        [ -n "$iid" ] && break
    done
    [ -n "$iid" ] || return 1
    label_user_applied "$pid" "$iid" "$lbl"
}
