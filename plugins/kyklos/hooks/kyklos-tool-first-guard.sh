#!/usr/bin/env bash
# kyklos-tool-first-guard.sh (Kyklos) — PreToolUse Bash. TOOL-FIRST discipline ("Look Before You Leap").
#
# PROBLEM (across projects, confirmed live): an agent DEFAULTS to a hand-crafted approach — here, driving the GitLab
# STORY-issue lifecycle by a raw client to the API (create a story issue, set its status::/type::/ssdlc:phase::
# labels, close it) — and only switches to the proper `story` tool REACTIVELY, when some downstream guard blocks it. The Tier-1
# "don't re-invent the wheel — use the standard mechanism" rule exists but was never OPERATIONALIZED, so the wrong
# path (hand-craft) was the path of least resistance. This guard makes the worst UNGUARDED footgun fail FAST and
# LOUD, naming the canonical tool, before the wasted work.
#
# TOOL-FIRST REGISTRY (routing table — "hand-craft signature -> canonical tool"). To honour GOVERNANCE.md single-
# ownership + non-duplication, rows already OWNED by a dedicated guard are DELEGATED (not re-matched here):
#   * raw `dotnet build|test|run|msbuild|vstest`  -> OWNED by kyklos-build-execution-guard.sh (-> KyklosBridge MCP).
#   * hand-edit BACKLOG.md / STORY-*/requirements.md -> OWNED by kyklos-story-mirror-edit-guard.sh (-> `story` cmds).
#   * >>> THIS guard OWNS the row: a raw client (curl/wget/glab/python) to the GitLab issues API that CREATES or MUTATES
#         a STORY issue (carries a story-governance label/state the `story` tool owns) -> `story new/set/phase/close`.
#
# MATCH (precise, low-false-positive): a Bash command that (1) invokes a raw client (curl/wget/glab/python, the
#   shared IAD_CLIENT_RE), (2) targets the issues API with a WRITE intent, AND (3) carries a STORY-GOVERNANCE token —
#   a label the `story` tool owns (`story`, `status::todo|doing|blocked|parked`, `ssdlc:phase::*`, `type::<storytype>`,
#   `proof-override`; the legacy single-colon / `S:` forms are matched too). The label names are owned by
#   _GL_KNOWN_LABELS in the story backend. A raw call to a NON-story concern (a coordination note `/issues/N/notes`, a runner, a CI variable, or a plain
#   issue with no governance label) has no governance token => NOT matched. The `story` tool's own internal curls
#   run inside the tool's subprocess, never as a top-level Bash call the hook sees => the tool is UNAFFECTED.
#
# FAIL-OPEN by construction: no jq / no command / not a raw client / not an issues-API write / no governance token => exit
#   0 (a novel action is NEVER blocked). FAIL-HARD: the detector library missing, failing to load or lacking a function
#   => every command refused, with the library named. OVERRIDABLE: for a deliberate non-story issue op that trips the match, run
#   `bash hooks/lib/override-marker.sh set tool-first-ok <your-working-folder>` in a SEPARATE prior step (a PreToolUse hook evaluates BEFORE the tool
#   runs); the one-shot marker is consumed on the next allow. The block message names the tool AND cites the norm,
#   so a block TEACHES tool-first rather than merely stopping the command.
#
# Wired: PreToolUse, matcher Bash.
set +e -uo pipefail

_TFG_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OK_NAME=tool-first-ok
OK_SCOPE_HINT="<your-working-folder>"

# FAIL-OPEN: without jq we cannot reliably parse the tool input — never wedge the command.
command -v jq >/dev/null 2>&1 || exit 0

PAYLOAD="$(cat 2>/dev/null)" || exit 0
CMD="$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // empty' 2>/dev/null)" || exit 0
[ -n "$CMD" ] || exit 0

# The client + write-verb + target detection is the SHARED lib/issue-api-detect.sh (one detector; this guard adds
# the STORY-governance policy below). Sourcing it keeps the guards from drifting on what counts as a raw issue write.
# The shared detector decides. A guard that cannot load it completely (missing, a syntax error, a function gone), or
# that a library ends while loading, cannot tell a raw write from any other command, so it refuses every command,
# naming the library: lib/guard-prologue.sh arms an EXIT trap that blocks unless the guard reached a decision
# (guard_done). The inline trap below covers the prologue itself being missing or ending the shell.
trap 'printf %s "{\"decision\":\"block\",\"reason\":\"BLOCKED (broken kyklos install): the tool-first guard cannot load lib/guard-prologue.sh, so it refuses every command. Edit and Write still work, so it can be repaired in place. Repair: relaunch the container so the kyklos plugin is installed again.\"}"; exit 0' EXIT
# shellcheck source=lib/guard-prologue.sh
. "$_TFG_HERE/lib/guard-prologue.sh" 2>/dev/null && declare -F guard_arm guard_load guard_load_optional guard_done guard_refuse >/dev/null \
  && guard_arm "the tool-first guard" || exit 0
