---
name: ssdlc-cysec-comments
description: Sweep code (a diff, file, directory, or whole repo) for security-motivated logic that lacks a `[CySec]` annotation and add it, per the ssdlc-cysec convention. Use when asked to add/backfill security annotations, when ssdlc-story-proof flags missing `[CySec]` in the Security Posture / Defense-in-Depth Evidence, or to build the CRA/NIS2 control inventory. PRECISION over recall — annotate only genuine, nameable controls; never invent a reference.
---

# ssdlc-cysec-comments — backfill `[CySec]` security annotations

Adds the `[CySec]` annotations of the [`ssdlc-cysec`] convention to code that is written to prevent a
vulnerability but is not yet annotated, so each control states its **intent** and a **formal reference**
(CWE / OWASP Top 10 / IEC-62443 / CAPEC). Result: an auditable (CRA/NIS2), educational, unambiguous security posture.

This is an **authoring aid**, not a gate: it improves traceability and the Proof **Evidence**; it never changes a
story-proof verdict (those are decided by tests) and never changes behaviour (it writes comments only).

## Core discipline — PRECISION over recall

Apply the [`ssdlc-cysec`] precision rules ("Precision over recall"): annotate only real controls, never invent a
reference, skip when unsure.

## Scope — and always say what you swept

- **Default:** the current change/diff, or a file/dir the user names. This is the common, high-value case
  (annotate what you just wrote/reviewed).
- **Whole-repo** sweeps are large and noisy — do them only when explicitly asked, in batches, and report the scale
  and what you skipped.
- **Idempotent:** `grep -rn "\[CySec\]" <scope>` first; never duplicate or re-annotate already-annotated code.

## Procedure

1. **Inventory existing** — `grep -rn "\[CySec\]" <scope>`; exclude anything already annotated.
2. **Find candidates**, then JUDGE each (these are places controls *usually* live, not proof one exists):
   input validation / sanitization / allow-lists; path canonicalization & `..`/traversal checks; SQL or shell
   command construction (parameterization/escaping); (de)serialization type-restriction; cryptography
   (algorithm, key handling, RNG); authN/authZ & permission checks; secret handling / redaction / no-log;
   deny-by-default gates; resource limits (size/time/recursion caps → DoS); output encoding (XSS).
3. **Classify** each *real* control — verb (Prevents/Mitigates/Hardens/Detects/Enforces) + canonical reference(s),
   most specific first — **per the [`ssdlc-cysec`] convention** (the single source of truth for verbs/refs/format).
4. **Annotate at the check site**, in the language's comment syntax, in the [`ssdlc-cysec`] format
   (`// [CySec] <verb> <REF> "<canonical title>"[: <why here>]`; block form when several refs apply).
   **Comments only — do not restructure or change behaviour.** Keep the diff pure annotation.
5. **Report the inventory** — `file:line → <verb> <REF>` for every annotation added. Paste it into the story's
   `## Proof` Evidence for Security Posture / Defense in Depth; it is also the CRA/NIS2 control catalogue, and
   `grep -rn "\[CySec\]"` regenerates it any time.

## Examples

```csharp
// [CySec] Prevents CWE-22 "Path Traversal": reject '..' before resolving under the content root.
if (relative.Contains("..")) throw new ArgumentException(nameof(relative));
```

```csharp
/* [CySec]
 * Hardens CWE-89 "SQL Injection" (defense in depth): parameterized here even though the caller validates.
 * Enforces OWASP A03:2021 "Injection"
 */
```

## Guardrails (do NOT)

- **Never change behaviour** — annotation only; the diff is comments.
- **Never fabricate** a reference; correct id + canonical title; skip if unsure.
- **Never over-annotate** — precision > recall; a missing annotation is acceptable (soft), a false one is not.
- **Never** treat this as a gate — it does not set or change any story-proof verdict.
