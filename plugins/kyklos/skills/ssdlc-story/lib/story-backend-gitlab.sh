#!/usr/bin/env bash
# story-backend-gitlab.sh — GitLab-native impl of the story-backend contract.
#
# Stories = Issues in $STORY_GITLAB_PROJECT; the story number IS the issue iid (id == iid, no mapping). The issue
# DESCRIPTION carries the canonical requirements.md markdown (the `- **Status:**` … bullets + body), so the READ
# functions materialize the description into a temp requirements.md and REUSE the FS helpers (story_get_field,
# story_emit_row) verbatim — the BACKLOG shape is identical. Done also honours the native CLOSED state.
#
# Writes map a story onto GitLab: the issue (title + description), scoped labels (status::, type::, kind::,
# ssdlc:phase:: — the names are listed in _GL_KNOWN_LABELS below), the epic's milestone, a native close on Done, and
# the Proof as a note.
#
# ALL HTTP goes through ONE seam, gl_api(), so tests stub it offline (STORY_GL_STUB_DIR). bash + curl + jq.

BACKEND_GL_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../hooks/lib/control-switch.sh
. "$BACKEND_GL_HERE/../../../hooks/lib/control-switch.sh" 2>/dev/null || true   # kyklos_control_off: the one control-switch reader
# Each library below must load completely. A failure is RECORDED in STORY_LIB_LOAD_FAILED and loading goes on as
# before, so the hooks that source this seam keep their behaviour; the story tool refuses to run when it is set.
# shellcheck source=../../../hooks/lib/require-lib.sh
. "$BACKEND_GL_HERE/../../../hooks/lib/require-lib.sh" \
  || { require_lib() { . "$1"; }; STORY_LIB_LOAD_FAILED="${STORY_LIB_LOAD_FAILED:+$STORY_LIB_LOAD_FAILED, }require-lib.sh"; }
# shellcheck source=story-lib.sh
require_lib "$BACKEND_GL_HERE/story-lib.sh" || STORY_LIB_LOAD_FAILED="${STORY_LIB_LOAD_FAILED:+$STORY_LIB_LOAD_FAILED, }story-lib.sh"
# The routing cross-check lives in the SINGLE resolver (hooks/lib/repo-role.sh); source it so
# backend_new can refuse creating a story in the PUBLIC ARTIFACT project. It ships in this SAME plugin, so its
# absence is a broken install — NOT a normal condition. [no-fail-open] We do NOT silently skip:
# a load FAILURE is surfaced here, and an ABSENT resolver is a HARD failure at create time in backend_new (below).
_RR_LIB="$BACKEND_GL_HERE/../../../hooks/lib/repo-role.sh"
# shellcheck source=/dev/null
if [ -f "$_RR_LIB" ]; then . "$_RR_LIB" || printf 'story: gitlab backend: routing resolver %s FAILED to load (routing check will hard-fail at create).\n' "$_RR_LIB" >&2; fi
# the shared kyklos-version resolver, so every story issue we create or mutate is stamped with a
# `kyklos:version::<v>` label. Best-effort (labelling nicety) — safe to double-source (guarded internally).
# the SINGLE "is this issue an adopted story" definition (story label AND the tool-written metadata header).
_SA_LIB="$BACKEND_GL_HERE/../../../hooks/lib/story-adoption.sh"
# shellcheck source=/dev/null
[ -f "$_SA_LIB" ] && { . "$_SA_LIB" || printf 'story: gitlab backend: adoption helper %s FAILED to load (adoption checks will refuse).\n' "$_SA_LIB" >&2; }
_BV_LIB="$BACKEND_GL_HERE/../../../hooks/lib/kyklos-version.sh"
# shellcheck source=/dev/null
[ -f "$_BV_LIB" ] && { . "$_BV_LIB" 2>/dev/null || true; }

# --- config (the `story` CLI parses the STORY_* knobs from .claude/standards.env before sourcing us; else env) ---
require_lib "$BACKEND_GL_HERE/../../../hooks/lib/gitlab-api-base.sh" || STORY_LIB_LOAD_FAILED="${STORY_LIB_LOAD_FAILED:+$STORY_LIB_LOAD_FAILED, }gitlab-api-base.sh"   # gitlab_api_base: the one API-base resolver (no default)
_GL_API="$(gitlab_api_base STORY_GITLAB_API 2>/dev/null)"
_GL_PID="${STORY_GITLAB_PROJECT:-}"
require_lib "$BACKEND_GL_HERE/../../../hooks/lib/gitlab-paged.sh" || STORY_LIB_LOAD_FAILED="${STORY_LIB_LOAD_FAILED:+$STORY_LIB_LOAD_FAILED, }gitlab-paged.sh"   # gitlab_paged_walk: the one rule for reading a whole list
require_lib "$BACKEND_GL_HERE/../../../hooks/lib/json-answer.sh" json_test json_read || STORY_LIB_LOAD_FAILED="${STORY_LIB_LOAD_FAILED:+$STORY_LIB_LOAD_FAILED, }json-answer.sh"   # json_test / json_read: an empty or cut answer is never valid
require_lib "$BACKEND_GL_HERE/../../../hooks/lib/gitlab-curl.sh" || STORY_LIB_LOAD_FAILED="${STORY_LIB_LOAD_FAILED:+$STORY_LIB_LOAD_FAILED, }gitlab-curl.sh"   # gitlab_curl / gitlab_token_present: the token never leaves the helper
# The NAME of the setting that holds the token (never the value): the configured one, else GitLab CI's GITLAB_TOKEN.
gitlab_pick_token _GL_TOKNAME "${STORY_GITLAB_TOKEN_ENV:-}" GITLAB_TOKEN || true

# Story marker label. The backend enumerates ONLY issues carrying this label and STAMPS it on every story it
# creates — so a story-backend project may hold NON-story issues (coordination, bug reports) WITHOUT them being
# mis-read as stories (they lack the label). Override via STORY_GITLAB_LABEL. (A project migrated before this
# existed must back-fill the label on its story-issues, or the backend will find none.)
_GL_STORY_LABEL="${STORY_GITLAB_LABEL:-story}"

_GL_CACHE="$(mktemp -d "${TMPDIR:-/tmp}/story-gl.XXXXXX")"
trap '[ -n "${_GL_CACHE:-}" ] && rm -rf "$_GL_CACHE" 2>/dev/null' EXIT

# A transport failure is one where curl could not complete the exchange with GitLab (DNS, connect, timeout, TLS,
# empty or broken reply), as opposed to GitLab answering with an error. gl_api returns 3 for it, 1 for an HTTP error.
_GL_TRANSPORT_EXITS=" 5 6 7 28 35 52 55 56 "

# _gl_retry_attempts -> the total number of attempts for a transport failure (STORY_GITLAB_RETRIES, default 3).
_gl_retry_attempts() {
    local n="${STORY_GITLAB_RETRIES:-3}"
    [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] || n=3
    printf '%s' "$n"
}

# _gl_retryable <METHOD> <curl-exit> -> rc 0 when the failed request may be sent again. Reads: any transport failure.
# Writes: only when the connection was never made (6 = host not resolved, 7 = connection refused); a write that
# timed out or lost its reply may already have been applied, so repeating it could duplicate the change.
_gl_retryable() {
    case "$_GL_TRANSPORT_EXITS" in *" $2 "*) ;; *) return 1 ;; esac
    [ "$1" = GET ] && return 0
    [ "$2" = 6 ] || [ "$2" = 7 ]
}

# shellcheck source=../../../hooks/lib/coordination-read.sh
require_lib "$BACKEND_GL_HERE/../../../hooks/lib/coordination-read.sh" || STORY_LIB_LOAD_FAILED="${STORY_LIB_LOAD_FAILED:+$STORY_LIB_LOAD_FAILED, }coordination-read.sh"   # coordination_read / coordination_read_fallback: the bridge reads

# _gl_has_token -> rc 0 when the story tool can read a GitLab token of its own. Decided once per command (the answer is
# kept in the command's cache folder, so the many subshells that call gl_api never ask the bridge again).
_gl_has_token() {
    [ "${STORY_GL_STUB_NO_TOKEN:-}" = 1 ] && [ -n "${STORY_GL_STUB_DIR:-}" ] && return 1
    local f="$_GL_CACHE/token-state"
    if [ ! -s "$f" ]; then
        if [ -n "$_GL_TOKNAME" ] && gitlab_token_present "$_GL_TOKNAME"; then printf yes > "$f"; else printf no > "$f"; fi
    fi
    [ "$(cat "$f" 2>/dev/null)" = yes ]
}

# _gl_note_direct_use -> announce, once per command, that the story tool still reads GitLab with the container's own
# token: one line on the direct-token fallback ledger, so a project goes host-only only once no command needs it.
_gl_note_direct_use() {
    [ -e "$_GL_CACHE/direct-use-noted" ] && return 0
    : > "$_GL_CACHE/direct-use-noted"
    coordination_read_fallback story-tool "the story tool reads GitLab with the container's own token"
}

# _gl_bridge_resource <path> -> "<resource>\t<iid>\t<sha>" for the bridge's story_read verb, or nothing when the path is
# not a read the verb serves.
_gl_bridge_resource() {
    local p="${1%%\?*}"
    case "$p" in
        "") printf 'project\t\t' ;;
        issues|milestones|labels|merge_requests) printf '%s\t\t' "$p" ;;
        issues/*/notes) printf 'issue_notes\t%s\t' "$(_gl_path_number "$p")" ;;
        issues/*/resource_state_events) printf 'issue_state_events\t%s\t' "$(_gl_path_number "$p")" ;;
        issues/*/resource_label_events) printf 'issue_label_events\t%s\t' "$(_gl_path_number "$p")" ;;
        issues/*) printf 'issue\t%s\t' "${p#issues/}" ;;
        merge_requests/*) printf 'merge_request\t%s\t' "${p#merge_requests/}" ;;
        repository/commits/*/refs) p="${p#repository/commits/}"; printf 'commit_refs\t\t%s' "${p%/refs}" ;;
    esac
}
_gl_path_number() { local p="${1#*/}"; printf '%s' "${p%%/*}"; }

# _gl_bridge_get <path(+query)> -> what gl_api GET answers, read through the bridge's story_read verb with the bridge's
# own token: the body on stdout and rc 0 for a 2xx answer, the body and rc 1 for a GitLab refusal (such as 404), '{}'
# and rc 3 when the bridge cannot be reached or cannot reach GitLab. A path the verb does not serve is rc 1, loud.
_gl_bridge_get() {
    local path="$1" res query="" args text rc status
    res="$(_gl_bridge_resource "$path")"
    if [ -z "$res" ]; then
        echo "[story] gl_api: GET $path has no bridge read, and this container has no GitLab token of its own; nothing was read." >&2
        printf '{}'; return 1
    fi
    case "$path" in *\?*) query="${path#*\?}" ;; esac
    args="$(jq -cn --arg p "$_GL_PID" --arg r "${res%%	*}" --arg rest "${res#*	}" --arg q "$query" \
        '{project:$p, resource:$r} + (($rest | split("\t")) as $x | {iid:$x[0], sha:$x[1]} | with_entries(select(.value != "")))
         + (if $q == "" then {} else {query:$q} end)')"
    text="$(coordination_read story_read "$args")"; rc=$?
    case "$rc" in
        0) ;;
        4) echo "[story] gl_api: GET $path - the bridge has no story_read verb, and this container has no GitLab token of its own; nothing was read." >&2
           printf '{}'; return 3 ;;
        *) echo "[story] gl_api: GET $path - the bridge could not answer (see above); nothing was read." >&2
           printf '%s' "$rc" > "$_GL_CACHE/last-network-error" 2>/dev/null
           printf '{}'; return 3 ;;
    esac
    status="$(printf '%s' "$text" | jq -r '.status // empty' 2>/dev/null)"
    printf '%s' "$text" | jq -c '.body' 2>/dev/null
    case "$status" in
        2*) return 0 ;;
        *) echo "[story] gl_api: GET $path - HTTP ${status:-?} (through the bridge): $(printf '%s' "$text" | jq -r '.body.message // ""' 2>/dev/null | head -c 160)" >&2; return 1 ;;
    esac
}

# backend_attach <file> -> uploads one proof report to the story project and prints the markdown link to cite. The bridge
# uploads it with its own token (story_upload); a bridge without that verb makes it upload with the container's token,
# announced on the direct-token fallback ledger. rc 0 uploaded; 1 refused or failed (the reason on stderr).
# [RiskMitigation RA-01] a proof report is attached without a GitLab token in the container.
backend_attach() {
    local file="$1" name b64 args text rc
    [ -n "$_GL_PID" ] || { echo "[story] attach: STORY_GITLAB_PROJECT is unset - no project to attach the report to" >&2; return 1; }
    name="$(basename -- "$file")"
    b64="$(mktemp "${TMPDIR:-/tmp}/story-attach.XXXXXX")" || return 1
    story_tmp_register "$b64"
    # The content reaches jq from a file, never as a command-line argument (one argument is capped at 128 KiB).
    base64 -w0 < "$file" > "$b64" || { rm -f "$b64"; return 1; }
    args="$(jq -cn --arg p "$_GL_PID" --arg n "$name" --rawfile c "$b64" '{project:$p, filename:$n, content:$c}')"; rm -f "$b64"
    text="$(coordination_read story_upload "$args")"; rc=$?
    case "$rc" in
        0) printf '%s' "$text" | json_read '.markdown' || { echo "[story] attach: the bridge answered no link: ${text:0:200}" >&2; return 1; }
           return 0 ;;
        4) : ;;   # an older bridge: the transition path below
        *) echo "[story] attach: the bridge could not upload '$name' (see above); nothing was attached." >&2; return 1 ;;
    esac
    [ -n "$_GL_TOKNAME" ] && gitlab_token_present "$_GL_TOKNAME" \
        || { echo "[story] attach: the bridge has no story_upload verb and this container has no GitLab token; nothing was attached." >&2; return 1; }
    coordination_read_fallback story-attach "the bridge has no story_upload verb"
    text="$(gitlab_request "$_GL_TOKNAME" -s --max-time 60 -F "file=@$file" "$_GL_API/projects/$_GL_PID/uploads" 2>/dev/null)" \
        || { echo "[story] attach: the upload of '$name' failed; nothing was attached." >&2; return 1; }
    printf '%s' "$text" | json_read '.markdown' || { echo "[story] attach: GitLab answered no link: ${text:0:200}" >&2; return 1; }
}

# backend_last_network_error -> the curl exit code of the last transport failure in this process ("" when none).
backend_last_network_error() { cat "$_GL_CACHE/last-network-error" 2>/dev/null || true; }

# gl_api <METHOD> <path(+query)> [k=v ...] -> JSON on stdout. The single HTTP seam; each k=v becomes a
# --data-urlencode field. Test stub: STORY_GL_STUB_DIR -> read a canned file named by the sanitised "METHOD path",
# and APPEND the call to _writes.log (non-GET) or _reads.log (GET) so tests can assert the exact calls.
_gl_stub_key() { printf '%s %s' "$1" "$2" | tr -c 'A-Za-z0-9._-' '_'; }
gl_api() {
    local method="$1" path="$2"; shift 2
    # No token of its own (an API token kept on the host): reads go through the bridge, and a write is refused here,
    # loudly; in story-stack mode 'on' the writes never reach this seam, they go to the bridge's story verbs.
    # [RiskMitigation RA-01] the story tool needs no API-capable token in the container.
    # Test seam: under the canned-API stub, STORY_GL_STUB_NO_TOKEN=1 plays a container without a token.
    if [ -n "${STORY_GL_STUB_DIR:-}" ] && [ "${STORY_GL_STUB_NO_TOKEN:-}" != 1 ]; then :
    elif [ -n "$_GL_PID" ] && ! _gl_has_token; then
        if [ "$method" = GET ]; then _gl_bridge_get "$path"; return $?; fi
        echo "[story] gl_api: $method $path refused - this container has no GitLab token of its own, so the story tool writes only through the bridge's story verbs (story-stack mode 'on' for this project). Nothing was changed." >&2
        printf '{}'; return 1
    fi
    if [ -n "${STORY_GL_STUB_DIR:-}" ]; then
        [ "$method" = "GET" ] && printf 'GET %s\n' "$path" >> "$STORY_GL_STUB_DIR/_reads.log"
        [ "$method" != "GET" ] && printf '%s %s | %s\n' "$method" "$path" "$*" >> "$STORY_GL_STUB_DIR/_writes.log"
        local key; key="$(_gl_stub_key "$method" "$path")"
        # A transient failure: a canned '<key>.fail' answers ONE request with its body and rc 1 (an HTTP error such as a
        # 500), then is spent, so the next request for the same path succeeds.
        if [ -f "$STORY_GL_STUB_DIR/${key}.fail" ]; then
            cat "$STORY_GL_STUB_DIR/${key}.fail"; rm -f -- "$STORY_GL_STUB_DIR/${key}.fail"; return 1
        fi
        if [ -f "$STORY_GL_STUB_DIR/${key}.json" ]; then cat "$STORY_GL_STUB_DIR/${key}.json"; return 0; fi
        # A paged read (the shared reader asks for '...per_page=100&page=<n>'): a test that canned one answer for the
        # list without the paging keys serves it as page 1, and the pages after it are empty. A test that cans
        # '...page=<n>' files exercises the real multi-page walk.
        case "$path" in
            *per_page=100\&page=1)
                local bare="${path%per_page=100&page=1}"
                for bare in "${bare}per_page=100" "${bare%[?&]}"; do
                    key="$(_gl_stub_key "$method" "$bare")"
                    [ -f "$STORY_GL_STUB_DIR/${key}.json" ] && { cat "$STORY_GL_STUB_DIR/${key}.json"; return 0; }
                done ;;
            *per_page=100\&page=[0-9]*) printf '[]'; return 0 ;;
        esac
        printf '{}'
        return 0
    fi
    # [no-fail-open] NEVER mask a transport/HTTP failure as a normal-looking body: `curl ... || printf '{}'` returns 0 even
    # when curl FAILED, and a 401/404 (which curl -s treats as success) becomes an error body indistinguishable from real
    # data. So: surface the real condition on stderr AND return non-zero, so callers (and the user) SEE the failure. The body
    # is still emitted so a caller that inspects it can diagnose; the non-zero rc is the signal.
    [ -n "$_GL_API" ] || { gitlab_api_base STORY_GITLAB_API >/dev/null; printf '{}'; return 1; }
    [ -n "$_GL_PID" ] || { echo "[story] gl_api: STORY_GITLAB_PROJECT unset — no target project for $method $path" >&2; printf '{}'; return 1; }
    _gl_note_direct_use
    { [ -n "$_GL_TOKNAME" ] || [ "$method" = GET ]; } || { echo "[story] gl_api: no API token (STORY_GITLAB_TOKEN_ENV='${STORY_GITLAB_TOKEN_ENV:-}'/GITLAB_TOKEN unset) for $method $path — the write cannot authenticate" >&2; printf '{}'; return 1; }
    local args=(); local kv; for kv in "$@"; do args+=(--data-urlencode "$kv"); done
    local _resp _code _rc _try=1 _max
    _max="$(_gl_retry_attempts)"
    while :; do
        _resp="$(gitlab_request "$_GL_TOKNAME" -s -w '\n%{http_code}' --max-time 15 -X "$method" "${args[@]}" \
             "$_GL_API/projects/$_GL_PID/$path" 2>/dev/null)"; _rc=$?
        [ "$_rc" -ne 0 ] && _gl_retryable "$method" "$_rc" && [ "$_try" -lt "$_max" ] || break
        echo "[story] gl_api: $method $path — network error (curl exit $_rc), retrying ($_try/$_max)" >&2
        sleep "$_try"; _try=$((_try + 1))
    done
    _code="${_resp##*$'\n'}"; _resp="${_resp%$'\n'*}"
    if [ "$_rc" -ne 0 ]; then
        echo "[story] gl_api: $method $path — request FAILED (curl exit $_rc: network/timeout/DNS) after $_try attempt(s)" >&2
        printf '%s' "$_rc" > "$_GL_CACHE/last-network-error" 2>/dev/null
        printf '{}'; return 3
    fi
    case "$_code" in
        2*) printf '%s' "$_resp" ;;
        *)  echo "[story] gl_api: $method $path — HTTP $_code (not 2xx): $(printf '%s' "$_resp" | tr '\n' ' ' | head -c 160)" >&2; printf '%s' "$_resp"; return 1 ;;
    esac
}

