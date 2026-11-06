---
name: ssdlc-story-proof
description: The FINAL gate for a ssdlc-story. Before a story may be marked Done / merged, evaluate the Quality Dimensions of its kind (17 for a development story) and record a verdict for each in the story's `## Proof` table. Distinct from per-story Acceptance Criteria (which define WHAT to deliver); this defines HOW WELL. A story with any UNPROVEN dimension cannot be auto-closed — only the user may override. Invoke at Finish, and whenever asked to prove/close a story.
---

# ssdlc-story-proof — the story's final quality gate

Corporate engineering policy applied to **every** story, on top of its own Acceptance Criteria. Acceptance
Criteria define **what** the story must deliver; the Quality Dimensions below define **how well** it is
engineered. This gate is the last step of the [`ssdlc-story`] **Finish** workflow: a story is not Done
until its `## Proof` table is filled and passes.

## Where the proof lives

The story tool stores the proof (an issue note on the GitLab backend, the `## Proof` section of the story's
`tasks.md` on the local backend); read and write it only through `story proof`.

**Start with the draft: `story proof <id> --draft [--branch "<deliverable>"]`** (the bridge's `proof_draft` verb; the
logic lives only there). The bridge assembles the table from the evidence it already holds: the coverage receipt and
the Test Discipline token, the Non-Duplication and Documentation tokens, the newest adversarial review note and its
token, the cited merge request or branch with its pipeline, the changed tests, and the story's spec. It fills every
row that evidence proves (Test Discipline, Non-Duplication, Documentation, Adversarial Review, Completeness), with the
links and the formal spec-item citations that evidence names (a test that names `UC1`, the review that covers `AC2`;
see the matching rule below). A documentation, analysis or data-only story with no test to name its items passes
`story` to the bridge's `doc_build` or `host_app_screenshot` run: the successful run leaves a host tool receipt naming
the items its pages or capture script name, and the draft cites it (`UC1 (tool receipt): doc_build run <id>`);
a row whose evidence is missing, unreadable or stale stays `UNPROVEN` with `OPEN (proof_draft): <what is missing>`.
The judgement rows (Security Posture, Defense in Depth, Poka-Yoke, ...) stay open with a short prompt of what to judge
and, for a correlated row, which items evidence names and which it does not. Then:

1. Get what a row is missing (the review, the coverage run, the report) and run `--draft` again; never type a drafted
   row yourself.
2. Write ONLY the open rows, with `story proof <id> --set 'Dimension=VERDICT|evidence|metrics'`. The bridge refuses to
   overwrite a drafted row with other evidence, and refuses a citation of an item the draft found no evidence for:
   add the evidence (a test that names it, a review that covers it) and draft again instead.

**Matching rule (what the draft counts as evidence; the bridge's scanner, documented here only).** Test files are the
files the cited deliverables change whose path has a `test` / `tests` folder or a folder ending in `.Tests`, or whose
name ends in `Test.cs` / `Tests.cs`, a partial `*Tests.<Part>.cs`, or is a `test-*.sh` suite. Several deliverables are
unioned, and each file takes its state at the newest cited commit that touched it (newest by git ancestry, never by
date): a file that commit deletes is no evidence, and a file whose cited commits are not on one line of history is
named unreadable. A file that cannot be read, or lies past the 200-file read cap, is named, and the others still count. In C#, only a running test counts (a `[Test]`, `[TestCase]`, `[Fact]`, `[Theory]`,
`[TestMethod]`... method that is not skipped): its method name, or a string literal in `[Category]`, `[Trait]` or
`[Property]` on the method or an enclosing class. In a shell suite, the label of a check it calls. The item must be an
exact upper-case token with no letter or digit touching it (an underscore is fine): `UC<n>`, `FM<n>`, `AC<n>`,
`R<n>`, `RA-<n>`, `FAIL-OPEN`, `FAIL-HARD` (so `AC1_band_starts_at_edge` and `[Property("Spec", "FAIL-OPEN")]` count;
`SampleAC3Strips`, `ac4` and `AC_1` do not). Doc comments, `//` comments, `[Description]`, `[TestCase]` arguments and
helper methods never count. The newest adversarial review whose token verifies counts for `AC`, `R` and `FAIL-` items
only (use cases and failure modes always need a test); `RA-` items come from the risk register. What to cite as
`--branch`: `group/project!<n>` (a merge request), `group/project@<commit>` (several, separated by spaces; a commit
not yet on the trunk stands for its whole branch, every file changed since it left the branch its own open merge
request (same project, same head commit) targets, or the default branch before there is one, so the head alone is enough; a commit on the trunk stands for itself), `group/project@<branch>` (a pushed story branch of that project, for a draft before the merge), or the bare project
path `group/project` alone, which drafts every commit on that project's trunk whose last paragraph carries the story's
`Refs: #<id>` trailer. That trailer names no project, so in that project it also matches a commit for that project's
own issue with the same number: cite the commits instead when numbers collide. A citation without a project names the
story's own project.

