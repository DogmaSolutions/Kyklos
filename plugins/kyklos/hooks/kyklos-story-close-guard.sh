#!/usr/bin/env bash
# kyklos-story-close-guard.sh (Kyklos) — PreToolUse(Bash). The POKA-YOKE that closes the hole where a GitLab issue
# is CLOSED via the RAW API (curl/python `state_event=close`, or `glab issue close`), BYPASSING the
# `story close` proof gate — so a story got marked Done with NO `## Proof` table ever produced or shown. The Stop-hook
# `story-proof-guard` only catches this RETROACTIVELY (at the next stop, after the close already happened, and only for
# the in-scope story); this guard stops the close BEFORE it happens.
#
# WHAT IT BLOCKS: a Bash command that closes ANY GitLab ISSUE by the raw API/CLI, unless the issue is a CONFORMING,
# PROVEN story (the required SSDLC sections in its body AND the CANONICAL Proof note — the
# `<!-- dogma:story-proof -->`-marked note the ssdlc-story-proof gate reads, with NO UNPROVEN verdict; a bare table in a
# sibling note does not count), or it carries a non-development disposition/coordination label (the list is in the
# code below). The sanctioned path — `story close <id>` — runs the proof gate + renders the table itself, so it is
# NEVER blocked here.
#
# FAIL-OPEN on uncertainty (can't parse the command, can't identify the issue, no API token, network error, the issue
# is not readable) — this guard must never wedge a legitimate close. A missing GitLab API base is the exception: it
# BLOCKS (the close cannot be verified). Disable with KYKLOS_STORY_CLOSE_GUARD=0. The only override is the
# user-applied proof-override label (lib/owner-labels.sh); there is no agent-touchable escape.
# Wired: PreToolUse, matcher Bash.
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
kyklos_control_off "${KYKLOS_STORY_CLOSE_GUARD:-}" && exit 0
INPUT="$(cat || true)"
command -v jq  >/dev/null 2>&1 || exit 0
command -v curl >/dev/null 2>&1 || exit 0

CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
[ -n "$CMD" ] || exit 0

STATE_DIR="${KYKLOS_STATE_DIR:-/tmp/kyklos-state}"
# [close-guard hardening] The agent-touchable one-shot `story-close-ok` escape was REMOVED. A marker the agent can
# `touch` itself is a lock whose key the CONSTRAINED party holds - it let the agent self-authorize a full proof-bypass
# (a dev story could be closed with its Documentation dimension, and even a whole README, unproven). This applies the
# same principle the sibling continue-guard already uses, having dropped its agent-touchable stop escapes: an escape the
# constrained party can author is not a gate. A DELIBERATE override is now a USER action: the user-applied proof-override
# label (below) - VISIBLE + AUDITABLE on the issue, the SAME override the proof Stop-gate honors, and one the
# tool-first-guard stops the agent from hand-applying. Retire this gate entirely with KYKLOS_STORY_CLOSE_GUARD=0.
. "$(dirname "${BASH_SOURCE[0]}")/lib/owner-labels.sh"   # fixed owner-label names (never redirected by a variable)
. "$(dirname "${BASH_SOURCE[0]}")/lib/json-answer.sh"   # json_test: an empty or cut answer is never a readable one
_PO_LABEL="$OWNER_OVERRIDE_LABEL"

# Is this command CLOSING a GitLab issue via the raw API/CLI? Two shapes: (a) a REST close = a reference to `issues/<n>`
# together with a `state_event` set to `close`; (b) the glab CLI `glab issue close <n>`. The `story` tool's own
# `story close` is the sanctioned path and self-enforces — never match it here.
_lc="$(printf '%s' "$CMD" | tr '[:upper:]' '[:lower:]')"
IS_CLOSE=0
# Match the REST close as a UNIT: an `issues/<n>` reference AND `state_event` BOUND to `close`
# (`state_event=close`, `--data-urlencode state_event=close`, or JSON `"state_event":"close"` — `=`/`:` with
# optional quotes/spaces between), so a command that merely mentions `issues/5`, the word `state_event`, and `close`
# in SEPARATE places does not trigger.
if printf '%s' "$_lc" | grep -Ec 'issues/[0-9]+' \
 >/dev/null   && printf '%s' "$_lc" | grep -Ec 'state_event["'"'"'[:space:]]*[=:]["'"'"'[:space:]]*close' >/dev/null; then IS_CLOSE=1; fi
