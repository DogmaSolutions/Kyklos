#!/usr/bin/env bash
# kyklos-scenario-init.sh — SessionStart. Two zero-ceremony conveniences for the scenario model:
#   1. If the project has EXACTLY ONE .slnx and no scenarios/ yet, generate scenarios/default-scenario.md
#      (the single solution) — so single-solution projects keep working with no ceremony.
#   2. If scenarios/ holds EXACTLY ONE scenario file, auto-select it (write the active-scenario marker). With
#      multiple scenarios it does NOT auto-select — the gate then makes the agent ask "what are we working on?".
# Idempotent (create-if-not-exists; never clobbers an existing file or marker). No-op for non-.NET / multi-SLNX.
set -e +u -o pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
SCEN_DIR="$PROJECT_DIR/scenarios"
STATE="${KYKLOS_STATE_DIR:-/tmp/kyklos-state}"; mkdir -p "$STATE" 2>/dev/null || true
MARKER="$STATE/active-scenario"

# 1) default stub for a single-solution project with no scenarios/ yet
if [ ! -d "$SCEN_DIR" ]; then
    mapfile -t slnx < <(find "$PROJECT_DIR" -maxdepth 4 -name '*.slnx' -not -path '*/bin/*' -not -path '*/obj/*' 2>/dev/null || true)
    if [ "${#slnx[@]}" -eq 1 ]; then
        mkdir -p "$SCEN_DIR"
        rel="$(realpath --relative-to="$PROJECT_DIR" "${slnx[0]}" 2>/dev/null || echo "${slnx[0]}")"
        name="$(basename "${slnx[0]}" .slnx)"
        cat > "$SCEN_DIR/default-scenario.md" <<EOF
---
scenario: default
description: Auto-generated single-solution default (the one .slnx discovered at install). Multi-SLNX work adds explicit <slug>-scenario.md files.
---
## Modules in scope
| name | repo | slnx | role | package |
|------|------|------|------|---------|
| $name | . | $rel | root-app | — |
## Relationships
(none — single solution)
## Bounded scope
Auto-generated default. Replace/extend with real scenarios when this workspace holds multiple SLNXes.
EOF
    fi
fi

# 2) auto-select when there is exactly one scenario; otherwise leave selection to the agent + user
if [ -d "$SCEN_DIR" ] && [ ! -f "$MARKER" ]; then
    mapfile -t scen < <(ls "$SCEN_DIR"/*-scenario.md 2>/dev/null || true)
    if [ "${#scen[@]}" -eq 1 ]; then printf '%s' "${scen[0]}" > "$MARKER"; fi
fi
exit 0
