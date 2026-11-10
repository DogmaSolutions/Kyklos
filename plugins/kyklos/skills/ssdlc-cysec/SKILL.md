---
name: ssdlc-cysec
description: The canonical `[CySec]` security-annotation convention — the single source of truth for its format, verbs, and references. Use WHILE writing or reviewing code whose purpose is to prevent a vulnerability: annotate the check inline, at the moment you write it. Recalled like Test Discipline. The ssdlc-story-proof Security dimensions AUDIT this; the ssdlc-cysec-comments skill BACKFILLS it on existing code; both defer to this skill for the format.
user-invocable: false
---

# ssdlc-cysec — the `[CySec]` security-annotation convention

When a piece of code exists **specifically to prevent a vulnerability**, annotate it with a greppable `[CySec]`
comment stating its **intent** and a **formal reference** (CWE / OWASP Top 10 / IEC-62443 / CAPEC). Write it
**while you write the check** — the annotation is cheapest and most accurate at authoring time, and it is exactly
the line a non-expert would otherwise delete as "redundant".

Three payoffs: **due-diligence evidence** for a CRA / NIS2 audit (`grep -rn "\[CySec\]"` = a standards-mapped
control inventory), **developer education**, and **intent clarity** (a security check and a functional check often
look identical — the comment says which it is and why).

This skill is the **canonical definition** of the convention. The [`ssdlc-story-proof`] Security Posture /
Defense-in-Depth dimensions **audit** it (softly — see below); the [`ssdlc-cysec-comments`] skill **backfills** it
onto already-written code. Both defer here for the format, so it lives in exactly one place.

## Format (language-agnostic — use the language's comment syntax)

    // [CySec] <Prevents|Mitigates|Hardens|Detects|Enforces> <REF> "<canonical title>"[: <why here>]

- **`[CySec]`** — a fixed tag, so `grep -rn "\[CySec\]"` yields the control inventory (the audit artifact).
- **Verb** = the control's relationship to the weakness:
  - **Prevents** — eliminates the weakness (e.g. parameterized query removes the injection).
  - **Mitigates** — reduces its likelihood/impact without eliminating it.
  - **Hardens** — a defense-in-depth / redundant layer (the inner check that still rejects if the outer is bypassed).
  - **Detects** — logs/alerts on the condition.
  - **Enforces** — applies a policy (e.g. least privilege, deny-by-default).
- **REF** = the canonical id **and** title, most specific first: `CWE-89`, `OWASP A03:2021`, `IEC-62443-4-1`,
  `CAPEC-66`, … Keep the title — it is the educational part.
- **`: why here`** (optional) — the local rationale, for the non-expert reader.

Single, and block form when several references apply:

    // [CySec] Prevents CWE-22 "Path Traversal": reject '..' before resolving the path.

    /* [CySec]
     * Prevents CWE-22 "Improper Limitation of a Pathname ('Path Traversal')"
     * Mitigates OWASP A01:2021 "Broken Access Control"
     */

## Precision over recall — a WRONG annotation is worse than a missing one

The security/functional boundary is blurred, so mis-annotation is misinformation in an audit trail:

- Annotate a line **only if its reason to exist is the security property** — you would remove or weaken it if the
  threat did not exist. Primarily-functional code that is merely *incidentally* safe → leave it.
- Use the **correct** canonical id **and** title. **Never invent a CWE/OWASP number.** If unsure of the exact
  id/title, verify it or **skip** the annotation. Prefer the most specific weakness (`CWE-89` over "injection").
- When genuinely unsure whether a line is security-motivated, **skip it**. Under-annotate, never over-annotate.

## Soft by design — it does NOT gate

`[CySec]` improves traceability and the Proof **Evidence**; it is **not** a proof criterion and never changes a
story-proof verdict (those are decided by *tests*). Two separate axes:

- **Verdict (hard):** is the threat handling demonstrated by a *named test*? → PROVEN / UNPROVEN / NOT_PERTINENT.
- **Annotation (soft):** is the security-motivated code traceably documented? → recorded in the Proof Evidence;
  a *missing* annotation is a **missed opportunity**, never an `UNPROVEN`.

A `[CySec]` comment also marks the code it sits on as security-sensitive for `mutation-due.sh` (the
`measuring-test-coverage` skill), which decides from it whether a story needs a mutation run, so place it at the
guarded code.

## When to use

- **While writing/reviewing** code whose purpose is a security control — annotate at the check site, then.
- Cite the annotations you added in the story's `## Proof` Evidence for Security Posture / Defense in Depth — they
  double as the CRA/NIS2 control catalogue.
- To **backfill** existing, unannotated controls (a diff, file, or repo sweep), use [`ssdlc-cysec-comments`] — it
  applies this exact format with the same precision-over-recall discipline.