if printf '%s' "$_lc" | grep -Ec 'glab[[:space:]]+issue[[:space:]]+close[[:space:]]+[0-9]' >/dev/null; then IS_CLOSE=1; fi
[ "$IS_CLOSE" = 1 ] || exit 0   # not an issue-close -> nothing to guard

# Resolve the target project + issue iid from the command; fall back to KYKLOS_ISSUES_PROJECT for the project.
PROJECT="$(printf '%s' "$CMD" | grep -oE 'projects/[0-9]+' | head -1 | grep -oE '[0-9]+' || true)"
[ -n "$PROJECT" ] || PROJECT="${KYKLOS_ISSUES_PROJECT:-}"
IID="$(printf '%s' "$CMD" | grep -oE 'issues/[0-9]+' | head -1 | grep -oE '[0-9]+' || true)"
[ -n "$IID" ] || IID="$(printf '%s' "$CMD" | grep -oE 'glab[[:space:]]+issue[[:space:]]+close[[:space:]]+[0-9]+' | grep -oE '[0-9]+' | head -1 || true)"
{ [ -n "$PROJECT" ] && [ -n "$IID" ]; } || exit 0   # cannot identify the issue -> fail-open

# READ the issue and its notes. The bridge reads them with its own token (coordination_show / coordination_notes), so
# the container needs none. Only a bridge WITHOUT those verbs falls back to a direct token, logged on the fallback
# ledger; the direct path keeps its old rules (a missing API base blocks, no token fails open).
. "$(dirname "${BASH_SOURCE[0]}")/lib/coordination-read.sh"   # coordination_read: the bridge answers with its own token
_BRIDGE_READ=0
if _bridge_issue="$(coordination_read coordination_show "$(jq -cn --arg p "$PROJECT" --arg i "$IID" '{project:$p, iid:$i}')" 2>/dev/null)"; then
  _BRIDGE_READ=1
else
  _bridge_rc=$?
  # A bridge that has the verbs but cannot read the issue: fail open as an unreadable issue always did.
  [ "$_bridge_rc" = 4 ] || exit 0
  coordination_read_fallback story-close-guard "the bridge has no coordination_show verb"
fi
if [ "$_BRIDGE_READ" = 1 ]; then
  _get() {
    case "$1" in
      '') printf '%s' "$_bridge_issue" ;;
      /notes*) coordination_read coordination_notes "$(jq -cn --arg p "$PROJECT" --arg i "$IID" '{project:$p, iid:$i, sort:"desc"}')" 2>/dev/null || true ;;
    esac
  }
else
. "$(dirname "${BASH_SOURCE[0]}")/lib/gitlab-api-base.sh"   # gitlab_api_base: the one API-base resolver
API="$(gitlab_api_base STORY_GITLAB_API 2>/dev/null)" || {
  _why="$(gitlab_api_base STORY_GITLAB_API 2>&1 >/dev/null | tr -d '"\\' | tr '\n' ' ')"
  printf '{"decision":"block","reason":"BLOCKED (story-close-guard): cannot verify the close. %s"}' "$_why"
  exit 0
}
. "$(dirname "${BASH_SOURCE[0]}")/lib/gitlab-curl.sh"   # gitlab_curl / gitlab_pick_token: the token never leaves the helper
# The NAME of the first setting that holds a token (never the value).
gitlab_pick_token TOKNAME "${KYKLOS_STORY_TOKEN_ENV:-}" "${STORY_GITLAB_TOKEN_ENV:-}" "${KYKLOS_ISSUES_TOKEN_ENV:-}" GITLAB_TOKEN KYKLOS_ISSUES_TOKEN || true
[ -n "$TOKNAME" ] || exit 0   # no token to verify -> fail-open (never wedge a close we cannot check)

