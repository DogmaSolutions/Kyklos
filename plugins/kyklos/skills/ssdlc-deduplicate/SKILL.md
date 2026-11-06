---
name: ssdlc-deduplicate
description: Perform the global deduplication pass for the ssdlc-story-proof Non-Duplication dimension — find duplicated constants/logic with project-appropriate tooling (mechanical pre-filter), triage candidates SEMANTICALLY, and resolve by centralizing them at the correct architecture level. Use when Non-Duplication is UNPROVEN, when asked to dedup/DRY a codebase, or before closing a story. It is a behaviour-preserving refactor (tests stay green) — and it never merges things that merely look alike.
---

# ssdlc-deduplicate — the global deduplication pass

The **doer** for the [`ssdlc-story-proof`] **Non-Duplication** dimension (which is only the *auditor*). It finds
duplicated constants and logic and removes them by **centralizing** — a behaviour-preserving refactor across the
whole relevant surface, not just the last unit written.

## Core discipline — SEMANTIC, both directions, behaviour-preserving

Deduplication is a **refactor**: behaviour must not change and tests stay green throughout (see [`running-tests`];
the zero-failures gate applies). And it is decided by **meaning**, in *both* directions — this is the part a
mechanical tool gets wrong:

- **DO merge things that share a single reason to change** (one source of truth) — even when named differently
  (renamed / paraphrased clones a text-matcher misses).
- **Do NOT merge things that merely look alike now** but change for *different* reasons or live in *different
  bounded contexts*. Coincidentally-identical text/values are not duplication; forcing them into one shared
  symbol couples unrelated code — premature abstraction is its own defect (the opposite mistake). When unsure,
  the rule of three: extract on the third genuine occurrence, not the second lookalike.

## Scope

- Default: the story's surface **plus** wherever its constants/logic could already be duplicated. Search
  **globally** for candidates; land the changes incrementally.
- Once a codebase is clean, re-running should surface nothing new.

## Procedure

1. **Pre-filter (mechanical)** — adopt or create a project-appropriate detector: a clone/copy-paste detector
   (e.g. jscpd, PMD-CPD, SonarQube duplications, Roslyn analyzers, `simian`), an analyzer rule, or a
   shared-constants / `nameof` check. Run it over the scope → a **candidate list**. If nothing fits the stack,
   build a minimal AST/grep pass and **keep it in the project's tooling** so the pass is
   repeatable.
2. **Triage (semantic)** — for each candidate decide by meaning: a real duplicate (shared reason to change) or a
   coincidental collision. Discard the false positives; **add** the true clones the mechanical tool missed
   (renamed/restructured) that you find by understanding the code.
3. **Resolve by centralizing** — per the architecture:
   - **Generic** constants/logic → the **lowest shared level** (a shared module/library used across
     projects/modules/files).
   - **Specialized** logic → the appropriate **higher** shared level — not left duplicated, just centralized
     where it belongs. Reference the single source of truth from every former duplicate; never re-declare it.
4. **Preserve behaviour** — after each centralization, run the affected tests (the whole surface, per
   [`running-tests`]); the change is a pure refactor. If anything goes red, fix or revert before moving on.
5. **Report** — what was centralized, **where** (the new/extended shared location), and any residual left
   un-merged **with the reason** (usually "coincidental — different reason to change"). This is the evidence for
   the story's **Non-Duplication** Proof row.
6. **Emit the proof token (when the Non-Duplication tool-gate is armed).** After the pass is CLEAN (nothing new
   to centralize), record a content-anchored token over the exact source files you inspected, so the Proof row
   cannot be marked PROVEN without this pass having run over the current file state:

   ```sh
   "$CLAUDE_PLUGIN_ROOT/hooks/lib/proof-tool-gate.sh" emit "Non-Duplication" <the source files you scanned>
   ```

   Tokens are bound to ONE story, so stories proven in parallel in the same container never overwrite or satisfy
   each other. The story is taken from the branch name (`story-<N>`) or the HEAD commit's `Refs: #<N>`; when neither
   names it, pass it explicitly: `proof-tool-gate.sh emit --story <N> "Non-Duplication" <files>`.

   Any later edit to those files invalidates the token (the story-proof guard re-hashes them at close), so the
   pass must be the LAST thing before you set the row. The close gate checks this token by default (the check is in
   `hooks/kyklos-story-proof-guard.sh`, the token in `hooks/lib/proof-tool-gate.sh`).

## Guardrails (do NOT)

- **Never change behaviour** — it is a refactor; tests are green before and after.
- **Never merge lookalikes** that change for different reasons or cross bounded contexts (over-DRY coupling).
- **Never centralize at the wrong level** — a generic constant must not be buried inside one project; a
  project-specific rule must not be hoisted into the shared base.
- **Never rely on the tool alone** — the mechanical pass only *pre-filters*; the decision is always semantic.
