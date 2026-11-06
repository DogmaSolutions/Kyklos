#!/usr/bin/env bash
# ci-access.sh — the ONE seam the Kyklos gate hooks and the ai-fix-loop use to read/act on CI state (pipelines,
# jobs, merge requests, artifacts). It PREFERS the KyklosBridge Control Tower verbs (ci_pipelines_list,
# ci_jobs_list, mr_list, ci_artifact_get, …) so a container needs NO GitLab API token, and falls back to a direct
# token request ONLY where the launcher declares the direct-token exception — never silently.
#
# WHY: the bridge holds the GitLab capability (project- and role-scoped, audited, compact), so a container needs no
# token of its own. This seam carries the hooks onto those verbs. The rule, byte for byte:
#   * PREFER the bridge verb.
#   * Fall back to a direct token ONLY where the launcher sets KYKLOS_CI_DIRECT_TOKEN=1 (the documented
#     direct-token exception) AND a token is actually available — never silently, never by default.
#   * Bridge DOWN / unreachable with no declared exception => "cannot verify" (rc 3). A gate that relies on a CI
#     verdict MUST treat rc 3 as fail-CLOSED (block / do not pass), NEVER as green.
#
# Source it; it defines functions only. bash + curl + jq.
#
#   ci_access_direct_declared          rc 0 iff KYKLOS_CI_DIRECT_TOKEN=1 (the launcher's exception flag)
#   ci_access_bridge_declared          rc 0 iff a KyklosBridge endpoint is resolvable from .mcp.json
#   ci_access_configured               rc 0 iff SOME verification mechanism exists (bridge OR direct-exception+token)
#   ci_access_mode                     prints the PRIMARY mechanism: bridge | direct | none
#   ci_access_repository_address <repo-dir>      -> the repository's origin address without credentials; rc 1 when it has none
#   ci_access_pipelines <ref> [status] [limit] [repository]   -> {"pipelines":[...]} (bridge shape); rc 3 = cannot verify, rc 5 = the bridge does not serve its CI verbs (show ci_access_capability_refusal)
#   ci_access_branch_repositories <branch> <repo-dir>...  -> the origin address of EVERY repository that holds <branch>
#                                                (local or origin/ ref), one per line; none holds it: the one origin when
#                                                there is exactly one; rc 1 otherwise (never a guess)
#   ci_access_pipeline_get <pipeline_id> [repository]   -> one pipeline object (duration_s, status, …); rc 3
#   ci_access_jobs <pipeline_id> [repository]    -> {"jobs":[...]}; rc 3
#   ci_access_merge_requests <source_branch> <state> [repository]  -> {"merge_requests":[...]}; rc 3
#   ci_access_merge_request <number> [repository]  -> one merge request object (state, auto_merge, ...); rc 3
# [repository] is a repository's origin address (ci_access_repository_address). The bridge reads the configured project
# that repository belongs to, and refuses by name one it does not serve; without it the bridge reads its DEFAULT project,
# which in a companion workspace holds the stories, not the nested source's pipelines. The choice is the bridge's: this
# file only passes the address. The direct-token exception keeps reading KYKLOS_CI_PROJECT_ID (the project it declares).
#   ci_access_artifact <job_id> <path> [repository]  -> the artifact file TEXT on stdout; rc 3
# Every reader above (and every write verb below) also returns rc 5 when the bridge answers "unknown tool" for its verb:
# the bridge does not serve its CI verbs. A caller shows ci_access_failure_reason "$rc" (the named refusal and its
# remedy) instead of a generic "cannot verify"; rc 5 falls back to the direct token only under the declared exception.
# plus write verbs for the fix loop:
#   ci_access_mr_reply <mr> <thread> <body> [repository]  -> rc 0 on success, 3 cannot-reach, 4 refused
#   ci_access_mr_thread_resolve <mr> <thread> [reply] [fix_commit] [repository]  -> rc 0 / 3 / 4
#   ci_access_job_retry <job_id> [repository]    -> rc 0 / 3 / 4
# Every pipeline, job and merge-request number belongs to one project: a caller passes the [repository] the number came
# from, or the bridge reads the number in its default project.
#
# Test seam: a test sources this file then redefines bridge_mcp_call / gitlab_curl / bridge_mcp_endpoint to drive
# the two transports offline. There is deliberately NO env "pretend the bridge is up" switch — the only way to
# exercise a path is to make that path's transport answer, so a test cannot accidentally certify a path that never ran.

