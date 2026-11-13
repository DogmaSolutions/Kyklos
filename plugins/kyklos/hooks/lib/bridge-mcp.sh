#!/usr/bin/env bash
# bridge-mcp.sh -- the ONE way a shell hook or tool reaches the KyklosBridge over HTTP: resolve the endpoint and the
# optional X-Bridge-Auth header from the workspace .mcp.json, and POST a JSON-RPC tools/call.
# Source it; it defines functions only.
#
#   bridge_mcp_endpoint            -> the bridge's http(s)://.../mcp URL (rc 2 when none can be resolved, rc 7 when the
#                                     shell is sealed for a test and the URL is not a loopback address)
#   bridge_mcp_sealed              -> rc 0 when the shell runs a test that must never reach a live bridge: one of
#                                     KYKLOS_TEST_SEALED, STORY_GL_STUB_DIR or CI_ACCESS_STUB_DIR is set
#   bridge_mcp_auth                -> the X-Bridge-Auth value, with a ${VAR} reference expanded from the environment
#   bridge_mcp_call <tool> [json] [max_seconds]
#                                  -> prints the raw JSON-RPC reply; rc 0 = a reply came back, 3 = transport error or
#                                     empty reply, 2 = endpoint not resolvable, 5 = curl/jq missing, 6 = the answer came
#                                     from a bridge that is not this session's (see bridge_mcp_check_identity), 7 = the
#                                     shell is sealed for a test and the endpoint is not a loopback stand-in
#   bridge_mcp_tool_takes <tool> <parameter> [max_seconds]
#                                  -> rc 0 when the bridge's tools/list gives <tool> the input <parameter>, rc 1 when not
#                                     (an older bridge), else bridge_mcp_call's codes
#   bridge_mcp_check_identity <headers-file> <endpoint>
#                                  -> rc 0 when the answer's X-Bridge-Project names this session's project
#                                     ($KYKLOS_BRIDGE_PROJECT_NAME) and its X-Bridge-Launch-Root this session's solution root
#                                     ($KYKLOS_BRIDGE_SOLUTION_ROOT), both set by the launcher (an unset one is not checked),
#                                     else rc 6 with both sides named on stderr
#   bridge_mcp_text <reply>        -> the concatenated text content of a tools/call result
#   bridge_mcp_is_error <reply>    -> rc 0 when the reply is a JSON-RPC error envelope or a result with isError=true
#
#   bridge_mcp_record_session <dir> -> remember <dir>/.mcp.json as this session's endpoint file (SessionStart)
#
# The endpoint file is $KYKLOS_BRIDGE_MCP_JSON when set, else $CLAUDE_PROJECT_DIR/.mcp.json (or ./.mcp.json) when it exists,
# else the session's own endpoint file recorded at SessionStart. That last step matters whenever a command points
# CLAUDE_PROJECT_DIR at another repository or at a fork's work tree, none of which carries the session's .mcp.json:
# without it, every bridge call and GUI event from such a command was silently lost.

# The record of the session's endpoint file (one path per line, the first one counts).
# shellcheck source=lib/json-answer.sh
. "$(dirname "${BASH_SOURCE[0]}")/json-answer.sh"   # json_test / json_read: an empty or cut answer is never valid
# shellcheck source=lib/seal-rule.sh
. "$(dirname "${BASH_SOURCE[0]}")/seal-rule.sh"     # kyklos_seal_refuses: a test shell reaches only loopback stand-ins
bridge_mcp_session_record() { printf '%s' "${KYKLOS_STATE_DIR:-/tmp/kyklos-state}/session-mcp-json"; }

bridge_mcp_record_session() {
    local dir="${1:-}" rec
    [ -n "$dir" ] && [ -f "$dir/.mcp.json" ] || return 0
    rec="$(bridge_mcp_session_record)"
    mkdir -p "$(dirname "$rec")" 2>/dev/null || return 0
    ( umask 077; printf '%s\n' "$(cd "$dir" && pwd -P)/.mcp.json" > "$rec" ) 2>/dev/null || true
    return 0
}

