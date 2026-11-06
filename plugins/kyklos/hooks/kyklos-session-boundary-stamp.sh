#!/usr/bin/env bash
# kyklos-session-boundary-stamp.sh — SessionStart. Records THIS session's start instant as a durable state
# marker so every close-time gate can tell a THIS-session close from a prior-session (or prior-container)
# one without depending on transcript internals. A session's point-in-time obligations (render-in-reply,
# container-local review tokens) are only satisfiable INSIDE that session — grading an earlier close
# against them can only produce impossible demands, so the boundary must be a recorded fact, not an
# inference. Overwrites on every SessionStart: a fresh session IS a fresh boundary.
# [json-answer-required] Every answer this hook reads goes through the JSON reader; without it a check would exit 127
# and fall into a fail-open path, so the hook refuses by name instead (a broken install). [CySec] CWE-636
. "$(dirname "${BASH_SOURCE[0]}")/lib/json-answer.sh" 2>/dev/null
if ! command -v json_test >/dev/null 2>&1; then
    echo "[kyklos] $(basename "$0"): the JSON reader hooks/lib/json-answer.sh did not load (broken install); the Kyklos's guards refuse until the kyklos plugin is reinstalled or repinned."
    exit 0
fi
set +e -uo pipefail

STATE="${KYKLOS_STATE_DIR:-/tmp/kyklos-state}"
mkdir -p "$STATE" 2>/dev/null || true
date +%s > "$STATE/session-start-epoch" 2>/dev/null || true
# The CONTAINER start marker is different: created on the first SessionStart of this container and never rewritten
# (a /clear or a resume is a new session, not a new container). Shared-folder proof tokens are judged against it.
# shellcheck source=lib/proof-tool-gate.sh
( . "$(dirname "${BASH_SOURCE[0]}")/lib/proof-tool-gate.sh" && container_start_marker_ensure >/dev/null ) 2>/dev/null || true
# Remember this session's bridge endpoint file, so a command that points CLAUDE_PROJECT_DIR at another repository or a
# fork's work tree still reaches the bridge (story routing, review tokens, GUI events).
# shellcheck source=lib/bridge-mcp.sh
{ . "$(dirname "${BASH_SOURCE[0]}")/lib/bridge-mcp.sh" && bridge_mcp_record_session "${CLAUDE_PROJECT_DIR:-$PWD}"; } 2>/dev/null || true
exit 0
