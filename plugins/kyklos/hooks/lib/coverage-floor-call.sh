#!/usr/bin/env bash
# coverage-floor-call.sh - the story close asks the BRIDGE whether a Test Discipline row's coverage figure meets the
# story's coverage floor. The plugin holds no floor and compares no figure: the bridge decides (the story's own
# Coverage-Floor line within the project minimum, else the project floor) and answers on every close path, whatever the
# story backend or the kind of change. Needs proof_receipt_call (hooks/lib/proof-tool-gate.sh) loaded.
#
# proof_floor_close_finding VERDICT STORY KIND PROJECT METRICS -> print a refusal and rc 0 when the PROVEN Test
# Discipline row does not meet its floor, or when the bridge cannot answer (the floor cannot be judged without it); else
# nothing, rc 1. Exempt by kind only: documentation, analysis and ops stories. DEFAULT-ON; the greppable opt-out is
# PROOF_COVERAGE_FLOOR=off (audited). FAIL-HARD: an unreachable or older bridge refuses.
# [CySec] Prevents CWE-636 "Not Failing Securely": a floor that cannot be judged refuses the close; it never passes.
proof_floor_close_finding() {
    local verdict="$1" story="$2" kind="$3" project="$4" metrics="$5" args answer lib
    [ "$verdict" = PROVEN ] || return 1
    case "$(printf '%s' "$kind" | tr '[:upper:]' '[:lower:]')" in documentation|analysis|ops) return 1 ;; esac
    if kyklos_control_off "${PROOF_COVERAGE_FLOOR:-}"; then
        lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        # shellcheck source=/dev/null
        [ -f "$lib/escape-audit.sh" ] && . "$lib/escape-audit.sh" 2>/dev/null
        command -v escape_audit >/dev/null 2>&1 && escape_audit "coverage-floor-off" "story=$story PROOF_COVERAGE_FLOOR=${PROOF_COVERAGE_FLOOR:-}" 2>/dev/null || true
        echo "[kyklos] coverage floor check skipped: PROOF_COVERAGE_FLOOR=${PROOF_COVERAGE_FLOOR:-} [audit]" >&2
        return 1
    fi
    args="$(jq -cn --arg s "$story" --arg p "$project" --arg k "${kind:-development}" --arg m "$metrics" \
        '{story:$s, project:$p, kind:$k, metrics:$m}')"
    if ! answer="$(proof_receipt_call coverage_floor_check "$args")"; then
        printf 'Test Discipline is PROVEN, but its coverage floor cannot be judged without the bridge: %s. Start (or update) the bridge and close again.\n' "$answer"
        return 0
    fi
    case "$answer" in
        "held: "*) return 1 ;;
    esac
    printf 'Test Discipline is PROVEN, but its coverage floor does not hold: %s\n' "${answer#refused: }"
    return 0
}