_CI_ACCESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib/bridge-mcp.sh
. "$_CI_ACCESS_DIR/bridge-mcp.sh"
# shellcheck source=lib/gitlab-curl.sh
. "$_CI_ACCESS_DIR/gitlab-curl.sh"
# shellcheck source=lib/gitlab-paged.sh
. "$_CI_ACCESS_DIR/gitlab-paged.sh"   # gitlab_paged_walk: the one rule for reading a whole list
# shellcheck source=lib/json-answer.sh
. "$_CI_ACCESS_DIR/json-answer.sh"     # json_test: an empty or cut answer is never a valid one

# --- configuration (read from the environment the launcher/standards.env already provide) ----------------------
# The DIRECT path still needs an instance + project + token NAME, exactly as the pre-migration hooks did. The
# BRIDGE path needs none of these: the bridge decides project and role from its own host-side settings.
_ci_access_api()     { printf '%s' "${KYKLOS_CI_API:-}"; }
_ci_access_project() { printf '%s' "${KYKLOS_CI_PROJECT_ID:-}"; }
_ci_access_tokenv()  { printf '%s' "${KYKLOS_CI_TOKEN_ENV:-}"; }

# ci_access_direct_declared — the launcher's direct-token exception. DEFAULT-OFF: a container falls
# back to a direct token ONLY when it explicitly opts IN. The resting state is bridge-only, so a project container
# that loses its token (once project containers no longer hold a token) keeps working through the bridge and can NEVER silently revert
# to a token it should no longer hold.
ci_access_direct_declared() { [ "${KYKLOS_CI_DIRECT_TOKEN:-0}" = "1" ]; }

# ci_access_bridge_declared — a bridge endpoint is CONFIGURED for this container (regardless of whether the server
# is answering right now). This is how we tell "this container verifies through the bridge, which is momentarily
# DOWN" (fail-CLOSED) apart from "this container has no CI verification at all" (the gate stays inert, as for an
# infra/trunk repo that merges locally).
#
# Test seam (hermetic, offline — mirrors the plugin's other stub seams): when CI_ACCESS_STUB_DIR or
# CI_ACCESS_STUB_BRIDGE is set, the bridge is treated as CONFIGURED and its verbs are answered from canned files /
# forced states, so a subprocess test can prove the cannot-verify, refusal and exception-fallback paths without a
# live bridge or any network. The stub replaces only the innermost transport; all of ci-access's selection logic runs.
ci_access_bridge_declared() {
    [ -n "${CI_ACCESS_STUB_DIR:-}" ] || [ -n "${CI_ACCESS_STUB_BRIDGE:-}" ] && return 0
    bridge_mcp_endpoint >/dev/null 2>&1
}

# ci_access_direct_usable — the direct fallback is BOTH declared AND actually usable (token + instance + project).
ci_access_direct_usable() {
    ci_access_direct_declared || return 1
    local tv; tv="$(_ci_access_tokenv)"
    [ -n "$tv" ] && [ -n "$(_ci_access_api)" ] && [ -n "$(_ci_access_project)" ] || return 1
    gitlab_token_present "$tv"
}

# ci_access_configured — is there ANY way to verify? If not, the caller's gate must stay inert (fail-open), because
# the container simply has no CI to check — never a false block.
ci_access_configured() { ci_access_bridge_declared || ci_access_direct_usable; }

ci_access_mode() {
    if ci_access_bridge_declared; then printf 'bridge';
    elif ci_access_direct_usable; then printf 'direct';
    else printf 'none'; fi
}

# _ci_access_tools  — curl + jq both present? (both transports need them)
_ci_access_tools() { command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; }

