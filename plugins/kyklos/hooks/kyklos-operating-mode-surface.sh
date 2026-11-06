#!/usr/bin/env bash
# kyklos-operating-mode-surface.sh (Kyklos, UserPromptSubmit) -- at the start of a turn, tell the agent when the
# bridge's operating modes changed since the last turn (for example the person at the host declared CI unavailable,
# or the mode ended). The bridge holds all the logic and every rule: this hook only reads its `mode_get` verb and
# compares the answer's version with the one it showed last; it keeps no mode, no knob and no rule of its own.
#
# The hook only adds context to a turn; it blocks one only when the plugin is broken (its JSON reader did not load). CONFIG: KYKLOS_OPERATING_MODE_SURFACE=on|off (default on).
# A bridge that is absent, too old (no mode_get) or silent shows nothing: the bridge itself still holds or queues every
# step a mode affects, so a missed notice never lets a step through.
# [json-answer-required] The bridge's answer is read through the one JSON reader (lib/bridge-mcp.sh); without it a
# check would exit 127 and fall into a fail-open path, so a broken install is refused by name instead. [CySec] CWE-636
. "$(dirname "${BASH_SOURCE[0]}")/lib/json-answer.sh" 2>/dev/null
if ! command -v json_test >/dev/null 2>&1; then
    printf '{"decision":"block","reason":"BLOCKED (%s): the JSON reader hooks/lib/json-answer.sh did not load (broken install), so the operating-mode notice cannot run. Reinstall or repin the kyklos plugin."}\n' "$(basename "$0")"
    exit 0
fi
set +e -uo pipefail
# shellcheck source=lib/control-switch.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/control-switch.sh" 2>/dev/null || true   # kyklos_control_off: the one control-switch reader
kyklos_control_off "${KYKLOS_OPERATING_MODE_SURFACE:-}" && exit 0
cat >/dev/null 2>&1   # drain the UserPromptSubmit payload (unused)
command -v jq >/dev/null 2>&1 || exit 0
# shellcheck source=lib/bridge-mcp.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/bridge-mcp.sh"

reply="$(bridge_mcp_call mode_get '{}' 10)" || exit 0
bridge_mcp_is_error "$reply" && exit 0
text="$(bridge_mcp_text "$reply")"
version="$(printf '%s\n' "$text" | sed -n 's/^version: \([0-9][0-9]*\)$/\1/p' | head -n1)"
[ -n "$version" ] || exit 0   # not a mode answer (an older bridge says "unknown tool")

state_dir="${KYKLOS_STATE_DIR:-/tmp/kyklos-state}"
mkdir -p "$state_dir" 2>/dev/null || exit 0
key="$(printf '%s' "$(bridge_mcp_endpoint 2>/dev/null)" | cksum | cut -d' ' -f1)"
seen_file="$state_dir/operating-mode-version-$key"
seen="$(cat "$seen_file" 2>/dev/null)"
printf '%s\n' "$version" > "$seen_file" 2>/dev/null
[ "$seen" = "$version" ] && exit 0
# The first look at a bridge with no mode on says nothing: there is no change to report.
[ -z "$seen" ] && grep -q '^no operating mode is on' <<< "$text" && exit 0

msg="[kyklos] OPERATING MODE CHANGED (set in the bridge GUI by the person at the host; read with the bridge's mode_get verb). $(printf '%s' "$text" | tr '\n' ';' | sed 's/;$//'). While ci-unavailable is on, the bridge queues mr_auto_merge, mr_merge and story_close and answers the pipeline and job reads at once: keep working on what does not need CI, do not poll or wait for pipelines. You may END the mode early with the bridge's mode_end verb (mode, reason) once you see CI answer; you can never set or extend one."
jq -nc --arg m "$msg" '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$m}}'
exit 0
