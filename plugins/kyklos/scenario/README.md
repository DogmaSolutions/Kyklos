# Working scenarios (multi-SLNX)

A **scenario** declares the *bounded slice* a task touches in a multi-SLNX workspace: which `.slnx` modules
are in scope and how their packages depend on each other. It is deliberately **not** a global deploy manifest
(the real deploy composition is finalized downstream by pipeline artifact-copy + manual steps, outside the
agent's reach) — it is the locally-true scope for *this* work.

## Why
The `KyklosBridge` targets **one** solution. With multiple SLNXes across repos forming a DAG of modules
consumed by different root apps, the tooling must be told *which* solutions this task involves — and must
never guess or fabricate the relationships. The scenario is that declaration; the gate + linter enforce it.

## File format — `scenarios/<slug>-scenario.md`
```markdown
---
scenario: <slug>
description: <one line>
---
## Modules in scope
| name     | repo           | slnx          | role              | package        |
|----------|----------------|---------------|-------------------|----------------|
| Lib.A    | group/lib-a    | Lib.A.slnx    | library           | Org.Lib.A      |
| App.Root | group/app-root | App.Root.slnx | root-app          | —              |
## Relationships   (package producer → consumer; MUST be a DAG)
- Lib.A -> App.Root
## Deploy groupings (OPTIONAL, informational — the agent MUST NOT derive build/test behavior from these)
- pack-together: App.Root
## Bounded scope
Only the slice this task touches — NOT the global deploy truth.
```
- `role` ∈ `library | root-app`; a `library` must carry a `package` id. `slnx` is a path (resolved against
  the workspace root) that **must exist** — this is what rejects a fabricated file name.
- **Placeholders above are `Lib.A` / `App.Root`, NOT real projects** — a scenario is authored WITH the user
  (agent-assisted), never invented by the agent.

## Enforcement
- **Linter** — `validate-scenario.sh <file> [workspace-root]`: frontmatter present; every `.slnx` exists;
  edges reference only declared modules; the graph is **acyclic**; libraries carry a package. Exit 0 = valid.
- **Gate** (`kyklos-scenario-gate.sh`, PreToolUse) — in a project that has `scenarios/`, blocks build/test
  (bridge `run_tests`/`build` and raw `dotnet test|build|run`) until an **active, valid** scenario is selected
  (marker `${KYKLOS_STATE_DIR:-/tmp/kyklos-state}/active-scenario` → the chosen file).
- **Init** (`kyklos-scenario-init.sh`, SessionStart) — a single-solution project gets a `default-scenario.md`
  auto-generated and auto-selected (zero ceremony); multi-SLNX projects declare explicit scenarios and the
  gate makes the agent ask *"what are we working on today?"*.
- **Story** — a scenario-enabled project requires the In-progress story to name its `**Scenario:**`
  (`story-backlog-guard`).

Tests: `tests/test-scenario.sh` (linter) + `tests/test-scenario-hooks.sh` (gate + init), run by `run-all.sh`.