`story proof <id> --write` (the empty canonical table, generated by `proof_emit_table` in `proof-dimensions.sh`) is
still there for a project whose bridge story stack is not in mode `on`. Either way the table is generated, never
hand-authored: fill evidence and flip verdicts only, never remove, rename or merge a row. The canonical set for the
story's kind is a **minimum**: the story-proof guard **blocks a missing or duplicated required dimension** (a merged
"Risk Assessment · Documentation" leaves two required rows missing, so it blocks too), while an **extra row is
accepted** and only noted. An extra row never counts toward the required set and never satisfies a required row, so it
cannot hide a missing one. The table has four columns, `Quality Dimension | Verdict | Evidence | Metrics`. The close
judges the stored proof with every gate unchanged; the draft only fills what it can prove.

## The Quality Dimensions (17 for a development story)

1. **Completeness** — every behaviour/feature in the story has *at least* one POSITIVE and one NEGATIVE
   *named* automated test (NUnit/xUnit/JUnit/Playwright/bUnit/…) asserting it.
2. **Feature Availability** — every planned feature is reachable through its public interface, exercised
   end-to-end. Unit-mocking alone is not enough.
3. **Input Validation** — every public/exported entry point validates its parameters and rejects malformed
   input without propagating it inward; a test asserts the rejection.
4. **Robustness** — invalid, boundary, rare, improbable and unexpected inputs/conditions are tested, not just
   the happy path.
5. **Resilience** — transient/environmental failures (network, I/O, filesystem, dependencies) are handled and
   recovered from. Where a retry is the mechanism it must be *configurable* (attempts, backoff) and
   *short-circuitable* (disablable for tests); a test injects the failure and asserts the recovery.
6. **Security Posture** — *keep security in context so it is never silently skipped.* Walk the change's attack
   surface — inputs / trust boundaries, secret handling, unsafe deserialization, auth paths, dependency + injection
   risk, least privilege — and for each ask "is there a control, and where?". Security-motivated code carries a
   `[CySec]` annotation (see *Security annotations* below). **Reasoning-signal, soft by design** (criterion 5 — overall
   posture is not a single metric): PROVEN = **change-anchored findings** — cite each control at `file:line` + the
   threat it handles, or "searched `<surface>`, found no new threat, why". A named test that asserts a rejection is
   the *strongest* such finding, not the only one.
7. **Defense in Depth** — *reason about the LAYERED nature of the controls — semantically, not mechanically.* For each
   control ask: **"if this were bypassed, what still stops the attack?"** — name the fallback layer, or state there is
   none and why. Annotate each redundant layer `[CySec] Hardens …` (exactly the line a non-expert would delete as
   "already validated upstream"). **Reasoning-signal** (criterion 5): PROVEN = that per-control bypass→fallback
   reasoning, grounded (cite the layers / `[CySec] Hardens` sites); a test showing an inner layer still rejects when
   the outer is bypassed is the strongest evidence.
8. **Observability / Diagnosability** — *take the operator's post-failure view: when this breaks in production, is it
   diagnosable?* For each failure path the change adds, ask "what signal does it emit?" — an exception logged/surfaced
   with actionable context (operation + inputs-summary + cause) rather than silently swallowed, or (for a service) a
   health/metric/log line. Optionally tag deliberate diagnostic points `[Observability]` (soft, like `[CySec]`; its
   absence is a missed opportunity, never `UNPROVEN`). **Reasoning-signal** (criterion 5), like Security Posture /
   Defense in Depth: PROVEN = **change-anchored findings, findings-first** — cite each failure path + the diagnostic
   signal it emits at `file:line`, or "no new failure path, why"; a failure-path test asserting the signal is the
   strongest finding, not required. Ties to NIS2 incident detection.
9. **Thread Safety** — behaviour under multi-threading, parallel invocation, concurrent access and shared-state
   mutation is tested.
10. **Configurability** — configuration is defaulted, loaded, validated and overridable; tests prove each,
   including how invalid configuration is rejected.