# --- internal helpers ---------------------------------------------------------------------------

# [no-fail-open] A MUTATING call is NOT fire-and-forget. gl_api now returns non-zero on any transport/HTTP failure;
# _gl_write runs it and, on failure, emits a clear "the change did NOT take" note (the gl_api error precedes it) and
# returns non-zero — so a failed write is surfaced instead of the CLI reporting phantom success while GitLab is
# unchanged. Success is silent (the normal path). Callers that need to abort can `|| return 1`.
_gl_write() {
    gl_api "$@" >/dev/null || { echo "[story] WRITE FAILED: $1 $2 — the change did NOT take on GitLab (see the gl_api error above); on-disk state may now diverge from the issue." >&2; return 1; }
    _gl_forget_issue "$2"
}

# _gl_forget_issue <api-path> [rendered] — after a write to an issue (issues/<iid> or below it), drop this process's
# cached JSON of that issue; with 'rendered', also its rendered requirements.md (for a write that replaced the whole
# description from another source). Reads are cached per process (_gl_issue, _gl_materialize), so without this a later
# step of the SAME command re-read the issue as it was BEFORE the write and wrote that stale text back: adopting while
# on the story's own branch stamped the Branch bullet onto the pre-adoption description and erased the adopted body.
# A bullet write (_gl_set_desc_bullet) keeps its rendered file: that file IS what it wrote.
# [RiskMitigation RA-03] Only a numeric issue id is accepted, and only that id's files in this command's cache go.
_gl_forget_issue() {
    local iid d
    iid="$(printf '%s' "$1" | sed -n 's#^issues/\([0-9][0-9]*\)\(/.*\)\{0,1\}$#\1#p')"
    [ -n "$iid" ] || return 0
    rm -f "${_GL_CACHE:?}/issue-$iid.json"
    [ "${2:-}" = rendered ] || return 0
    for d in "${_GL_CACHE:?}/STORY-$iid-"*; do
        [ -f "$d/requirements.md" ] && rm -f "$d/requirements.md"
    done
    return 0
}

# _gl_paged <path> -> ALL results across pages as ONE JSON array, through the shared reader (hooks/lib/gitlab-paged.sh:
# per_page=100, every page until an empty one, each failed page asked once more, a page cap and a time limit that fail
# closed). rc 0 the whole list; rc 1 a page could not be read twice (the first page's answer is printed as it came);
# rc 4 the list is longer than the cap; rc 5 the walk ran past its time limit. Every list the story
# tool judges goes through here, so no check can decide on GitLab's default first page of 20.
_gl_paged() { gitlab_paged_walk _gl_page_get "$1"; }
_gl_page_get() { gl_api GET "$1"; }

# _gl_issue <iid> -> the issue JSON (cached per iid for the process).
_gl_issue() {
    local iid="$1" f="$_GL_CACHE/issue-$1.json" _body
    if [ ! -s "$f" ]; then
        # [no-fail-open] Do NOT cache a FAILED fetch as a phantom empty issue — that would silently turn an API outage into
        # a story reported as "Todo" and a real issue reported as "not found". Only cache a response that is genuinely
        # an issue (numeric .iid); otherwise surface it and return non-zero so callers can distinguish outage from data.
        local _rc=0
        _body="$(gl_api GET "issues/$iid")" || _rc=$?
        if [ "$_rc" -eq 0 ] && printf '%s' "$_body" | json_test '(.iid // empty) | numbers'; then
            printf '%s' "$_body" > "$f"
        else
            echo "[story] gl_api: could not fetch issue #$iid (API error or issue absent) — refusing to cache a phantom empty issue." >&2
            if [ -n "$_body" ]; then printf '%s' "$_body"; else printf '{}'; fi   # not a braces default inside the expansion: bash would append a stray closing brace
            [ "$_rc" -eq 3 ] && return 3   # network failure: the issue was never looked up, it is NOT "absent"
            return 1
        fi
    fi
    cat "$f"
}

# _gl_self_user_id -> the numeric GitLab user id of THIS token (GET /user .id), cached per process. Prints the id, or
# nothing + rc 1 when it cannot be resolved (offline / no token). Used by adoption to SELF-ASSIGN: an agent that
# starts working a story claims the issue, so "who is working this" is never blank. /user is NOT under /projects, so
# this bypasses gl_api (which prefixes /projects/<id>/) and calls the bare endpoint directly. Stub seam: in a test,
# STORY_GL_STUB_DIR/self_user_id supplies the id (absent -> empty, i.e. adopt WITHOUT assign).
_gl_self_user_id() {
    if [ -n "${STORY_GL_STUB_DIR:-}" ]; then cat "$STORY_GL_STUB_DIR/self_user_id" 2>/dev/null || printf ''; return 0; fi
    local f="$_GL_CACHE/self-user-id" _uid
    # A best-effort lookup is asked ONCE per command: a failure is remembered too, so a command that self-assigns more
    # than once never waits on an unreachable GitLab or bridge a second time.
    [ -e "$f.failed" ] && return 1
    if [ ! -s "$f" ]; then
        if ! _gl_has_token; then
            # No token of its own: the bridge's token is the identity the bridge writes with, so it is the one to assign.
            _uid="$(coordination_read coordination_whoami '{}' 2>/dev/null | jq -r '(.id // empty) | numbers' 2>/dev/null)"
            [ -n "$_uid" ] || { : > "$f.failed" 2>/dev/null; return 1; }
            printf '%s' "$_uid" > "$f" 2>/dev/null || true
            cat "$f" 2>/dev/null; return 0
        fi
        # [CySec] CWE-214/CWE-532: the token reaches curl via the sealed helper (stdin config), never on the command line.
        _uid="$(gitlab_curl "$_GL_TOKNAME" -s --connect-timeout 3 --max-time 8 "$_GL_API/user" 2>/dev/null | jq -r '(.id // empty) | numbers' 2>/dev/null || true)"
        [ -n "$_uid" ] || { : > "$f.failed" 2>/dev/null; return 1; }
        printf '%s' "$_uid" > "$f" 2>/dev/null || true
    fi
    cat "$f" 2>/dev/null
}

# _gl_self_assign_state <iid> [<issue json>] -> prints how the issue stands for a self-assignment, one word (the issue
# is read from GitLab unless the caller already holds it):
#   assign:<user id>  the issue has NO assignee and this token's user id is known: claim it with that id
#   already           the issue already has an assignee (a person or another agent): never overwrite it
#   unresolved        the issue is unassigned but this token's user id cannot be resolved (offline / no token)
#   unreadable        the issue could not be read, so nothing is known about its assignee
# Never assigns anything itself, so its callers (new, adopt, the move to In-progress, `set assignee=self`) share
# ONE rule.
# [RiskMitigation RA-01] A body that is not an issue never reads as "no assignee": an unreadable issue must not be
# claimed over an existing assignee.
_gl_self_assign_state() {
    local iid="$1" body="${2:-}" cnt uid
    # The own id is resolved BEFORE the issue is read, so the read that finds "no assignee" is as close as possible to
    # the write that claims it (a slow first identity lookup would otherwise widen the window another agent can use).
    uid="$(_gl_self_user_id 2>/dev/null)" || uid=""
    [ -n "$body" ] || body="$(gl_api GET "issues/$iid" 2>/dev/null)" || { printf 'unreadable'; return 0; }
    printf '%s' "$body" | json_test '(.iid // empty) | numbers' || { printf 'unreadable'; return 0; }
    cnt="$(printf '%s' "$body" | jq -r '((.assignees // []) | length)' 2>/dev/null)"
    case "${cnt:-}" in ''|*[!0-9]*) printf 'unreadable'; return 0 ;; esac
    [ "$cnt" -eq 0 ] || { printf 'already'; return 0; }
    case "$uid" in ''|*[!0-9]*) printf 'unresolved'; return 0 ;; esac
    printf 'assign:%s' "$uid"
}

# _gl_claim_held <iid> <user id> -> after a write that assigned <user id>, confirm the claim still holds. GitLab has no
# conditional update, so two agents that both read "no assignee" both write, and the LAST write wins. Each claimant
# waits a settle window (STORY_CLAIM_SETTLE_SECONDS, default 2; 0 under the canned-API test stub, whose answers never
# change) and re-reads the issue: when another user now holds it, this claim was overwritten. rc 0 = held, or the
# re-read cannot tell (unreadable or unassigned: nothing contradicts the write); rc 1 = lost, and the owner's username
# (or id) is printed on stdout. Residual: an agent whose read-to-write gap is longer than the settle window can still
# overwrite a claim that was already confirmed; the window bounds it, GitLab offers nothing stronger.
# [RiskMitigation RA-01] A lost claim is reported, never silently treated as ownership.
_gl_claim_held() {
    local iid="$1" uid="$2" settle body owners
    settle="${STORY_CLAIM_SETTLE_SECONDS:-}"
    [ -n "$settle" ] || { if [ -n "${STORY_GL_STUB_DIR:-}" ]; then settle=0; else settle=2; fi; }
    [[ "$settle" =~ ^[0-9]+(\.[0-9]+)?$ ]] || settle=2
    [[ "$settle" =~ ^0+(\.0+)?$ ]] || sleep "$settle"
    body="$(gl_api GET "issues/$iid" 2>/dev/null)" || return 0
    owners="$(printf '%s' "$body" | jq -r --argjson me "$uid" \
        '[(.assignees // [])[] | select(.id != $me) | (.username // (.id|tostring))] | join(", ")' 2>/dev/null)" || return 0
    printf '%s' "$body" | json_test '[(.assignees // [])[] | .id] | index($me)' --argjson me "$uid" && return 0
    [ -n "$owners" ] || return 0
    printf '%s' "$owners"
    return 1
}

# backend_self_assign <dir> <iid> -> claim the issue for this token's user when it has no assignee. Used right after a
# story is created. Fail-open: an assignee never blocks the story, so an unresolved identity or a refused write only
# warns (the repair is `story set <id> assignee=self`).
backend_self_assign() {
    local iid="$2" st
    st="$(_gl_self_assign_state "$iid")"
    case "$st" in
        assign:*) if _gl_write PUT "issues/$iid" "assignee_ids=${st#assign:}"; then
                      _gl_warn_lost_claim "$iid" "${st#assign:}"
                  else
                      printf 'story: could not assign #%s to this token'"'"'s user; assign it with: story set %s assignee=self\n' "$iid" "$iid" >&2
                  fi ;;
        unresolved|unreadable) printf 'story: could not resolve this token'"'"'s GitLab user, so #%s was left unassigned; assign it with: story set %s assignee=self\n' "$iid" "$iid" >&2 ;;
    esac
    return 0
}

# _gl_warn_lost_claim <iid> <user id> -> the fail-open callers (new, adopt, the move to In-progress): when the claim
# just written was overwritten by another agent at the same moment, say plainly who owns the story. Never fails.
_gl_warn_lost_claim() {
    local owner
    owner="$(_gl_claim_held "$1" "$2")" && return 0
    printf 'story: #%s was claimed by %s at the same moment, so it is THEIRS, not yours; the assignee was left with them. Coordinate before working it.\n' "$1" "$owner" >&2
    return 0
}

# The story STATUS namespace is a strict MUTEX — a story carries exactly ONE status. Three naming
# schemes have existed over time and any may still be present mid-migration: the new canonical
# GitLab-SCOPED `status::*` (double-colon; on Premium GitLab enforces the mutex natively, on CE our Kyklos does),
# the legacy single-colon `status:*`, and the oldest `S:*`. A status WRITE always ADDS exactly one canonical
# `status::<x>` and REMOVES every OTHER status label across ALL three schemes, so a re-labelled or web-UI-dirtied
# issue converges back to a single status. Centralized here so no write site re-hardcodes the scheme list.
_GL_STATUS_TODO_LABELS="status::todo,status:todo,S:todo"
_GL_STATUS_DOING_LABELS="status::doing,status:doing,S:doing"
# Blocked: the kinds (status::blocked-on-issue|user|external, which the bridge writes) and the legacy bare forms.
_GL_STATUS_BLOCKED_LABELS="status::blocked-on-issue,status::blocked-on-user,status::blocked-on-external,status::blocked,status:blocked,S:blocked"
# The UNIFIED lifecycle scope: parked (open, deferred) and the closed-issue
# terminal reasons (wontfix/duplicate/invalid/archived) are STATUS values on the SAME single dimension as
# todo/doing/blocked - one label answers "what should an observer do with this issue". Each dual-reads its legacy
# bare-name form during the migration window (the alias machinery below migrates + retires the bare names).
_GL_STATUS_PARKED_LABELS="status::parked,parked"
_GL_STATUS_WONTFIX_LABELS="status::wontfix,wontfix"
_GL_STATUS_DUPLICATE_LABELS="status::duplicate,duplicate"
_GL_STATUS_INVALID_LABELS="status::invalid,invalid"
_GL_STATUS_ARCHIVED_LABELS="status::archived,archived"
_GL_STATUS_AXES="todo doing blocked parked wontfix duplicate invalid archived"
_GL_STATUS_ALL_LABELS="$_GL_STATUS_TODO_LABELS,$_GL_STATUS_DOING_LABELS,$_GL_STATUS_BLOCKED_LABELS,$_GL_STATUS_PARKED_LABELS,$_GL_STATUS_WONTFIX_LABELS,$_GL_STATUS_DUPLICATE_LABELS,$_GL_STATUS_INVALID_LABELS,$_GL_STATUS_ARCHIVED_LABELS"

# _gl_status_axis_labels <axis> -> that axis's full dual/triple-read label list (single lookup point).
_gl_status_axis_labels() {
    case "$1" in
        todo)      printf '%s' "$_GL_STATUS_TODO_LABELS" ;;
        doing)     printf '%s' "$_GL_STATUS_DOING_LABELS" ;;
        blocked)   printf '%s' "$_GL_STATUS_BLOCKED_LABELS" ;;
        parked)    printf '%s' "$_GL_STATUS_PARKED_LABELS" ;;
        wontfix)   printf '%s' "$_GL_STATUS_WONTFIX_LABELS" ;;
        duplicate) printf '%s' "$_GL_STATUS_DUPLICATE_LABELS" ;;
        invalid)   printf '%s' "$_GL_STATUS_INVALID_LABELS" ;;
        archived)  printf '%s' "$_GL_STATUS_ARCHIVED_LABELS" ;;
    esac
}

# _gl_status_others <keep-axis> -> comma-joined list of every status label EXCEPT the kept axis's (across every
# scheme, all 8 axes). Use as the mutex `remove_labels=` when adding the canonical `status::<keep>` - setting ANY
# status strips every other, so the one-status invariant holds by construction at every write site.
_gl_status_others() {
    local keep="$1" ax out=""
    for ax in $_GL_STATUS_AXES; do
        [ "$ax" = "$keep" ] && continue
        out="${out:+$out,}$(_gl_status_axis_labels "$ax")"
    done
    printf '%s' "$out"
}

# _gl_status <iid> -> Todo | In-progress | Blocked | Parked | Done | Dropped (closed = Done, UNLESS it carries a
# non-development disposition label -> Dropped; else the status label, classified by gl-status-classify.jq).
_gl_status() {
    local j; j="$(_gl_issue "$1")"
    if [ "$(printf '%s' "$j" | jq -r '.state // ""')" = "closed" ]; then
        # A story CLOSED as a non-development disposition (wontfix/duplicate/invalid) was DROPPED, not
        # completed — it must NOT read as Done (backend_is_done stays false) so the proof gate never retroactively
        # demands a Proof table for an abandoned story. Mirrors the close-guard's disposition exemption set.
        local _dl; _dl="$(printf '%s' "$j" | jq -r '[.labels[]? | ascii_downcase] | join(" ")' 2>/dev/null || true)"
        # dual-read the scoped status:: disposition forms alongside the legacy bare names.
        case " $_dl " in *" wontfix "*|*" duplicate "*|*" invalid "*|*" status::wontfix "*|*" status::duplicate "*|*" status::invalid "*) printf 'Dropped'; return 0 ;; esac
        printf 'Done'; return 0
    fi
    # Match the status label as an EXACT array element — a substring test (`case *status:doing*`) would misclassify
    # a custom label like `x-status:doing-ish`. jq `index` tests exact membership. TRIPLE-READ the SCOPED
    # `status::*` names (the new canonical, GitLab-scoped so Premium enforces the mutex natively) AND the legacy
    # single-colon `status:*` AND the older `S:*`, during the rename window, so an issue labelled by any of the
    # three schemes — incl. one written by a not-yet-migrated container — is still classified correctly. Order the
    # scoped name FIRST (it is the target scheme). Surface an ambiguous multi-status LOUDLY on
    # stderr instead of silently first-match-winning (CE has no native scope mutex; the GitLab web UI can add a 2nd).
    # jq externalized (inline multi-line jq reads as kcov phantom lines though exercised). Behaviour unchanged.
    local st; st="$(printf '%s' "$j" | jq -rf "$BACKEND_GL_HERE/gl-status-classify.jq" 2>/dev/null)"
    # fail-loud on an out-of-band double status (a 2nd status::* added via the web UI, which no local guard
    # can intercept on CE). Count DISTINCT status states present across all three schemes; >1 is ambiguous.
    local _nstate; _nstate="$(printf '%s' "$j" | jq -rf "$BACKEND_GL_HERE/gl-status-count.jq" 2>/dev/null)"
    [ "${_nstate:-0}" -gt 1 ] 2>/dev/null && printf '[kyklos] WARNING: issue carries %s conflicting status states — exactly one status is expected. Heal via the story tool (status is a mutex). Reading the highest-precedence one.\n' "$_nstate" >&2
    printf '%s' "${st:-Todo}"
}

