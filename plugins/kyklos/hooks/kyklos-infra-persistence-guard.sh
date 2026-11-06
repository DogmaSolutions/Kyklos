#!/usr/bin/env bash
# kyklos-infra-persistence-guard.sh (Kyklos) — PostToolUse, matchers Bash + Write|Edit.
# NON-BLOCKING reminder to persist durable things in the REPO, because agent memory is VOLATILE (dies with the
# throw-away container). Two triggers:
#   (a) Bash provisions durable infra (currently: creates a GitLab access token / bot user) -> record its
#       EXISTENCE + purpose in the project's PERSISTENT git docs (never its VALUE — Tier-0 secret rule).
#   (b) a Write/Edit targets an agent-memory dir (*/memory/*.md) -> if it's a rule/fact/decision/convention,
#       ALSO persist it versioned (memory holds a one-line pointer at most), and prefer a HOOK where the rule
#       is mechanically checkable (poka-yoke). Trigger (b) fires once per container (a state marker) so it nudges, not nags.
# Reads only; never blocks (both actions are legitimate).
set -euo pipefail

# Load optional per-project config so the marker dir co-locates with the configured state (same as the other
# guards); default matches the fleet-wide convention.
_cfg="${CLAUDE_PROJECT_DIR:-$(pwd)}/.claude/standards.env"
. "$(dirname "${BASH_SOURCE[0]}")/lib/standards-env.sh"; load_standards_env "$_cfg"   # PARSE, never source (CWE-829)
STATE_DIR="${KYKLOS_STATE_DIR:-/tmp/kyklos-state}"

INPUT="$(cat || true)"
CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
FILE="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)"

MSG=""

# (a) durable-infra PROVISIONING (a create), not reads.
if [ -n "$CMD" ] \
   && printf '%s' "$CMD" | grep -ciE '(-X[[:space:]]+POST|--request[[:space:]]+POST|"POST"|=POST)' \
 >/dev/null   && printf '%s' "$CMD" | grep -ciE '/(projects|groups)/[^/]+/access_tokens' >/dev/null; then
  MSG="REMINDER (infra-persistence guard): you just provisioned a GitLab ACCESS TOKEN (which also creates a bot user). Per the managed policy (Tier 0 secret rule, Tier 1 durable knowledge), record its EXISTENCE + purpose (name, scope, project, expiry) in the project's PERSISTENT git docs THIS session — but NEVER its VALUE: a secret lives only in the secrets manager and/or the OS credential store, never in git or on the filesystem. Agent memory is volatile and dies with the container; an undocumented token is the footgun behind tokens being 'forgotten' and wrongly revoked."
fi

# (b) a Write/Edit under an agent-memory dir — remind ONCE per container to persist versioned + prefer a hook.
if [ -z "$MSG" ] && [ -n "$FILE" ] && printf '%s' "$FILE" | grep -cE '/memory/[^/]+\.md$' >/dev/null; then
  _state="$STATE_DIR"; mkdir -p "$_state" 2>/dev/null || true
  _mk="$_state/persist-over-memory-reminded"
  if [ ! -f "$_mk" ]; then
    touch "$_mk" 2>/dev/null || true
    MSG="REMINDER (persist-over-memory): you wrote under an agent-memory dir. Memory is VOLATILE — it dies with the throw-away container, so it must NEVER be the sole record of a rule / fact / decision / convention. If this is one, ALSO persist it THIS session in a git-tracked file (the project's CLAUDE.md index -> docs/*.md); memory may keep a one-line pointer at most. And where the rule is mechanically checkable, make it a HOOK (poka-yoke) — a written rule is the weakest rung, memory weaker still."
  fi
fi

[ -z "$MSG" ] && exit 0
esc="$(printf '%s' "$MSG" | sed 's/\\/\\\\/g; s/"/\\"/g')"
printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}' "$esc"
exit 0
