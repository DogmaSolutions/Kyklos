#!/usr/bin/env bash
# flow-strip.sh — print a compact, GROUND-TRUTH "you are here in the global flow" status line for a story.
#
# Why generated, not hand-authored: a status a model writes from memory can contradict reality (a "CI green"
# that's actually red) and then poison its own later context. This reads the truth instead — the BACKLOG
# status column + (optionally) the live pipeline via the closed-loop seam (KYKLOS_CI_*). Producing it is a
# grounding act. Keep it to ONE line, emit it at TRANSITIONS only (never every turn), replace don't accumulate.
# [RiskMitigation RA-01] generate-from-truth is itself the mitigation: a status that cannot be hand-authored
# cannot contradict reality, so it can never poison the agent's own later context.
#
# Usage:
#   flow-strip.sh STORY-nnn      # one story
#   flow-strip.sh --all          # one line per ACTIVE story in the BACKLOG (checkpoint use only)
#   flow-strip.sh --all-done     # the same, including Done stories
#
# Glyphs (single-token, no box-drawing): ✓ done · ● you-are-here · · pending · ✗ failed · ⛔ blocked
# Fail-soft: unknown story / unreadable BACKLOG / uncurlable pipeline -> best-effort line, always exit 0.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../hooks/lib/ci-access.sh"   # ci_access_pipelines: bridge first, no container token
set +e -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
# [CySec] Prevents CWE-829: the settings file is PARSED (standards-env.sh), never sourced, so a malformed or hostile
# line cannot execute. [RiskMitigation RA-02]
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../hooks/lib/standards-env.sh"
load_standards_env "$PROJECT_DIR/.claude/standards.env"
BACKLOG="$PROJECT_DIR/Stories/BACKLOG.md"

PHASES=(spec code commit push CI merge release)

# Render the 7-phase strip: cells before $1 are ✓, the cell at $1 is ● (or the $2 override on the CI cell),
# cells after are ·.  $1=reached index (0..7; 7 => all done)  $2=optional CI-cell glyph override.
render() {
    local reached="$1" ciov="${2:-}" out="" i g
    for i in "${!PHASES[@]}"; do
        if [ "$i" -eq 4 ] && [ -n "$ciov" ]; then g="$ciov"
        elif [ "$i" -lt "$reached" ]; then g="✓"
        elif [ "$i" -eq "$reached" ]; then g="●"
        else g="·"; fi
        out="$out ${PHASES[$i]}$g"
    done
    printf '%s' "${out# }"
}

# Latest pipeline status for a branch via the closed-loop seam. Echoes "<status> <id>" or "" (fail-soft).
pipeline_of() {
    local br="$1"
    [ "${KYKLOS_CI_MONITOR:-0}" = "1" ] || return 0
    [ -n "$br" ] && [ "$br" != "—" ] || return 0
    command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || return 0
    # The CI seam asks the bridge (ci_pipelines_list); only the declared direct-token exception reads GitLab itself.
    # Read the project the branch lives in: the origin of the repository holding it (a companion's nested source).
    # A branch held by several repositories, or (through the bridge) by none, names no single project: show no CI state
    # rather than one guessed project's (this line is advisory; the gates judge every repository).
    local repo; repo="$(ci_access_branch_repositories "$br" "$PROJECT_DIR" "$PROJECT_DIR/${KYKLOS_SOURCE_DIR:-Repo}")" || repo=""
    [ "$(printf '%s\n' "$repo" | grep -c .)" -le 1 ] || return 0
    [ -n "$repo" ] || [ "$(ci_access_mode)" != bridge ] || return 0
    ci_access_pipelines "$br" "" 1 "$repo" 2>/dev/null \
        | jq -r '.pipelines[0] // empty | "\(.status) \(.id)"' 2>/dev/null | grep -v '^null' || true
}

# One line for one story. $1 = STORY-nnn (any form; matched against the BACKLOG row).
strip_for() {
    local key="$1"
    [ -f "$BACKLOG" ] || { printf '%s  (no BACKLOG)\n' "$key"; return; }
    local row status branch
    # Match the story's OWN row (its title cell links `[STORY-nnn]`), not another row that merely mentions
    # it in prose. Fall back to a bare match only if no linked row exists (e.g. a legacy unlinked row).
    row="$(grep -E '^\|' "$BACKLOG" 2>/dev/null | grep -F "[$key]" | head -1)"
    [ -z "$row" ] && row="$(grep -E '^\|' "$BACKLOG" 2>/dev/null | grep -F "$key" | head -1)"
    if [ -z "$row" ]; then printf '%s  (not in BACKLOG)\n' "$key"; return; fi
    status="$(printf '%s' "$row" | awk -F'|' '{print $3}')"                       # status column
    branch="$(printf '%s' "$row" | awk -F'|' '{print $4}' | sed -E 's/^[[:space:]]*//; s/[[:space:]].*$//' | tr -d '`')"

    local reached=1 ciov="" note=""
    if   printf '%s' "$status" | grep -c '✅' >/dev/null; then reached=7; note="released"
    elif printf '%s' "$status" | grep -c '⛔' >/dev/null; then reached=1; note="⛔ blocked"
    elif printf '%s' "$status" | grep -c '⬜' >/dev/null; then reached=0; note="todo"
    elif printf '%s' "$status" | grep -c '🔵' >/dev/null; then
        local ci; ci="$(pipeline_of "$branch")"
        case "${ci%% *}" in
            running)          reached=4; note="pipeline ${ci##* } ▶ running" ;;
            failed|canceled)  reached=4; ciov="✗"; note="pipeline ${ci##* } ✗ → fix" ;;
            success)          reached=5; note="pipeline ${ci##* } ✓ (awaiting merge)" ;;
            *)                reached=1; note="in-progress" ;;
        esac
    else reached=1; note=""; fi

    local strip; strip="$(render "$reached" "$ciov")"
    if [ -n "$note" ]; then printf '%-10s %s   %s\n' "$key" "$strip" "$note"
    else printf '%-10s %s\n' "$key" "$strip"; fi
}

# ---- main ----
# --all: the ACTIVE stories only (Todo / In-progress / Blocked) — a "what's in flight" dashboard. Released/Done
# stories are history, not flow, and dumping them all defeats the point (context economy). --all-done adds them.
if [ "${1:-}" = "--all" ] || [ "${1:-}" = "--all-done" ]; then
    [ -f "$BACKLOG" ] || { echo "(no BACKLOG at $BACKLOG)"; exit 0; }
    local_all="$1"
    grep -E '^\|' "$BACKLOG" 2>/dev/null | grep -oE '\[STORY-[0-9]+\]' | tr -d '[]' | sort -u | while read -r s; do
        if [ "$local_all" = "--all" ]; then
            # skip stories whose status column is Done (✅)
            printf '%s' "$(grep -E '^\|' "$BACKLOG" | grep -F "[$s]" | head -1 | awk -F'|' '{print $3}')" | grep -c '✅' >/dev/null && continue
        fi
        strip_for "$s"
    done
    exit 0
fi
[ -n "${1:-}" ] || { echo "usage: flow-strip.sh STORY-nnn | --all | --all-done" >&2; exit 2; }
strip_for "$1"
exit 0