bridge_mcp_json_path() {
    if [ -n "${KYKLOS_BRIDGE_MCP_JSON:-}" ]; then printf '%s' "$KYKLOS_BRIDGE_MCP_JSON"; return 0; fi
    local proj="${CLAUDE_PROJECT_DIR:-$(pwd)}" rec recorded=""
    if [ -f "$proj/.mcp.json" ]; then printf '%s' "$proj/.mcp.json"; return 0; fi
    rec="$(bridge_mcp_session_record)"
    # [CySec] CWE-15 / CWE-73 (external control of a file name): the record decides where the bridge auth header is
    # sent, so it is used only when this user owns it and no one else can write it; otherwise it is ignored.
    if [ -f "$rec" ] && [ -O "$rec" ] && [ -z "$(find "$rec" -perm /022 2>/dev/null)" ]; then
        recorded="$(head -n1 "$rec" 2>/dev/null || true)"
    fi
    if [ -n "$recorded" ] && [ -f "$recorded" ]; then printf '%s' "$recorded"; return 0; fi
    printf '%s' "$proj/.mcp.json"
}

# The seal rule itself lives in seal-rule.sh (one rule for the bridge and GitLab clients); these names keep the
# bridge client's vocabulary.
bridge_mcp_sealed() { kyklos_test_sealed; }
bridge_mcp_is_loopback() { kyklos_url_is_loopback "$1"; }

bridge_mcp_endpoint() {
    local endpoint
    endpoint="$(_bridge_mcp_endpoint_resolve)" || return $?
    # [CySec] CWE-668 (exposure of a resource to the wrong sphere): a test's stubbed tracker is bypassed when the tool
    # forwards to the bridge, and the session's recorded endpoint file points at the LIVE bridge, which writes the real
    # tracker with the host's token (a story-tool test once reopened and rewrote three real stories). In a sealed test
    # shell only a loopback stand-in the test started itself may be reached; anything else is refused, fail-closed,
    # for every caller (all of them resolve the address here).
    if kyklos_seal_refuses "bridge-mcp" "$endpoint"; then
        return 7
    fi
    printf '%s' "$endpoint"
}