# _ci_access_bridge_payload <verb> <args-json> — call a bridge verb.
#   rc 0 : verb succeeded; its payload TEXT (the compact JSON) is on stdout.
#   rc 4 : the VERB ran and REFUSED (out-of-scope / wrong-role / the CI system refused). The reason goes to stderr.
#          A verb-level refusal is a DEFINITIVE answer from the authority that owns scope — we do NOT fall back to a
#          direct token, which would circumvent the very scope the bridge enforces.
#   rc 5 : the bridge answered "unknown tool" for this verb: it does not serve its CI verbs (missing capability).
#          Like rc 3 the caller may fall back under the declared exception; otherwise the refusal is named by
#          ci_access_capability_refusal (every reader returns 5 then, never a bare "cannot verify").
#   rc 3 : the bridge is unreachable (transport error) OR a JSON-RPC protocol error (e.g. the bridge does not serve
#          this verb — an older bridge, or CI not configured in its host settings). This is "the bridge cannot serve
#          it", like down — the caller MAY fall back under the declared exception; otherwise it is cannot-verify.
# The split matters for rollout: a bridge that has not yet gained the Control Tower verbs behaves like "down" (so a
# container that still holds a token and declares the exception keeps working), while a genuine scope refusal never
# falls back to a token.
_ci_access_bridge_payload() {
    # The default is set on its own line: a braces default inside the expansion would append a stray "}" to every
    # NON-empty argument list (bash ends the expansion at the first "}"), breaking the JSON of every call with arguments.
    local verb="$1" args="${2:-}" max="${3:-20}" reply
    [ -n "$args" ] || args='{}'
    # Hermetic test seam (see ci_access_bridge_declared): force a state or answer from a canned file.
    if [ -n "${CI_ACCESS_STUB_DIR:-}" ] || [ -n "${CI_ACCESS_STUB_BRIDGE:-}" ]; then
        case "${CI_ACCESS_STUB_BRIDGE:-}" in
            down|unreachable) return 3 ;;
            unknown-tool) return 5 ;;
            refuse) printf 'stub: refused (out-of-scope or wrong role)\n' >&2; return 4 ;;
        esac
        if [ -n "${CI_ACCESS_STUB_DIR:-}" ] && [ -f "$CI_ACCESS_STUB_DIR/$verb.json" ]; then
            cat "$CI_ACCESS_STUB_DIR/$verb.json"; return 0
        fi
        return 3   # a configured-but-silent bridge behaves as DOWN for an unstubbed verb
    fi
    ci_access_bridge_declared || return 3
    reply="$(bridge_mcp_call "$verb" "$args" "$max")" || return 3
    [ -n "$reply" ] || return 3
    # A JSON-RPC protocol error (.error) = the bridge could not dispatch the verb at all (unknown tool / server
    # error) -> treat as "cannot serve", like down (rc 3). Only a verb RESULT with isError=true is a scope/role
    # refusal (rc 4, no fallback).
    if ! printf '%s' "$reply" | json_test '(.error != null) | not'; then
        printf '%s' "$reply" | jq -r '.error.message // "bridge error"' >&2
        return 3
    fi
    if bridge_mcp_is_error "$reply"; then
        bridge_mcp_text "$reply" >&2
        return 4
    fi
    local text; text="$(bridge_mcp_text "$reply")"
    # The bridge answers a verb it does not serve (its CI section is missing) as plain text, not as an error: name
    # that as a missing capability (rc 5) instead of passing the sentence on as data. Anything else is data.
    case "$text" in
        "unknown tool: $verb"*) return 5 ;;
    esac
    printf '%s' "$text"
    return 0
}

# ci_access_capability_refusal — the one sentence every caller shows for rc 5 (the bridge does not serve the CI verbs).
ci_access_capability_refusal() {
    printf '%s' "the bridge does not serve its CI verbs (it was started without its ContinuousIntegration section): relaunch the project from the launcher, and if it still happens check that the launch configuration does not carry the CI off-switch (KYKLOS_BRIDGE_CI_OFF_REASON)"
}

