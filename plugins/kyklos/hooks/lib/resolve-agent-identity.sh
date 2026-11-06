#!/usr/bin/env bash
# resolve-agent-identity.sh — determine THIS agent's own GitLab username (its identity), MECHANICALLY, so the
# coordination logic can tell whether an Issue's last reply is OURS. Hardcoding a name ("claude") is wrong on any
# container whose token belongs to a different GitLab user (e.g. another project's bot), so the identity is resolved,
# never assumed.
#
# Contract — source this file, then call `resolve_agent_identity`:
#   rc 0 : prints the resolved username on stdout.
#   rc 1 : could not resolve (no identity from the token, no cache, no env fallback). Never guess a name. Each
#          caller decides what rc 1 means for it; a caller that GRANTS a privilege on the identity (an
#          authorization check, e.g. label_user_applied in lib/user-applied-label.sh) must FAIL CLOSED.
#
# Resolution precedence (the token is AUTHORITATIVE, env is a fallback):
#   1. cache                     — a prior authoritative identity, honoured only within KYKLOS_IDENTITY_TTL_MIN.
#   2. the token's identity      — AUTHORITATIVE: asked of the bridge (coordination_whoami, answered with the
#                                  bridge's own token); only a bridge without that verb falls back to a direct
#                                  GitLab `GET /user` with the container's token, logged. A token maps to exactly one
#                                  GitLab identity and an agent CANNOT forge it; it is also the CORRECT source for
#                                  "is the last note ours?" because every note is authored AS the token's user.
#   3. a stale cache, announced  — when the token identity is unavailable.
#   4. KYKLOS_AGENT_NAME / KYKLOS_ISSUES_SELF — FALLBACK, used ONLY when the token identity is unavailable.
#                                  Announced loudly (unverified). NOT cached (so a later online resolution
#                                  recovers the authoritative identity).
#
# WHY the token outranks the env: an env identity is agent-writable, so an agent could `export
# KYKLOS_ISSUES_SELF=<other-agent>` in-session to spoof its identity and clear its own inbox gate (the gate
# compares the last note's author to "self"). A mismatched env override (env set AND != the token user) is a
# spoof/misconfig — it is IGNORED (token wins) and surfaced loudly.
#
# [CySec] Mitigates CWE-522 "Insufficiently Protected Credentials": on the direct-token fallback the token is
# referenced by the NAME of its env var (KYKLOS_ISSUES_TOKEN_ENV) and dereferenced in-place for the single /user
# call — never on argv, never logged, never written to disk. [CySec] Mitigates CWE-290 "Authentication Bypass by Spoofing": the identity is bound to the
# token (unforgeable), not an agent-writable env var. bash + curl + jq only.
. "$(dirname "${BASH_SOURCE[0]}")/gitlab-curl.sh"   # gitlab_curl / gitlab_token_present: the token never leaves the helper
. "$(dirname "${BASH_SOURCE[0]}")/coordination-read.sh"   # coordination_read: the bridge answers with its own token