# backend_status_conflicts <dir> — The Kyklos's POSITIVE single-status invariant. CE cannot
# enforce the scoped-label mutex, so this REPORTS (never mutates, never blocks) every OPEN story carrying >=2
# DISTINCT status states across any scheme (status::*/status:*/S:*) — e.g. a 2nd status added out-of-band via the
# GitLab web UI, which no local guard can intercept on CE. On Premium the scope mutex makes this the redundant
# second layer; on CE it IS the enforcement, surfaced LOUDLY for healing instead of silently first-match-hidden.
# Prints one TAB-separated `iid<TAB>n<TAB>status-labels` line per offender; rc 0 always (report-only; a hard block
# would be a NEW gate for every project = always-stop). Stub-aware via _gl_paged.
backend_status_conflicts() {
    # jq externalized to gl-status-conflicts.jq (an inline multi-line jq string reads as kcov phantom
    # "uncovered" lines though it is exercised; the file is measured honestly). Behaviour unchanged.
    _gl_paged "issues?state=opened&labels=story" 2>/dev/null \
        | jq -rf "$BACKEND_GL_HERE/gl-status-conflicts.jq" 2>/dev/null || true
}

# _gl_slug <iid> -> the story slug from the issue title (kebab, via the shared story_slugify rule).
_gl_slug() {
    story_slugify "$(_gl_issue "$1" | jq -r '.title // ""')"
}

# _gl_write_requirements <iid> <req-file> — render the issue to requirements.md: the issue description with a
# Status bullet synced to the NATIVE GitLab status (closed=>Done etc.). The SINGLE place that renders an issue to
# a requirements.md file, so the temp-cache read path (_gl_materialize) and the persistent on-disk path
# (backend_materialize) can never drift. Always (re)writes — the ISSUE is the source of truth for requirements.md.
_gl_write_requirements() {
    local iid="$1" req="$2" st issue title body
    mkdir -p "$(dirname "$req")" 2>/dev/null || return 1
    # The issue description no longer repeats the title as an H1 (the native `title` field holds it). The
    # requirements.md SSoT DOES need the "# STORY-<id>: <Title>" H1 (story_title_from_file + FS export read it), so
    # re-derive it here from the issue title and prepend it. This keeps the GitLab description clean while the FS
    # import/export round-trip is unchanged (the H1 is present in requirements.md exactly as before).
    issue="$(_gl_issue "$iid")" || return 1
    title="$(printf '%s' "$issue" | jq -r '.title // ""')"
    body="$(printf '%s' "$issue" | jq -r '.description // ""')"
    # A legacy (pre-) description embeds its own leading H1 — strip it (and a following blank) so the derived H1
    # below is the ONLY title line; a -era description has no H1, so this is a no-op for it.
    case "$body" in
        '#'[[:space:]]*) body="$(printf '%s\n' "$body" | sed '1d;1{/^[[:space:]]*$/d}')" ;;
    esac
    { printf '# STORY-%s: %s\n\n' "$iid" "$title"; printf '%s\n' "$body"; } > "$req" || return 1
    st="$(_gl_status "$iid")"
    if grep -qiE '^[[:space:]]*[-*][[:space:]]+\*\*Status:\*\*' "$req"; then
        sed -i -E "s|^([[:space:]]*[-*][[:space:]]+\*\*Status:\*\*).*|\1 ${st}|" "$req"
    else
        printf -- '- **Status:** %s\n%s\n' "$st" "$(cat "$req")" > "$req"
    fi
}

# _gl_strip_title_h1 <body> -> the body with a LEADING "# STORY-<n>: <title>" H1 (and one following blank
# line) removed. GitLab's native `title` field already shows the title, so a first-line H1 that repeats it DOUBLES
# the title in the rendered issue. The INVERSE of _gl_write_requirements, which re-derives that
# H1 for the FS requirements.md mirror (story_title_from_file / FS export need it). This is the ONE strip that every
# issue-DESCRIPTION write must pass through, so the H1 can never leak into the issue body regardless of how the body
# was composed (poka-yoke). Matches ONLY the auto-generated story-title H1 (`# STORY-<digits>:`) — never a user's own
# `# Heading` (so an adopted issue's original prose is untouched). Idempotent; a body with no such H1 is unchanged.
_gl_strip_title_h1() {
    printf '%s' "$1" | awk -f "$BACKEND_GL_HERE/gl-strip-title-line.awk"
}

# _gl_materialize <iid> -> path to a temp story dir (STORY-<iid>-<slug>) whose requirements.md is the issue
# description with the Status bullet synced to the native status. Reused by the FS read helpers. Cached (rendered once).
_gl_materialize() {
    local iid="$1" slug d req
    slug="$(_gl_slug "$iid")"; [ -n "$slug" ] || slug="story"
    d="$_GL_CACHE/STORY-$iid-$slug"
    req="$d/requirements.md"
    [ -f "$req" ] || _gl_write_requirements "$iid" "$req"   # cache: render once
    printf '%s' "$d"
}

# =============================== CONTRACT (READ subset) =========================================

backend_max_num() {  # highest issue iid; 0 if the project is genuinely EMPTY; rc!=0 on an API ERROR.
    # CRITICAL: distinguish "empty project" ([] -> 0) from "API failed" ({} / error body). Returning 0 on an API
    # error would make `story new` mint the first number (001), colliding with the real, populated project. On error, abort.
    local out; out="$(_gl_paged "issues?scope=all&labels=$_GL_STORY_LABEL")"
    printf '%s' "$out" | json_test 'type=="array"' \
      || { printf 'story: GitLab API error listing issues — refusing to guess the next number (would collide)\n' >&2; return 1; }
    printf '%s' "$out" | jq -r '[(.[]?.iid)] | max // 0' 2>/dev/null || echo 0
}

# Highest iid across ALL issues (UNFILTERED by label); 0 if genuinely empty; rc!=0 on an API error.
# The migrate --apply "fresh project" gate needs THIS, not backend_max_num: GitLab assigns the iid across EVERY
# issue in the project (story-labelled or not), so a project already holding non-story issues is NOT fresh even
# though its story-max is 0 — id==iid renumbering would then collide. Mirrors backend_new's scope=all baseline.
backend_max_iid_any() {
    local out; out="$(_gl_paged "issues?scope=all")"
    printf '%s' "$out" | json_test 'type=="array"' \
      || { printf 'story: GitLab API error listing issues — refusing to guess whether the target is empty (would collide)\n' >&2; return 1; }
    printf '%s' "$out" | jq -r '[(.[]?.iid)] | max // 0' 2>/dev/null || echo 0
}

backend_resolve() {  # <dir> <ref> -> the iid (the gitlab handle); rc 1 if the issue doesn't exist, 3 on a network failure
    local num; num="$(printf '%s' "$2" | grep -oE '[0-9]+' | head -1)"
    [ -n "$num" ] || return 1
    # Normalise leading zeros: the no-id resolution path yields the ZERO-PADDED identifier form for an iid < 100
    # (e.g. iid 35 rendered as "0"+"35"), but a GitLab iid is unpadded, so the padded string never equalled the
    # numeric iid and backend_resolve returned rc 1 for every such story — which silently made the structure guard
    # inert (it fails open on any `story structure` exit != 1). Canonicalise to the numeric iid BEFORE the lookup so
    # the padded label, the padded number, and the bare number all resolve. `10#` forces base-10 (a leading zero is
    # NOT octal here) and drops the padding.
    num=$((10#$num))
    local body rc=0
    body="$(_gl_issue "$num")" || rc=$?
    [ "$rc" -eq 3 ] && return 3   # network failure: cannot tell whether the story exists
    [ "$(printf '%s' "$body" | jq -r '.iid // "null"')" = "$num" ] || return 1
    printf '%s' "$num"
}

# backend_epic_has_milestone <dir> <epic> -> rc 0 iff the epic resolves to a milestone in this project. Used by the
# CLI to REQUIRE a milestone before creating/adopting a story (a gitlab story must be milestone-backed).
# A closed epic does not count: a story never joins a closed epic (the bridge's verbs refuse the same), and the caller is
# told why on stderr.
backend_epic_has_milestone() {
    [ -n "$(_gl_milestone_id "$2")" ] && return 0
    _gl_milestone_closed "$2" && printf 'story: epic %s is closed; a story joins only an open epic. Reopen it (story epic reopen %s) or choose another (story epic list).\n' "$2" "$2" >&2
    return 1
}

# backend_is_adopted_story <dir> <iid> -> classify an issue for the branch guard (does it belong to the SSDLC
# lifecycle?). A raw user-created issue lacks the story label, so it is invisible to the proof gate + milestone
# logic — the guard must catch it BEFORE work begins.
#   rc 0: an adopted story (carries the story label AND the adoption metadata block in its body)
#   rc 1: the issue exists but is NOT an adopted story (a raw issue, OR a user-created issue that merely carries a
#         pre-applied story label but was never `story adopt`ed -> must be adopted first)
#   rc 3: could not determine (missing issue / API / transport error) -> caller should warn+allow, never hard-block
backend_is_adopted_story() {
    local iid="$2" body got msg
    body="$(_gl_issue "$iid" 2>/dev/null)"
    got="$(printf '%s' "$body" | jq -r '.iid // empty' 2>/dev/null)"
    if [ "$got" = "$iid" ]; then
        # Adoption = the story label AND the tool-written metadata header (a label-only issue is NOT adopted). The one
        # definition lives in hooks/lib/story-adoption.sh; a broken install (helper absent) is a determinate config
        # error (rc 2 -> the caller BLOCKS loudly), never a silent pass.
        command -v story_issue_is_adopted >/dev/null 2>&1 || return 2
        story_issue_is_adopted "$body" "$_GL_STORY_LABEL" && return 0
        return 1   # exists but not adopted (no story label, or a label-only issue)
    fi
    # The check could not resolve. DISTINGUISH a DETERMINATE auth/config error (a token that cannot read
    # the project, a missing/absent issue: HTTP 401/403/404) from a TRANSIENT transport failure (network/timeout ->
    # an empty/no-message body). A config error means the gate CANNOT function here and must NOT silently pass (the
    # fail-open-inert-control that would let un-adopted feature/story-<N> work land); a transient error may
    # fail-open for availability. The callers (_require_adopted_story in the story CLI, _enforce_adopted_story in the
    # gitflow branch guard) BLOCK on 2 and warn+allow on 3.
    msg="$(printf '%s' "$body" | jq -r '.message // empty' 2>/dev/null)"
    case "$msg" in
        *40[134]*|*"Not Found"*|*"Not found"*|*Unauthorized*|*Forbidden*) return 2 ;;   # determinate auth/config
    esac
    return 3   # transient / unknown -> caller may fail-open (availability)
}

backend_get_field() {  # <dir> <handle=iid> <field>
    case "$3" in
        Status) _gl_status "$2" ;;
        Kind)   backend_get_kind "$1" "$2" ;;   # the kind:: label is the SoT — never a description bullet
        *)      story_get_field "$(_gl_materialize "$2")/requirements.md" "$3" ;;
    esac
}

backend_get_type()  { story_get_field "$(_gl_materialize "$2")/requirements.md" 'Story-Type'; }
backend_body_read() { cat "$(_gl_materialize "$2")/requirements.md" 2>/dev/null; }   # full body (for the story-quality gate)
backend_is_done()   { [ "$(_gl_status "$2")" = "Done" ]; }
backend_tasks_path(){ printf 'gitlab:issue:%s' "$2"; }   # opaque handle (the Proof itself is a note, see backend_proof_write)

backend_epic_members() {  # <dir> <epic> -> iids whose Epic field == epic
    local epic="$2" iid
    for iid in $(_gl_paged "issues?scope=all&labels=$_GL_STORY_LABEL" | jq -r '.[]?.iid' 2>/dev/null | sort -n); do
        [ "$(story_get_field "$(_gl_materialize "$iid")/requirements.md" Epic)" = "$epic" ] && printf '%s\n' "$iid"
    done
}

# backend_children_of <dir> <parent-iid> -> the iids of every story whose `- **Parent:**` bullet resolves to
# <parent-iid>, ascending. The child's Parent bullet is the SOLE source of truth for the relationship, so
# this is a single robust scan of the story issues (no duplicated Children: list to drift). Compares NORMALISED
# numbers so and `151` match. Never returns the parent itself.
backend_children_of() {
    local dir="$1" parent iid p
    parent="$(story_parent_ref_normalize "$2")"; [ -n "$parent" ] || return 0
    for iid in $(_gl_paged "issues?scope=all&labels=$_GL_STORY_LABEL" | jq -r '.[]?.iid' 2>/dev/null | sort -n); do
        [ "$iid" = "$parent" ] && continue
        p="$(story_parent_iid_from_body "$(backend_body_read "$dir" "$iid" 2>/dev/null)")"
        [ -n "$p" ] && [ "$p" = "$parent" ] && printf '%s\n' "$iid"
    done
}

# backend_note <dir> <iid> <text> -> post a plain issue note (used for the auto-close audit trail ). Fail-loud
# on a dropped write (same no-fail-open discipline as backend_proof_write): a note that curls 200 but carries no id
# means the write did not land, so return non-zero rather than believe an audit note was posted when it was not.
backend_note() {
    local iid="$2" resp
    [ -n "$_GL_PID" ] && [ -n "$_GL_TOKNAME" ] || return 0
    resp="$(gl_api POST "issues/$iid/notes" "body=$3")"
    printf '%s' "$resp" | json_test '(.id // empty) | numbers' || {
        printf 'story: gitlab backend: FAILED to post note to issue #%s (auto-close audit not recorded).\n' "$iid" >&2
        return 1
    }
}

# backend_note_required <dir> <iid> <text> -> like backend_note, but an unconfigured project or token is a FAILURE,
# never a silent skip: a note a gate depends on (the reopen root cause) must land, or the caller must know it did not.
backend_note_required() {
    [ -n "$_GL_PID" ] && [ -n "$_GL_TOKNAME" ] || {
        printf 'story: gitlab backend: no project or API token is configured, so the note on issue #%s was NOT posted.\n' "$2" >&2
        return 1
    }
    backend_note "$@"
}

# backend_close_umbrella <dir> <iid> -> close a PARENT story directly (native close + status:: label mutex), WITHOUT the
# per-story proof/quality gates. This is NOT green-washing: a parent is an umbrella whose completion is
# evidenced by its children — every child passed its OWN gates before closing, and the caller only invokes this once
# ALL children are closed, recording the naming audit note. Kept separate from cmd_set's gated Done-transition so the
# gate-bypass is explicit + narrow (umbrella parents only), never a general escape.
backend_close_umbrella() {
    local iid="$2"
    _gl_write PUT "issues/$iid" "state_event=close" "remove_labels=$_GL_STATUS_ALL_LABELS"
    _gl_set_desc_bullet "$iid" Status Done
}
# backend_find_by_title <dir> <title> -> rc 0 if an issue with EXACTLY this title exists, rc 1 if none, rc 2 if the
# SSoT (GitLab issues) is UNREACHABLE (API error). Queries the issues SSoT directly — NEVER the local folder mirror
# (stale/empty under gitlab => a duplicate finding would slip through). The caller MUST fail hard on rc 2 and never
# treat "cannot tell" as "not found". Mirrors backend_max_num's array-vs-error discrimination (CWE: fail-closed).
backend_find_by_title() {
    local want="$2" out
    out="$(_gl_paged "issues?scope=all&labels=$_GL_STORY_LABEL")"
    printf '%s' "$out" | json_test 'type=="array"' \
      || { printf 'story: GitLab API error listing issues — cannot verify the finding is not already tracked\n' >&2; return 2; }
    printf '%s' "$out" | json_test 'any(.[]; (.title // "") == $t)' --arg t "$want" && return 0
    return 1
}

backend_generate_index() {  # emit the BACKLOG index (reuse story_emit_header/row/footer on materialized dirs)
    local dir="$1" iid id tmpd listing
    story_emit_header "$dir"
    # [Poka-Yoke] BACKLOG.md is a DERIVED mirror of GitLab under this backend — mark it so a hand-edit is visibly
    # futile (refresh/sync regenerates it). Emitted by generate_index so BOTH the written file (sync) and the compare
    # buffer (check) carry it — no false drift.
    printf '<!-- GENERATED MIRROR of GitLab (SoT) — DO NOT EDIT; regenerated by `story` (refresh/sync). -->\n\n'
    # ONE paged list call feeds the whole index: each list element is a full issue object, so pre-seeding the
    # per-issue cache from it turns the former one-fetch-per-story pattern (the minutes-long sync on a real
    # backlog) into a single round-trip; every downstream _gl_issue read below hits the warm cache.
    listing="$(_gl_paged "issues?scope=all&labels=$_GL_STORY_LABEL")"
    printf '%s' "$listing" | jq -c '.[]?' 2>/dev/null | while IFS= read -r _it; do
        _iid="$(printf '%s' "$_it" | jq -r '.iid // empty' 2>/dev/null)"
        [ -n "$_iid" ] && [ ! -s "$_GL_CACHE/issue-$_iid.json" ] && printf '%s' "$_it" > "$_GL_CACHE/issue-$_iid.json"
    done
    for iid in $(printf '%s' "$listing" | jq -r '.[]?.iid' 2>/dev/null | sort -n); do
        # story_emit_row links to the dir BASENAME, so materialize into a temp dir named with the CANONICAL on-disk
        # id (backend_id_from_handle: zero-padded + reusing the real folder if present) — otherwise the BACKLOG links
        # to STORY-<iid>-<40-char-title> while the real folder is STORY-<NNN>-<curated-slug>, and every link is dead.
        id="$(backend_id_from_handle "$dir" "$iid")"
        tmpd="$_GL_CACHE/$id"
        [ -f "$tmpd/requirements.md" ] || _gl_write_requirements "$iid" "$tmpd/requirements.md"
        story_emit_row "$tmpd"
    done
    story_emit_footer "$dir" 2>/dev/null || true
}

# =============================== CONTRACT (mutating) ============================================