11. **Test Discipline** — the story's Test Discipline token holds: **the bridge** issued it only when at least 95 % of the story's lines (for C#, its statements) run under a test or carry a limit; and the project's interviewed `COVERAGE_THRESHOLD` for CI (see
    [`measuring-test-coverage`], which interviews + persists it) and the tests are trustworthy (each would FAIL if its
    behaviour broke). The row also cites the evidence the managed policy's Testing section requires. A story with no
    executable behaviour marks the row NOT_PERTINENT. Coverage is the **floor**; two stronger trust signals back it,
    both persisted per-project in `.claude/standards.env`:
    - **C.R.A.P. score** (complexity × coverage) — the KyklosBridge computes it (`get_coverage` reports it for the run
      it measures; `crap.sh` forwards a cobertura report to it) and gates on the interviewed `CRAP_THRESHOLD`,
      **locally at close AND in CI** (same formula/threshold). Cite the max CRAP + worst method.
    - **Mutation score** — the **Stryker** family (Stryker.NET / StrykerJS / Stryker4s) mutates the code and checks the
      tests *kill* the mutant; surviving mutants expose vacuous tests. Whether a mutation run is required, and what
      the row then states, is decided by `mutation-due.sh check` (see [`measuring-test-coverage`]). When a run is
      made, cite its score and the level it used.
12. **Non-Duplication** — the story introduces no duplicated constants or logic, and resolves duplication its
    work exposes. Tooling is language-specific, so the agent **adopts or creates** a project-appropriate
    duplication detector as the mechanical pre-filter, then triages candidates **semantically** (coincidental
    name/value matches across boundaries are not duplicates). Resolve by centralizing per the architecture; it
    is a **global** pass, not a check on the last unit written. (See *Deduplication discipline*.)
13. **Documentation** — every doc the story **impacts** (a) **EXISTS**, (b) is **COHERENT** with the real, shipped
    behaviour (no drift, no stale/contradicted claims), (c) is **COMPLETE** to that file's required level, and (d)
    carries content **PROPER FOR ITS AUDIENCE** — a consumer-facing file (public README, marketplace/plugin docs,
    the nested public source repo) contains **NO internal hints**: no infra hostnames/IPs/runner/CI internals, no
    "internal/DISTRIBUTION repo / do-not-edit" scaffolding, no agent-memory fragments or orphan planning titles.
    Pertinence is behaviour-anchored: PERTINENT when the story changes an external contract (public API/CLI,
    config, CI consumer-contract) or user-facing behaviour; a purely internal refactor is `NOT_PERTINENT` **with a
    reason**. The [`update-docs`] skill is the **doer** (it finds impacted docs, updates them to (a)–(d), and runs
    the audience lint); this dimension **audits** it. Like Test Discipline / Non-Duplication it is **tool-signal,
    not named-test** (see criterion 5).
14. **Poka-Yoke** — where the story's code introduces a **footgun** (an easy-to-make, damaging mistake — a
    misusable API, an order-dependent call, an unchecked invariant, a silent-failure path), it carries the
    **highest-rung guard that makes the whole mistake-class impossible**, not one that merely documents it or fails
    late. The ladder (prefer higher): (1) make it **impossible by design** (types/API shape so the wrong call
    doesn't compile/exist) > (2) **fail-closed at the boundary** (reject bad input/state immediately) > (3) **fail
    loudly at runtime** (assert/throw, never silently continue) > (4) **documented convention** (weakest). The
    [`poka-yoke`] skill is the **doer** (its ladder, design questions, and invariant registry); this dimension
    **audits** the story's changes against it. **Tool-signal, not named-test** (see criterion 5): PROVEN = the
    poka-yoke review ran over the story's diff and every introduced footgun got its highest-feasible guard (cite
    the guard + rung in the Evidence). `NOT_PERTINENT` **with a reason** when the change introduces no footgun.