# [json-answer-required] The libraries this guard loads read every JSON answer through the one reader; without it a
# check would exit 127 and fall into a fail-open path, so the guard refuses by name instead (guard_load names the
# missing reader, a broken install). Loaded after the prologue, so a reader that ends the shell is refused too.
# [CySec] CWE-636
guard_load "$_TFG_HERE/lib/json-answer.sh" json_test || guard_refuse
guard_load "$_TFG_HERE/lib/issue-api-detect.sh" var:IAD_CLIENT_RE var:IAD_HTTP_WRITE_RE var:IAD_NORMALISER_BROKEN iad_normalize_cmd iad_refuse_broken_normaliser iad_route_norm iad_split_segments iad_seg_is_raw_issue_write iad_seg_has_curl_wget iad_http_words_write iad_http_client_words || guard_refuse
# The one-shot override (override_take: scoped, expiring) is optional: without its library no override is honoured
# and a hit is still refused.
_TFG_OVERRIDE=0
guard_load_optional "$_TFG_HERE/lib/override-marker.sh" override_take override_hook_scope && _TFG_OVERRIDE=1
# Program names and glab flags are read the way the shell and glab read them (c""url, glab -R a/b issue ...).
CMD="$(iad_normalize_cmd "$CMD")"
[[ $CMD == "$IAD_NORMALISER_BROKEN" ]] && { iad_refuse_broken_normaliser "tool-first"; exit 0; }

# (1) must invoke a supported raw client (curl/wget/glab/python) at all.
printf '%s' "$CMD" | grep -Ec "$IAD_CLIENT_RE" >/dev/null || guard_done
# (2) must target the issues API (create-collection `/…/issues` or edit `/issues/<n>`) — NOT `/issues/<n>/notes`
#     (a coordination note is owned by kyklos-agent-msg-guard, not this story guard).
iad_route_norm "$CMD" | grep -Ec '/issues(/[0-9]+)?([^A-Za-z0-9_/-]|/([^0-9n]|$)|$)' >/dev/null || guard_done
# (2b) must be a WRITE (create/mutate), not a read. Judged over the WHOLE command (a URL held in a variable from an
#     earlier statement still counts): a statement the shared detector calls a raw issue write, the curl/wget
#     arguments writing (iad_http_words_write: a data flag beside -G/--get is a search, a read), or a state transition.
_tfg_write=1
while IFS= read -r _seg || [ -n "$_seg" ]; do
    [ -n "$_seg" ] || continue
    iad_seg_is_raw_issue_write "$_seg" && { _tfg_write=0; break; }
done < <(iad_split_segments "$CMD")
# The curl/wget arguments are judged per statement (a -G of one statement never hides another's data flag), without
# requiring the statement itself to name /issues (step 2 found the target in the command).
if [ "$_tfg_write" != 0 ]; then
    while IFS= read -r _seg || [ -n "$_seg" ]; do
        iad_seg_has_curl_wget "$_seg" && iad_http_words_write "$(iad_http_client_words "$_seg")" "$_seg" && { _tfg_write=0; break; }
    done < <(iad_split_segments "$CMD")
fi
printf '%s' "$CMD" | grep -Eic 'state_event[[:space:]=]*(close|reopen)' >/dev/null && _tfg_write=0
printf '%s' "$CMD" | grep -Ec 'glab[[:space:]]+api' >/dev/null && printf '%s' "$CMD" | grep -Eic -- "$IAD_HTTP_WRITE_RE" >/dev/null && _tfg_write=0
[ "$_tfg_write" = 0 ] || guard_done
# (3) must carry a STORY-GOVERNANCE token — the discriminator that makes this a STORY op the `story` tool owns.
#     The token must be the LABEL VALUE in any label param (labels= / add_labels= / remove_labels=): a non-story
#     label edit (e.g. `add_labels=for:<agent>` on a coordination issue) has no story token => NOT matched (fail-open).
#     Parked counts: adding or removing it by hand is exactly how a story ends up with two statuses or none.
printf '%s' "$CMD" | grep -Eic '(labels?|add_labels|remove_labels)=[^&"'"'"' ]*(story|status::(todo|doing|blocked|parked)|status:(todo|doing|blocked|parked)|S:(todo|doing|blocked)|parked|ssdlc:phase|type::?(library|service|ci|infra|plugin|docs|test)|proof-override)' >/dev/null || guard_done

# One-shot override: a deliberate non-story issue op that tripped the match. Consume it and allow.
if [ "$_TFG_OVERRIDE" = 1 ] && override_take "$OK_NAME" "$(override_hook_scope "$PAYLOAD")" "$PAYLOAD"; then
    echo "[kyklos] tool-first override consumed — allowing this one raw issues-API write." >&2
    guard_done
fi

reason="BLOCKED (tool-first): this raw issues-API write hand-drives the GitLab issue lifecycle for a STORY (it carries a story-governance label such as story / status::doing / ssdlc:phase:: / type::<t> / proof-override). Hand-crafting story issues via the API is the footgun this guard exists to stop — the 'story' tool is the canonical mechanism and keeps the GitLab source-of-truth, the on-disk mirror, the labels, the SSDLC phase and the proof gate all in sync (a hand curl silently diverges them). Use the tool: create -> story new <kebab-slug> --title \"<title>\" --type <type> --kind <development|analysis|documentation|ops> --severity <critical|high|medium|low> --epic <E0N>; adopt an existing issue -> story adopt <id> --type <t> --epic <E0N>; fields/labels -> story set <id> <field=value>; SSDLC phase -> story phase <id> <Requirements|Design|Implementation|Testing|Deployment|Review>; close -> story close <id>. TOOL-FIRST NORM: before hand-crafting, consult the SessionStart capability catalog + ToolSearch the MCP inventory — hand-crafting is only justified with an explicit 'no tool fits because ...'. Deliberate non-story issue op that tripped this: bash ${OVERRIDE_MARKER_CLI:-hooks/lib/override-marker.sh} set $OK_NAME $OK_SCOPE_HINT in a SEPARATE prior step, then retry."
reason="${reason//\\/\\\\}"; reason="${reason//\"/\\\"}"; reason="$(printf '%s' "$reason" | tr '\n' ' ')"
printf '{"decision":"block","reason":"%s"}' "$reason"
guard_done
