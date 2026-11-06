#!/usr/bin/env bash
# kyklos-tool-catalog-surface.sh (Kyklos, SessionStart) — TOOL-FIRST discoverability (Layer 1).
#
# PROBLEM (fleet-wide): agents hand-craft what a kyklos/MCP tool already does, and only discover the tool
# REACTIVELY when a guard blocks them — because discovering the right tool was never the path of least resistance.
# This hook makes the right tool the FIRST thing seen: at session start it injects an always-in-context, TASK-
# ORIENTED capability catalog ("want to do X -> use Y").
#
# SOURCES:
#   * GENERATED: installed Kyklos skills — every skills/*/SKILL.md `name:` + `description:` (the "when to invoke").
#   * GENERATED: the MCP tools the Kyklos actually binds to — grepped `mcp__*` references (the firm run-on-host
#     contract); the full LIVE inventory is loaded on demand via ToolSearch, which the catalog tells the agent to do.
#   * HAND-MAINTAINED in this file: the `story` / `story epic` verb lines (the story tool's own usage text, `story
#     --help`, owns the syntax; keep these lines in step with it).
#
# It also REINFORCES the Tool-First norm (Layer 3) every session: consult this catalog + ToolSearch the MCP
# inventory BEFORE hand-crafting; hand-crafting needs an explicit "no tool fits because ...".
#
# FAIL-OPEN by construction: every step is best-effort; a missing skills dir, an unparseable SKILL.md (->
# degrade to the raw skill name), or no MCP binding just yields a shorter catalog — SessionStart is NEVER crashed
# or stalled. CONFIG: KYKLOS_TOOL_CATALOG=on|off (default on). A concise ROUTING TABLE, not a tool dump.
# Wired: SessionStart.
set +e -uo pipefail

# shellcheck source=lib/control-switch.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/control-switch.sh" 2>/dev/null || true   # kyklos_control_off: the one control-switch reader
kyklos_control_off "${KYKLOS_TOOL_CATALOG:-}" && exit 0
cat >/dev/null 2>&1   # drain the SessionStart payload (unused)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)" || exit 0
SKILLS="$ROOT/skills"

# --- skills: name + a short "when to invoke" from each SKILL.md frontmatter (degrade to the dir name) ---
skills_tbl=""
if [ -d "$SKILLS" ]; then
    for sm in "$SKILLS"/*/SKILL.md; do
        [ -f "$sm" ] || continue
        dir="$(basename "$(dirname "$sm")")"
        name="$(awk -F': *' '/^name:/{print $2; exit}' "$sm" 2>/dev/null)"
        desc="$(awk -F': *' '/^description:/{sub(/^description: */,""); print; exit}' "$sm" 2>/dev/null)"
        [ -n "$name" ] || name="$dir"
        # first sentence, clipped — a routing hint, not the whole description (keeps the catalog lean).
        # Split on a period FOLLOWED BY A SPACE so abbreviations (".NET") survive; then clip length.
        hint="$(printf '%s' "$desc" | sed 's/\. .*//' | cut -c1-104)"
        [ -n "$hint" ] || hint="(see skills/$dir/SKILL.md)"
        skills_tbl="${skills_tbl}  - ${name}: ${hint}"$'\n'
    done
fi

# --- MCP: the tools the Kyklos actually binds to (generated); full live inventory via ToolSearch ---
mcp_tbl="$(grep -rhoE 'mcp__[A-Za-z0-9]+__[a-z_]+' "$ROOT/hooks" "$SKILLS" 2>/dev/null | sort -u | sed 's/^/  - /')"
[ -n "$mcp_tbl" ] || mcp_tbl="  - (no MCP binding found — ToolSearch the live inventory)"

msg="[kyklos] TOOL-FIRST CAPABILITY CATALOG (auto-generated) — LOOK BEFORE YOU LEAP.
Before hand-crafting ANYTHING, check whether a tool already does it. Hand-crafting is justified ONLY with an
explicit \"no tool fits because ...\". Consult this catalog + ToolSearch the MCP inventory FIRST.

STORY / SSDLC lifecycle -> the \`story\` CLI (NEVER hand-edit Stories/ files or curl the issues API for a story):
  new | adopt | set | phase | proof | close | ra | track-finding | materialize | refresh | structure
  (e.g. new story -> story new <kebab-slug> --title \"<title>\" --type <t> --kind <development|analysis|documentation|ops> --severity <critical|high|medium|low> --epic <E0N>; next work -> story next; SSDLC phase -> story phase <id> <Phase>;
   proof -> story proof <id> --set \"<Dim>=PROVEN|evidence\"; close -> story close <id>.)

EPICS (GitLab milestones) -> \`story epic ...\` / the bridge epic verbs ONLY (NEVER curl/glab/python the milestones API):
  find/search -> story epic list [--state active|closed|all] [--search \"<text>\"]   (epic_list)
  one epic, its stories + progress -> story epic show <E0N> [--search \"<text>\"]   (epic_get)
  create/configure title, goal, dates -> story epic set <E0N> --title \"<t>\" [--goal ..] [--start ..] [--due ..]   (epic_set)
  close / reopen / delete (empty only) -> story epic close|reopen|delete <E0N>   (epic_close / epic_reopen / epic_delete)
  move a story to another epic -> story set <id> epic=<E0N>   (story_field_set field epic)

OVERRIDES -> every use of the owner's override label across the projects, with its named cause and that cause's state:
  bridge override_audit [{\"causeMap\": <the operator map text>}]   (override_audit; the map names the causes of past uses)

Kyklos SKILLS (invoke the skill; its SKILL.md says exactly when):
${skills_tbl}
BUILD / TEST on the real host -> KyklosBridge MCP (never a hand-rolled local dotnet/Pester harness):
${mcp_tbl}
  (Load the full live MCP inventory with ToolSearch, e.g. \"select:mcp__KyklosBridge__run_tests\".)
READ-ONLY bridge verbs from the shell or a script -> the \`bridge\` command: \`bridge\` lists them, \`bridge <verb> '<json>'\`
  calls one (the bridge refuses any verb that writes or acts on the host)."

if command -v jq >/dev/null 2>&1; then
    jq -nc --arg m "$msg" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$m}}'
else
    esc="${msg//\\/\\\\}"; esc="${esc//\"/\\\"}"; esc="$(printf '%s' "$esc" | tr '\n' ' ')"
    printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}' "$esc"
fi
exit 0