# ci_access_failure_reason <rc> — prints the capability refusal for rc 5, nothing for any other code.
ci_access_failure_reason() { [ "${1:-}" = "5" ] && ci_access_capability_refusal; return 0; }

# _ci_access_direct_json <relative-path> — a GET through the direct token (only under the exception). Prints the raw
# GitLab JSON on 2xx; rc 3 on any failure (unconfigured / non-2xx / transport). Never falls open to anonymous.
_ci_access_direct_json() {
    ci_access_direct_usable || return 3
    _ci_access_tools || return 3
    local api pid tv resp code body
    api="$(_ci_access_api)"; pid="$(_ci_access_project)"; tv="$(_ci_access_tokenv)"
    resp="$(gitlab_curl "$tv" -s --max-time 12 -w $'\n%{http_code}' "$api/projects/$pid/$1" 2>/dev/null || true)"
    code="$(printf '%s' "$resp" | tail -n1)"
    body="$(printf '%s' "$resp" | sed '$d')"
    [ "$code" = "200" ] || return 3
    printf '%s' "$body"
    return 0
}

# _ci_access_uri <value> — URL-encode a path/query component (branch names may carry / & # ?). Falls back to the raw
# value only if jq is unavailable (the callers also validate shape).
_ci_access_uri() { printf '%s' "$1" | jq -sRr @uri 2>/dev/null || printf '%s' "$1"; }

# ---- reads ---------------------------------------------------------------------------------------------------

# ci_access_repository_address <repo-dir> -> the origin address of the repository at <repo-dir>, as data for the bridge
# to choose the project from. rc 1 when the repository has no origin.
# [CySec] The credentials part of an https/ssh address (user:token@) is dropped before the address leaves this
# function, so a token embedded in an origin never reaches the bridge, an answer or a log. CWE-522 Insufficiently
# Protected Credentials.
ci_access_repository_address() {
    local url rest hostpart
    url="$(git -C "${1:-.}" remote get-url origin 2>/dev/null)" || return 1
    [ -n "$url" ] || return 1
    # [CySec] A query string or fragment may carry a token too (CWE-598): it is dropped with the credentials.
    url="${url%%\?*}"; url="${url%%#*}"
    case "$url" in
        *://*)
            rest="${url#*://}"; hostpart="${rest%%/*}"
            case "$hostpart" in
                *@*) case "$rest" in */*) rest="${hostpart##*@}/${rest#*/}" ;; *) rest="${hostpart##*@}" ;; esac
                     url="${url%%://*}://$rest" ;;
            esac ;;
    esac
    printf '%s' "$url"
}

# _ci_access_own_repository <dir> -> rc 0 when <dir> is the top level of its own git repository (a plain folder inside
# another repository is not: git would answer for the outer one, and its origin would be counted twice).
_ci_access_own_repository() {
    local top real
    top="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" || return 1
    real="$(cd "$1" 2>/dev/null && pwd -P)" || return 1
    [ "$(cd "$top" 2>/dev/null && pwd -P)" = "$real" ]
}

# ci_access_branch_repositories <branch> <repo-dir>... -> the origin address (ci_access_repository_address) of EVERY
# <repo-dir> that holds <branch> as a local branch or an origin/ remote-tracking ref, one per line, each address once.
# When none holds it (a branch deleted after its merge), the one origin of the given directories when there is exactly
# one (a single-repository project: no doubt which project); with several candidates nothing is guessed. rc 1 when
# nothing is printed. A companion passes its own directory and its nested source directory; a caller that judges a
# branch (a gate) must judge EVERY printed repository, because the same branch name may live in both, and refuse on
# rc 1 rather than read a default project.
ci_access_branch_repositories() {
    local br="${1:-}" d addr holders="" origins=""; shift
    for d in "$@"; do
        [ -d "$d" ] && _ci_access_own_repository "$d" || continue
        addr="$(ci_access_repository_address "$d")" || continue
        printf '%s\n' "$origins" | grep -cxF -- "$addr" >/dev/null || origins="${origins:+$origins
}$addr"
        if [ -n "$br" ] && { git -C "$d" rev-parse -q --verify "refs/heads/$br" >/dev/null 2>&1 \
                             || git -C "$d" rev-parse -q --verify "refs/remotes/origin/$br" >/dev/null 2>&1; }; then
            printf '%s\n' "$holders" | grep -cxF -- "$addr" >/dev/null || holders="${holders:+$holders
}$addr"
        fi
    done
    if [ -n "$holders" ]; then printf '%s\n' "$holders"; return 0; fi
    if [ -n "$origins" ] && [ "$(printf '%s\n' "$origins" | grep -c .)" = 1 ]; then printf '%s\n' "$origins"; return 0; fi
    return 1
}

