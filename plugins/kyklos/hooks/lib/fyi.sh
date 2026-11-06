#!/usr/bin/env bash
# fyi.sh -- the fail-open DISPLAY-only notifier: tell the KyklosBridge GUI about an SSDLC step that went STRAIGHT to
# the tracker (a story phase/proof/close, an adversarial review) and so never passed through a bridge verb. Source it;
# it defines one function:
#
#   fyi_emit <kind> [story] [detail] [status] [repo-dir]
#       POSTs {kind, story, detail, status, project, actor, session, ts} to the bridge's /fyi endpoint, authenticated
#       with the bridge's shared
#       secret (the same X-Bridge-Auth the MCP calls use). It is DISPLAY-ONLY and FAIL-OPEN: on ANY failure
#       (no bridge configured, unreachable, timeout, non-2xx, missing jq/curl) it prints a single
#       '[kyklos] fyi: bridge not reached, continuing' warning and returns 0 -- it MUST NEVER fail or block the
#       caller. <kind> is required; an empty kind is a silent no-op (rc 0).
#
# DEFAULT-ON. The ONE greppable opt-out is KYKLOS_BRIDGE_FYI=off.
#
# WHO and WHERE. Several agents can work at once in one session: the parent and its forks share one process, one
# session id and one environment, so nothing in the environment tells them apart. What does tell them apart is WHERE a
# step runs: each fork works in its own git work tree on its own story branch. So every event carries:
#   project  STORY_GITLAB_PROJECT when set, else the git origin path of the repository (both are what the agent sees);
#   actor    KYKLOS_ACTOR when set (an explicit, stable name), else "<work tree folder>@<branch>" of the repository;
#   session  the first 8 characters of CLAUDE_CODE_SESSION_ID (the parent and its forks share it).
# The repository is [repo-dir] when the caller knows it (a hook that resolved the repo a git command ran in), else
# CLAUDE_PROJECT_DIR, else the current directory. All three are display data only: no token or secret value is ever part of an event.

# The endpoint + auth are resolved through the SAME seam the other hooks use (bridge-mcp.sh over the workspace
# .mcp.json): there is no hand-built URL and no hand-copied token. The bridge /fyi URL is derived from the resolved
# /mcp URL, so a project that wires the bridge at all gets the FYI channel for free.

# shellcheck source=control-switch.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/control-switch.sh" 2>/dev/null || true   # kyklos_control_off: the one control-switch reader
_fyi_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bridge-mcp.sh
. "$_fyi_here/bridge-mcp.sh"
# shellcheck source=same-repository.sh
. "$_fyi_here/same-repository.sh"

# The ONE fail-open warning: any reason the display post did not land prints this and the caller continues. One place,
# so the message can never drift between the failure paths.
_fyi_unreached() { printf '[kyklos] fyi: bridge not reached, continuing\n' >&2; return 0; }

# fyi_repo_top [dir] -> the top of the git work tree that holds dir, or nothing. Without dir: the project the command
# works on (CLAUDE_PROJECT_DIR, which a fork points at its own work tree), else the current directory - so a fork that
# runs a story command from the session's folder is still named after its own work tree.
fyi_repo_top() {
    local d="${1:-}"
    [ -n "$d" ] || d="${CLAUDE_PROJECT_DIR:-$PWD}"
    git -C "$d" rev-parse --show-toplevel 2>/dev/null || git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true
}