15. **Risk Assessment** — the story's change is measured against its **`risk-assessment.md`** register (produced by
    the [`ssdlc-risk-assessment`] doer — a pragmatic, numbered `RA-##` register cited to the project's standards/
    laws: IEC-62443 / CRA / NIS2). Two checks: **(a)** the code does NOT introduce or promote a **higher or added**
    risk that is **not** enumerated in the register (if it does → the register is updated with a new `RA-##`, or
    the story is stopped); **(b)** each enumerated security risk is **mitigated**, and the mitigating code carries a
    greppable **`[RiskMitigation RA-##]`** comment (mirrors `[CySec]`; `grep -rn "\[RiskMitigation RA-"` is the
    mitigation inventory). **Enabled by DEFAULT** — this dimension is `UNPROVEN` until the register exists and both
    checks hold. When it may be `NOT_PERTINENT` is stated by the [`ssdlc-risk-assessment`] doer.
    **Review-signal** (see criterion 5): PROVEN = the register is current for the delta and every `RA-##` mitigation
    is present + annotated (cite the `RA-##` items + `[RiskMitigation RA-##]` locations in the Evidence).

16. **i18n** — *development stories only.* Every user-facing string the story **added or changed** (GUI labels and
    descriptions, validation messages, exception messages, messages returned by an API) is promoted into the
    project's **existing, centralized** i18n resources (RESX, `IStringLocalizer`, … — the technique recorded in
    `CLAUDE.md` or detected from the code), **deduplicated** in the scope the project uses (global or per module).
    Excluded by rule: log messages, strings that drive business logic (comparisons, switch labels, keys), script
    files, and agent-facing messages (text a tool, gate, hook or MCP server returns to an AI agent or developer
    tooling, never to an end user). The [`ssdlc-i18n`] skill is the **doer**. **Tool-signal with arithmetic**: PROVEN requires three
    whole-number metrics, each citing the tool that produced it —
    `<kbd>Candidates ({tool}):</kbd> N<br><kbd>Promoted ({tool}):</kbd> P<br><kbd>Ignored ({tool}):</kbd> I` — with
    `P + I = N`, and the Evidence naming why each ignored candidate was ignored. It can **never** be
    `NOT_PERTINENT` on a development story: a change with no user-facing strings proves it with all three at 0,
    citing the scanner. The Kyklos close gate and the bridge's Proof Court both enforce this.
17. **Adversarial Review** — see the [`ssdlc-adversarial-review`] skill (always the last row).

## Why these are forcing functions, not metrics (and why security is three, not one)

The dimensions are **not measurements of one quantity — they are prompts that force distinct modes of reasoning** the
agent would otherwise skip. So **do not merge them to reduce "overlap"**: collapsing distinct cognitive triggers into
one row makes the model resolve the ambiguity toward its easiest, most **mechanical** reading, and the harder modes
(semantic, human-in-loop) are lost. In particular, **security is deliberately three dimensions, not one:**

- **Security Posture** — *breadth / anti-forgetting.* Soft **by design** (overall posture is not a single index): its
  job is to keep security in context so it is never silently skipped; at review it forces you to point at concrete
  controls.
- **Defense in Depth** — *semantic / hierarchical.* Forces reasoning about the **layered** nature of controls (very
  hard to measure): "if this were bypassed, what still stops the attack?" — reasoning, not a mechanical tick.
- **Risk Assessment** — *human-in-loop + regulatory identity.* The **developer helps fill it** from domain knowledge,
  and it carries the **CRA formal-process** identity — so it stands on its own.

**Why the soft ones need change-anchored evidence (the mechanic).** For an LLM the **writing *is* the reasoning**: it
does bounded computation per emitted token, so the analysis only happens if the tokens that constitute it are
generated. A row that accepts a bare verdict lets the model skip the chain-of-thought that *is* the analysis, and
next-token prediction then fills the cell with the highest-probability **generic** note (retrieved, not derived).
Demanding a **change-anchored, verifiable finding** — a `file:line` control, a named threat, or an explicit "searched
`<scope>`, found none, why" — forces the derivation into the tokens, so "satisfy the row" and "do the reasoning"
become the same act. Record such verdicts **findings-first** (see the *reasoning-signal* class in criterion 5).

## Verdicts

Each dimension gets exactly one verdict. A dimension that genuinely does not apply is `NOT_PERTINENT` **with a
reason** — never left blank, and never `UNPROVEN` as a shortcut.

| Verdict         | Glyph | Meaning                                                                                | Required evidence          |
|-----------------|-------|----------------------------------------------------------------------------------------|----------------------------|
| `PROVEN`        | ✅    | A *named* test asserts the dimension AND was run & passed locally at least once         | the test name(s) + evidence |
| `UNPROVEN`      | ❌    | No *named* test proves it yet                                                          | the gap/finding (optional) |
| `NOT_PERTINENT` | ∅     | The dimension genuinely does not apply to this story                                   | **the reason (required)**  |

## Story-type profiles — focus the pertinent dimensions

