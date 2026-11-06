#!/usr/bin/env bash
# kyklos-epic-gate-guard.sh (Kyklos) - PreToolUse Bash. EPIC GATE: an epic is changed only through the epic verbs.
#
# An epic is a GitLab milestone. The bridge's epic verbs (the `story epic ...` commands) keep the milestone, the
# stories' Epic header and their labels in agreement, and refuse what would orphan a story (closing an epic with open
# issues, deleting one that still has issues, a story joining a closed epic). A hand-made call to the milestones API
# skips all of that. This guard refuses, in a command the agent runs:
#   * a WRITE to a milestones endpoint (create, edit, close/reopen, delete) by curl, wget, `glab api`, python, node,
#     PowerShell, ruby, perl, deno, bun, httpie or xh, by a GitLab client library, or by a program file one of them runs;
#   * a raw issue write that sets an issue's milestone (`milestone_id`, glab `--milestone` or `-m`): moving a story between
#     epics is `story set <id> epic=<E0N>`.
# Reads (a GET of milestones) and every other command pass. The `story` tool and the bridge make their own calls inside
# their own process, which this hook never sees.
#
# SCOPE / HONESTY: pure string inspection over the shared detector (lib/issue-api-detect.sh); a strong deterrent for
# the realistic clients, not a sandbox (a compiled client, a program file it cannot read, or a method hidden in a
# variable can still slip). A client whose URLs come from xargs or parallel counts as a milestone write when it writes.
# FAIL-OPEN only when the input cannot be read (no jq, no command): blocking every command then would wedge the agent.
# FAIL-HARD when the detector library is missing, fails to load or lacks a function: every command is refused, with
# the library named, until the plugin is installed again (lib/guard-prologue.sh).
# OVERRIDE (one shot, scoped to the working folder and to the agent that set it, expiring, audited): for a deliberate
#   hand-made milestone write, run in a SEPARATE prior step
#     bash hooks/lib/override-marker.sh set epic-api-ok <your-working-folder>
#   The next blocked command is allowed once and the use is recorded by escape_audit (transcript + state log).
# DEFAULT-ON. The only off-switch is KYKLOS_EPIC_GATE=off in the session environment (set by the launcher, never by
# a command: a hook reads its own environment, not the command it inspects).
# Wired: PreToolUse, matcher Bash.
set +e -uo pipefail

PAYLOAD="$(cat 2>/dev/null)" || exit 0
command -v jq >/dev/null 2>&1 || { echo "[kyklos] WARNING: epic gate INERT - jq is missing; raw milestone writes are not refused. Install jq." >&2; exit 0; }
CMD="$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // empty' 2>/dev/null)" || exit 0
[ -n "$CMD" ] || exit 0

_EGG_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The shared detector decides. A guard that cannot load it completely (missing, a syntax error, a function gone), or
# that a library ends while loading, cannot tell a raw write from any other command, so it refuses every command,
# naming the library: lib/guard-prologue.sh arms an EXIT trap that blocks unless the guard reached a decision
# (guard_done). The inline trap below covers the prologue itself being missing or ending the shell.
trap 'printf %s "{\"decision\":\"block\",\"reason\":\"BLOCKED (broken kyklos install): the epic gate cannot load lib/guard-prologue.sh, so it refuses every command. Edit and Write still work, so it can be repaired in place. Repair: relaunch the container so the kyklos plugin is installed again.\"}"; exit 0' EXIT
# shellcheck source=lib/guard-prologue.sh
. "$_EGG_HERE/lib/guard-prologue.sh" 2>/dev/null && declare -F guard_arm guard_load guard_load_optional guard_done guard_refuse >/dev/null \
  && guard_arm "the epic gate" || exit 0