# _ci_access_with_repository <args-json> <repository> -> the arguments with "repository" added when one is given.
_ci_access_with_repository() {
    if [ -n "${2:-}" ]; then printf '%s' "$1" | jq -c --arg r "$2" '. + {repository:$r}'; else printf '%s' "$1"; fi
}

# ci_access_pipelines <ref> [status] [limit] [repository] -> {"pipelines":[...]} in the bridge verb's shape.
# The direct path wraps GitLab's raw array into the same shape and normalises .web_url -> .url so one jq works on both.
ci_access_pipelines() {
    local ref="${1:-}" status="${2:-}" limit="${3:-20}" repository="${4:-}"
    _ci_access_tools || return 3
    local args; args="$(jq -cn --arg r "$ref" --arg s "$status" --arg l "$limit" \
        '{limit:$l} + (if $r=="" then {} else {ref:$r} end) + (if $s=="" then {} else {status:$s} end)')"
    args="$(_ci_access_with_repository "$args" "$repository")"
    local out rc
    out="$(_ci_access_bridge_payload ci_pipelines_list "$args")"; rc=$?
    case "$rc" in
        0) printf '%s' "$out"; return 0 ;;
        4) return 3 ;;   # refusal => cannot verify (never a silent direct fallback)
        5) ci_access_direct_usable || return 5 ;;
    esac
    # bridge down (rc 3) — fall back ONLY under the declared exception.
    local q="pipelines?per_page=$limit"
    [ -n "$ref" ] && q="$q&ref=$(_ci_access_uri "$ref")"
    [ -n "$status" ] && q="$q&status=$(_ci_access_uri "$status")"
    local raw; raw="$(_ci_access_direct_json "$q")" || return 3
    printf '%s' "$raw" | json_test 'type=="array"' || return 3
    printf '%s' "$raw" | jq -c '{pipelines: [ .[] | (. + {url: (.web_url // .url)}) ]}'
}

# ci_access_pipeline_get <pipeline_id> [repository] -> one pipeline object (incl. duration_s / status).
ci_access_pipeline_get() {
    local id="${1:-}" repository="${2:-}"; _ci_access_tools || return 3
    [ -n "$id" ] || return 3
    local out rc
    out="$(_ci_access_bridge_payload ci_pipeline_get "$(_ci_access_with_repository "$(jq -cn --arg p "$id" '{pipeline:$p}')" "$repository")")"; rc=$?
    case "$rc" in
        0) printf '%s' "$out"; return 0 ;;
        4) return 3 ;;
        5) ci_access_direct_usable || return 5 ;;
    esac
    local raw; raw="$(_ci_access_direct_json "pipelines/$id")" || return 3
    # Normalise GitLab's `duration` (seconds) -> `duration_s` so one jq works on both transports.
    printf '%s' "$raw" | json_test 'type=="object"' || return 3
    printf '%s' "$raw" | jq -c '. + {duration_s: (.duration // null), url: (.web_url // .url)}'
}