# _gl_milestone_id <epic> -> the milestone id whose title starts with the epic id (empty if none/blank).
_gl_milestone_id() {
    { [ -z "$1" ] || [ "$1" = "-" ]; } && { printf ''; return 0; }
    # URL-encode the search term (it lands in the query PATH, unlike gl_api's --data-urlencode'd k=v extras), and
    # match the epic token EXACTLY — `startswith(<id>)` also matches a longer epic id with the same prefix, attaching the wrong milestone.
    # The titles are read by epic-records.jq, the one rule for which milestone is which epic: a shorter epic id never
    # matches a longer one, and a title whose first word only starts with the epic letter and digits is no epic.
    # Fall back to a client-side scan of `search` results.
    local q; q="$(jq -rn --arg s "$1" '$s|@uri' 2>/dev/null || printf '%s' "$1")"
    # Page the lookup: `search` narrows server-side but can still return >100 hits (a project with many
    # milestones, or a broad substring match), and a single unpaged GET would miss an exact-title match past page 1
    # -> the story is then refused ("epic has no milestone") or silently created milestone-less. _gl_paged walks all.
    # Only an OPEN milestone counts (a missing state reads as open): a closed epic takes no new story.
    _gl_paged "milestones?search=$q" | jq -c -f "$BACKEND_GL_HERE/epic-records.jq" 2>/dev/null \
      | jq -r --arg e "$1" '[.[]? | select(.epic == $e and .active)][0].id // empty' 2>/dev/null
}

# _gl_milestone_closed <epic> -> rc 0 when the epic has milestones and every one of them is closed.
_gl_milestone_closed() {
    [ -n "$1" ] && [ "$1" != "-" ] || return 1
    local q; q="$(jq -rn --arg s "$1" '$s|@uri' 2>/dev/null || printf '%s' "$1")"
    _gl_paged "milestones?search=$q" | jq -c -f "$BACKEND_GL_HERE/epic-records.jq" 2>/dev/null \
      | json_test '[.[]? | select(.epic == $e)] | length > 0 and all(.active | not)' --arg e "$1"
}

# backend_new <dir> <id> <title> <type> <epic> [kind] [severity] -> create an issue (id == the returned iid): status::todo +
# type::<t> + kind::<k> (+ severity::<s> when given) labels, milestone if the epic resolves, and the canonical requirements body as the description.
# kind defaults to development (the strictest set) — every creation path stamps a kind by construction.
backend_new() {
    local id="$2" title="$3" type="$4" epic="$5" kind="${6:-development}" severity="${7:-}" desc labels args mid iid prevmax tol
    # Routing, enforced at CREATION: refuse to create a story if STORY_GITLAB_PROJECT is the declared
    # public artifact project (an agent can't route around the topology by hand-setting the knob).
    # [no-fail-open] The resolver ships in this plugin: if routing_check is UNAVAILABLE, that is a
    # broken install — HARD-FAIL rather than silently create the story with the routing control skipped.
    command -v routing_check >/dev/null 2>&1 || { printf 'story: gitlab backend_new: FATAL — routing resolver unavailable; refusing to create a story without the routing check (routing_check in hooks/lib/repo-role.sh; fix the install).\n' >&2; return 1; }
    routing_check "$1" || { printf 'story: gitlab backend_new: routing refused — will NOT create a story in the public artifact project (stories belong in the private source).\n' >&2; return 1; }
    # The GitLab issue already carries the title in its native `title` field, so DO NOT repeat it as an H1 in
    # the description (that was redundant — and doubled, since $id already embeds the title slug). The requirements.md
    # SSoT still needs the H1: _gl_write_requirements re-derives it from the issue title when materializing.
    desc="$(printf -- '- **Status:** Todo\n- **Story-Type:** %s\n- **Epic:** %s\n- **Branch:** -\n- **Summary:** %s\n\n' \
        "$type" "${epic:--}" "$title")$(story_emit_spec_skeleton "$type")"
    labels="$_GL_STORY_LABEL,status::todo"; [ -n "$type" ] && labels="$labels,type::$type"
    labels="$labels,kind::${kind:-development}"   # no creation path yields a kind-less story
    [ -n "$severity" ] && labels="$labels,severity::$severity"   # 'story new' requires it; migration has none to give
    args=("title=$title" "description=$desc" "labels=$labels")
    # [Require-milestone] Attach the epic's milestone. The old form silently OMITTED it when the epic had no
    # milestone — the drift that let a story exist milestone-less. The INTERACTIVE hard-require lives in the CLI
    # (cmd_new / cmd_adopt via backend_epic_has_milestone), so a user can never create a milestone-less story; here
    # (also reached by MIGRATION of legacy epic-less stories) a missing milestone is WARNED — never silently dropped,
    # never a hard block that would break importing historical stories. ('-' = the explicit no-epic sentinel.)
    if [ -n "$epic" ] && [ "$epic" != "-" ]; then
        mid="$(_gl_milestone_id "$epic")"
        if [ -n "$mid" ]; then args+=("milestone_id=$mid")
        else printf 'story: gitlab backend_new: WARNING — epic %s has no milestone in project %s; creating the story WITHOUT one (interactive `story new`/`adopt` require it — this path is migration/direct). Create it: story epic set %s --title "...".\n' "$epic" "${_GL_PID:-?}" "$epic" >&2
        fi
    fi
    # [Poka-Yoke] Capture the TRUE high-water (max over ALL issues, unfiltered — the counter tracks every issue,
    # not just stories) BEFORE creating, so we can detect a DRIFTED iid counter afterwards. GitLab's per-project
    # iid counter never decreases: a deleted probe/high issue leaves a permanent gap, so GitLab may auto-assign an
    # iid far above the real max and SILENTLY mint a 4-digit story number. rc!=0/non-numeric
    # (API error, or genuinely empty project) => prevmax=0 => the jump check below is skipped (fail-OPEN: the guard
    # is a safety net, it must never block a legitimate create on an unreadable baseline).
    # [no-fail-open] Distinguish a baseline READ-FAILURE from a genuinely-empty project. Masking an API/token error as
    # prevmax=0 would SILENTLY disable the relative jump check (only the absolute ceiling would remain), so a drifted iid
    # below the ceiling atop an unknown baseline would be minted with no loud error. Capture
    # whether the issues-list read SUCCEEDED (a JSON ARRAY — the SAME signal backend_reachable uses; an error returns
    # a non-array `{}`) SEPARATELY from the numeric max, so an UNREADABLE baseline is refused below, not trusted as 0.
    _pm_raw="$(_gl_paged "issues?scope=all")"
    if printf '%s' "$_pm_raw" | json_test 'type=="array"'; then
        prevmax="$(printf '%s' "$_pm_raw" | jq -r '[(.[]?.iid)] | max // 0' 2>/dev/null)"
        printf '%s' "$prevmax" | grep -cE '^[0-9]+$' >/dev/null || prevmax=0
        _baseline_known=1
    else
        prevmax=0; _baseline_known=0     # baseline UNREADABLE (API/token error) — do NOT trust it as an empty project
    fi
    # GitLab AUTO-assigns the iid; return the ACTUAL created iid as the handle so follow-up mutations target
    # the right issue. Fail (rc 1) if the POST returned no iid (API error).
    iid="$(gl_api POST "issues" "${args[@]}" | jq -r '.iid // empty' 2>/dev/null)"
    [ -n "$iid" ] || { printf 'story: gitlab backend_new: create returned no iid (API/token error)\n' >&2; return 1; }
    printf '%s' "$iid" | grep -cE '^[0-9]+$' >/dev/null || { printf 'story: gitlab backend_new: create returned a non-numeric iid "%s"\n' "$iid" >&2; return 1; }
    # [Poka-Yoke] Counter-DRIFT guard: refuse to accept a jumped story number. A legit new issue is always
    # prevmax+1; a jump far beyond that means the counter has drifted. Delete the errant issue (best-effort) and
    # FAIL LOUD with the reset instructions, rather than silently persist a 4-digit story. Tolerance absorbs concurrent
    # creates; override via STORY_IID_JUMP_TOLERANCE (set very high to disable). Only checked when prevmax is known.
    tol="${STORY_IID_JUMP_TOLERANCE:-100}"
    # ABSOLUTE sane ceiling (override STORY_IID_SANE_MAX). CRITICAL to break the CASCADE: if a prior errant issue
    # could NOT be deleted (the delete below needs OWNER perms — a Maintainer-only token cannot delete issues, so
    # the errant issue PERSISTS), prevmax drifts up to include it and the NEXT iid looks like prevmax+1 — the
    # RELATIVE check alone then SILENTLY ACCEPTS it. An absolute ceiling refuses every
    # implausibly-large story number regardless of prevmax, so a drift can never silently persist a 4-digit story.
    sane="${STORY_IID_SANE_MAX:-2000}"
    # If the baseline could NOT be read, we cannot verify the minted iid is not a drift — do not
    # silently accept it. Delete the just-created issue (best-effort; needs OWNER perms) and refuse loud. A genuinely
    # EMPTY project returns a verified-reachable `[]` (prevmax=0, _baseline_known=1) and is accepted by the checks below.
    if [ "${_baseline_known:-0}" != 1 ]; then
        gl_api DELETE "issues/$iid" >/dev/null 2>&1 || true
        printf 'story: gitlab backend_new: the issues-list baseline could NOT be read (API/token error), so iid #%s cannot be verified against a counter drift — refusing rather than silently minting it. Retry when GitLab is reachable; if the counter is genuinely drifted, a GitLab instance administrator must reset the issue iid counter of the project (gitlab-rails console) to the highest real iid.\n' "$iid" >&2
        return 1
    fi
    if [ "$iid" -gt "$sane" ] || { [ "$prevmax" -gt 0 ] && [ "$iid" -gt "$(( prevmax + 1 + tol ))" ]; }; then
        gl_api DELETE "issues/$iid" >/dev/null 2>&1 || true   # best-effort; needs OWNER perms (see below)
        printf 'story: gitlab backend_new: refusing a DRIFTED iid #%s (highest existing #%s; sane ceiling %s).\n' "$iid" "$prevmax" "$sane" >&2
        printf '  The project %s iid counter has drifted. NOTE the delete above needs OWNER perms — a Maintainer-only\n' "${_GL_PID:-?}" >&2
        printf '  token cannot delete issues, so the errant issue may persist. A GitLab instance administrator resets the\n' >&2
        printf '  issue iid counter of the project to the highest real iid (gitlab-rails console), then retry.\n' >&2
        return 1
    fi
    _ensure_kyklos_version_label "$iid"   # stamp the creating plugin version
    printf '%s' "$iid"
}

# _gl_norm_title <text> -> the text lower-cased with whitespace collapsed and trimmed (title comparison only).
_gl_norm_title() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//'; }

# _gl_folder_is_issue <folder> <iid> -> rc 0 when the on-disk folder holds THIS issue's story, rc 1 when it holds
# ANOTHER story that happened to carry the same number (an older local story, or an issue numbering reused), rc 2
# when it cannot tell (no requirements.md, issue unreadable, an older mirror without the id). Identity first: a mirror
# written by this backend names the issue's instance-wide id in its banner, which no other issue can share. A folder
# from the local-file era (no banner) is judged by its title line against the issue title.
_gl_folder_is_issue() {
    local d="$1" iid="$2" req="$1/requirements.md" issue gid title fid ftitle
    [ -f "$req" ] || return 2
    issue="$(_gl_issue "$iid" 2>/dev/null)" || return 2
    gid="$(printf '%s' "$issue" | jq -r '.id // empty' 2>/dev/null)"
    title="$(printf '%s' "$issue" | jq -r '.title // empty' 2>/dev/null)"
    fid="$(head -1 "$req" 2>/dev/null | grep -F "$GL_MIRROR_BANNER_PREFIX" | sed -nE 's/.*\(id ([0-9]+)\).*/\1/p')"
    if [ -n "$fid" ] && [ -n "$gid" ]; then
        [ "$fid" = "$gid" ] && return 0
        return 1
    fi
    # A mirror this backend wrote before it recorded the id names only the number, which both stories share, and its
    # title line follows the issue's title at that write, so a later retitle would look like another story: unknown.
    head -1 "$req" 2>/dev/null | grep -cF "$GL_MIRROR_BANNER_PREFIX" >/dev/null && return 2
    ftitle="$(grep -m1 -E '^# STORY-[0-9]+:' "$req" 2>/dev/null | sed -E 's/^# STORY-[0-9]+:[[:space:]]*//')"
    [ -n "$ftitle" ] && [ -n "$title" ] || return 2
    [ "$(_gl_norm_title "$ftitle")" = "$(_gl_norm_title "$title")" ] && return 0
    return 1
}

# _gl_archive_folder <storiesdir> <folder-path> -> move a folder that belongs to another story out of the way, into
# <storiesdir>/_archive/superseded/ (a numbered suffix when the name is taken). Never deletes: the folder may hold
# notes worth keeping. Reports on stdout (the refresh path silences stderr). rc 1 when the move failed.
# [RiskMitigation RA-02] move only, never delete.
_gl_archive_folder() {
    local sd="$1" src="${2%/}" name dest n=1
    name="${src##*/}"
    mkdir -p "$sd/_archive/superseded" 2>/dev/null || return 1
    dest="$sd/_archive/superseded/$name"
    while [ -e "$dest" ]; do n=$((n + 1)); dest="$sd/_archive/superseded/$name-$n"; done
    if mv "$src" "$dest" 2>/dev/null; then
        printf 'story: mirror: moved "%s" to _archive/superseded/%s (it held another story with the same number)\n' "$name" "${dest##*/}"
        return 0
    fi
    printf 'story: mirror: could not move "%s" out of the way; left it as it is.\n' "$name"
    return 1
}

# _gl_archive_foreign_folders <storiesdir> <id> <iid> -> archive every folder of the same number that holds another
# story, so this issue never inherits a stranger's folder name or files. A folder whose owner cannot be told is kept.
_gl_archive_foreign_folders() {
    local sd="$1" id="$2" iid="$3" num f rc
    num="$(printf '%s' "$id" | grep -oE '^STORY-[0-9]+')" || return 0
    for f in "$sd/$num-"*/; do
        [ -d "$f" ] || continue
        f="${f%/}"
        [ "${f##*/}" = "$id" ] && continue
        rc=0; _gl_folder_is_issue "$f" "$iid" || rc=$?
        [ "$rc" -eq 1 ] && _gl_archive_folder "$sd" "$f"
    done
    return 0
}

# backend_id_from_handle <dir> <handle=iid> -> the canonical on-disk story folder id (the gitlab handle IS the
# iid). Two invariants keep the folder name STABLE across the FS era and the gitlab backend, so materialize +
# BACKLOG links target the SAME folder instead of minting a duplicate:
#   1. Zero-PAD the number to 3 digits (STORY-<NNN>), matching the FS backend's `printf %03d` + the usual convention.
#   2. REUSE an existing on-disk folder for this number (any slug) if one is present — the FS era chose curated
#      slugs the issue title can't reproduce; honour them rather than create STORY-<NNN>-<40-char-title> alongside.
# Only when NO folder exists yet does it mint STORY-<NNN>-<slug-from-title> (folder-naming parity).
#   3. A reused folder must be kebab-case. A LEGACY folder whose name is not (a human title passed as the slug, or
#      an old truncation that ended in '-') maps to its slugified name instead, and a kebab folder for the same
#      number always wins over a legacy one (independent of glob order). PURE: it only names the folder; the
#      rename happens on the write path (backend_materialize), so `story check` stays non-mutating.
backend_id_from_handle() {
    local dir="$1" iid="$2" num existing slug legacy="" _own
    num="$(printf 'STORY-%03d' "$iid" 2>/dev/null)"; [ -n "$num" ] || num="STORY-$iid"
    if [ -n "$dir" ] && [ -d "$dir" ]; then
        for existing in "$dir/$num-"*/; do
            [ -d "$existing" ] || continue
            existing="${existing%/}"; existing="${existing##*/}"
            # A folder that holds another story with the same number is never reused for this issue.
            _own=0; _gl_folder_is_issue "$dir/$existing" "$iid" || _own=$?
            [ "$_own" -eq 1 ] && continue
            slug="${existing#"$num-"}"
            if story_slug_has_kebab_shape "$slug"; then printf '%s' "$existing"; return 0; fi
            [ -n "$legacy" ] || legacy="$slug"
        done
        if [ -n "$legacy" ]; then
            slug="$(story_slugify "$legacy")"
            [ -n "$slug" ] && { printf '%s-%s' "$num" "$slug"; return 0; }
        fi
    fi
    slug="$(_gl_slug "$iid" 2>/dev/null)"; [ -n "$slug" ] || slug="story"
    printf '%s-%s' "$num" "$slug"
}

# _gl_heal_legacy_folder <storiesdir> <id> — the write-side half of the folder-name rule: before the story <id> is
# materialized, RENAME a legacy non-kebab folder of the same number to <id>, so the agent's mirror files (tasks.md,
# notes, proof) move with it and no title-named duplicate is left behind. Only a GENERATED MIRROR folder is moved:
# a hand-made folder of the same number may be unrelated stale work (`story new` leaves one in place), so it is
# kept and reported rather than folded into this story. Never deletes: when <id> already exists the legacy folder is
# kept and reported (it may hold edits a human must merge). Reports on stdout because the refresh path silences
# stderr. rc 1 when a rename FAILED: the caller must then not create <id> beside the legacy folder, or the next run
# would see a "clean twin" and never move the agent's files.
# [RiskMitigation RA-02] rename only (never delete), only into a free target, only a generated mirror folder.
_gl_heal_legacy_folder() {
    local sd="$1" id="$2" num legacy name
    num="$(printf '%s' "$id" | grep -oE '^STORY-[0-9]+')" || return 0
    for legacy in "$sd/$num-"*/; do
        [ -d "$legacy" ] || continue
        legacy="${legacy%/}"; name="${legacy##*/}"
        [ "$name" = "$id" ] && continue
        story_slug_has_kebab_shape "${name#"$num-"}" && continue   # a clean curated folder is not legacy
        if [ -e "$sd/$id" ]; then
            printf 'story: mirror: kept the legacy folder "%s" beside "%s" (it may hold edits); merge it by hand, then remove it.\n' "$name" "$id"
        elif ! grep -qF "$GL_MIRROR_BANNER_PREFIX" "$legacy/requirements.md" 2>/dev/null; then
            printf 'story: mirror: kept the legacy folder "%s": it is not a generated mirror, so it is not folded into "%s"; rename or remove it by hand.\n' "$name" "$id"
        elif mv "$legacy" "$sd/$id" 2>/dev/null; then
            printf 'story: mirror: renamed the legacy folder "%s" -> "%s"\n' "$name" "$id"
        else
            printf 'story: mirror: could not rename the legacy folder "%s" -> "%s"; left it as it is, the next refresh retries.\n' "$name" "$id"
            return 1
        fi
    done
    return 0
}