resolve_agent_identity() {
    # 1) cache — the cache file is AGENT-WRITABLE, so it is a performance artifact, never an authority: honor it
    # only within a TTL; past the TTL fall through to the authoritative token re-derivation, which OVERWRITES it.
    # A poisoned cache (e.g. the user's name written into it, which would clear the inbound awaiting-me gate and
    # make agent-applied privileged labels pass label_user_applied) therefore survives at most one TTL window, and a
    # live mismatch is audited below.
    local cache="${KYKLOS_STATE_DIR:-/tmp/kyklos-state}/agent-identity"
    local _id_ttl="${KYKLOS_IDENTITY_TTL_MIN:-15}"
    if [ -s "$cache" ] && [ -n "$(find "$cache" -mmin -"$_id_ttl" 2>/dev/null)" ]; then
        cat "$cache"; return 0
    fi

    # 2) AUTHORITATIVE: the identity of the token the agent acts with. The bridge holds it (coordination_whoami), so
    #    no token is needed here; only a bridge without that verb falls back to the direct token, logged.
    local api="${KYKLOS_ISSUES_API:-}" token_env="${KYKLOS_ISSUES_TOKEN_ENV:-}" user="" _who _who_rc
    if command -v jq >/dev/null 2>&1; then
        _who="$(coordination_read coordination_whoami '{}' 2>/dev/null)"; _who_rc=$?
        [ "$_who_rc" = 0 ] && user="$(printf '%s' "$_who" | jq -r '.username // empty' 2>/dev/null || true)"
    fi
    if [ -z "$user" ] && [ "${_who_rc:-4}" = 4 ] && [ -n "$api" ] && [ -n "$token_env" ]; then
        coordination_read_fallback resolve-agent-identity "the bridge has no coordination_whoami verb"
        if gitlab_token_present "$token_env" && command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
            user="$(gitlab_curl "$token_env" -s --max-time 8 "$api/user" 2>/dev/null \
                    | jq -r '.username // empty' 2>/dev/null || true)"
        fi
    fi
    if [ -n "$user" ]; then
        # A mismatched env override (set AND != the token user) is a spoof/misconfig — IGNORE it, but surface loudly.
        local _envname="${KYKLOS_AGENT_NAME:-${KYKLOS_ISSUES_SELF:-}}"
        if [ -n "$_envname" ] && [ "$_envname" != "$user" ]; then
            printf '[kyklos] resolve-agent-identity: IGNORING an env identity override (%s) — the token identity is authoritative (%s). An env-set identity that differs from the token is a spoof or a misconfig.\n' "$_envname" "$user" >&2
        fi
        # A STALE cache that disagrees with the live token identity is a poisoning/corruption
        # signal — audit it durably before overwriting (the trail names both values).
        if [ -s "$cache" ]; then
            local _cached; _cached="$(cat "$cache" 2>/dev/null)"
            if [ -n "$_cached" ] && [ "$_cached" != "$user" ]; then
                printf '[kyklos] resolve-agent-identity: STALE CACHE MISMATCH — cache said %s, the token says %s; overwriting with the authoritative token identity (a hand-edited cache is a spoof signal).\n' "$_cached" "$user" >&2
                command -v escape_audit >/dev/null 2>&1 && escape_audit "identity-cache-mismatch" "cache=$_cached token=$user" 2>/dev/null || true
            fi
        fi
        mkdir -p "$(dirname "$cache")" 2>/dev/null || true
        printf '%s' "$user" > "$cache" 2>/dev/null || true
        printf '%s' "$user"; return 0
    fi
    # Token identity unavailable but a STALE cache exists -> reuse it (announced): a previously-authoritative
    # value beats the unverified env fallback.
    if [ -s "$cache" ]; then
        printf '[kyklos] resolve-agent-identity: the token identity is unavailable — reusing the STALE cached identity (%s), unverified this window.\n' "$(cat "$cache")" >&2
        cat "$cache"; return 0
    fi

    # 4) FALLBACK — the token identity was unavailable (offline, or no bridge verb and no token). Use the
    #    launcher/operator env name if set, but announce it (unverified) and do NOT cache it (so a later online call recovers the authoritative identity).
    if [ -n "${KYKLOS_AGENT_NAME:-}" ]; then
        printf '[kyklos] resolve-agent-identity: the token identity is unavailable — falling back to the unverified KYKLOS_AGENT_NAME=%s.\n' "$KYKLOS_AGENT_NAME" >&2
        printf '%s' "$KYKLOS_AGENT_NAME"; return 0
    fi
    if [ -n "${KYKLOS_ISSUES_SELF:-}" ]; then
        printf '[kyklos] resolve-agent-identity: the token identity is unavailable — falling back to the unverified KYKLOS_ISSUES_SELF=%s.\n' "$KYKLOS_ISSUES_SELF" >&2
        printf '%s' "$KYKLOS_ISSUES_SELF"; return 0
    fi

    # 5) could not resolve (no token/identity, no env fallback).
    return 1
}