Applying every dimension uniformly makes most rows `NOT_PERTINENT` for a given change (a docs pass, a CI-template
fix), which turns the table into a ritual and buries the *pertinence* call. A story may declare a **`Story-Type:`**
in its `requirements.md`; the profile then says which dimensions are **expected-pertinent** vs **expected-N/A**, so
you pre-seed the table and spend attention on the live rows. It is **advisory** — the gate still requires every row
to be `PROVEN` or a justified `NOT_PERTINENT`; the profile just tells you which rows should be live.

    bash "$CLAUDE_PLUGIN_ROOT/skills/ssdlc-story-proof/story-type-profile.sh" <type>

The script's usage lists the types. An **unknown or absent** type returns the **full set** (no narrowing). If the
profile calls a dimension expected-pertinent and you still mark it `NOT_PERTINENT`, the required reason is where you
justify it.

## Story KIND — the row set itself (`kind::`)

Orthogonal to the type profile (which pre-seeds verdicts on the FIXED row set), a story's **kind** selects the
**row set itself**. A `kind::development` story (the default — every story with no `kind::` label) carries the
full canonical set exactly as above. A **`kind::analysis`** story's Proof table carries ONLY **Completeness +
Adversarial Review**; a **`kind::documentation`** story ONLY **Completeness + Documentation + Adversarial
Review** — every row live (a kind row is never pre-waived by the type profile). A **`kind::ops`** story carries
the full canonical set **minus i18n** (a development-only dimension; ops deliverables are scripts and configuration),
and its **Test Discipline** metrics are OPTIONAL — an ops
deliverable (bash/config/deployment) may prove Test Discipline without a coverage % (or mark it NOT_PERTINENT
even when a code file changed) when the technology cannot be tested or testing is destructive; every OTHER
dimension keeps full rigor. The set-check and the close
gate demand exactly the kind's set, both directions: a lighter table can never serve a development story, and a
full table on an analysis story is refused (no mixed sets). A kind that cannot be read — or an issue carrying
two `kind::` labels — resolves to `development`, the FULL set: an error can only raise rigor. Adversarial
Review is in every kind's set and can never be waived by kind.

## Criteria for a PROVEN verdict

1. **ALWAYS PROVE, NEVER ASSERT.** Never infer a dimension from reading the code — a verdict with no named
   test is not PROVEN.
2. For a **named-behavioural-test** dimension, PROVEN **only** when: a specific, *named*, automated test exists that
   would FAIL if the property were violated, **and** that test has actually been run and passed locally at least once.
   (The **tool-signal** and **reasoning-signal** dimensions prove differently — see criterion 5 — but the "never
   assert, always ground" rule of criterion 1 still binds them: their evidence must be a real tool result or a
   change-anchored finding, never a bare claim.)
3. A blanket sheet of `NOT_PERTINENT` is a **smell**, not a pass — justify each one.
4. The `[CySec]` security annotation is **not** a proof criterion — its absence is a *missed opportunity*
   recorded in the Evidence, never an `UNPROVEN` verdict (see *Security annotations*).
5. **Match the verdict to the dimension's evidence class — there are three:**
   - **Named-behavioural-test** (the default; criteria 1–2): Completeness, Feature Availability, Input Validation,
     Robustness, Resilience, Thread Safety, Configurability. PROVEN = a *named* test that would FAIL if the property
     broke, run + passed at least once.
   - **Tool-signal**: **Test Discipline** (a coverage tool), **Non-Duplication** (a duplication detector),
     **Documentation** (the [`update-docs`] pass + its audience lint), **Poka-Yoke** (the [`poka-yoke`] design review
     over the diff), **Risk Assessment** (the [`ssdlc-risk-assessment`] register + `[RiskMitigation RA-##]`
     traceability). PROVEN = the tool/pass/review ran over the relevant scope with a passing result AND the follow-
     through is documented. (Documentation: `update-docs` ran, criteria (a)–(d) hold, and the **audience lint passed**
     on every consumer-facing file. Poka-Yoke: each introduced footgun carries its highest-feasible guard — cite the
     guard + ladder rung. Risk Assessment: the register is current for the delta and every `RA-##` risk is mitigated +
     annotated, or the row is NOT_PERTINENT as [`ssdlc-risk-assessment`] allows.)
   - **Reasoning-signal (soft, semantic — the forcing functions):** **Security Posture**, **Defense in Depth**,
     **Observability / Diagnosability**. These are **not** gated on a single test (overall posture / layering /
     diagnosability is not one metric). PROVEN = **change-anchored
     findings**, and *how* you record them decides whether it is real reasoning or ritual:
     - **Findings FIRST, then the verdict** — never verdict-then-justify. Earlier tokens condition later ones, so
       evidence-first makes the verdict *follow* the findings; verdict-first produces **post-hoc rationalization**.
     - **Ground, don't pad** — each finding **links an anchor to what it handles** (`file:line` control → threat);
       "searched `<scope>`, found none, here is why" is a **first-class** result — never invent findings to fill a quota.
     - **Open-shaped for the semantic dim** — Defense in Depth's findings are a *shape* (per control: bypass → fallback?),
       not a flat checklist. A named test (a rejection / an inner-layer catch) is the *strongest* finding, not the only one.

