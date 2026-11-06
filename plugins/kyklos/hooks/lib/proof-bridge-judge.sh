#!/usr/bin/env bash
# proof-bridge-judge.sh -- the Stop hook's question to the bridge about a closed story's proof. When the bridge's story
# stack is 'on' for this project, the bridge alone judges the proof (verb proof_validate); the hook does not re-judge it
# in bash. Source it; it defines functions only. Needs ssdlc-engine.sh (ssdlc_engine_mode, ssdlc_project) and
# bridge-mcp.sh, which proof_bridge_judge_load sources.
#
#   proof_bridge_judge_load            -> rc 0 when the engine library loaded, else rc 1 (a broken install)
#   proof_bridge_judge_mode            -> prints 'bridge' (the bridge judges), 'bash' (mode off or shadow) or
#                                         'unreachable' (the bridge was last 'on' and does not answer now)
#   proof_bridge_validate <issue>      -> asks proof_validate for the story; prints the bridge's answer on one line.
#                                         rc 0 = clean, 4 = waived by the owner's label, 1 = refused, 3 = no answer

_PBJ_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

proof_bridge_judge_load() {
    command -v ssdlc_engine_mode >/dev/null 2>&1 && return 0
    # shellcheck source=../../skills/ssdlc-story/lib/ssdlc-engine.sh
    . "$_PBJ_DIR/../../skills/ssdlc-story/lib/ssdlc-engine.sh" 2>/dev/null || return 1
    command -v ssdlc_engine_mode >/dev/null 2>&1
}

proof_bridge_judge_mode() {
    local m
    # [RiskMitigation RA-03] An 'on' bridge that stops answering never hands the judgement back to bash.
    m="$(ssdlc_engine_mode)" || { printf 'unreachable'; return 0; }
    if [ "$m" = on ]; then printf 'bridge'; else printf 'bash'; fi
}

# The answer of proof_validate when the owner's exception label waives the proof gates (the bridge's
# AgileVerbDispatcher.ProofWaivedByOwner).
_PBJ_WAIVED="waived: the owner's exception label"

proof_bridge_validate() {
    local issue="$1" resp rc text
    resp="$(bridge_mcp_call proof_validate "$(jq -cn --arg id "$issue" --arg p "$(ssdlc_project)" '{id:$id,project:$p}')" 120)"; rc=$?
    if [ "$rc" -ne 0 ]; then printf 'transport rc %s' "$rc"; return 3; fi
    text="$(bridge_mcp_text "$resp" | tr '\n' ' ' | sed -E 's/[[:space:]]+$//')"
    if bridge_mcp_is_error "$resp"; then printf '%s' "${text:-refused}"; return 1; fi
    printf '%s' "$text"
    [ "$text" = "$_PBJ_WAIVED" ] && return 4
    [ "$text" = clean ] && return 0
    # An answer the hook does not know is not a pass.
    return 1
}