# fyi_actor [dir] -> who did the step: KYKLOS_ACTOR, else "<work tree folder>@<branch>", else "unattributed".
fyi_actor() {
    if [ -n "${KYKLOS_ACTOR:-}" ]; then printf '%s' "$KYKLOS_ACTOR"; return 0; fi
    local top branch
    top="$(fyi_repo_top "${1:-}")"
    if [ -z "$top" ]; then printf 'unattributed'; return 0; fi
    branch="$(git -C "$top" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    printf '%s@%s' "${top##*/}" "${branch:-detached}"
}

# fyi_project [dir] -> where the step happened: STORY_GITLAB_PROJECT, else the repository's origin path (scheme, host,
# user and .git stripped, so no credential embedded in a remote URL can reach an event), else nothing.
fyi_project() {
    if [ -n "${STORY_GITLAB_PROJECT:-}" ]; then printf '%s' "$STORY_GITLAB_PROJECT"; return 0; fi
    local top url
    top="$(fyi_repo_top "${1:-}")"
    [ -n "$top" ] || return 0
    url="$(git -C "$top" remote get-url origin 2>/dev/null || true)"
    # [CySec] CWE-200: only the path part of the remote is kept; a user:token@ prefix is cut with the host.
    same_repository_remote_path "$url"
}

fyi_emit() {
    # DEFAULT-ON; the single greppable opt-out.
    kyklos_control_off "${KYKLOS_BRIDGE_FYI:-}" && return 0

    local kind="${1:-}" story="${2:-}" detail="${3:-}" status="${4:-}" repo="${5:-}"
    # An empty kind is a no-op, not a warning: a caller with nothing to say should cost nothing.
    [ -n "$kind" ] || return 0

    # jq/curl are needed to build + send the event; their absence is a fail-open warning, never a block.
    if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        _fyi_unreached; return 0
    fi

    local mcp_url fyi_url body
    mcp_url="$(bridge_mcp_endpoint 2>/dev/null)" || mcp_url=""
    if [ -z "$mcp_url" ]; then
        _fyi_unreached; return 0
    fi
    # Derive /fyi from the resolved /mcp endpoint (same host/port/scheme).
    fyi_url="${mcp_url%/mcp}/fyi"

    local project actor session
    project="$(fyi_project "$repo")"; actor="$(fyi_actor "$repo")"; session="${CLAUDE_CODE_SESSION_ID:-}"
    session="${session:0:8}"
    body="$(jq -cn --arg k "$kind" --arg s "$story" --arg d "$detail" --arg st "$status" \
        --arg p "$project" --arg a "$actor" --arg se "$session" \
        '{kind:$k, story:$s, detail:$d, status:$st, project:$p, actor:$a, session:$se, ts:(now|todateiso8601)}' 2>/dev/null)" || {
        _fyi_unreached; return 0
    }

    # [CySec] Mitigates CWE-214 "Invocation of Process Using Visible Sensitive Information" / CWE-532: the auth header
    # goes to curl through its stdin config, never as a command-line argument, and tracing is off while the value is in
    # scope, so a `bash -x` trace cannot print it.
    local hdr
    hdr="$(mktemp "${TMPDIR:-/tmp}/bridge-fyi-hdr.XXXXXX" 2>/dev/null)" || { _fyi_unreached; return 0; }
    { local _fyi_xt="$-"; set +x; } 2>/dev/null
    local auth curl_config="" rc=0
    auth="$(bridge_mcp_auth 2>/dev/null)"
    [ -n "$auth" ] && curl_config="$(printf 'header = "X-Bridge-Auth: %s"' "$auth")"
    printf '%s\n' "$curl_config" | curl -sf -o /dev/null -D "$hdr" -K - --max-time 2 \
        -H "Content-Type: application/json" -d "$body" "$fyi_url" >/dev/null 2>&1 || rc="${PIPESTATUS[1]}"   # curl's code, not the writer's broken pipe
    auth=""; curl_config=""
    case "$_fyi_xt" in *x*) set -x ;; esac

    # [CySec] CWE-346 Origin Validation Error: the answer goes through the shared identity check (bridge-mcp.sh), so an
    # event that reached another project's bridge, or a leftover bridge of another solution root, is reported on
    # stderr instead of passing as delivered, like every other bridge call.
    if [ "$rc" -eq 0 ] && ! bridge_mcp_check_identity "$hdr" "$fyi_url"; then rc=6; fi
    rm -f "$hdr"

    # ANY transport/HTTP failure is swallowed -- the GUI is a convenience, never a dependency. One warning, rc 0.
    [ "$rc" -eq 0 ] || _fyi_unreached; return 0
}
