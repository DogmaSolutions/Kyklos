#!/usr/bin/env bash
# kyklos-session-continuation-guard.sh (Kyklos) — ensures CLAUDE.md (and, if present, a task-context file and
# an AI_TOOLS.md tooling doc) are read in a fresh container and periodically thereafter, to counter context drift.
# A container restart wipes the state dir, so the read is required up front; within a container the read is
# re-required every STALE_MINUTES (a new session in the same container inherits the last read).
#
# Wired (see hooks.json):
#   PostToolUse Read                          -> sets the "recently read" markers (never blocks)
#   PreToolUse  Edit|Write|MultiEdit | Bash | Agent
#                                             -> blocks until CLAUDE.md (+ optional context/AI_TOOLS) read
set -e +u -o pipefail

_cfg="$(. "$(dirname "${BASH_SOURCE[0]}")/lib/repo-role.sh" 2>/dev/null && repo_companion_root "${CLAUDE_PROJECT_DIR:-$(pwd)}" || printf '%s' "${CLAUDE_PROJECT_DIR:-$(pwd)}")/.claude/standards.env"
. "$(dirname "${BASH_SOURCE[0]}")/lib/standards-env.sh"; load_standards_env "$_cfg"   # PARSE, never source (CWE-829)
STATE_DIR="${KYKLOS_STATE_DIR:-/tmp/kyklos-state}"
mkdir -p "$STATE_DIR"

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
# A project directory inside a companion's nested source (CLAUDE_PROJECT_DIR or the session working directory) is
# resolved to the companion root, where Stories/ and .claude/ live.
. "$(dirname "${BASH_SOURCE[0]}")/lib/repo-role.sh" 2>/dev/null && PROJECT_DIR="$(repo_companion_root "$PROJECT_DIR")"
CLAUDE_MD_READ="$STATE_DIR/claudemd-read-this-session"
PLAN_READ="$STATE_DIR/plan-read-this-session"
AITOOLS_READ="$STATE_DIR/aitools-read-this-session"
STALE_MINUTES="${KYKLOS_CLAUDEMD_STALE_MINUTES:-45}"

