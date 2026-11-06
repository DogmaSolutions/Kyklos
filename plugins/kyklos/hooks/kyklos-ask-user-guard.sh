#!/usr/bin/env bash
# kyklos-ask-user-guard.sh (Kyklos) — PreToolUse(AskUserQuestion). Closes the loophole where the agent DEFERS to the
# user by ASKING a question instead of deciding + acting — the Stop-hook continue-guard forbids an unmotivated pause,
# but an AskUserQuestion bypasses it entirely. The standing directive is "prioritize autonomously, keep rolling", so
# a question to the user is sanctioned ONLY for a genuine ALWAYS-STOP decision (external/public publish · destructive
# GitLab admin · a push to a public-bound repo · a NEW fleet-wide blocking gate) or a hard blocker the agent truly
# cannot self-resolve. Otherwise this BLOCKS the question and tells the agent to decide + keep working: the USER
# intervenes proactively, the agent does not defer via questions.
#
# FAIL-OPEN on any parse error (never wedge). Escape (one-shot): `bash hooks/lib/override-marker.sh set ask-user-ok <your-working-folder>`
# in a SEPARATE prior step to allow the next single question. Disable entirely with KYKLOS_ASK_USER_GUARD=0.
# Wired: PreToolUse, matcher AskUserQuestion.
# [json-answer-required] Every answer this hook reads goes through the JSON reader; without it a check would exit 127
# and fall into a fail-open path, so the hook refuses by name instead (a broken install). [CySec] CWE-636
. "$(dirname "${BASH_SOURCE[0]}")/lib/json-answer.sh" 2>/dev/null
if ! command -v json_test >/dev/null 2>&1; then
    printf '{"decision":"block","reason":"BLOCKED (%s): the JSON reader hooks/lib/json-answer.sh did not load (broken install), so this check cannot run. Reinstall or repin the kyklos plugin."}\n' "$(basename "$0")"
    exit 0
fi
set +e -uo pipefail

# shellcheck source=lib/control-switch.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/control-switch.sh" 2>/dev/null || true   # kyklos_control_off: the one control-switch reader
kyklos_control_off "${KYKLOS_ASK_USER_GUARD:-}" && exit 0
INPUT="$(cat || true)"
command -v jq >/dev/null 2>&1 || exit 0
# SHARED prohibited-prioritization detector — the SAME one the continue-guard applies to plain-prose questions
# at Stop. If the lib is unavailable, the inline pattern below is used instead; it is NOT kept in step with the lib.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ask-detect.sh" 2>/dev/null || true

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/override-marker.sh"   # override_take: the scoped, expiring one-shot override
# One-shot override, spent only when this guard would block (a question that passes leaves it in place).
ask_block() {
  override_take ask-user-ok "$(override_hook_scope "$INPUT")" "$INPUT" && { echo "[kyklos] ask-user gate: OVERRIDDEN once (ask-user-ok spent)." >&2; exit 0; }
  printf '{"decision":"block","reason":"BLOCKED (ask-user-guard): %s"}' "$1"
  exit 0
}

# The concatenated question + option text, lowercased — so an always-stop signal ANYWHERE in the prompt allows it.
Q="$(printf '%s' "$INPUT" | jq -r '[(.tool_input.questions[]? | .question, (.options[]?.label // empty), (.options[]?.description // empty))] | join(" ")' 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
[ -n "$Q" ] || exit 0   # cannot parse the questions -> fail-open (never block on uncertainty)

# [circumvention closed] A PRIORITIZATION / PREFERENCE question is a DISGUISED stop — "which should I do next", "in
# what order", "your preference", "keep rolling through X or Y", "continue autonomous work or…". The standing
# directive is that the AGENT decides the SEQUENCE (by dependency + efficiency) and keeps rolling; the user does not
# rank the agent's queue. This is checked BEFORE (and OVERRIDES) the always-stop allow, because a prioritization
# question that merely NAMES an always-stop task (…publish… as one option) is still a deferral, not an always-stop
# AUTHORIZATION — that was the exact hole a real user hit. A genuine authorization is a DIRECT yes/no on ONE action
# ("Should I publish X to nuget.org?" / "How should I proceed?" + a destructive option) and carries none of these
# preference tells, so it still passes. Escape for a true edge case: the one-shot ask-user-ok marker above.
_ask_hit=1
if command -v ask_prohibited_prioritization >/dev/null 2>&1; then
  ask_prohibited_prioritization "$Q" && _ask_hit=0
else
  printf '%s' "$Q" | grep -cE 'prefer|keep rolling|prioriti|in (what|which) order|(which|what|where) .{0,40}(next|first)|which (of (these|those|the|them)|would you|one )|(next|first) (task|item|story|issue|step)|should i (continue|keep going|keep rolling)|(do|would) you want me to|continue autonomous|pause here|take on next|which should i (do|take|start|work|tackle|proceed)' >/dev/null && _ask_hit=0
fi
if [ "$_ask_hit" = 0 ]; then
  reason="this reads as a PRIORITIZATION / PREFERENCE question (which task next · in what order · your preference · keep-rolling-or · continue-autonomous-or-pause) — a DISGUISED stop. Naming an always-stop task as one of the options does NOT make it an always-stop question. The standing directive: YOU decide the sequence by DEPENDENCY + EFFICIENCY and KEEP ROLLING; the user does not rank your queue and intervenes proactively. If you genuinely must AUTHORIZE a SINGLE always-stop ACTION, ask a DIRECT yes/no on THAT action (never a which/prefer/next/order choice), or bash ${OVERRIDE_MARKER_CLI} set ask-user-ok <your-working-folder> in a SEPARATE prior step."
  reason="${reason//\\/\\\\}"; reason="${reason//\"/\\\"}"; reason="$(printf '%s' "$reason" | tr '\n' ' ')"
  ask_block "$reason"
fi

# Genuine ALWAYS-STOP / hard-blocker signals -> ALLOW the question.
if printf '%s' "$Q" | grep -cE 'publish|nuget\.org|make .*(public|private)|public (mirror|github)|revoke|destroy|delete .*(project|token|branch|tag|subgroup|repo)|drop .*(project|token|branch|tag)|rename .*(project|subgroup)|move .*(project|subgroup)|fleet-wide (block|gate|hard)|new .*blocking gate|irreversib|break-glass|production (deploy|secret)|force[- ]?push' >/dev/null; then
  exit 0
fi

reason="you are asking the user, but nothing here reads as a genuine ALWAYS-STOP decision (external/public publish, destructive GitLab admin, a public-bound push, or a NEW fleet-wide blocking gate) or an unresolvable hard blocker. The standing directive is PRIORITIZE AUTONOMOUSLY and KEEP ROLLING: decide it yourself and act — the user intervenes proactively, you do NOT defer via questions. If it TRULY is an always-stop decision or a blocker you cannot self-resolve, run: bash ${OVERRIDE_MARKER_CLI} set ask-user-ok <your-working-folder> in a SEPARATE prior step, then re-ask."
# 3-step JSON escape (backslash, quote, flatten newlines) — same as the sibling guards.
reason="${reason//\\/\\\\}"; reason="${reason//\"/\\\"}"; reason="$(printf '%s' "$reason" | tr '\n' ' ')"
ask_block "$reason"