# [json-answer-required] The libraries this guard loads read every JSON answer through the one reader; without it a
# check would exit 127 and fall into a fail-open path, so the guard refuses by name instead (guard_load names the
# missing reader, a broken install). Loaded after the prologue, so a reader that ends the shell is refused too.
# [CySec] CWE-636
guard_load "$_EGG_HERE/lib/json-answer.sh" json_test || guard_refuse
# The off-switch is read after the prologue, so a reader that ends the shell while loading is refused like any other
# library; a reader that does not load leaves the gate on (kyklos_control_off then fails).
guard_load_optional "$_EGG_HERE/lib/control-switch.sh" kyklos_control_off || true   # kyklos_control_off: the one control-switch reader
kyklos_control_off "${KYKLOS_EPIC_GATE:-}" && guard_done
guard_load "$_EGG_HERE/lib/issue-api-detect.sh" var:IAD_CLIENT_RE var:IAD_NORMALISER_BROKEN iad_normalize_cmd iad_refuse_broken_normaliser iad_cmd_is_milestone_write || guard_refuse
# The one-shot override is optional: without its library no override is honoured and a hit is still refused.
_EGG_OVERRIDE=0
guard_load_optional "$_EGG_HERE/lib/override-marker.sh" override_take override_hook_scope && _EGG_OVERRIDE=1
guard_load_optional "$_EGG_HERE/lib/escape-audit.sh" || true

OK_NAME=epic-api-ok

# Free text - an epic's title or goal, a search, a commit message - may describe an API call without making one. The
# value of each free-text option is emptied before the inspection (lib/free-text-blank.pl), when it cannot run anything;
# everything else in the command, including what follows on the same line, is still inspected. Without perl the
# command is inspected as it is (stricter, never weaker).
CHECK="$CMD"
if command -v perl >/dev/null 2>&1; then
    CHECK="$(printf '%s' "$CMD" | perl "$_EGG_HERE/lib/free-text-blank.pl" 2>/dev/null)" || CHECK="$CMD"
    [ -n "$CHECK" ] || CHECK="$CMD"
fi
# Program names and glab flags are read the way the shell and glab read them (c""url, glab -R a/b issue ...).
CHECK="$(iad_normalize_cmd "$CHECK")"
[[ $CHECK == "$IAD_NORMALISER_BROKEN" ]] && { iad_refuse_broken_normaliser "Epic Gate"; exit 0; }
# A program file the command runs is read relative to the command's own working folder.
IAD_CWD="$(printf '%s' "$PAYLOAD" | jq -r '.cwd // empty' 2>/dev/null)"; export IAD_CWD

# Only a command that invokes a raw client can write by hand.
printf '%s' "$CHECK" | grep -Ec "$IAD_CLIENT_RE" >/dev/null || guard_done
# [CySec] Enforces the sanctioned change path for epics (CWE-284 Improper Access Control): a hand-made milestone write
# bypasses the epic verbs' checks that keep stories from being orphaned. [RiskMitigation RA-05]
iad_cmd_is_milestone_write "$CHECK" || guard_done

if [ "$_EGG_OVERRIDE" = 1 ] && override_take "$OK_NAME" "$(override_hook_scope "$PAYLOAD")" "$PAYLOAD"; then
    command -v escape_audit >/dev/null 2>&1 && escape_audit "$OK_NAME" "raw milestone write allowed by override"
    guard_done
fi

reason="BLOCKED (Epic Gate): this command writes a GitLab milestone (an epic), or sets an issue's milestone, through the raw API (curl, wget, glab, python, node, PowerShell, ruby, perl, deno, bun, httpie or xh, a GitLab client library, or a program file one of them runs). Epics are changed ONLY through the story epic commands or the bridge's epic verbs (the same rules on both paths), which keep the milestone, the stories' Epic header and labels in agreement and refuse what would orphan a story. Use: find -> story epic list [--state active|closed|all] [--search \"<text>\"]; one epic, its stories and progress -> story epic show <E0N>; create or configure title, goal, dates -> story epic set <E0N> --title \"<t>\" [--goal \"<g>\"] [--start <yyyy-MM-dd|none>] [--due <yyyy-MM-dd|none>]; close / reopen / delete (an empty epic only) -> story epic close|reopen|delete <E0N>; archive a finished epic -> story archive <E0N>; move a story to another epic -> story set <id> epic=<E0N>. (MCP: epic_list, epic_get, epic_set, epic_close, epic_reopen, epic_delete, epic_archive, story_field_set field epic.) A container with no GitLab token of its own writes epics only when the project's story stack is in mode 'on'. A deliberate hand-made milestone write: bash ${OVERRIDE_MARKER_CLI:-hooks/lib/override-marker.sh} set $OK_NAME <your-working-folder> in a SEPARATE prior step, then retry (one use, audited)."
reason="${reason//\\/\\\\}"; reason="${reason//\"/\\\"}"; reason="$(printf '%s' "$reason" | tr '\n' ' ')"
printf '{"decision":"block","reason":"%s"}' "$reason"
guard_done
