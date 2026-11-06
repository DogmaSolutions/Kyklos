---
name: ssdlc-risk-assessment
description: Produce (and keep current) a story's Risk Assessment — a pragmatic, numbered security-risk register for the change the story makes, cited to the standards/laws that apply to the project (IEC-62443, Cyber Resilience Act, NIS2). Use at story start and before close, and whenever asked to assess risk / threat-model a change. On first use in a project it interviews the developer for the applicable standards + always-include criteria and persists them. The ssdlc-story-proof Risk Assessment dimension AUDITS this.
---

# ssdlc-risk-assessment — the per-story security risk register

The **doer** for the [`ssdlc-story-proof`] **Risk Assessment** dimension (which only audits). It produces a
story's `risk-assessment.md`: a **pragmatic risk register** — numbered items, scoped to the change the story
makes — cited to the standards and regulations that apply to *this* project. **Pragmatic, not a full formal
IEC-62443 zones-and-conduits assessment**: a lightweight register that *references* the standards, so it scales
to a normal story.

**Where the register lives (backend-aware).** Author it through the `story` tool, NOT by hand, so it lands where
the proof gate actually reads it:

```
story ra <id> --apply <file>     # write the register (also '-' for stdin);  story ra <id>  prints the current one
```

On the **local (filesystem) backend** this writes the story's `risk-assessment.md`. On the **gitlab backend** the
register is a GitLab-native note the gate reads via the `backend_ra_read` seam — a hand-edited `risk-assessment.md`
there is a generated mirror the gate ignores (and the mirror-edit guard forbids editing it). Either way the same
rules apply below (a numbered `RA-##` register for PROVEN; a user `Risk-Assessment-Waived:` line for NOT_PERTINENT).

## Enabled by DEFAULT — opt-out only on explicit user waiver (except the no-risk-surface types)

Every story gets a Risk Assessment **unless the developer explicitly waives it** (a
`Risk-Assessment-Waived: <who/why>` line in `risk-assessment.md`, mirroring `Proof-Override:`); the agent may **not**
self-skip it. **Exception — the no-risk-surface story types** `docs` and `test`: they have no risk delta, so the
[`ssdlc-story-proof`] Risk Assessment row may be `NOT_PERTINENT` with the type profile's stock reason and no waiver.
If such a story *does* touch a risk surface, mark the row PROVEN with a real `RA-##` register as usual.

`kyklos-story-proof-guard` enforces this at the close (it also refuses a PROVEN row while `CLAUDE.md` has no
`## Risk assessment criteria` section), so run Step 0 for real, with the developer.

## Step 0 — load the project's risk-assessment criteria (interview once, then reuse)

The criteria are **persisted in the repo** (team-wide, survive compaction, systematic). Read them from the
project's **`CLAUDE.md` `## Risk assessment criteria`** section. Decide mechanically with the gate:

    bash "$CLAUDE_PLUGIN_ROOT/skills/ssdlc-risk-assessment/has-risk-criteria.sh" CLAUDE.md   # exit 0 present, 1 absent

- **Exit 0 (present)** → use it. Do not interview.
- **Exit 1 (absent — first use)** → run the **first-run interview**, then **write** the section into `CLAUDE.md`
  (+ a one-line agent-memory pointer). One-time onboarding; later runs just read it.

### First-run interview (agent ⇄ developer)

Because the criteria are project- and country-specific, drill the developer (propose these as the starting set;
their answers win and are what you persist):

1. **Applicable standards / frameworks** — default **IEC-62443** (industrial/OT security). Which parts apply
   (e.g. 4-1 secure-dev-lifecycle, 4-2 component requirements)? Any others (ISO 27001, OWASP ASVS)?
2. **Applicable regulations / directives** — default the **Cyber Resilience Act** (CRA essential requirements)
   and **NIS2** (for in-scope sectors). Confirm which apply and any **country-specific** laws.
3. **Always-include general criteria** — the risks EVERY story's register must consider regardless of the change
   (e.g. authN/authZ, input validation & injection, secret handling, supply-chain/dependency, data-at-rest/in-
   transit, logging/auditability, denial-of-service / resource limits, safe defaults / least privilege).
4. **Scope** — confirm **per-story delta** (assess the risks the change introduces/mitigates), not a full
   project re-assessment.

Persist the confirmed answers verbatim under `## Risk assessment criteria` in `CLAUDE.md`, then proceed.

## Step 1 — assess the story's DELTA and write `risk-assessment.md`

Scope to what the change **introduces, exposes, or mitigates** (new entry points, new data flows, new
dependencies, new privileges, new trust boundaries) — plus the persisted always-include criteria. For each risk,
write a **numbered `RA-##`** register row (pragmatic register):

| # | Asset / entry point | Threat | Vector (CWE/CAPEC) | Impact × Likelihood | Mitigation (+ where) | Residual | Std ref |
|---|---------------------|--------|--------------------|---------------------|----------------------|----------|---------|
| RA-01 | … | … | CWE-… | High × Med | … (`file:line`) | Low | IEC-62443-4-2 SR… / CRA / NIS2 |

- **Number stably** (`RA-01`, `RA-02`, …) — these anchors are consumed by the Risk Assessment dimension and by
  the `[RiskMitigation RA-##]` code comments.
- **Impact × Likelihood** — a simple qualitative pair (Low/Med/High), not a formal CVSS computation.
- **Std ref** — cite the applicable IEC-62443 requirement / CRA essential requirement / NIS2 measure. Cite, don't
  reproduce the standard.
- Keep it **honest and short**: a real risk with a real mitigation beats a long speculative list.

## Step 2 — traceability to code (the [RiskMitigation RA-##] convention)

Where code implements a mitigation for a register item, annotate it with a greppable comment that names the item
— **mirroring the [`ssdlc-cysec`] `[CySec]` convention**, so `grep -rn "\[RiskMitigation RA-"` yields the
mitigation inventory:

    // [RiskMitigation RA-03] Prevents CWE-89 "SQL Injection": parameterized query (see risk-assessment.md).

(Combine with a `[CySec]` line where the control is also a formal security annotation.) The Risk Assessment
dimension audits both directions: no un-enumerated higher risk introduced, and each enumerated risk mitigated
(grep for its `RA-##`).

## Report (for the Proof Evidence)
Cite the `risk-assessment.md` items (RA-##), the mitigations applied (with `[RiskMitigation RA-##]` locations),
and any residual/accepted risk — the evidence the **Risk Assessment** dimension cites.