# ci_access_jobs <pipeline_id> [repository] -> {"jobs":[...]} (bridge shape: each job has name,status,id,…). The direct path maps
# GitLab's raw array into the same shape, keeping name,status,id and web_url (bridge omits the url — callers tolerate that).
ci_access_jobs() {
    local id="${1:-}" repository="${2:-}"; _ci_access_tools || return 3
    [ -n "$id" ] || return 3
    local out rc
    out="$(_ci_access_bridge_payload ci_jobs_list "$(_ci_access_with_repository "$(jq -cn --arg p "$id" '{pipeline:$p}')" "$repository")")"; rc=$?
    case "$rc" in
        0) printf '%s' "$out"; return 0 ;;
        4) return 3 ;;
        5) ci_access_direct_usable || return 5 ;;
    esac
    # Every page (the shared reader): a pipeline with more than 100 jobs must not lose the later ones.
    local raw; raw="$(gitlab_paged_walk _ci_access_direct_json "pipelines/$id/jobs")" || return 3
    printf '%s' "$raw" | json_test 'type=="array"' || return 3
    printf '%s' "$raw" | jq -c '{jobs: [ .[] | {id,name,status,web_url} ]}'
}

# ci_access_merge_requests <source_branch> <state> [repository] -> {"merge_requests":[...]}.
ci_access_merge_requests() {
    local br="${1:-}" state="${2:-opened}" repository="${3:-}"; _ci_access_tools || return 3
    local out rc
    out="$(_ci_access_bridge_payload mr_list "$(_ci_access_with_repository "$(jq -cn --arg b "$br" --arg s "$state" '{source_branch:$b,state:$s,limit:"20"}')" "$repository")")"; rc=$?
    case "$rc" in
        0) printf '%s' "$out"; return 0 ;;
        4) return 3 ;;
        5) ci_access_direct_usable || return 5 ;;
    esac
    local raw; raw="$(_ci_access_direct_json "merge_requests?source_branch=$(_ci_access_uri "$br")&state=$(_ci_access_uri "$state")&per_page=20")" || return 3
    printf '%s' "$raw" | json_test 'type=="array"' || return 3
    # Normalise GitLab's `iid` -> `merge_request` so one jq field works on both.
    printf '%s' "$raw" | jq -c '{merge_requests: [ .[] | (. + {merge_request: (.merge_request // .iid)}) ]}'
}

# ci_access_merge_request <number> [repository] -> one merge request in the bridge verb's shape (merge_request, state, auto_merge,
# target_branch, ...). The direct path maps GitLab's raw object into the same field names.
ci_access_merge_request() {
    local n="${1:-}" repository="${2:-}"; _ci_access_tools || return 3
    printf '%s' "$n" | grep -cxE '[0-9]+' >/dev/null || return 3
    local out rc
    out="$(_ci_access_bridge_payload mr_get "$(_ci_access_with_repository "$(jq -cn --arg m "$n" '{merge_request:$m}')" "$repository")")"; rc=$?
    case "$rc" in
        0) printf '%s' "$out"; return 0 ;;
        4) return 3 ;;
        5) ci_access_direct_usable || return 5 ;;
    esac
    local raw; raw="$(_ci_access_direct_json "merge_requests/$n")" || return 3
    printf '%s' "$raw" | json_test 'type=="object"' || return 3
    printf '%s' "$raw" | jq -c '. + {merge_request: (.merge_request // .iid), auto_merge: (.auto_merge // .merge_when_pipeline_succeeds // false)}'
}

# ci_access_artifact <job_id> <path> [repository] -> the artifact file TEXT on stdout.
ci_access_artifact() {
    local job="${1:-}" path="${2:-}" repository="${3:-}"; _ci_access_tools || return 3
    [ -n "$job" ] && [ -n "$path" ] || return 3
    local out rc
    out="$(_ci_access_bridge_payload ci_artifact_get "$(_ci_access_with_repository "$(jq -cn --arg j "$job" --arg p "$path" '{job:$j,path:$p}')" "$repository")")"; rc=$?
    case "$rc" in
        0) printf '%s' "$out" | jq -r '.content // ""'; return 0 ;;
        4) return 3 ;;
        5) ci_access_direct_usable || return 5 ;;
    esac
    # Direct: the artifact file comes back as its RAW bytes (not wrapped), so return it verbatim.
    ci_access_direct_usable || return 3
    _ci_access_tools || return 3
    local api pid tv resp code body
    api="$(_ci_access_api)"; pid="$(_ci_access_project)"; tv="$(_ci_access_tokenv)"
    resp="$(gitlab_curl "$tv" -s --max-time 20 -w $'\n%{http_code}' "$api/projects/$pid/jobs/$job/artifacts/$path" 2>/dev/null || true)"
    code="$(printf '%s' "$resp" | tail -n1)"
    body="$(printf '%s' "$resp" | sed '$d')"
    [ "$code" = "200" ] || return 3
    printf '%s' "$body"
    return 0
}