## Security annotations — `[CySec]`

Security-motivated code carries a greppable `[CySec]` annotation naming its intent + a formal reference (CWE /
OWASP / IEC-62443 / CAPEC). The **convention itself — format, verbs, references, precision-over-recall — is the
[`ssdlc-cysec`] skill** (the single source of truth); write it *while* you write the check, or backfill it with
[`ssdlc-cysec-comments`]. Here only the **audit** relationship matters:

The annotation is soft (see [`ssdlc-cysec`]): a *missing* `[CySec]` comment is a **missed opportunity** recorded in
the row's Evidence, never an `UNPROVEN`. In the Evidence for Security Posture and Defense in Depth, cite the `[CySec]`
annotations as the evidence trail — they double as the audit inventory.

## Deduplication discipline

The discipline is the managed policy's (Coding conventions, *Reuse & duplication*); the [`ssdlc-deduplicate`] skill
**performs** the pass (the doer); this dimension **audits** it. The **Non-Duplication** row's Evidence names the tool
used, the candidates triaged, and where duplicates were centralized.

## The Metrics column & the Metrics gate

The Proof table carries a 4th **Metrics** column: for a tool-gated dimension, cite the tool + its output value as
`<kbd>{Metric} ({Tool}):</kbd> {Value}<br>` (default `—`). It is a place to pin the *number behind the verdict*.
A row is set with `story proof <id> --set 'Dimension=VERDICT|evidence|metrics'`; the unescaped `|` separates the
three fields, so write a literal pipe inside the evidence or the metrics as `\|` (it is stored as `&#124;` so the
table keeps its columns).

**The label is free text; only the value is read.** Every gate that reads a number from a Metrics cell reads it from
the text AFTER the segment's `</kbd>`, never from the `{Metric} ({Tool})` label. So a job id, a commit sha, a run or
pipeline number, or a floor written in the label (`<kbd>Coverage (get_coverage e198b9ff7e97, floor 95%):</kbd> 97.4%`)
is never taken for the score. The coverage figure is the value of the first metric whose label names coverage (else an
unlabelled `coverage N%` fragment, else the first percentage after any other label), and a metric that names mutation
is never read as coverage; the CRAP score is the value of the first metric whose label names CRAP.

The **Metrics gate** is on by default (opt out with `PROOF_METRICS_GATE=off`; `proof_metrics_gate_on` in
`proof-dimensions.sh`) and turns that column from advisory into enforced. When armed, a **PROVEN** verdict on a **mandatory** dimension
(`Test Discipline`, `Non-Duplication`, `Documentation`, `Risk Assessment`) must fill its Metrics cell, and some
dimensions add a specific check. All checks run at BOTH the CLI (`story proof --set`) and the close guard, through the
one shared seam so the two can never diverge:

- **Mandatory-cell** — a PROVEN mandatory dimension whose Metrics cell is empty (`—`) is refused.
- **Test Discipline thresholds** — the cell must **declare the story-line figure** (the share of the story lines covered
  or limited, as the receipt states it; `proof_draft` writes it as `Story lines`). The plugin only checks that a figure is
  there; the **judgement is the bridge's alone** (see "The token's coverage question" below), so no plugin setting or
  script compares the figure with a floor. **CRAP applicability is AUTO-DETECTED** (default-on for the
  stacks that can compute it): a CRAP score = complexity×coverage needs a cyclomatic-complexity tool, which exists for
  .NET/cobertura but not for bash/PowerShell. With `PROOF_TD_CRAP_APPLICABLE` UNSET the gate detects the stack itself —
  story-first (the story tool passes the story: it applies iff the story's own change window, as the proof CLI's
  `changed-files --story` computes it, holds `.cs`/`.csproj`/`.sln(x)`/F#/VB files, so a shell-only merged story is judged
  by its shell receipt whatever else merged since), then diff-first (the recent change touches such files), falling back to
  tree-presence of .NET project/solution files when no diff is readable — so a .NET story can never silently skip CRAP
  because a flag was never set. An explicit `off` is the greppable opt-out for a stack that truly cannot compute it;
  an explicit `on` forces it. When applicable, the score must be ≤ the CRAP ceiling: `PROOF_TD_MAX_CRAP` if set,
  else the repository's own `CRAP_THRESHOLD` (the bar its CI crap-gate enforces), else 30; on a
  no-CRAP-tool stack coverage carries Test Discipline. A **present** CRAP is always thresholded regardless.