_get() { gitlab_curl "$TOKNAME" -s --max-time 12 "$API/projects/$PROJECT/issues/$IID$1" 2>/dev/null || true; }
# _scg_page_get <path> -> one page of a list through the direct token; rc 1 unless GitLab answered 200.
_scg_page_get() {
  local resp; resp="$(gitlab_curl "$TOKNAME" -s --max-time 12 -w $'\n%{http_code}' "$API/projects/$PROJECT/issues/$IID$1" 2>/dev/null || true)"
  printf '%s' "$resp" | sed '$d'; [ "$(printf '%s' "$resp" | tail -n1)" = 200 ]
}
fi

ISSUE="$(_get '')"
# The reader decides every check below: without it a check would exit 127 and fall into a fail-open path, so a close
# that cannot be judged is refused instead. [CySec] CWE-636: a missing library never lets a close through.
if ! command -v json_test >/dev/null 2>&1; then
  printf '{"decision":"block","reason":"BLOCKED (story-close-guard): cannot verify the close: the JSON reader hooks/lib/json-answer.sh did not load (broken install). Reinstall or repin the plugin, or close it with story close <id>."}'
  exit 0
fi
if ! printf '%s' "$ISSUE" | json_test '.iid'; then
  # An EMPTY answer is not "not an issue": the read returned nothing, so the close cannot be judged -> refused, named.
  if [ -z "$ISSUE" ]; then
    printf '{"decision":"block","reason":"BLOCKED (story-close-guard): cannot verify the close. The issue read returned an empty answer; retry, or close it with story close <id>."}'
    exit 0
  fi
  exit 0   # an answer that is not an issue (for example a 404 body) -> fail-open, as documented above
fi
# Any dev-work close: gate EVERY agent-initiated issue-close, NOT just story-labelled ones -
# the hole was a bug/task issue worked + closed OUTSIDE the story lifecycle with no structure/proof.
# A close is allowed ONLY if the issue is a CONFORMING, PROVEN story (the required SSDLC sections in its body AND a
# clean canonical Proof note), OR it carries an explicit NON-DEVELOPMENT disposition label, OR the user applied the
# proof-override label (below).
_labels="$(printf '%s' "$ISSUE" | jq -r '[.labels[]? | ascii_downcase] | join(" ")' 2>/dev/null || true)"
case " $_labels " in
  *" duplicate "*|*" wontfix "*|*" invalid "*|*" status::duplicate "*|*" status::wontfix "*|*" status::invalid "*|*" coordination "*|*" agent-comms "*|*" question "*) exit 0 ;;
esac
# USER-authority deliberate override: a VISIBLE, auditable proof-override label on the issue (the SAME label the proof
# Stop-gate honors). This replaces the removed agent-touchable marker - the override is now on the issue for anyone to
# see, not a silent ephemeral file the agent touched.
# The label counts only when a GitLab user OTHER than this agent applied it (shared authorship check, fail-closed):
# a label the agent put on the issue itself must not authorize its own close.
. "$(dirname "${BASH_SOURCE[0]}")/lib/user-applied-label.sh"
# Named Cause: the label admits the close only when the story also names the cause of its gap; the bridge decides it
# (lib/override-cause.sh). Without its answer the close is judged by the checks below, as without the label.
. "$(dirname "${BASH_SOURCE[0]}")/lib/override-cause.sh"
if [ -n "$_PO_LABEL" ] && printf ' %s ' "$_labels" | grep -cF " $_PO_LABEL " >/dev/null \
   && label_user_applied "$PROJECT" "$IID" "$_PO_LABEL" && override_cause_named "$PROJECT" "$IID"; then exit 0; fi

# STRUCTURE: the same rule as `story structure` and `story close` (story_min_structure_problem: the 7 required items,
# plus every 2a-2f spec section the close gate requires once a spec is present) - one list, so the guards cannot drift.
# The library is loaded through require_lib, which fails when it stops loading part-way or does not define the rule: a
# broken library must never read as "no section missing", so it BLOCKS the close, naming the broken install.
# [RiskMitigation RA-03]
_SCG_STORY_LIB="$(dirname "${BASH_SOURCE[0]}")/../skills/ssdlc-story/lib/story-lib.sh"
_desc="$(printf '%s' "$ISSUE" | jq -r '.description // ""')"
_miss=""; _broken=""
if { . "$(dirname "${BASH_SOURCE[0]}")/lib/require-lib.sh" 2>/dev/null \
     && require_lib "$_SCG_STORY_LIB" story_min_structure_problem 2>/dev/null; }; then
  _miss="$(story_min_structure_problem "$_desc" | paste -sd, - | sed 's/,/, /g')"