# ---- writes (the fix loop) -----------------------------------------------------------------------------------
# A write returns: rc 0 success · rc 4 the bridge/CI REFUSED (reason on stderr) · rc 3 cannot reach (bridge down &
# no declared exception). A gate/loop must NOT treat rc 3 or rc 4 as "done".

ci_access_mr_reply() {
    local mr="$1" thread="$2" body="$3" repository="${4:-}" rc
    _ci_access_bridge_payload mr_reply "$(_ci_access_with_repository "$(jq -cn --arg m "$mr" --arg t "$thread" --arg b "$body" '{merge_request:$m,thread:$t,body:$b}')" "$repository")" >/dev/null; rc=$?
    { [ "$rc" = 3 ] || { [ "$rc" = 5 ] && ci_access_direct_usable; }; } || return "$rc"
    _ci_access_direct_write POST "merge_requests/$mr/discussions/$thread/notes" "body=$body"
}

ci_access_mr_thread_resolve() {
    local mr="$1" thread="$2" reply="${3:-}" fix="${4:-}" repository="${5:-}" rc
    local args; args="$(jq -cn --arg m "$mr" --arg t "$thread" --arg r "$reply" --arg f "$fix" \
        '{merge_request:$m,thread:$t,resolved:"true"} + (if $r=="" then {} else {reply:$r} end) + (if $f=="" then {} else {fix_commit:$f} end)')"
    _ci_access_bridge_payload mr_thread_resolve "$(_ci_access_with_repository "$args" "$repository")" >/dev/null; rc=$?
    { [ "$rc" = 3 ] || { [ "$rc" = 5 ] && ci_access_direct_usable; }; } || return "$rc"
    # Direct fallback: honour the review-integrity contract — when a reply / fix reference is given, POST it FIRST
    # (an AI-review or CI thread is resolved only WITH the fix reference), then resolve. If the reply cannot be
    # posted, do NOT resolve (never resolve a finding thread without its fix note).
    local note=""
    [ -n "$reply" ] && note="$reply"
    [ -n "$fix" ] && note="${note:+$note }Fixed in ${fix}."
    if [ -n "$note" ]; then
        _ci_access_direct_write POST "merge_requests/$mr/discussions/$thread/notes" "body=$note" || return "$?"
    fi
    _ci_access_direct_write PUT "merge_requests/$mr/discussions/$thread?resolved=true" ""
}

ci_access_job_retry() {
    local job="$1" repository="${2:-}" rc
    _ci_access_bridge_payload ci_job_retry "$(_ci_access_with_repository "$(jq -cn --arg j "$job" '{job:$j}')" "$repository")" >/dev/null; rc=$?
    { [ "$rc" = 3 ] || { [ "$rc" = 5 ] && ci_access_direct_usable; }; } || return "$rc"
    _ci_access_direct_write POST "jobs/$job/retry" ""
}

# _ci_access_direct_write <method> <relpath> <form-body> — a direct write, ONLY under the declared exception.
_ci_access_direct_write() {
    ci_access_direct_usable || return 3
    _ci_access_tools || return 3
    local method="$1" path="$2" form="$3" api pid tv code
    api="$(_ci_access_api)"; pid="$(_ci_access_project)"; tv="$(_ci_access_tokenv)"
    local -a args=(-s -o /dev/null -w '%{http_code}' --max-time 20 -X "$method")
    [ -n "$form" ] && args+=(--data-urlencode "$form")
    code="$(gitlab_curl "$tv" "${args[@]}" "$api/projects/$pid/$path" 2>/dev/null || true)"
    case "$code" in 2*) return 0 ;; *) return 4 ;; esac
}