# backend_materialize <storiesdir> <handle=iid> <id> -> write the story's ON-DISK folder so BACKLOG links resolve
# and the story is workable / handed-off offline. The GitLab ISSUE stays the source of truth: requirements.md is
# (re)generated from the issue description (Status bullet synced to the native state), and tasks.md is only SEEDED
# from the shared template if ABSENT (never clobbers an agent-filled one). This is what makes `story new`/`sync`
# under the gitlab backend produce the same on-disk artifacts the FS backend does (no hand-crafting).
# The banner stamped on every gitlab-mode ON-DISK mirror file. It marks the file as a DERIVED copy of the GitLab
# issue (the SoT) so a hand-edit is visibly futile — `story refresh`/`sync` overwrites it. Kept OUT of the temp-cache
# render (_gl_write_requirements) and the issue-upload path so it can never leak INTO the issue description itself.
GL_MIRROR_BANNER_PREFIX='<!-- GENERATED MIRROR — derived from GitLab issue'
_gl_stamp_generated() {  # <file> <iid> — prepend the DO-NOT-EDIT banner once (idempotent).
    # The banner names the issue's instance-wide id as well as its number, so a later run can tell this story's
    # folder from one left by another story with the same number (_gl_folder_is_issue).
    local f="$1" iid="$2" gid ident
    [ -f "$f" ] || return 0
    gid="$(_gl_issue "$iid" 2>/dev/null | jq -r '.id // empty' 2>/dev/null)"
    ident="#$iid"; [ -n "$gid" ] && ident="#$iid (id $gid)"
    head -1 "$f" 2>/dev/null | grep -cF "$GL_MIRROR_BANNER_PREFIX $ident;" >/dev/null && return 0
    local tmp; tmp="$(mktemp "$(dirname "$f")/.mirror.XXXXXX")" || return 0
    story_tmp_register "$tmp"
    { printf '%s %s; DO NOT EDIT. Regenerated by `story` (refresh/sync) from the source of truth. Edit the GitLab issue instead. -->\n' "$GL_MIRROR_BANNER_PREFIX" "$ident"
      if head -1 "$f" 2>/dev/null | grep -cF "$GL_MIRROR_BANNER_PREFIX" >/dev/null; then tail -n +2 "$f"; else cat "$f"; fi
    } > "$tmp" && mv -f "$tmp" "$f" || rm -f "$tmp"
}

# GL_PROOF_MIRROR_MARK: the comment that opens the generated Proof section of a mirror tasks.md. It names the issue
# update time the projection was made from, so an unchanged issue is not re-read.
GL_PROOF_MIRROR_MARK='<!-- GENERATED from the proof note of the GitLab issue; DO NOT EDIT (story proof writes it). issue-updated:'

# _gl_project_proof <tasks-file> <iid> -> replace the `## Proof` section of a mirror tasks.md with the proof table
# stored on the issue (a read-only projection, like requirements.md). Everything above the section (the Work
# checklist an agent may edit) is kept as it is. Skipped when the issue has not changed since the last projection.
_gl_project_proof() {
    local t="$1" iid="$2" upd proof tmp
    [ -f "$t" ] || return 0
    upd="$(_gl_issue "$iid" 2>/dev/null | jq -r '.updated_at // empty' 2>/dev/null)"
    [ -n "$upd" ] || return 0
    grep -cF "$GL_PROOF_MIRROR_MARK $upd -->" "$t" >/dev/null && return 0
    proof="$(backend_proof_read "" "$iid" 2>/dev/null)"
    tmp="$(mktemp "$(dirname "$t")/.mirror.XXXXXX")" || return 0
    story_tmp_register "$tmp"
    {
        awk '/^##[[:space:]]+Proof([[:space:]]|$)/{exit} {print}' "$t"
        printf '## Proof\n%s %s -->\n\n' "$GL_PROOF_MIRROR_MARK" "$upd"
        if [ -n "$(printf '%s' "$proof" | tr -d '[:space:]')" ]; then printf '%s\n' "$proof"
        else printf '_No proof table is recorded on the issue yet._\n'; fi
        awk 'f && /^##[[:space:]]/{p=1} p{print} /^##[[:space:]]+Proof([[:space:]]|$)/{f=1}' "$t"
    } > "$tmp" && mv -f "$tmp" "$t" || rm -f "$tmp"
}

# backend_reachable <dir> -> rc 0 iff the GitLab API answers (the story-list GET returns a JSON array); rc 1 on any
# network/timeout/DNS/auth failure (gl_api returns {} + rc1 there). The ONE reachability signal cmd_refresh uses to
# decide fresh-regenerate vs serve-cache-and-say-so. Cheap (per_page=1). [RiskMitigation]
backend_reachable() {
    local out; out="$(gl_api GET "issues?scope=all&labels=$_GL_STORY_LABEL&per_page=1" 2>/dev/null)"
    printf '%s' "$out" | json_test 'type=="array"'
}

backend_materialize() {
    local storiesdir="$1" iid="$2" id="$3"
    [ -n "$storiesdir" ] && [ -n "$iid" ] && [ -n "$id" ] || return 0
    local d="$storiesdir/$id"
    _gl_archive_foreign_folders "$storiesdir" "$id" "$iid"            # another story's same-number folder moves out
    if [ -d "$d" ]; then                                             # ... including one sitting at $id itself
        local _own=0; _gl_folder_is_issue "$d" "$iid" || _own=$?
        if [ "$_own" -eq 1 ]; then _gl_archive_folder "$storiesdir" "$d" || return 0; fi
    fi
    _gl_heal_legacy_folder "$storiesdir" "$id" || return 0          # a legacy non-kebab folder moves to $id first
    _gl_write_requirements "$iid" "$d/requirements.md" || return 0   # issue -> requirements.md (Status synced)
    _gl_stamp_generated "$d/requirements.md" "$iid"                  # [Poka-Yoke] mark the on-disk mirror as derived
    [ -f "$d/tasks.md" ] || story_emit_tasks_template "$id" > "$d/tasks.md"   # seed once; never clobber agent edits
    _gl_project_proof "$d/tasks.md" "$iid"                           # the stored proof, projected read-only
}

# backend_materialize_all <storiesdir> [mode] -> materialize every story's folder so BACKLOG links resolve and
# pre-existing gitlab-backend stories gain their on-disk folders. Best-effort; skips on API error.
#   mode=missing : only materialize stories whose folder has NO requirements.md yet (cheap — one API GET per NEW
#                  story). Used by `story sync` so a routine sync doesn't re-fetch every issue every time.
#   mode=full (default) : re-render EVERY story from the issue (refreshes stale requirements.md). Used by the
#                  explicit `story materialize --all`.
backend_materialize_all() {
    local storiesdir="$1" mode="${2:-full}" iid id
    for iid in $(_gl_paged "issues?scope=all&labels=$_GL_STORY_LABEL" | jq -r '.[]?.iid' 2>/dev/null | sort -n); do
        [ -n "$iid" ] || continue
        id="$(backend_id_from_handle "$storiesdir" "$iid")"
        [ "$mode" = missing ] && [ -f "$storiesdir/$id/requirements.md" ] && continue
        backend_materialize "$storiesdir" "$iid" "$id"
    done
}

# backend_import_issue <dir> <iid> <title> <type> <epic> <desc-file> — MIGRATION import: create an issue with an
# EXPLICIT iid (so the issue number EQUALS the story number, no renumber) and the FULL story body read from
# <desc-file> (the story's requirements.md) as the description, plus the status::todo + type:: + kind:: labels and the epic
# milestone. Setting iid requires a token with owner/admin on a project where that iid is still free. Prints the
# created iid (empty on failure) so the caller can verify iid == the requested number.
backend_import_issue() {
    local iid="$2" title="$3" type="$4" epic="$5" descfile="$6" labels args mid
    labels="$_GL_STORY_LABEL,status::todo"; [ -n "$type" ] && labels="$labels,type::$type"
    labels="$labels,kind::development"   # a migrated historical story is development-kind by definition
    args=("iid=$iid" "title=$title" "labels=$labels")
    [ -f "$descfile" ] && args+=("description=$(_gl_strip_title_h1 "$(cat "$descfile")")")   # imported body carries no title H1
    mid="$(_gl_milestone_id "$epic")"; [ -n "$mid" ] && args+=("milestone_id=$mid")
    gl_api POST "issues" "${args[@]}" | jq -r '.iid // empty' 2>/dev/null
}

# backend_adopt <dir> <iid> <type> <epic> [kind] — bring an EXISTING (user-created) issue into the SSDLC story
# lifecycle: stamp the story + status::doing + type::<t> + kind::<k> + ssdlc:phase:: labels, attach the epic's
# milestone (REQUIRED), and
# PREPEND the canonical story-metadata block to the description — PRESERVING the user's original title (untouched)
# and body (kept below a separator). Idempotent: a re-adopt of an already-metadata'd issue leaves the body as-is and
# only re-syncs labels/milestone. Fails LOUD if the issue does not exist or the epic has no milestone (a gitlab
# story must be milestone-backed). Prints the iid on success.
# Adoption reads the issue's EXISTING kind:: label (dual-scheme) and PRESERVES it; absent
# -> kind::development, stamped ATOMICALLY in the same PUT as status::doing/phase (the invariant now
# covers kind: no tool path yields a status::doing story without a kind). An explicit [kind] argument that CONFLICTS
# with a different existing label is REFUSED loudly — a kind changes only through the auditable `story set kind=`.
backend_adopt() {
    local iid="$2" type="$3" epic="$4" want_kind="${5:-}" want_severity="${6:-}" body title desc mid newdesc
    body="$(_gl_issue "$iid" 2>/dev/null)"
    [ "$(printf '%s' "$body" | jq -r '.iid // "null"')" = "$iid" ] \
        || { printf 'story: gitlab backend_adopt: issue #%s does not exist in project %s.\n' "$iid" "${_GL_PID:-?}" >&2; return 1; }
    mid="$(_gl_milestone_id "$epic")"
    [ -n "$mid" ] || { printf 'story: gitlab backend_adopt: epic %s has no milestone in project %s — create it first (story epic set %s --title "..."). A gitlab story must be milestone-backed.\n' "$epic" "${_GL_PID:-?}" "$epic" >&2; return 1; }
    title="$(printf '%s' "$body" | jq -r '.title // ""')"
    desc="$(printf '%s' "$body" | jq -r '.description // ""')"
    if printf '%s' "$desc" | grep -ciE '^[[:space:]]*[-*][[:space:]]+\*\*Story-Type:\*\*' >/dev/null; then
        newdesc="$desc"   # already carries the story metadata (re-adopt) — keep the body verbatim
    else
        # Prepend the canonical metadata block; preserve the user's ORIGINAL description verbatim in a
        # `## Original request (verbatim)` section (blockquoted), not a bare `---` + raw prose.
        newdesc="$(_story_adopt_body "$type" "$epic" "$title" "$desc")"
    fi
    local _vl; _vl="$(command -v kyklos_version_label >/dev/null 2>&1 && kyklos_version_label || true)"
    # Adoption sets status::doing — and a story worked at status::doing MUST carry an SSDLC phase, else
    # it is the incoherent 'worked with no phase' state. Set the phase ATOMICALLY in this SAME PUT (no phase-less window, no fail-open):
    # preserve an EXISTING phase on re-adopt, default a FRESH adopt to Requirements, and mutex-remove any other phase.
    # Dual-read the phase (scoped `ssdlc:phase::X` AND legacy `ssdlc:phase:X`) so a re-adopt PRESERVES + converts
    # an existing phase; a fresh adopt (no phase) defaults to Requirements. Mutex-remove EVERY other phase label (both
    # schemes) so the result carries exactly one, scoped.
    local _adopt_ph _ph_rem
    _adopt_ph="$(printf '%s' "$body" | jq -r '([.labels[]? | select(startswith("ssdlc:phase:"))][0] // "") | sub("^ssdlc:phase::?"; "")' 2>/dev/null)"
    [ -n "$_adopt_ph" ] || _adopt_ph="Requirements"
    _ph_rem="$(printf '%s' "$body" | jq -r --arg keep "ssdlc:phase::$_adopt_ph" '[.labels[]? | select(startswith("ssdlc:phase:")) | select(. != $keep)] | join(",")' 2>/dev/null)"
    # Resolve the story KIND for this adoption: PRESERVE an existing kind:: label (dual-scheme read);
    # a fresh adopt defaults to development (the STRICTEST set — an omission can never lighten the gate). An
    # explicit requested kind that CONFLICTS with a different existing label is refused loudly (no silent re-kind).
    local _adopt_kind _k_rem _kind_distinct
    # DISTINCT normalized values, same semantics as backend_get_kind: dual-scheme same-value is
    # ONE kind; two DISTINCT values is a true ambiguity — adoption REFUSES rather than silently picking one (the old
    # first-label pick would let the LIGHTER kind win a conflict). The ONE
    # sanctioned repair is an EXPLICIT `--kind <v>` on the adopt itself (an auditable operator disambiguation — the
    # mutex write then strips every other kind label); `story set kind=` is not available pre-adoption.
    _kind_distinct="$(printf '%s' "$body" | jq -r '[.labels[]? | select(startswith("kind:")) | sub("^kind::?"; "")] | unique | length' 2>/dev/null)"
    if [ "${_kind_distinct:-0}" -gt 1 ] && [ -z "$want_kind" ]; then
        printf 'story: gitlab backend_adopt: issue #%s carries %s DISTINCT kind label values — a true ambiguity; refusing to adopt rather than silently picking one (the lighter kind must never win a conflict). Disambiguate EXPLICITLY: story adopt %s --type <t> --epic <E0N> --kind <development|analysis|documentation|ops> (or remove the stray kind:: label on the issue first).\n' "$iid" "$_kind_distinct" "$iid" >&2
        return 1
    fi
    if [ "${_kind_distinct:-0}" -gt 1 ]; then
        _adopt_kind=""   # ambiguous + explicit --kind: the operator's choice wins (auditable); skip the single-label conflict check
    else
        _adopt_kind="$(printf '%s' "$body" | jq -r '([.labels[]? | select(startswith("kind:"))][0] // "") | sub("^kind::?"; "")' 2>/dev/null)"
    fi
    if [ -n "$want_kind" ] && [ -n "$_adopt_kind" ] && [ "$want_kind" != "$_adopt_kind" ]; then
        printf 'story: gitlab backend_adopt: issue #%s already carries kind::%s — refusing the conflicting --kind %s (a kind changes only via `story set %s kind=%s`, an auditable label event).\n' \
            "$iid" "$_adopt_kind" "$want_kind" "$iid" "$want_kind" >&2
        return 1
    fi
    [ -n "$_adopt_kind" ] || _adopt_kind="${want_kind:-development}"
    # [CySec] Prevents CWE-74 "Injection": the kind read from an ISSUE LABEL is untrusted input that lands in the
    # comma-separated add_labels PUT — a crafted label name carrying a comma (GitLab allows them) would inject
    # arbitrary extra labels into the adoption write. Only the canonical kinds (proof_kind_is_valid) may ever be written; anything
    # else refuses the adoption loudly (write-side exactness — silently re-kinding to development would be worse).
    case "$_adopt_kind" in
        development|analysis|documentation|ops) : ;;
        *) printf 'story: gitlab backend_adopt: issue #%s carries a NON-CANONICAL kind label value "%s" — refusing to adopt until it is repaired (use one of kind::development|kind::analysis|kind::documentation|kind::ops).\n' "$iid" "$_adopt_kind" >&2; return 1 ;;
    esac
    _k_rem="$(printf '%s' "$body" | jq -r --arg keep "kind::$_adopt_kind" '[.labels[]? | select(startswith("kind:")) | select(. != $keep)] | join(",")' 2>/dev/null)"
    # Resolve the SEVERITY the same way: keep the issue's one canonical severity; a requested one that differs is
    # refused (a severity changes through an auditable label event, not a silent re-adopt); with none on the issue and
    # none requested the adoption is refused, so no story enters the lifecycle unranked. A non-canonical or ambiguous
    # severity on the issue is replaced only by an explicit --severity.
    local _adopt_sev _sev_vals _s_rem
    _sev_vals="$(printf '%s' "$body" | jq -r '[.labels[]? | select(startswith("severity:")) | sub("^severity::?"; "")] | unique | join(",")' 2>/dev/null)"
    case "$_sev_vals" in
        critical|high|medium|low) _adopt_sev="$_sev_vals" ;;
        "") _adopt_sev="" ;;
        *) _adopt_sev="?" ;;
    esac
    if [ -n "$want_severity" ]; then
        if [ -n "$_adopt_sev" ] && [ "$_adopt_sev" != "?" ] && [ "$_adopt_sev" != "$want_severity" ]; then
            printf 'story: gitlab backend_adopt: issue #%s already carries severity::%s — refusing the conflicting --severity %s (change the label on the issue itself, an auditable label event).\n' "$iid" "$_adopt_sev" "$want_severity" >&2
            return 1
        fi
        _adopt_sev="$want_severity"
    elif [ -z "$_adopt_sev" ] || [ "$_adopt_sev" = "?" ]; then
        printf 'story: gitlab backend_adopt: issue #%s carries %s — give one with --severity critical | high | medium | low (critical: a live outage or exposure; high: a security gap, a check that fails open, or a fault that stops work or loses data; medium: a defect with a workaround, or a requested feature; low: polish or parked work). Nothing was adopted.\n' \
            "$iid" "$( [ -z "$_sev_vals" ] && printf 'no severity' || printf 'no single canonical severity (%s)' "$_sev_vals")" >&2
        return 1
    fi
    _s_rem="$(printf '%s' "$body" | jq -r --arg keep "severity::$_adopt_sev" '[.labels[]? | select(startswith("severity:")) | select(. != $keep)] | join(",")' 2>/dev/null)"
    # SELF-ASSIGN: an adopted (status::doing) story must show WHO is working it. When the issue has NO assignee,
    # claim it for the token's own user, stamped ATOMICALLY in this SAME PUT (no unassigned-while-doing window). NEVER
    # overwrite an EXISTING assignee — a human or another agent may have claimed it, and stealing that is worse than a
    # blank. If the id can't be resolved (offline), adopt WITHOUT assign and warn (fail-open — an assignee never blocks
    # adoption). This prevents a story being status::doing but unassigned ("half-adopted").
    local _assign_field="" _ast
    _ast="$(_gl_self_assign_state "$iid" "$body")"
    case "$_ast" in
        assign:*) _assign_field="assignee_ids=${_ast#assign:}" ;;
        unresolved|unreadable)
            printf 'story: gitlab backend_adopt: could not resolve this token'\''s GitLab user id — adopting #%s WITHOUT self-assign (assign it with: story set %s assignee=self).\n' "$iid" "$iid" >&2 ;;
    esac
    _gl_write PUT "issues/$iid" \
        "description=$(_gl_strip_title_h1 "$newdesc")" "milestone_id=$mid" \
        "add_labels=$_GL_STORY_LABEL,status::doing,type::$type,ssdlc:phase::$_adopt_ph,kind::$_adopt_kind,severity::$_adopt_sev${_vl:+,$_vl}" \
        "remove_labels=$(_gl_status_others doing)${_ph_rem:+,$_ph_rem}${_k_rem:+,$_k_rem}${_s_rem:+,$_s_rem}" \
        ${_assign_field:+"$_assign_field"} || return 1
    _gl_forget_issue "issues/$iid" rendered   # the description was replaced: later steps must read the adopted body
    [ -z "$_assign_field" ] || _gl_warn_lost_claim "$iid" "${_ast#assign:}"
    printf '%s' "$iid"
}