else
  _broken="the structure check cannot run: cannot load $_SCG_STORY_LIB completely, a broken kyklos install (reinstall it)"
fi

# PROOF: the CANONICAL Proof note. The ssdlc-story-proof gate reads ONLY a note whose body STARTS WITH the marker
# '<!-- dogma:story-proof -->' (what `story proof` writes + `backend_proof_read` reads) — a bare `| Quality Dimension |`
# table in a sibling note does NOT count for the gate. Match EXACTLY that so this guard and the Stop-hook proof gate
# agree: if the last marked note exists AND has no UNPROVEN verdict, the close is legitimate.
# Every note (the bridge verb pages itself; the direct path reads every page through the shared reader): a proof note
# older than the newest 100 must still count. An unreadable list reads as no notes, so the close is blocked, never
# allowed. [RiskMitigation RA-01]
if [ "$_BRIDGE_READ" = 1 ]; then NOTES="$(_get '/notes')"
else
  . "$(dirname "${BASH_SOURCE[0]}")/lib/gitlab-paged.sh"   # gitlab_paged_walk: the one rule for reading a whole list
  NOTES="$(gitlab_paged_walk _scg_page_get '/notes?sort=desc' 2>/dev/null)" || NOTES='[]'
fi
MARKER='<!-- dogma:story-proof -->'
HAS_PROOF=0; HAS_UNPROVEN=0
if printf '%s' "$NOTES" | json_test '.[]?.body // "" | select(startswith($m))' --arg m "$MARKER"; then HAS_PROOF=1; fi
if [ "$HAS_PROOF" = 1 ] && printf '%s' "$NOTES" | jq -r --arg m "$MARKER" '[.[]? | select((.body//"")|startswith($m))] | sort_by(.created_at) | (last // {}) | .body // ""' 2>/dev/null | grep -ciE 'UNPROVEN' >/dev/null; then HAS_UNPROVEN=1; fi

# CONFORMING + PROVEN story -> allow. BOTH the 7 structural items AND a clean canonical Proof note are required.
if [ -z "$_broken" ] && [ -z "$_miss" ] && [ "$HAS_PROOF" = 1 ] && [ "$HAS_UNPROVEN" = 0 ]; then exit 0; fi

# BLOCK: name exactly what is missing (structure and/or proof).
_parts="$_broken"
[ -n "$_miss" ] && _parts="missing required SSDLC section(s): ${_miss}"
if [ "$HAS_UNPROVEN" = 1 ]; then _parts="${_parts}${_parts:+ ; }the Proof note has an UNPROVEN Quality Dimension"
elif [ "$HAS_PROOF" = 0 ]; then _parts="${_parts}${_parts:+ ; }no canonical Proof note (a note starting with the dogma:story-proof marker)"; fi
why="you are closing issue #$IID (project $PROJECT) as done, but it is NOT a conforming, proven SSDLC story (${_parts}). EVERY dev-work close must be a structured + proven story. RESTRUCTURE it (add the sections \`story structure $IID\` lists, fill every row \`story proof $IID\` generates, render the Proof table) and close via \`story close $IID\`; OR - if this is genuinely NOT development work - close it with its reason through the tool (\`story set $IID status=wontfix|duplicate|invalid\`), or, for a coordination issue, through \`agent-msg close\`; OR for a deliberate override ask the USER to apply the \`$_PO_LABEL\` label to the issue (there is no agent-touchable bypass - a close cannot be self-authorized)."
why="${why//\\/\\\\}"; why="${why//\"/\\\"}"; why="$(printf '%s' "$why" | tr '\n' ' ')"
printf '{"decision":"block","reason":"BLOCKED (story-close-guard): %s"}' "$why"
exit 0