- **A refused token says GAP or TOOL-LIMIT first** — a `GAP` needs the missing evidence (tests, a green run, every
  shard); a `TOOL-LIMIT` of a green run makes the bridge post one note on the story for the owner to tick. When the owner
  ticked "accept", the Test Discipline row cites that note (its `#note_<id>` link) and the close takes it as the
  evidence, with no coverage token and no override label. The rule (who may tick, what voids it) is the bridge's: see
  the bridge README, "Every refusal has a class".
- **The token's coverage question (decided by the bridge only)** — a Test Discipline token is issued when at least 95 %
  of the story lines (the lines the story's own commits changed; for C#, its statements) run under a test or carry a limit:
  the uncovered story lines may be at most 5 % of them, rounded down, so a story of fewer than 20 story lines tolerates
  none. It is judged per receipt kind (C# and shell apart), and every uncovered story line is listed on the receipt, also
  when tolerated. A story's own coverage floor is **obsolete**: `story_field_set` answers `obsolete: the token judges 95 %
  of the story lines` for the field `coverage-floor`, a stored `Coverage-Floor` line is named obsolete on the receipt, and
  `coverage_floor_check` (which `story close` still asks on every backend; greppable opt-out `PROOF_COVERAGE_FLOOR=off`,
  audited) only reports the figure. The project-wide CI floor (`COVERAGE_THRESHOLD`) is a different control.
- **Test Discipline coverage receipt (at the close, default on)** — on the gitlab backend, a PROVEN Test Discipline row
  of a development story whose cited change touches C# (`.cs`) or shell scripts (`.sh`, `.bash`) that shell coverage
  measures (inside the folders the bridge declares, today `plugins/kyklos/`; a changed script outside them is
  named in the receipt and in the close answer, never counted and never asked for) must **link the
  coverage receipt** the story's token records for each kind: the comment the bridge posts with the run's compressed
  report set. A .NET receipt is posted by the bridge's own coverage run (`get_coverage` / `run_tests` with `story`); a
  shell receipt by `story attach-coverage <id> <bashcov report or folder>`. Each prints the markdown link to put in the
  Metrics cell, e.g. `<kbd>Receipt (bridge):</kbd> [coverage-receipt-<id>-dotnet-<run>.zip](/uploads/...)`. The
  bridge judges it (`coverage_receipt_check`, the same rule as its own `story_close`): the upload is fetched again and
  must still hash to the recorded fingerprint, its comment must still exist and link it, a link to an older run's or
  another story's receipt is refused, and the token it binds was issued only within the story-line tolerance, so the
  order of the percentages in the cell never decides the verdict; a shell receipt counts only the lines the story's
  own commits added or modified in each script (the whole-file figure stays in the receipt for information);
  a changed file no report lists counts as not run,
  and a receipt with no figure never binds. Re-measuring posts a new receipt; link the latest. A token an older bridge
  minted (before receipts) closes with a warning naming the missing receipt; one a receipt-capable bridge minted needs
  its receipt.
  Documentation, analysis and ops stories are exempt by kind. Opt-out (audited): `PROOF_COVERAGE_RECEIPT=off`.
- **Non-Duplication report-link** — the dedup report is too large for the cell, so the cell must **link** the attached
  scan output (a markdown link, a GitLab `/uploads/` reference, or an `http(s)://` URL), not just summarise it.
  Attach it with `story attach <report-file>` (the bridge uploads it; no GitLab token needed) and paste the markdown
  link it prints; never build the upload call by hand.
- **Documentation changed-file link** — a PROVEN `Documentation` must **link the actual changed doc file(s)** in the
  source repo (e.g. `[docs/topic.md](…/-/blob/<sha>/docs/topic.md)`), so "docs updated" is demonstrated by a clickable
  link the reader can open, not merely asserted.
- **Proof↔story correlation** (`PROOF_METRICS_CORRELATION`) — every identifier declared in a story section
  (`UC#`, `FM#`, `AC#`) must appear in the Metrics cell of its correlated PROVEN dimension.

`NOT_PERTINENT`/`UNPROVEN` verdicts and non-mandatory dimensions are never gated. With the gate opted out the Metrics
column is purely advisory.

## Closing rule (enforced)

- A story with **any `UNPROVEN` row cannot be auto-closed** (marked Done / merged). The
  `kyklos-story-proof-guard` Stop hook blocks it.
- **Only the user may override.** On explicit user authorization, add a line
  `Proof-Override: <who/why>` under the `## Proof` heading; the guard then allows closing. The agent never
  self-authorizes an override.
  - **On the GitLab backend the override is a USER-APPLIED LABEL, not a note line.** A gitlab proof lives as an
    agent-writable NOTE, so a `Proof-Override:` line there could be self-authored — the guard ignores it. Instead the
    **user applies the `proof-override` label** to the issue (a fixed name: no variable can point the check at another label; the
    agent cannot self-apply — authorship is verified and fails closed). That waives the UNPROVEN/tool-gate checks for
    that story, but a proof note must still EXIST (the override waives HOW-WELL, never the proof's existence).
  - **Named Cause.** The label waives nothing unless the story names the cause of its gap: a line
    starting with `Override cause: <reference>` (in a note or the Test Discipline row) naming an OPEN story or triage item
    that removes the cause, is not the story itself, was not created by the closing agent (unless an owner account created
    it) and refers back to it in text another account wrote (the item's description, a note or a link), or a note
    `Override cause: accepted <figure>%` by one of the configured owner accounts, at a figure no higher than the story
    measured. The same
    rule holds for an arm's one-shot `automerge-coverage-ok` override. The bridge decides it (`proof_validate`); with no
    bridge answer no override counts.
- The clean path is not to override but to turn each `UNPROVEN` into `PROVEN` (write the missing named test)
  or a justified `NOT_PERTINENT`.
- **SHOW the proof — do not merely save it.** When you close a story (or the user asks to prove / close / gate
  one), you MUST show the completed proof **in your reply**, with its tally
  (`N PROVEN · M NOT_PERTINENT · K UNPROVEN`). The user frequently works **remote, with no filesystem access** —
  a Proof written only to `tasks.md` is **invisible** to them and does **not** count as shown. "It's in the file"
  is a workflow failure, not a close. This generalises: **any artifact that *is* the deliverable** — a result
  table, a diff/summary, a command's decisive output — is surfaced **in the response**, never left only on disk.
- **One record, two renderings — both from the tool.** The stored `## Proof` markdown table is the canonical record;
  on GitLab (the proof note, comments) it stays that table, unchanged. A terminal breaks that table (`<br>`, `<kbd>`,
  long cells), so **in the terminal show its terminal form**: name the story (`#<id>` / `STORY-<NNN>`), then paste the
  output of `story proof <id> --format text` **exactly as printed** (`story close` prints the same block between its
  `=== Proof … ===` markers; the bridge's `proof_get` with `format` `text` returns it too). It is derived from the
  stored table by one renderer: a numbered entry per dimension (verdict symbol, **bold** dimension name, verdict
  word), the evidence as indented lines, each metric as a bullet, any other line of the stored section (a
  `Proof-Override:` line, a note) as written, and the tally counted from the rows. Never type,
  merge, shorten or re-word it by hand — a hand-made form is not the proof.
  **This is HARD-ENFORCED**: the `kyklos-story-proof-guard` Stop hook blocks closing a story it sees marked Done
  this session unless the recent transcript, after the story's id, actually contains EVERY dimension of its rendered
  proof — either the stored table (each dimension as its own row under the `| Verdict | Evidence |` header) or the
  terminal form (its heading and each dimension as its own numbered `**Dimension** — VERDICT` entry); a tally alone,
  a missing dimension or merged rows do not count.
  It grandfathers stories closed in an earlier session and fails open if it cannot read the transcript, so it can
  never wedge a Stop loop.

## When to invoke

- At a story's **Finish** step, before flipping its `Status` to Done or merging its branch.
- Whenever the user asks to "prove", "close", or "gate" a story.
- After a compaction, if the ACTIVE story is near completion — re-read its `## Proof` before closing.
