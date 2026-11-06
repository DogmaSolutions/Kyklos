---
name: poka-yoke
description: Mistake-proofing by design — make the wrong thing impossible or fail immediately, reaching for the highest rung (impossible-by-construction > fails-at-build > fails-in-test > blocked-by-hook > documented). Invoke when designing or implementing ANY new feature, config surface, identifier, or cross-boundary contract, and immediately after a bug a design could have made impossible (add the guard before closing the fix).
---

# Poka-Yoke (mistake-proofing by design)

Poka-Yoke means designing so the **wrong thing is impossible, or fails immediately** — instead of being
merely discouraged, detected late, or written down. Apply it to EVERY new feature, config surface,
identifier, cross-process contract, and public API.

## The escalation ladder — always reach for the highest rung you can

1. **Impossible by construction** (best — the wrong state cannot be represented or reached):
   - Select/bind by a **stable, globally-unique key**, never an ambiguous **ordinal/position** another
     tool numbers differently.
   - **One canonical constant** every site references, so a rename can't diverge two files.
   - Make illegal states **unrepresentable**: `required` init-only properties, non-nullable types, an
     `enum` over a closed set instead of a free string, a type that can only hold valid values.
2. **Fails loudly at build / startup** — the mistake breaks compilation or throws before any work:
   an analyzer error; `ArgumentException`/validation in the constructor; settings that FAIL
   `ValidateDataAnnotations` unless real values are set; a `default:`/`else` over a closed set that
   **throws** instead of silently dropping.
3. **Fails loudly in a test** — a born-green guard/architecture test or isolated expected-value test
   that stays green only while the invariant holds.
4. **Blocked by a hook** — a Pre/PostToolUse/Stop hook rejects the mistake in changed files.
5. **Documented convention** — WEAKEST. Only when 1–4 are genuinely infeasible, paired with a
   reviewer-facing note. A design sitting at rung 5 when rung 1–2 was reachable is a latent bug.

## No unneeded freedom — every knob is a mistake surface

A tool an agent (or a launcher) uses MUST be poka-yoke: **no unneeded freedom, and no escape hatches unless
absolutely necessary.** A free-form / ambient knob (an env var of arbitrary args, a "pass anything through"
flag) is an ANTI-pattern — it re-introduces the very drift/chaos the tool was meant to prevent (just relocated
and now invisible/unversioned), and it lets the wrong thing happen silently. Before adding ANY config surface,
knob, env var, or flag, ask: *"is this freedom NECESSARY, or can the correct behaviour be enforced BY
CONSTRUCTION?"* — prefer fixed args + a committed, versioned project config that every path inherits (e.g. build
settings in `Directory.Build.props`, not an env-var passthrough). Default to **no knob**. An escape hatch is
justified only when a legitimate flow genuinely needs it AND it fails loud + visible; audit existing hatches and
delete the unneeded. *(Lesson: a `KYKLOS_BRIDGE_BUILD_PROPS` "append arbitrary MSBuild args" env var was added to make a
local build match CI signing — WRONG; it was reverted in favour of project-level `Directory.Build.props` that
every build inherits by construction.)*

## Ask these when you touch any of the following

- **Identity / selection / dispatch:** is anything chosen by position/order/index that another tool
  (driver, OS, DB) numbers differently? Bind by a stable unique key; show humans a label anchored to it.
- **A value shared across files** (type name, config key, label, CLI flag, path): one canonical
  constant, or copy-pasted and free to diverge?
- **A `switch`/`default`/`else` over a closed set:** does the fall-through silently drop/no-op, or
  throw? A silent fall-through compiles clean and loses data.
- **A new setting:** does a default-constructed object FAIL validation? Are factory defaults in
  `appsettings.json` (the seed), not hardcoded in the property?
- **A cross-process / serialized contract** (gRPC, JSON DTO, DB column): can a field be forgotten on
  one side and silently default to empty? Add a round-trip test; make it required where the framework allows.
- **A destructive action** (delete/overwrite/wipe/DB mutation): dry-run by default behind an explicit
  opt-in, with a rollback/backup where feasible?
- **Resource lifecycle:** can a leak/zombie/orphan accumulate over months? Make cleanup **structural**,
  not "remember to."

## The standing loop — this IS the enforcement

Mistake-proofing **cannot be fully automated**: no hook can judge "is this design sound," and a blanket
"did you Poka-Yoke?" gate is low-signal noise. The real enforcement is a **ratchet**: every time a footgun
actually bites, *before closing the fix*, add the **highest-rung guard you can** that makes that whole
class of mistake impossible to reintroduce — then record it in the project's registry of enforced
invariants. The set only ever grows.

## The registry lives in the project

Keep a **Registry of enforced Poka-Yoke invariants** in the consuming project (its `CLAUDE.md` or a
project doc) — a table of `mistake class | guard | rung`. It is project-specific by nature (it names your
guards), so it is NOT part of this shared skill. This skill is the *method*; your project owns the *ledger*.

## When to invoke

- Designing or implementing ANY new feature, config, identifier, pipeline, or cross-boundary contract.
- Immediately after a bug caused by a mistake a design could have made impossible — add the guard to the
  project registry **before** closing the fix.