_bridge_mcp_endpoint_resolve() {
    command -v jq >/dev/null 2>&1 || return 5
    local mcp; mcp="$(bridge_mcp_json_path)"
    [ -f "$mcp" ] || return 2
    # Accept either an http.url transport or an args-embedded URL: the first http(s)://.../mcp string anywhere in
    # the KyklosBridge entry.
    local endpoint
    endpoint="$(jq -r '
        (.mcpServers.KyklosBridge // empty)
        | [.. | strings]
        | map(select(test("^https?://.*/mcp$")))
        | (.[0] // empty)' "$mcp" 2>/dev/null)"
    [ -n "$endpoint" ] || return 2
    printf '%s' "$endpoint"
}

bridge_mcp_auth() {
    command -v jq >/dev/null 2>&1 || return 5
    local mcp auth; mcp="$(bridge_mcp_json_path)"
    [ -f "$mcp" ] || return 0
    auth="$(jq -r '(.mcpServers.KyklosBridge.headers["X-Bridge-Auth"] // .mcpServers.KyklosBridge.headers["x-bridge-auth"] // empty)' "$mcp" 2>/dev/null)"
    # The launcher writes a REFERENCE (${KYKLOS_BRIDGE_AUTH_TOKEN}) that Claude Code expands from the environment, so the
    # token is never stored in the file; expand it the same way here, or the bridge would get the literal text.
    if [[ "$auth" =~ ^\$\{([A-Za-z_][A-Za-z0-9_]*)\}$ ]]; then
        local ref="${BASH_REMATCH[1]}"
        auth="${!ref:-}"
    fi
    printf '%s' "$auth"
}

# bridge_mcp_unescape TEXT -> TEXT with its %XX escapes decoded (the bridge percent-encodes its identity headers).
bridge_mcp_unescape() { local t="${1//\\/\\\\}"; printf '%b' "${t//%/\\x}"; }

# bridge_mcp_header <headers-file> <name> -> the last value of answer header <name> (any case), trimmed and with its
# %XX escapes decoded; empty when absent.
bridge_mcp_header() {
    local v
    v="$(tr -d '\r' < "$1" 2>/dev/null | awk -v want="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]'):" \
        'index(tolower($0), want) == 1 { sub(/^[^:]*:[ \t]*/, ""); sub(/[ \t]+$/, ""); v = $0 } END { print v }')"
    bridge_mcp_unescape "$v"
}

# bridge_mcp_same_root A B -> rc 0 when the two host paths name one folder: compared ignoring case, separator style
# and trailing separators (the host is Windows; the launcher and the bridge write the same text in practice).
bridge_mcp_same_root() {
    local a="${1//\\//}" b="${2//\\//}"
    while [ "${a%/}" != "$a" ] && [ "${#a}" -gt 1 ]; do a="${a%/}"; done
    while [ "${b%/}" != "$b" ] && [ "${#b}" -gt 1 ]; do b="${b%/}"; done
    [ "${a,,}" = "${b,,}" ]
}

# [CySec] Mitigates CWE-346 "Origin Validation Error": an answer is used only when the bridge that gave it names this
# session's project ($KYKLOS_BRIDGE_PROJECT_NAME) AND was launched for this session's solution root ($KYKLOS_BRIDGE_SOLUTION_ROOT),
# both set by the launcher; so a leftover bridge of an earlier session (of the same project but another root), or
# another project's bridge on a colliding port, is refused instead of trusted. Fail-hard: a bridge that names no
# project, or no root while the launcher named one, is refused too. A value the launcher did not set is not checked.
# This is the ONE identity check of the shell clients: every caller (bridge_mcp_call, fyi_emit) passes it its headers.
bridge_mcp_check_identity() {
    local hdr="$1" endpoint="${2:-the bridge}" want="${KYKLOS_BRIDGE_PROJECT_NAME:-}" want_root="${KYKLOS_BRIDGE_SOLUTION_ROOT:-}" got
    if [ -n "$want" ]; then
        got="$(bridge_mcp_header "$hdr" X-Bridge-Project)"
        if [ -z "$got" ]; then
            echo "bridge-mcp: refusing the answer from $endpoint: that bridge does not say which project it serves, and this session's bridge must serve '$want'. Restart this project's bridge from the launcher." >&2
            return 6
        fi
        if [ "${got,,}" != "${want,,}" ]; then
            echo "bridge-mcp: refusing the answer from $endpoint: that is the bridge of project '$got', and this session's bridge must serve '$want'." >&2
            return 6
        fi
    fi
    if [ -n "$want_root" ]; then
        # The launch root survives a restart that moves the working root; a bridge older than that header names only
        # its working root.
        got="$(bridge_mcp_header "$hdr" X-Bridge-Launch-Root)"
        [ -n "$got" ] || got="$(bridge_mcp_header "$hdr" X-Bridge-Solution-Root)"
        if [ -z "$got" ]; then
            echo "bridge-mcp: refusing the answer from $endpoint: that bridge does not say which solution root it was launched for, and this session's bridge must serve '$want_root'. Restart this project's bridge from the launcher." >&2
            return 6
        fi
        if ! bridge_mcp_same_root "$got" "$want_root"; then
            echo "bridge-mcp: refusing the answer from $endpoint: that bridge was launched for the solution root '$got', and this session's bridge must serve '$want_root' (a leftover bridge of another session). Stop it, then restart this project's bridge from the launcher." >&2
            return 6
        fi
    fi
    return 0
}

bridge_mcp_call() {
    local tool="$1" args="${2:-}" max="${3:-120}" body
    [ -n "$args" ] || args='{}'
    command -v curl >/dev/null 2>&1 || return 5
    command -v jq >/dev/null 2>&1 || return 5
    # The arguments can be large (a coverage report is hundreds of kilobytes): a single command-line argument is capped
    # (128 KiB on Linux), so the arguments reach jq on stdin and the request reaches curl from a file, never on argv.
    body="$(mktemp "${TMPDIR:-/tmp}/bridge-mcp.XXXXXX")" || return 3
    if ! printf '%s' "$args" | jq -c --arg name "$tool" '{jsonrpc:"2.0",id:1,method:"tools/call",params:{name:$name,arguments:.}}' > "$body" 2>/dev/null; then
        rm -f "$body"; return 3
    fi
    _bridge_mcp_send "$body" "$max"
}

# bridge_mcp_tool_takes <tool> <parameter> [max_seconds] -> rc 0 when the bridge lists <tool> with <parameter> in its
# input schema, rc 1 when it lists the tool without it (a bridge older than that parameter) or does not list the tool,
# and bridge_mcp_call's codes when it cannot be asked. A caller that needs the parameter refuses on rc 1 with
# BRIDGE-TOO-OLD rather than letting an older bridge ignore it.
bridge_mcp_tool_takes() {
    local tool="$1" param="$2" max="${3:-30}" body reply rc=0
    command -v curl >/dev/null 2>&1 || return 5
    command -v jq >/dev/null 2>&1 || return 5
    body="$(mktemp "${TMPDIR:-/tmp}/bridge-mcp.XXXXXX")" || return 3
    printf '%s' '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' > "$body"
    reply="$(_bridge_mcp_send "$body" "$max")" || rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    printf '%s' "$reply" | json_test '.result.tools | type == "array"' || return 3
    printf '%s' "$reply" | json_test 'any(.result.tools[]; .name == $t and ((.inputSchema.properties // {}) | has($p)))' --arg t "$tool" --arg p "$param"
}

# _bridge_mcp_send <body-file> <max_seconds> -> POSTs the JSON-RPC request in <body-file> (removed afterwards) to the
# bridge; prints the reply, with bridge_mcp_call's return codes.
_bridge_mcp_send() {
    local body="$1" max="$2"
    local endpoint resp hdr
    local _bm_erc=0
    endpoint="$(bridge_mcp_endpoint)" || _bm_erc=$?
    case "$_bm_erc" in 0) ;; 5|7) rm -f "$body"; return "$_bm_erc" ;; *) rm -f "$body"; return 2 ;; esac
    hdr="$(mktemp "${TMPDIR:-/tmp}/bridge-mcp-hdr.XXXXXX")" || { rm -f "$body"; return 3; }
    # [CySec] Mitigates CWE-214 "Invocation of Process Using Visible Sensitive Information" and CWE-532: the auth
    # header goes to curl through its stdin config, never as a command-line argument, and tracing is off while the
    # auth value is in scope, so a `bash -x` trace cannot print it.
    { local _bm_xt="$-"; set +x; } 2>/dev/null
    local auth curl_config="" _bm_rc=0
    auth="$(bridge_mcp_auth)"
    [ -n "$auth" ] && curl_config="$(printf 'header = "X-Bridge-Auth: %s"' "$auth")"
    # curl's own exit code decides (PIPESTATUS[1]), never the writer's broken pipe when curl exits first (see gitlab-curl.sh).
    resp="$(printf '%s\n' "$curl_config" | curl -s -K - -D "$hdr" --max-time "$max" -H "Content-Type: application/json" --data-binary @"$body" "$endpoint" 2>/dev/null; exit "${PIPESTATUS[1]}")" || _bm_rc=3
    auth=""; curl_config=""
    case "$_bm_xt" in *x*) set -x ;; esac
    rm -f "$body"
    [ "$_bm_rc" -eq 0 ] || { rm -f "$hdr"; return 3; }
    [ -n "$resp" ] || { rm -f "$hdr"; return 3; }
    bridge_mcp_check_identity "$hdr" "$endpoint" || { rm -f "$hdr"; return 6; }
    rm -f "$hdr"
    printf '%s' "$resp"
}

bridge_mcp_text() {
    printf '%s' "$1" | jq -r '[(.result.content // [])[] | select(.type == "text") | .text] | join("\n")' 2>/dev/null
}

bridge_mcp_is_error() {
    ! printf '%s' "$1" | json_test '((.error != null) or (.result.isError == true)) | not'
}