# _gl_set_desc_bullet <iid> <field> <val> — set/insert a `- **Field:** val` bullet in the issue DESCRIPTION and
# PUT it back. Uses awk (NOT sed) to write the value: a `val` containing `|`/`&`/`\` corrupts sed's `s|…|…|`
# (`&` expands to the whole match, `|` ends the command). awk carries `val` as an opaque -v variable — verbatim.
_gl_set_desc_bullet() {
    local iid="$1" field="$2" val="$3" d t
    d="$(_gl_materialize "$iid")/requirements.md"
    if grep -qiE "^[[:space:]]*[-*][[:space:]]+\*\*${field}:\*\*" "$d"; then
        t="$(mktemp)"
        story_tmp_register "$t"
        awk -v f="$field" -v v="$val" -f "$BACKEND_GL_HERE/gl-set-field-bullet.awk" "$d" > "$t" && mv -f "$t" "$d"
    else
        # A NEW metadata bullet is inserted INTO the header — before the first '## ' section OR the
        # '<!-- spec' marker — NOT appended at EOF. Appending put it after the spec body, where `story requirements`
        # (which replaces everything from the first '## ') would silently WIPE it. Header placement keeps it with the
        # other metadata AND makes it survive a spec rewrite. Falls back to EOF only if there is no section/marker.
        t="$(mktemp)"
        story_tmp_register "$t"
        awk -v line="- **$field:** $val" -f "$BACKEND_GL_HERE/gl-insert-metadata-bullet.awk" "$d" > "$t" && mv -f "$t" "$d"
    fi
    _gl_write PUT "issues/$iid" "description=$(_gl_strip_title_h1 "$(cat "$d")")"   # strip the title H1 (the FS mirror keeps it)
}

# backend_set_body <dir> <iid> <full-body> -> replace the issue DESCRIPTION (the whole story body) in one PUT.
# The sanctioned write path behind `story requirements` (author the spec via the tool, not a raw curl PUT). Reuses
# the single _gl_write no-fail-open seam, so a failed write is surfaced + returns non-zero.
backend_set_body() { _gl_write PUT "issues/$2" "description=$(_gl_strip_title_h1 "$3")" && _gl_forget_issue "issues/$2" rendered; }   # never leak the title H1 into the body

# Remote Truth lookups (used by story_remote_truth_problem). Each asks the REMOTE, never the local checkout, and
# returns 0 only on positive evidence; any API failure returns non-zero (the caller refuses: fail-closed).
# The optional <project> is a "group/sub/project" path; empty means the story's own project.
_gl_rt_pid() { if [ -n "${1:-}" ]; then printf '%s' "$1" | sed 's#/#%2F#g'; else printf '%s' "$_GL_PID"; fi; }
# backend_commit_on_trunk <sha> [<project>] -> 0 when the commit is merged onto an integration TRUNK of the remote
# project, i.e. a branch that CONTAINS it is the project's default branch or one of main/master/develop. "Contains it"
# means the commit is an ancestor of that branch's tip (merged in), NOT merely that the object exists on some feature
# branch — that distinction is the whole point: a story closed on a commit that sits only on its own unmerged branch
# was never shipped. Fail-closed: any API failure returns non-zero.
backend_commit_on_trunk() {
    local sha="$1" pid out def
    pid="$(_gl_rt_pid "${2:-}")"; [ -n "$pid" ] || return 1
    # The branches whose history contains this commit.
    # Every page: an old commit is contained in every branch made after it, so a project with many branches lists the
    # trunk after the first 100 (names sort 'feature/...' before 'main'). [RiskMitigation RA-01]
    out="$(_GL_PID="$pid" _gl_paged "repository/commits/$sha/refs?type=branch" 2>/dev/null)" || return 1
    # The project's own default branch (best-effort) plus the conventional GitFlow integration trunks.
    def="$(_GL_PID="$pid" gl_api GET "" 2>/dev/null | jq -r '.default_branch // empty' 2>/dev/null || true)"
    printf '%s' "$out" | json_test 'if type=="array" then any(.[]?; .name as $n | $n=="main" or $n=="master" or $n=="develop" or ($dflt!="" and $n==$dflt)) else false end' --arg dflt "$def"
}
# backend_project_location -> the story's own project as GitLab names it: its web_url without the scheme, lower case
# (e.g. "gitlab.example.com/group/project"). Trunk Reach compares it with the origin a close judges against.
# rc 1 when GitLab does not answer it.
backend_project_location() {
    local url
    url="$(gl_api GET "" 2>/dev/null | jq -r '.web_url // empty' 2>/dev/null)" || return 1
    [ -n "$url" ] || return 1
    url="${url#*://}"; url="${url%/}"
    printf '%s' "$url" | tr '[:upper:]' '[:lower:]'
}
# backend_mr_merged <iid> [<project>] -> 0 when that merge request is merged.
backend_mr_merged() {
    local n="$1" pid out
    pid="$(_gl_rt_pid "${2:-}")"; [ -n "$pid" ] || return 1
    out="$(_GL_PID="$pid" gl_api GET "merge_requests/$n" 2>/dev/null)" || return 1
    [ "$(printf '%s' "$out" | jq -r '.state // empty' 2>/dev/null)" = "merged" ]
}
# backend_mr_stall_reason <iid> [<project>] -> prints a plain sentence when an OPEN merge request is stuck for a reason
# GitLab states, nothing otherwise (merged, closed, still running its pipeline, or unreadable). A merge request armed to
# merge when its pipeline succeeds can stall without ever failing: GitLab records `merge_error` (for example, the user who
# armed it may not merge into the target) and the request stays open, so a close that only waits would wait forever.
backend_mr_stall_reason() {
    local n="$1" pid out err st mu
    pid="$(_gl_rt_pid "${2:-}")"; [ -n "$pid" ] || return 0
    # Advice only, never a gate: one attempt, no retries, so an unreachable GitLab adds one short wait to a refusal.
    out="$(STORY_GITLAB_RETRIES=1 _GL_PID="$pid" gl_api GET "merge_requests/$n" 2>/dev/null)" || return 0
    [ "$(printf '%s' "$out" | jq -r '.state // empty' 2>/dev/null)" = opened ] || return 0
    # [CySec] merge_error can carry a server hook's output: terminal escape sequences and other control characters are
    # dropped and the text is cut, so it reaches the agent's terminal as one plain line (CWE-150).
    err="$(printf '%s' "$out" | jq -r '(.merge_error // "") | tostring | gsub("\u001b\\[[0-9;?]*[ -/]*[@-~]"; "")
        | gsub("[\u0000-\u001f\u007f]+"; " ") | if length > 300 then .[0:300] + "..." else . end' 2>/dev/null)"
    st="$(printf '%s' "$out" | jq -r '.detailed_merge_status // empty' 2>/dev/null)"
    mu="$(printf '%s' "$out" | jq -r '.merge_user.username // empty' 2>/dev/null)"
    if [ -n "$err" ]; then
        printf 'GitLab refused the merge and it will not retry: "%s"%s. Waiting will not help: fix the cause (when it is a missing merge right, cancel the arm and arm it again as a user who may merge, for example through the bridge merge request verbs), then close.' \
            "$err" "${mu:+ (armed by $mu)}"
        return 0
    fi
    case "$st" in
        conflict|need_rebase|not_approved|discussions_not_resolved|draft_status|blocked_status|jira_association_missing|requested_changes|merge_request_blocked)
            printf 'GitLab reports the merge request cannot merge yet: %s. Waiting will not change that on its own: resolve it, then close.' "$st" ;;
    esac
    return 0
}
# backend_branch_merged_on_remote <branch> [<project>] -> 0 when a MERGED merge request used <branch> as its source
# (covers a squash-merged, deleted branch whose local commits no remote ref contains).
backend_branch_merged_on_remote() {
    local br="$1" pid out enc
    pid="$(_gl_rt_pid "${2:-}")"; [ -n "$pid" ] || return 1
    enc="$(printf '%s' "$br" | jq -sRr @uri)"
    out="$(_GL_PID="$pid" gl_api GET "merge_requests?state=merged&source_branch=$enc&per_page=1" 2>/dev/null)" || return 1
    [ "$(printf '%s' "$out" | jq -r 'if type=="array" then length else 0 end' 2>/dev/null)" -gt 0 ] 2>/dev/null
}

# backend_reopen_rootcause_problem <dir> <iid> -> print a REFUSAL when the issue was REOPENED
# and NO root-cause has been recorded SINCE the last reopen, else nothing. A reopened story is a control that
# previously declared compliance and was wrong — re-closing it without recording WHY the prior proof passed is how
# the same defect re-closes twice (the reopened-twice pattern). The record is a non-system note,
# posted AFTER the last reopen, carrying the greppable marker "Reopen-Root-Cause:". DEFAULT-ON: an
# unset/blank/garbage PROOF_REOPEN_ROOTCAUSE ENFORCES; only an explicit
# off|0|false|no opts out. Fail-OPEN on the innocent path (never reopened -> no gate) and on an unreadable events
# API (cannot judge -> do not block).
backend_reopen_rootcause_problem() {
    local iid="$2" reopened_at notes have
    kyklos_control_off "${PROOF_REOPEN_ROOTCAUSE:-}" && return 0
    reopened_at="$(backend_last_reopen_at "$1" "$iid")" || return 0    # unreadable events -> cannot judge
    [ -n "$reopened_at" ] || return 0                                   # never reopened -> no gate
    notes="$(_gl_paged "issues/$iid/notes" 2>/dev/null)" || notes="[]"
    have="$(printf '%s' "$notes" | jq -r --arg t "$reopened_at" --arg m "$STORY_REOPEN_ROOT_CAUSE_MARKER" \
        '[.[]? | select((.system|not) and (.created_at > $t) and (.body | ascii_downcase | contains($m | ascii_downcase)))] | length' 2>/dev/null)"
    [ "${have:-0}" -gt 0 ] && return 0
    printf 'issue #%s was REOPENED (last %s) and no root-cause has been recorded since — before re-closing, record WHY the previous proof passed while the work was wrong: story reopen-root-cause %s --reason "<why>" (or --file <f>), which posts the "%s" note; an unexplained reopen must never silently re-close' "$iid" "$reopened_at" "$iid" "$STORY_REOPEN_ROOT_CAUSE_MARKER"
}

# backend_last_reopen_at <dir> <iid> -> the time of the issue's last reopen on stdout (empty when it was never
# reopened); rc 1 when the state events cannot be read. One reader for the re-close gate and the root-cause verb.
backend_last_reopen_at() {
    local ev
    ev="$(_gl_paged "issues/$2/resource_state_events" 2>/dev/null)" || return 1
    printf '%s' "$ev" | json_test 'type == "array"' || return 1
    printf '%s' "$ev" | jq -r '[.[]? | select(.state=="reopened")] | sort_by(.created_at) | last | .created_at // empty' 2>/dev/null
}

# _gl_reopen_problem <iid> [reopen] -> print why a write that would REOPEN issue <iid> must not be sent, else nothing.
# A closed story is reopened only when the caller passes the explicit token "reopen" (story set --reopen --reason,
# which also records the root cause); an issue whose state cannot be read is never written blind. [RiskMitigation
# RA-01] The check lives in the write function itself, so every caller (set, resume, migrate, a future one) inherits it.
_gl_reopen_problem() {
    local iid="$1" explicit="${2:-}" j state
    if ! j="$(_gl_issue "$iid" 2>/dev/null)"; then
        printf 'could not read the state of issue #%s, so a status that would reopen it was not sent; retry when GitLab answers' "$iid"
        return 0
    fi
    state="$(printf '%s' "$j" | jq -r '.state // empty' 2>/dev/null)"
    case "$state" in
        opened) : ;;
        closed) [ "$explicit" = reopen ] || printf 'issue #%s is CLOSED; an open status would reopen it, and a reopen must be explicit and explained: story set %s status=<status> --reopen --reason "<why the closed work must be reopened>"' "$iid" "$iid" ;;
        *) printf 'issue #%s has an unexpected state "%s", so a status that would reopen it was not sent' "$iid" "$state" ;;
    esac
}

# backend_set_field <dir> <iid> <field> <val> [reopen] — Status→status::* label mutex + close/reopen; Type→label;
# Epic→milestone AND the readable bullet; title→PUT title; anything else→edit that description bullet and PUT the
# description. An open status on a CLOSED issue is refused unless the fifth argument is the explicit token "reopen".
backend_set_field() {
    local iid="$2" field="$3" val="$4" old a _rp
    case "$field" in
        Status)
            _st="$(story_normalize_status "$val")"
            if story_status_is_open_work "$_st"; then
                _rp="$(_gl_reopen_problem "$iid" "${5:-}")"
                [ -z "$_rp" ] || { printf 'story: refused: %s\n' "$_rp" >&2; return 1; }
            fi
            case "$_st" in
                Done)        _gl_write PUT "issues/$iid" "state_event=close"  "remove_labels=$_GL_STATUS_ALL_LABELS" ;;
                In-progress)
                    # Phase-coherence at the CHOKEPOINT: a `status::doing` issue MUST carry an
                    # `ssdlc:phase::` label — a doing-with-no-phase story is the incoherence. cmd_set enforces this
                    # for the interactive path, but backend_set_field is ALSO reached by cmd_migrate (and any future
                    # caller), which would otherwise write a phaseless status::doing. Enforce it HERE so EVERY writer
                    # inherits it: if no phase label is present, seed Requirements atomically in the same PUT (mirrors
                    # backend_adopt) — the invariant is closed at the label-writing chokepoint, not just one command.
                    local _ph_add=""
                    [ -n "$(_gl_get_scoped "$iid" "ssdlc:phase" 2>/dev/null)" ] || _ph_add=",ssdlc:phase::Requirements"
                    # Self-assign in the SAME write when the story has no assignee (never overwrites one; an
                    # unresolved identity only warns, so the status change is never blocked by it).
                    local _as="" _ast; _ast="$(_gl_self_assign_state "$iid")"
                    case "$_ast" in
                        assign:*) _as="assignee_ids=${_ast#assign:}" ;;
                        unresolved|unreadable) printf 'story: could not resolve this token'"'"'s GitLab user, so #%s stays unassigned; assign it with: story set %s assignee=self\n' "$iid" "$iid" >&2 ;;
                    esac
                    _gl_write PUT "issues/$iid" "state_event=reopen" "add_labels=status::doing${_ph_add}" "remove_labels=$(_gl_status_others doing)" ${_as:+"$_as"} \
                        && { [ -z "$_as" ] || _gl_warn_lost_claim "$iid" "${_ast#assign:}"; } ;;
                Blocked)     _gl_write PUT "issues/$iid" "state_event=reopen" "add_labels=status::blocked" "remove_labels=$(_gl_status_others blocked)" ;;
                # Parked: an OPEN deferred state - the ssdlc:phase:: label survives, so the resume
                # rule (phase present -> In-progress, else Todo; `story resume`) is derivable by construction.
                Parked)      _gl_write PUT "issues/$iid" "state_event=reopen" "add_labels=status::parked"  "remove_labels=$(_gl_status_others parked)"  ;;
                # Terminal reasons: CLOSE the issue carrying exactly one status::<reason>.
                Wontfix)     _gl_write PUT "issues/$iid" "state_event=close"  "add_labels=status::wontfix"   "remove_labels=$(_gl_status_others wontfix)"   ;;
                Duplicate)   _gl_write PUT "issues/$iid" "state_event=close"  "add_labels=status::duplicate" "remove_labels=$(_gl_status_others duplicate)" ;;
                Invalid)     _gl_write PUT "issues/$iid" "state_event=close"  "add_labels=status::invalid"   "remove_labels=$(_gl_status_others invalid)"   ;;
                Archived)    _gl_write PUT "issues/$iid" "state_event=close"  "add_labels=status::archived"  "remove_labels=$(_gl_status_others archived)"  ;;
                *)           _gl_write PUT "issues/$iid" "state_event=reopen" "add_labels=status::todo"    "remove_labels=$(_gl_status_others todo)"    ;;
            esac
            # Keep the description BODY's `- **Status:**` bullet in sync with the native state, so a closed issue read
            # directly on GitLab (the SSoT) does not still say "Status: Todo". The READ side
            # already re-derives Status from native state, but the raw body is what a human sees on the issue page.
            _gl_set_desc_bullet "$iid" Status "$_st" ;;
        Story-Type)
            # scoped mutex: one canonical type::<val>, removing any legacy type:* / other type::* (dual-read-safe).
            _gl_set_scoped "$iid" "type" "$val" ;;
        Kind)
            # the kind:: label IS the source of record on gitlab (no description bullet) — mutex-set it
            # (one kind by construction). Value validation (the canonical kinds, proof_kind_is_valid) lives in the CLI (cmd_set).
            _gl_set_scoped "$iid" "kind" "$val" ;;
        Epic)
            # Native grouping is the milestone; but the READ side (backend_get_field/epic_members) reads the Epic
            # BULLET, so keep BOTH in sync — otherwise a set-then-read returns the stale value (asymmetry bug).
            # A story never moves into a closed epic (the bridge's story_field_set refuses the same).
            if _gl_milestone_closed "$val"; then
                printf 'story: epic %s is closed; a story moves only into an open epic. Reopen it (story epic reopen %s) or choose another.\n' "$val" "$val" >&2
                return 1
            fi
            old="$(_gl_milestone_id "$val")"; [ -n "$old" ] && _gl_write PUT "issues/$iid" "milestone_id=$old"
            _gl_set_desc_bullet "$iid" Epic "$val" ;;
        Assignee)
            # `story set <id> assignee=self` (the only value; cmd_set refuses any other): claim an UNASSIGNED story for
            # this token's user. An existing assignee is never overwritten, so a backfill loop is safe to re-run.
            local _ast; _ast="$(_gl_self_assign_state "$iid")"
            case "$_ast" in
                assign:*) _gl_write PUT "issues/$iid" "assignee_ids=${_ast#assign:}" || return 1
                    local _owner
                    if ! _owner="$(_gl_claim_held "$iid" "${_ast#assign:}")"; then
                        printf 'story: assignee: #%s was claimed by %s at the same moment; it stays theirs and is NOT yours.\n' "$iid" "$_owner" >&2
                        return 1
                    fi ;;
                already) printf 'story: #%s already has an assignee; left unchanged.\n' "$iid" >&2 ;;
                *) printf 'story: assignee: could not %s for #%s, so nothing was changed.\n' \
                       "$([ "$_ast" = unresolved ] && echo "resolve this token's GitLab user" || echo "read the issue")" "$iid" >&2
                   return 1 ;;
            esac ;;
        title)
            _gl_write PUT "issues/$iid" "title=$val" ;;
        *)
            _gl_set_desc_bullet "$iid" "$field" "$val" ;;
    esac
}