INPUT="$(cat || true)"
TOOL="$(printf '%s' "$INPUT" | grep -oE '"tool_name"[[:space:]]*:[[:space:]]*"[^"]+' | head -1 | sed -E 's/.*"//' 2>/dev/null || true)"
EVENT="$(printf '%s' "$INPUT" | grep -oE '"hook_event_name"[[:space:]]*:[[:space:]]*"[^"]+' | head -1 | sed -E 's/.*"//' 2>/dev/null || true)"

# Read calls SET the markers and never block.
if [ "$TOOL" = "Read" ]; then
    FILE_PATH="$(printf '%s' "$INPUT" | grep -oE '"file_path"[[:space:]]*:[[:space:]]*"[^"]+' | head -1 | sed -E 's/.*"//' || true)"
    printf '%s' "$FILE_PATH" | grep -cE 'CLAUDE\.md$' >/dev/null                                        && echo read > "$CLAUDE_MD_READ"
    printf '%s' "$FILE_PATH" | grep -ciE '(BACKLOG\.md|Stories/.*\.md|PLAN\.md|plan.*\.md)$' >/dev/null && echo read > "$PLAN_READ"
    printf '%s' "$FILE_PATH" | grep -cE 'AI_TOOLS\.md$' >/dev/null                                      && echo read > "$AITOOLS_READ"
    exit 0
fi

# POST-Bash: interrogating the SSoT restores task context just as reading the mirror does. Under the GitLab backend
# the authority is GitLab, NOT the Stories/BACKLOG.md file (that file is only a generated projection) -- so a live
# GitLab interrogation (a real story subcommand 'story refresh|proof|structure|materialize', or a direct issues-API read) SATISFIES the
# task-context gate. This is why the gate does not FORCE a file read: query the source of truth and you are done.
# Gated to PostToolUse so it never short-circuits the PreToolUse Bash BLOCK (which must still fire on an unread session).
if [ "$TOOL" = "Bash" ] && [ "$EVENT" = "PostToolUse" ]; then
    printf '%s' "$INPUT" | grep -cE 'story[[:space:]]+(refresh|proof|structure|materialize)|/api/v[0-9]+/projects/[0-9]+/issues' \
 >/dev/null        && echo read > "$PLAN_READ"
    exit 0
fi

stale() { [ ! -f "$1" ] || [ -n "$(find "$1" -mmin +"$STALE_MINUTES" 2>/dev/null)" ]; }

# EXEMPT from the PreToolUse Bash block the very commands the block tells the agent to
# run — a whitelisted GitLab interrogation (a real story subcommand: refresh|proof|structure|materialize) or a direct issues-API read.
# These are read-only SoT interrogations that RESTORE context (the PostToolUse handler above then marks it read), so
# blocking them is self-defeating: it would make the very command the block tells the agent to run impossible, leaving
# only "Read the mirror" as the real escape while the message says to interrogate GitLab (a chicken-and-egg). The
# suggested commands MUST be ones the shipped story CLI actually accepts -- 'list'/'show' were suggested but never
# existed, so an agent following the hint hit 'unknown subcommand' and went in circles. Letting the real ones RUN
# closes the loop. Scoped to PreToolUse Bash so it never affects the Edit/Write/Agent gates.
if [ "$TOOL" = "Bash" ] && [ "$EVENT" = "PreToolUse" ]; then
    printf '%s' "$INPUT" | grep -cE 'story[[:space:]]+(refresh|proof|structure|materialize)|/api/v[0-9]+/projects/[0-9]+/issues' \
 >/dev/null        && exit 0
fi

# Gate 1: CLAUDE.md read recently.
if stale "$CLAUDE_MD_READ"; then
    printf '{"decision":"block","reason":"%s"}' "BLOCKED: CLAUDE.md has not been read recently (a fresh container, or >${STALE_MINUTES} min since the last read). Read CLAUDE.md to reload the project rules before continuing."
    exit 0
fi

# Gate 2: task context, only if the project uses one.
CONTEXT_FILE=""; _ctx_is_backlog=0
if [ -f "$PROJECT_DIR/Stories/BACKLOG.md" ]; then CONTEXT_FILE="Stories/BACKLOG.md (then the ACTIVE story it points to)"; _ctx_is_backlog=1;
elif [ -f "$PROJECT_DIR/PLAN.md" ]; then CONTEXT_FILE="PLAN.md"; fi
if [ -n "$CONTEXT_FILE" ] && stale "$PLAN_READ"; then
    _ctx_note=""
    # Under the GITLAB backend Stories/BACKLOG.md is a DERIVED mirror refreshed only by
    # kyklos-story-mirror-refresh.sh at SessionStart, ONCE per container — yet THIS gate re-demands the read every
    # STALE_MINUTES for the whole session. So a >45-min session's "restore task context" read is served from a
    # never-re-refreshed mirror (a FALSE "context restored"). Fix: on our OWN staleness timer, before forcing the
    # re-read, refresh the mirror from GitLab so the context is actually current. Best-effort + bounded so a slow or
    # unreachable GitLab can NEVER wedge this always-on guard; and if the refresh could not reach GitLab, SAY the
    # mirror may be stale (fail loud) rather than silently presenting a stale projection as fresh context.
    if [ "$_ctx_is_backlog" -eq 1 ] && [ "${STORY_BACKEND:-local}" = gitlab ]; then
        _story="$(dirname "${BASH_SOURCE[0]}")/../skills/ssdlc-story/story"
        if [ -f "$_story" ]; then
            if command -v timeout >/dev/null 2>&1; then
                CLAUDE_PROJECT_DIR="$PROJECT_DIR" timeout 25 bash "$_story" refresh --dir "$PROJECT_DIR/Stories" >/dev/null 2>&1 || true
            else
                CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$_story" refresh --dir "$PROJECT_DIR/Stories" >/dev/null 2>&1 || true
            fi
        fi
        if [ -f "$PROJECT_DIR/Stories/.mirror-stale" ]; then
            _ctx_note=" WARNING: GitLab was UNREACHABLE at refresh, so this mirror MAY BE STALE -- re-run 'story refresh' when GitLab is back before trusting task context."
        else
            _ctx_note=" (The mirror was just refreshed from GitLab.)"
        fi
    fi
    # SSoT-first framing: under the GitLab backend the authority is GitLab, and the mirror file is only a projection,
    # so tell the agent to INTERROGATE GitLab (which also satisfies the gate) rather than presenting the file as the
    # thing to read. On the FS backend the file genuinely IS the source of truth, so the plain read message stands.
    if [ "$_ctx_is_backlog" -eq 1 ] && [ "${STORY_BACKEND:-local}" = gitlab ]; then
        _reason="BLOCKED: restore current task context from GitLab (the SSoT for this workspace). Interrogate it directly -- run 'story refresh' (re-syncs the backlog from GitLab), or 'story structure <id>' / 'story proof <id>' for a specific story -- any of which satisfies this gate; the local mirror Stories/BACKLOG.md is only a projection of GitLab (I just refreshed it), not the authority, so reading it also works but is the fallback.$_ctx_note"
    else
        _reason="BLOCKED: task context ($CONTEXT_FILE) has not been read recently. Read it to restore task context.$_ctx_note"
    fi
    printf '{"decision":"block","reason":"%s"}' "$_reason"
    exit 0
fi

# Gate 3: AI_TOOLS.md, only if the project has one.
if [ -f "$PROJECT_DIR/AI_TOOLS.md" ] && stale "$AITOOLS_READ"; then
    printf '{"decision":"block","reason":"%s"}' "BLOCKED: AI_TOOLS.md exists but has not been read recently. Read it to reload the tooling details before continuing."
    exit 0
fi

exit 0
