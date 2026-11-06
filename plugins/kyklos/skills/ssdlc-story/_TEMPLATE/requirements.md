# STORY-<id>: <Title>

- **Status:** Todo <!-- set with: story set <id> status=... (the story tool lists the valid values) -->
- **Story-Type:** <library | service | ci | infra | plugin | docs | test> <!-- OPTIONAL: focuses the Proof dimensions (see ssdlc-story-proof story-type-profile.sh). Omit -> the full table. -->
- **Branch:** <feature/… | hotfix/… | — (merged)>
- **Scenario:** <slug> <!-- REQUIRED in a scenario-enabled (multi-SLNX) project: the one working scenario this story targets (a scenarios/<slug>-scenario.md). Omit only where the project has no scenarios/ dir. -->
- **Links:** <HISTORY entry · commits · [[memory-note]] · related [STORY-xxx](../STORY-xxx-…/requirements.md)>

## User story
As a **<role>**, I want **<capability>**, so that **<benefit>**.

<!-- Capture the user's verbatim request here too when it exists — the exact words are the ground truth. -->

## Requirements
- **R1** — <requirement>
- **R2** — <requirement>

## Use cases to test
- **UC1** — <the concrete usage/path a test will exercise (the happy path + the meaningful variants)>
- **UC2** — <…>

## Failure modes handled
- **FM1** — <how it can fail (bad input, missing dependency, race, crash) and what the code does about it>
- **FM2** — <…>

## Fail-open vs fail-hard
- <for each failure mode: does it fail-OPEN (degrade/allow, never wedge) or fail-HARD (block loud)? State which, and WHY that choice is correct here. No silent fail-open unless explicitly justified.>

## Poka-yoke
- <the mistake this makes IMPOSSIBLE by construction (not merely documented/checked-late), and the rung of the poka-yoke ladder it sits on. If none applies, say why.>

## Enforcement — the agent MUST use it (2e)
- <the hook, gate or tool path that makes this the only way to do the thing, so an agent cannot skip it.>

## Anti-circumvention / anti-reinvention (2f)
- <what stops an agent bypassing it, or building its own private copy of it.>

## Acceptance criteria (Given / When / Then)
- **AC1** — Given <context>, when <action>, then <observable, checkable outcome>.
- **AC2** — Given <context>, when <action>, then <outcome>.

> Each AC must be *checkable* — ideally by a named automated test or a concrete observation, not a vibe.

## Out of scope / non-goals
- <what this story deliberately does NOT do>