backend_set_title()   { _gl_write PUT "issues/$2" "title=$3"; }   # <dir> <handle> <val>

# The proof lives as a NOTE on the issue, prefixed with a hidden MARKER so it can be found + replaced (idempotent)
# and read back verbatim — the story-proof gate reads it to enforce "Done => a proof with no UNPROVEN row".
_GL_PROOF_MARKER='<!-- kyklos:story-proof -->'
# Notes written under the earlier marker name stay readable and are replaced like current ones; nothing writes it.
_GL_PROOF_MARKER_FORMER='<!-- dogma:story-proof -->'
backend_proof_write() {   # <dir> <iid> <table> — replace our own prior proof note (never stack), then post the new one.
    local iid="$2" nid resp
    # Paginate: an issue with >100 notes would hide our prior proof note on page 2 → duplicates stack on write.
    for nid in $(_gl_paged "issues/$iid/notes" | jq -r --arg m "$_GL_PROOF_MARKER" --arg f "$_GL_PROOF_MARKER_FORMER" '.[]? | select((.body//"")|startswith($m) or startswith($f)) | .id' 2>/dev/null); do
        gl_api DELETE "issues/$iid/notes/$nid" >/dev/null
    done
    # [no-fail-open] gl_api masks HTTP/token errors (a 401 curls fine and returns an error body),
    # so a POST can "succeed" WITHOUT creating the note. VERIFY the write: the
    # response must carry a numeric note id, else FAIL LOUD so the proof is never believed-saved when it wasn't.
    resp="$(gl_api POST "issues/$iid/notes" "body=$(printf '%s\n%s' "$_GL_PROOF_MARKER" "$3")")"
    printf '%s' "$resp" | json_test '(.id // empty) | numbers' || {
        # [MANAGE: self-diagnose + escalate with the fix] Don't just dump the response — name the LIKELY cause and the
        # concrete action, so the failure is actionable rather than opaque.
        local _msg _why
        _msg="$(printf '%s' "$resp" | jq -r '.message? // .error? // empty' 2>/dev/null)"
        if   [ -z "${_GL_TOKNAME:-}" ]; then _why="no API token in the environment (STORY_GITLAB_TOKEN_ENV='${STORY_GITLAB_TOKEN_ENV:-}', and GITLAB_TOKEN is unset) → export the token, then retry"
        elif [ -z "${_GL_PID:-}" ]; then _why="STORY_GITLAB_PROJECT is unset (no target project) → set it, then retry"
        elif printf '%s' "$_msg" | grep -ciE '401|unauthor' >/dev/null; then _why="the token was rejected (401) → check its scope (needs 'api') and expiry"
        elif printf '%s' "$_msg" | grep -ciE '403|forbidden' >/dev/null; then _why="forbidden (403) → the token lacks permission on project '${_GL_PID}'"
        elif printf '%s' "$_msg" | grep -ciE '404' >/dev/null; then _why="project '${_GL_PID}' or issue #${iid} not found (404) → check STORY_GITLAB_PROJECT and the issue number"
        elif [ -n "$_msg" ]; then _why="$_msg"
        else _why="unknown — raw response: $(printf '%s' "$resp" | tr '\n' ' ' | head -c 160)"
        fi
        printf 'story: gitlab backend: FAILED to write the proof note to issue #%s — proof NOT saved.\n  Cause: %s\n  Fix:   re-run once resolved: story proof %s --apply <file>\n' "$iid" "$_why" "$iid" >&2
        return 1
    }
}
backend_proof_read() {    # <dir> <iid> — the proof table text (marker stripped); empty if the issue has no proof note.
    # Read the NEWEST marked note: sort_by(.created_at) then take the last, so a later proof UPDATE always wins
    # regardless of the notes-fetch order. (A bare `last` read whichever the API happened to return last — newest-first
    # fetches then returned the OLDEST proof, so an updated proof silently did not take effect.)
    _gl_paged "issues/$2/notes" \
      | jq -r --arg m "$_GL_PROOF_MARKER" --arg f "$_GL_PROOF_MARKER_FORMER" '[.[]? | select((.body//"")|startswith($m) or startswith($f))] | sort_by(.created_at) | (last // {}) | .body // ""' 2>/dev/null \
      | awk -v m="$_GL_PROOF_MARKER" -v f="$_GL_PROOF_MARKER_FORMER" 'NR==1 && ($0==m || $0==f) {next} {print}'
}
backend_done_handles() {  # <dir> — the iids of the DONE (closed + completed) stories, ascending. Used by the proof gate.
    # EXCLUDE a story closed as a non-development disposition (wontfix/duplicate/invalid): it was DROPPED,
    # not completed, so the proof gate must not retroactively demand a Proof table for it (the close-guard already
    # exempts these labels at close time — this makes the read-path agree). Key off the disposition LABELS.
    # DUAL-READ the scoped `status::<disposition>` forms alongside the legacy bare names: `set status=wontfix`
    # applies ONLY the scoped `status::wontfix`, so matching just the bare name left a disposition-closed story
    # looking Done and the proof gate wrongly demanded a Proof for an abandoned story. MUST mirror the Dropped set
    # in backend_status exactly, so the read-path and the close-guard agree.
    _gl_paged "issues?scope=all&state=closed&labels=$_GL_STORY_LABEL" \
      | jq -r '.[]? | . as $i | ([$i.labels[]? | ascii_downcase]) as $l
               | if ($l | any(. == "wontfix" or . == "duplicate" or . == "invalid"
                              or . == "status::wontfix" or . == "status::duplicate" or . == "status::invalid"))
                 then empty else ($i.iid|tostring) end' 2>/dev/null \
      | sort -n
}

# --- Risk Assessment register seam ---------------------------------------------------------------------------
# The GitLab-native store for the per-story Risk Assessment register: its OWN marker-prefixed NOTE, mirroring the
# proof note (a description-section round-trip would fight the Status-bullet sync + metadata-bullet parser). The
# story-proof gate reads it via backend_ra_read so the RA self-waiver / empty-register checks run on gitlab too.
_GL_RA_MARKER='<!-- kyklos:risk-assessment -->'
_GL_RA_MARKER_FORMER='<!-- dogma:risk-assessment -->'
backend_ra_write() {   # <dir> <iid> <text> — replace our own prior RA note (never stack), then post the new one.
    local iid="$2" nid resp
    for nid in $(_gl_paged "issues/$iid/notes" | jq -r --arg m "$_GL_RA_MARKER" --arg f "$_GL_RA_MARKER_FORMER" '.[]? | select((.body//"")|startswith($m) or startswith($f)) | .id' 2>/dev/null); do
        gl_api DELETE "issues/$iid/notes/$nid" >/dev/null
    done
    # VERIFY the write carried a numeric note id (gl_api masks HTTP/token errors) — never believe an unsaved register.
    resp="$(gl_api POST "issues/$iid/notes" "body=$(printf '%s\n%s' "$_GL_RA_MARKER" "$3")")"
    printf '%s' "$resp" | json_test '(.id // empty) | numbers' || {
        printf 'story: gitlab backend: FAILED to write the Risk Assessment register to issue #%s (token/scope/project?) — register NOT saved.\n' "$iid" >&2
        return 1
    }
}
backend_ra_read() {    # <dir> <iid> — the RA register text (marker stripped); empty if the issue has no RA note.
    # sort_by(.created_at) before last, exactly like backend_proof_read: a later RA UPDATE must win. The
    # notes API does not guarantee creation order, so without the sort a STALE earlier register could be read.
    _gl_paged "issues/$2/notes" \
      | jq -r --arg m "$_GL_RA_MARKER" --arg f "$_GL_RA_MARKER_FORMER" '[.[]? | select((.body//"")|startswith($m) or startswith($f))] | sort_by(.created_at) | (last // {}) | .body // ""' 2>/dev/null \
      | awk -v m="$_GL_RA_MARKER" -v f="$_GL_RA_MARKER_FORMER" 'NR==1 && ($0==m || $0==f) {next} {print}'
}

# --- epics (milestones) ------------------------------------------------------------------------------------------
# The epic contract: the story tool decides (which epic, may it close, may it go); these only read and write GitLab.
# An epic is a milestone titled "<epic id> — <title>" whose description is the goal.

# backend_epic_records <dir> -> every epic of the project as one JSON array of {epic, id, title, goal, active, start, due}
# (start/due a yyyy-MM-dd day or null), ordered by epic number then milestone id. rc 1 when GitLab cannot be read.
backend_epic_records() {
    local body
    body="$(_gl_paged milestones)" || { printf 'story: could not read the milestones of project %s (see the error above); nothing was changed.\n' "${_GL_PID:-?}" >&2; return 1; }
    printf '%s' "$body" | jq -c -f "$BACKEND_GL_HERE/epic-records.jq"
}

# backend_epic_issues <dir> <epic> <id> -> the issues attached to the epic's milestone as one JSON array of
# {iid, title, open, story} (story: carries the story label), ordered by number. rc 1 when GitLab cannot be read.
backend_epic_issues() {
    local body
    body="$(_gl_paged "milestones/$3/issues")" || { printf 'story: could not read the issues of epic %s (see the error above); nothing was changed.\n' "$2" >&2; return 1; }
    printf '%s' "$body" | jq -c --arg l "$_GL_STORY_LABEL" \
      '[.[]? | select(.iid != null) | {iid:(.iid|tostring), title:(.title // ""), open:(.state == "opened"), story:(((.labels // []) | map(if type == "object" then .name else . end) | index($l)) != null)}] | sort_by(.iid|tonumber)'
}

# backend_epic_create <dir> <epic> <title> <goal> <start> <due> -> create the epic's milestone (an empty date is left
# unset); prints the new milestone id.
backend_epic_create() {
    local -a args=("title=$2 — $3" "description=$4")
    [ -n "$5" ] && args+=("start_date=$5")
    [ -n "$6" ] && args+=("due_date=$6")
    local resp; resp="$(gl_api POST milestones "${args[@]}")" || { echo "[story] WRITE FAILED: POST milestones — the epic was NOT created (see the gl_api error above)." >&2; return 1; }
    printf '%s' "$resp" | jq -r '.id // empty' 2>/dev/null
}

# backend_epic_update <dir> <epic> <id> <changes-json> -> apply the changes given ({title, goal, start_date, due_date,
# active}); a key that is absent is kept as it is, an empty date clears it, active false closes and true reopens.
# Prints nothing (the milestone id does not change).
backend_epic_update() {
    local epic="$2" id="$3" changes="$4" k v
    local -a args=()
    while IFS=$'\t' read -r k v; do
        case "$k" in
            title) args+=("title=$epic — $v") ;;
            goal) args+=("description=$v") ;;
            start_date|due_date) args+=("$k=$v") ;;
            active) if [ "$v" = true ]; then args+=("state_event=activate"); else args+=("state_event=close"); fi ;;
        esac
    done < <(printf '%s' "$changes" | jq -r 'to_entries[] | "\(.key)\t\(.value|tostring)"')
    [ "${#args[@]}" -gt 0 ] || return 0
    _gl_write PUT "milestones/$id" "${args[@]}"
}

# backend_epic_delete <dir> <epic> <id> -> delete the epic's milestone.
backend_epic_delete() { _gl_write DELETE "milestones/$3"; }

# archive marks the closed story with the canonical status::archived (mutex + alias-strip via the
# scoped setter, label-only - never reopens); the legacy bare `archived` converges via the alias machinery.
backend_archive_story() { _gl_set_scoped "$3" "status" "archived"; }

# backend_add_labels <dir> <handle> <csv-labels> -> add free labels to a story (e.g. severity::high, ai-review). A
# GitLab-native concept; the FS backend no-ops it (there are no free labels on a folder story).
backend_add_labels() { [ -n "$3" ] && _gl_write PUT "issues/$2" "add_labels=$3"; }

# The canonical labels the story lifecycle uses. Ensured to EXIST at project level (backend_ensure_labels) so a user
# creating a story by hand in the GitLab GUI can SEE + pick them — the tool knew them, the GUI didn't. Each row
# is name|color|description.
_GL_KNOWN_LABELS="story|#6699cc|SSDLC story (managed by the story tool)
status::todo|#cccccc|Story status: not started
status::doing|#f0ad4e|Story status: in progress
status::blocked|#d9534f|Story status: blocked, reason not recorded (legacy; block it again with its kind)
status::blocked-on-issue|#d9534f|Story status: blocked, waiting on another issue, story or merge request
status::blocked-on-user|#d9534f|Story status: blocked, waiting on the user's answer to a recorded question
status::blocked-on-external|#d9534f|Story status: blocked, waiting on something outside the tracker
type::feat|#5843ad|Story type: feature (conventional-commit)
type::fix|#5843ad|Story type: fix (conventional-commit)
type::docs|#5843ad|Story type: documentation
type::style|#5843ad|Story type: style (conventional-commit)
type::refactor|#5843ad|Story type: refactor (conventional-commit)
type::perf|#5843ad|Story type: perf (conventional-commit)
type::test|#5843ad|Story type: test
type::build|#5843ad|Story type: build (conventional-commit)
type::ci|#5843ad|Story type: CI/CD
type::chore|#5843ad|Story type: chore (conventional-commit)
type::revert|#5843ad|Story type: revert (conventional-commit)
type::library|#5843ad|Story type: library
type::service|#5843ad|Story type: service
type::infra|#5843ad|Story type: infrastructure
type::plugin|#5843ad|Story type: plugin
kind::development|#3d5afe|Story kind: development (full SSDLC rigor; the default — all proof dimensions)
kind::analysis|#ff6f00|Story kind: analysis (research; proof = Completeness + Adversarial Review; soft no-code nudge)
kind::documentation|#00796b|Story kind: documentation (docs; proof = Completeness + Documentation + Adversarial Review; soft no-code nudge)
proof-override|#8e44ad|User-applied: waive the story proof gate (authenticated override)
push-override|#8e44ad|User-applied: authorize a push exception on this story (un-self-grantable)
merge-override|#8e44ad|User-applied: authorize a merge-without-green exception on this story (un-self-grantable)
status::parked|#7f8c8d|Story status: parked (user-deferred; not forced by the continue-guard)
status::wontfix|#616161|Story status: closed as won't-fix
status::duplicate|#9e9e9e|Story status: closed as duplicate
status::invalid|#757575|Story status: closed as invalid
status::archived|#95a5a6|Story status: archived (closed-story history retained on the issue)
ai-review|#5bc0de|Finding raised by the AI reviewer
severity::critical|#d9534f|Finding severity: critical
severity::high|#e67e22|Finding severity: high
severity::medium|#f0ad4e|Finding severity: medium
severity::low|#cccccc|Finding severity: low
ssdlc:phase::Requirements|#1f75cb|SSDLC phase: Requirements (pre-Design structuring/authoring)
ssdlc:phase::Design|#6699cc|SSDLC phase: Design
ssdlc:phase::Implementation|#f0ad4e|SSDLC phase: Implementation
ssdlc:phase::Testing|#8e44ad|SSDLC phase: Testing
ssdlc:phase::Deployment|#2fb380|SSDLC phase: Deployment
ssdlc:phase::Review|#e67e22|SSDLC phase: Review"

# DEPRECATED-NAME label aliases — a legacy label whose NAME differs from its canonical scoped
# twin (unlike backend_prune_legacy_labels, which handles only the `<ns>::<val>`<->`<ns>:<val>` single-colon
# collapse). GitLab auto-creates the built-in default `bug` label in every project; it is a semantic DUPLICATE of the
# scoped `type::fix`, so a work item can land under either — splitting queries and breaking the one-`type::`-value
# invariant. Expressed ONCE here (alias-name|canonical-scoped-label) and consumed by _gl_set_scoped (strip the alias
# when the canonical is set), _gl_get_scoped (dual-READ the alias as its canonical) and backend_prune_aliases
# (migrate issues off the alias, then delete its definition) — so no site hardcodes the `bug` string (poka-yoke: a
# site cannot forget the alias). Add a row per deprecated default that duplicates a scoped label.
_GL_LABEL_ALIASES="bug|type::fix
parked|status::parked
archived|status::archived
wontfix|status::wontfix
duplicate|status::duplicate
invalid|status::invalid"

# The SSDLC phase label suffixes this backend knows, used ONLY as the mutual-exclusion remove-set in
# backend_set_phase (so setting one phase strips every other, INCLUDING the legacy Prerequisites alias). The
# ORDERED sequence + validation is STORY_PHASE_ORDER / story_phase_canon in story-lib.sh — the single
# source of truth. Requirements is now the canonical first phase (in STORY_PHASE_ORDER); this list
# prepends the legacy `Prerequisites` suffix so an old label gets cleaned up on the next set_phase.
_GL_SSDLC_PHASES="Prerequisites $STORY_PHASE_ORDER"

# backend_ensure_labels <dir> — mechanical hygiene: create any KNOWN label missing at project level so it
# shows in the GitLab GUI for a hand-created story, AND RECONCILE the color of an existing KNOWN label that has
# DRIFTED from the SSoT (_GL_KNOWN_LABELS). The color drift was the bug seen across projects: the old code SKIPPED
# every existing label, so when an SSoT color changed (e.g. a new color for type::*) the projects that already had the
# label kept the OLD color forever -> the SAME label showed in DIFFERENT colors across projects (read as duplicates).
# Now a create-if-missing OR a PUT-reconcile-if-drifted keeps every project's colors converged on the SSoT, so the
# drift self-heals on the next story op and can never accumulate again. Idempotent, best-effort / FAIL-OPEN (a
# labels-API hiccup must NEVER block a story create/close), no-op without a write token. Hex compare is
# case-insensitive (GitLab may echo a different case than the SSoT literal).
backend_ensure_labels() {
    [ -n "$_GL_PID" ] && [ -n "$_GL_TOKNAME" ] || return 0
    # name<TAB>color<TAB>id of existing project labels — color+id are needed for the PUT-reconcile, not just create.
    local existing; existing="$(_gl_paged "labels" | jq -r '.[]? | "\(.name)\t\(.color)\t\(.id)"' 2>/dev/null)" || existing=""
    printf '%s\n' "$_GL_KNOWN_LABELS" | while IFS='|' read -r _ln _lc _ld; do
        [ -n "$_ln" ] || continue
        local _row; _row="$(printf '%s\n' "$existing" | awk -F'\t' -v n="$_ln" '$1==n{print; exit}')"
        if [ -z "$_row" ]; then
            gl_api POST "labels" "name=$_ln" "color=$_lc" "description=$_ld" >/dev/null 2>&1 || true   # missing -> create
        else
            local _cur _cid
            _cur="$(printf '%s' "$_row" | cut -f2)"; _cid="$(printf '%s' "$_row" | cut -f3)"
            # exists but the color DRIFTED from the SSoT -> reconcile (PUT by id), case-insensitive hex compare.
            if [ -n "$_lc" ] && [ -n "$_cid" ] \
               && [ "$(printf '%s' "$_cur" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$_lc" | tr '[:upper:]' '[:lower:]')" ]; then
                gl_api PUT "labels/$_cid" "color=$_lc" >/dev/null 2>&1 || true
            fi
        fi
    done
    backend_prune_legacy_labels   # then remove any legacy single-colon duplicates
    backend_prune_aliases         # then converge any deprecated-NAME default (bug -> type::fix)
    return 0
}

# backend_prune_aliases — SELF-HEAL the deprecated-NAME default labels (_GL_LABEL_ALIASES): for
# each alias present in the project (e.g. the built-in `bug`), migrate every issue carrying it onto its canonical
# scoped twin (`type::fix`) via the scoped mutex, THEN DELETE the alias definition so it stops showing as a duplicate
# and new stories cannot pick it. Same shape + safety as backend_prune_legacy_labels: strongest enforcement the
# labels API allows (the alias becomes TRANSIENT, pruned on the next story op, so everything converges and the
# duplicate can never re-accumulate). Idempotent, best-effort / FAIL-OPEN (a labels/issues API hiccup must NEVER
# block a story op), no-op without a write token. NOTE: this deletes only the PROJECT-level alias; retiring the
# instance-wide GitLab default template label is a separate admin action.
backend_prune_aliases() {
    [ -n "$_GL_PID" ] && [ -n "$_GL_TOKNAME" ] || return 0
    local existing; existing="$(_gl_paged "labels" | jq -r '.[]? | "\(.name)\t\(.id)"' 2>/dev/null)" || return 0
    printf '%s\n' "$_GL_LABEL_ALIASES" | while IFS='|' read -r _an _ac; do
        [ -n "$_an" ] && [ -n "$_ac" ] || continue
        local _row; _row="$(printf '%s\n' "$existing" | awk -F'\t' -v n="$_an" '$1==n{print; exit}')"
        [ -n "$_row" ] || continue                                         # alias def not present -> nothing to prune
        local _lid _ns _val; _lid="$(printf '%s' "$_row" | cut -f2)"
        _ns="${_ac%::*}"; _val="${_ac##*::}"                               # <ns>::<val> -> ns + val
        # migrate every issue (any state) carrying the alias onto the canonical via the scoped mutex (reuse, not
        # reinvent): _gl_set_scoped adds the canonical and strips the alias, converging each issue to exactly one.
        local _iid
        for _iid in $(_gl_paged "issues?labels=$_an&state=all" | jq -r '.[]?.iid' 2>/dev/null); do
            _gl_set_scoped "$_iid" "$_ns" "$_val" || true
        done
        [ -n "$_lid" ] && { _gl_write DELETE "labels/$_lid" || true; }      # then delete the alias definition
    done
    return 0
}

# backend_prune_legacy_labels — SELF-HEAL: delete LEGACY single-colon label DEFINITIONS
# that have a canonical scoped `::` twin in the SSoT, AFTER migrating any issues off them. A legacy alias is DERIVED
# from the SSoT (never hardcoded): every known `<ns>::<value>` implies the legacy `<ns>:<value>` (its LAST `::`
# collapsed to a single `:`) — e.g. type::feat -> type:feat, ssdlc:phase::Design -> ssdlc:phase:Design. For each
# legacy label present in the project: relabel every issue carrying it onto the canonical (native scoped mutex),
# THEN DELETE the legacy definition so it stops showing as a duplicate. This is the strongest ENFORCEMENT the labels
# API allows: legacy labels become TRANSIENT — pruned on the next story op, in every project, so the drift can never
# accumulate again. Runs only when a legacy def actually exists (post-cleanup it is a cheap no-op). Idempotent,
# best-effort / FAIL-OPEN (a labels/issues API hiccup must NEVER block a story op), no-op without a write token.
backend_prune_legacy_labels() {
    [ -n "$_GL_PID" ] && [ -n "$_GL_TOKNAME" ] || return 0
    local existing; existing="$(_gl_paged "labels" | jq -r '.[]? | "\(.name)\t\(.id)"' 2>/dev/null)" || return 0
    printf '%s\n' "$_GL_KNOWN_LABELS" | while IFS='|' read -r _kn _ _; do
        case "$_kn" in *::*) ;; *) continue ;; esac                       # only scoped known labels have a legacy twin
        local _legacy; _legacy="$(printf '%s' "$_kn" | sed 's/::\([^:]*\)$/:\1/')"    # collapse the LAST :: -> :
        [ "$_legacy" = "$_kn" ] && continue
        local _row; _row="$(printf '%s\n' "$existing" | awk -F'\t' -v n="$_legacy" '$1==n{print; exit}')"
        [ -n "$_row" ] || continue                                        # legacy def not present -> nothing to prune
        local _lid _ns _val; _lid="$(printf '%s' "$_row" | cut -f2)"
        _val="${_kn##*::}"; _ns="${_kn%::*}"                              # <ns>::<val> -> ns + val
        # migrate every issue carrying the legacy label onto the canonical via the SCOPED MUTEX helper (reuse, not
        # reinvent): _gl_set_scoped adds <ns>::<val> and strips every OTHER label in the namespace (both schemes), so
        # a pre-migration issue converges to exactly one — never a legacy+scoped or a double-scoped pair.
        local _iid
        for _iid in $(_gl_paged "issues?labels=$_legacy&state=all" | jq -r '.[]?.iid' 2>/dev/null); do
            _gl_set_scoped "$_iid" "$_ns" "$_val" || true
        done
        [ -n "$_lid" ] && { _gl_write DELETE "labels/$_lid" || true; }     # then delete the legacy definition
    done
    return 0
}
# Generic GitLab-SCOPED multi-level-label helpers — the canonical scheme for EVERY multi-level namespace
# (ssdlc:phase, type, kind, severity, for). A WRITE adds `<ns>::<value>` and removes every OTHER label in the
# namespace across BOTH schemes (legacy `<ns>:*` and scoped `<ns>::*`) so a pre-migration / web-UI-dirtied issue
# converges to exactly one — the native GitLab scoped-label mutex, the same guarantee `status::*` gets. A READ
# dual-reads both schemes, preferring the scoped canonical. (status keeps its OWN helper above: it also carries the
# oldest `S:*` scheme.) The namespaces have no regex metacharacters, so `test("^"+ns+":")` is a safe literal match.
# _gl_alias_names_for <canonical> — space-list of deprecated alias NAMES whose canonical is the
# given scoped label (e.g. `type::fix` -> `bug`), derived from _GL_LABEL_ALIASES (never hardcoded at the call site).
_gl_alias_names_for() {
    local canon="$1"
    printf '%s\n' "$_GL_LABEL_ALIASES" | while IFS='|' read -r _an _ac; do
        [ -n "$_an" ] && [ "$_ac" = "$canon" ] && printf '%s ' "$_an"
    done
}
# _gl_alias_canonical <name> — the canonical scoped label for a deprecated alias name, or empty.
_gl_alias_canonical() {
    local name="$1"
    printf '%s\n' "$_GL_LABEL_ALIASES" | while IFS='|' read -r _an _ac; do
        [ "$_an" = "$name" ] && { printf '%s' "$_ac"; return; }
    done
}
# _ensure_kyklos_version_label <iid> — ensure the story issue carries a `kyklos:version::<v>` label
# naming the plugin version acting on it. add_labels is ADDITIVE and idempotent (a version already present is a
# no-op; a newer plugin adds a second label, which is allowed by design so the labels record the version history).
# Fails SOFT: an unresolvable version or a labelling error never aborts the primary operation (rc always 0). Every
# story function that CREATES or MUTATES an issue calls this (or folds the label into its own write — see
# _gl_set_scoped, which appends it to its existing PUT to avoid an extra API round-trip).
_ensure_kyklos_version_label() {
    local iid="$1" vl
    [ -n "$iid" ] || return 0
    command -v kyklos_version_label >/dev/null 2>&1 || return 0
    vl="$(kyklos_version_label)" || return 0
    [ -n "$vl" ] || return 0
    _gl_write PUT "issues/$iid" "add_labels=$vl" >/dev/null 2>&1 || true
    return 0
}

_gl_set_scoped() {   # <iid> <namespace> <value>  — mutex-set the canonical <namespace>::<value>
    local iid="$1" ns="$2" val="$3" rem alias_names _vl
    rem="$(_gl_issue "$iid" | jq -r --arg ns "$ns" --arg keep "$ns::$val" \
        '[ .labels[]? | select(test("^" + $ns + ":")) | select(. != $keep) ] | join(",")' 2>/dev/null)"
    # ALSO strip any deprecated-name alias of the canonical being set (e.g. setting type::fix
    # removes the built-in `bug`), so the alias converges to the canonical — the same mutex guarantee, across names.
    for _a in $(_gl_alias_names_for "$ns::$val"); do
        case ",$rem," in *",$_a,"*) : ;; *) rem="${rem:+$rem,}$_a" ;; esac
    done
    # fold the kyklos-version label into THIS lifecycle write (no extra round-trip) so every scoped-label
    # change — phase/status/type/severity — also stamps the acting plugin version.
    _vl="$(command -v kyklos_version_label >/dev/null 2>&1 && kyklos_version_label || true)"
    _gl_write PUT "issues/$iid" "add_labels=$ns::$val${_vl:+,$_vl}" ${rem:+"remove_labels=$rem"}
}
_gl_get_scoped() {   # <iid> <namespace> -> current value (suffix), preferring the scoped canonical, or empty
    local iid="$1" ns="$2" v
    v="$(_gl_issue "$iid" | jq -r --arg ns "$ns" \
        '[ .labels[]? | select(test("^" + $ns + ":")) ] as $m
         | ( ($m | map(select(startswith($ns + "::"))) | .[0]) // ($m | .[0]) // "" )
         | sub("^" + $ns + "::?"; "")' 2>/dev/null | head -1)"
    [ -n "$v" ] && { printf '%s' "$v"; return; }
    # DUAL-READ: no scoped/legacy label in this namespace -> fall back to a deprecated-name alias
    # that maps INTO this namespace (e.g. an issue carrying only the built-in `bug` reads as type value `fix`), so a
    # `type::fix` selection is never fooled into 0 by an alias-only issue (the partial-sweep all-clear trap).
    local labels; labels="$(_gl_issue "$iid" | jq -r '.labels[]?' 2>/dev/null)"
    printf '%s\n' "$_GL_LABEL_ALIASES" | while IFS='|' read -r _an _ac; do
        case "$_ac" in "$ns::"*) ;; *) continue ;; esac                    # alias canonical is in THIS namespace
        printf '%s\n' "$labels" | grep -cxF "$_an" >/dev/null && { printf '%s' "${_ac##*::}"; break; }
    done
}
# backend_set_phase <dir> <handle> <Phase> — set the story's ssdlc:phase::<Phase>, removing any OTHER phase label
# (mutex). The caller (cmd_phase) validates <Phase> with story_phase_canon (story-lib.sh).
backend_set_phase() { _gl_set_scoped "$2" "ssdlc:phase" "$3"; }
# backend_get_phase <dir> <handle> -> the story's CURRENT phase name, dual-reading legacy + scoped.
backend_get_phase() { _gl_get_scoped "$2" "ssdlc:phase"; }

# [phase-walk gate] backend_phase_walked <dir> <iid> -> rc 0 when the SERVER-side label-event history shows the
# work ENTERED Implementation (scoped or legacy form) BEFORE this close; rc 1 = a phase jump (the story is being
# closed over an unwalked history), or a history longer than the page cap (refused, never judged on a part of it).
# The WHOLE history is read (_gl_paged: every page): GitLab's default first page of 20 events can hide the
# Implementation add of a story with many events. A fetch failure is fail-OPEN with a LOUD notice: a transient must never
# wedge a close, and the gate re-arms on the next attempt. The events live server-side, so an agent cannot rewrite them.
# [RiskMitigation RA-01] the phase walk is judged on every page of the history.
backend_phase_walked() {
    local iid="$2" ev rc=0
    ev="$(_gl_paged "issues/$iid/resource_label_events")" || rc=$?
    if [ "$rc" -eq 4 ]; then
        printf 'story: phase-walk gate: the label-event history of #%s is longer than the page cap; refusing to judge the phase walk on a part of it.\n' "$iid" >&2
        return 1
    fi
    [ "$rc" -eq 0 ] || {
        printf 'story: phase-walk gate: label-event history UNAVAILABLE for #%s — allowing this close (transient fail-open; the check re-arms on the next attempt).\n' "$iid" >&2
        return 0
    }
    # A NON-ARRAY payload (an error body, or an endpoint the test stub did not can) is UNKNOWN history, not a
    # jump — only a REAL event list that lacks the Implementation add is positive evidence. Fail-open loud.
    if ! printf '%s' "$ev" | json_test 'type == "array"'; then
        printf 'story: phase-walk gate: label-event history UNREADABLE for #%s — allowing this close (unknown history is never graded as a jump).\n' "$iid" >&2
        return 0
    fi
    printf '%s' "$ev" | json_test '
        [.[]? | select(.action=="add") | (.label.name // "")]
        | any(. == "ssdlc:phase::Implementation" or . == "ssdlc:phase:Implementation")'
}
# backend_owner_override <dir> <iid> -> rc 0 iff the owner's exception label (OWNER_OVERRIDE_LABEL, a fixed name from
# hooks/lib/owner-labels.sh) is on the issue AND its latest label event is an `add` by a GitLab user OTHER than this token's user.
# It is the only way past the Done gates for a tracker story: the agent cannot author a label event as another user, so
# it cannot grant the exception to itself. FAIL-CLOSED on every uncertainty (events or own identity unreadable, or a
# history longer than the page cap). The WHOLE history is read (_gl_paged): the latest event of the label may sit on
# any page. Named Cause: the label also needs the story to name the cause of its gap, which the bridge decides
# (override_cause_named, hooks/lib/override-cause.sh); no bridge answer, no override. [RiskMitigation RA-01]
# [CySec] CWE-863 "Incorrect Authorization": a self-applied label, or one whose cause is not named, confers nothing.
backend_owner_override() {
    local iid="$2" ev self lbl
    # shellcheck source=../../../hooks/lib/owner-labels.sh
    . "$STORY_BACKEND_HERE/../../../hooks/lib/owner-labels.sh" || return 1   # unreadable label names: no override
    lbl="$OWNER_OVERRIDE_LABEL"
    self="$(_gl_self_user_id 2>/dev/null || true)"
    [ -n "$self" ] || return 1
    ev="$(_gl_paged "issues/$iid/resource_label_events")" || return 1
    printf '%s' "$ev" | json_test '
        type == "array"
        and (([ .[] | select(((.label.name // "") | ascii_downcase) == $lbl) ] | sort_by(.id) | last) as $e
             | $e != null and $e.action == "add" and (($e.user.id // "") | tostring) != "" and (($e.user.id | tostring) != $self))' --arg lbl "$lbl" --arg self "$self" \
        || return 1
    # Named Cause: the label waives the gates only when the story names the cause of its gap; the bridge decides it.
    # shellcheck source=../../../hooks/lib/override-cause.sh
    . "$STORY_BACKEND_HERE/../../../hooks/lib/override-cause.sh" || return 1
    override_cause_named "${_GL_PID:-${STORY_GITLAB_PROJECT:-}}" "$iid" && return 0
    printf "story: the owner's '%s' label is on #%s but waives nothing: %s\n" "$lbl" "$iid" "$OVERRIDE_CAUSE_WHY" >&2
    return 1
}
# backend_get_kind <dir> <handle> -> the story's kind (raw label suffix), or empty when absent.
# AMBIGUITY IS STRICTEST: an issue carrying MORE THAN ONE kind label (hand-applied outside the tool — the mutex
# write makes this impossible through any tool path) reads as `development` (the FULL dimension set) with a loud
# warning, so a doctored label set can only RAISE the bar, never lighten it. [RiskMitigation RA-03]
backend_get_kind() {
    local iid="$2" n
    # DISTINCT normalized values, not raw labels: mid-migration an issue can carry the SAME value under both
    # schemes (kind:analysis + kind::analysis) — that is ONE kind (the house dual-read), not an ambiguity.
    n="$(_gl_issue "$iid" | jq -r '[.labels[]? | select(test("^kind:")) | sub("^kind::?"; "")] | unique | length' 2>/dev/null)"
    if [ "${n:-0}" -gt 1 ]; then
        printf 'story: WARNING — issue #%s carries %s kind labels (ambiguous); reading the STRICTEST kind (development). Repair with `story set %s kind=<value>`.\n' "$iid" "$n" "$iid" >&2
        printf 'development'
        return 0
    fi
    _gl_get_scoped "$iid" "kind"
}
# backend_get_status <dir> <handle> -> Todo | In-progress | Blocked | Parked | Done | Dropped. Public seam over
# _gl_status so cmd_phase can freeze a BLOCKED story's phase.
backend_get_status() { _gl_status "$2"; }
backend_archive_row()   { story_emit_row "$(_gl_materialize "$2")"; }                   # read-only

# backend_story_audit <dir> — report every OPEN story whose state labels contradict each other (see
# gl-story-audit.jq for the rules), plus `merged-open`: a story whose own branch (feature|hotfix/story-<iid>-*, or feature|hotfix/story-<iid> with no
# slug) has a
# MERGED merge request in the last 60 days while the story is still open and marked todo (or has no status). Prints `iid<TAB>rule<TAB>detail` lines;
# rc 0 always (a report, not a gate). Stub-aware via _gl_paged.
backend_story_audit() {
    local open since merged
    open="$(_gl_paged "issues?state=opened&labels=story" 2>/dev/null)" || open='[]'
    [ -n "$open" ] || open='[]'
    printf '%s' "$open" | jq -rf "$BACKEND_GL_HERE/gl-story-audit.jq" 2>/dev/null || true
    since="${STORY_AUDIT_SINCE:-$(date -u -d '60 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)}"
    merged="$(_gl_paged "merge_requests?state=merged&updated_after=$since" 2>/dev/null)" || merged='[]'
    [ -n "$merged" ] || merged='[]'
    jq -rn --argjson open "$open" --argjson merged "$merged" '
        # only stories nobody has marked as worked (todo or no status): a doing/blocked/parked story legitimately
        # ships in several merge requests before it closes.
        ($open | map(select((.labels // []) as $l
            | ((["status::doing","status:doing","S:doing","status::blocked","status:blocked","S:blocked","status::parked","parked"]
               | any(. as $n | $l | index($n) != null)) or any($l[]; startswith("status::blocked-on-"))) | not)) | map(.iid)) as $ids
        | $merged[]
        | .source_branch as $b
        | ($b | capture("^(feature|hotfix)/story-(?<n>[0-9]+)(-|$)") | .n | tonumber) as $n
        | select($ids | index($n) != null)
        | "\($n)\tmerged-open\tbranch \($b) merged (!\(.iid)) but the story is still open"' 2>/dev/null | sort -u || true
}
