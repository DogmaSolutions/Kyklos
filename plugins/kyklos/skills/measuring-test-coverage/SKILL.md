---
name: measuring-test-coverage
description: Line coverage as a FLOOR, test TRUST as the goal. Use when measuring or improving coverage, deciding what to test next, or citing coverage numbers. Covers how to collect coverage (`dotnet test --collect`, or the KyklosBridge), the trust checklist (a test only counts if it can FAIL when the behaviour breaks), and what to exclude (generated / DTO / migrations).
---

# Measuring Test Coverage

"Coverage" here means **line coverage**, and it is only a **floor** — the real goal is **trust**: a line
executed without a behaviour-anchored assertion is not trust. Do NOT chase the number by instantiating
DTOs/records or adding assertion-free tests — that raises the percentage and lowers trust.

## Targets (per project) — interviewed once, persisted, runtime-editable

The floors are **not hardcoded and never invented** — they are the developer's call, interviewed once and
persisted to `.claude/standards.env` (the machine-read source of truth; editable mid-session, so a change
needs no container restart). On first use in a project, probe the config with the mechanical gate:

    bash "$CLAUDE_PLUGIN_ROOT/skills/measuring-test-coverage/has-test-discipline-config.sh" .claude/standards.env   # exit 0 = configured, 1 = interview

If it exits non-zero (the file is missing, or `COVERAGE_THRESHOLD`, `CRAP_THRESHOLD` **or** `MUTATION_TESTING`
is unset — plus `MUTATION_LEVEL` when `MUTATION_TESTING=on`), run the **first-run interview** (the developer's answers win — that is what you persist), then write
the values:

1. **Coverage floor** — "What line-coverage floor must this project meet? (a common baseline is business
   logic ≥ 90–95 %, GUI ≥ 90 %; algorithm/heuristic assemblies validated by isolated expected-value tests are
   judged by those tests, not the line number, and are excluded from the business figure)." → `COVERAGE_THRESHOLD=<n>`.
2. **C.R.A.P. ceiling** — "What is the maximum acceptable C.R.A.P. score for any single method? (30 is a common
   industry default: it permits a fully-tested complexity-30 method, or a complexity-5 method at ≈ 55 % coverage,
   but not a complex under-tested one)." → `CRAP_THRESHOLD=<n>`.
3. **Mutation testing** — "Run mutation testing (Stryker) for this project? It proves the tests *assert* behaviour,
   not just execute it — but it is slow and Windows-runner-bound, so it is **opt-in with no default**. (on / off)" →
   `MUTATION_TESTING=on|off`. If `on`, the project must also add the `mutation-test` job to its pipeline (extends
   `.mutation_test_dotnet`); `off` (the safe answer) means no mutation run.
4. **Mutation level** *(ask ONLY when `MUTATION_TESTING=on`)* — "Which Stryker mutation level? `Basic` (fewest
   mutants, fastest) · `Standard` · `Advanced` · `Complete` (most thorough, slowest). Default `Basic`." →
   `MUTATION_LEVEL=Basic|Standard|Advanced|Complete`. This knob is CONSUMED by the fleet CI templates' `mutation.yml`, so the
   interview is its ONLY sanctioned writer — persist it here rather than letting a consumer ride the in-template
   `Basic` default silently. (An `off` project skips this — no level is needed.)

Once the knobs are set (all three always; `MUTATION_LEVEL` too when `MUTATION_TESTING=on`), USE them and do not
re-interview. To change one later, just edit the line in `.claude/standards.env`.

## C.R.A.P. score — complexity × coverage (computed locally AND gated in CI)

C.R.A.P. (Change Risk Anti-Patterns) catches what a coverage % hides: a method that is BOTH complex AND
under-tested. Per method: **`CRAP = complexity² · (1 − coverage)³ + complexity`**. A fully-covered method
scores exactly its cyclomatic complexity; an uncovered complex method explodes (e.g. complexity 10 at 0 %
coverage = 110). It needs no extra tooling — the **cobertura** report already carries per-method `complexity`
and line-rate, so compute it straight from there:

- The score is computed by the **KyklosBridge**, by the same host run that measures coverage and mints the Test
  Discipline token: **`get_coverage` reports `crap`** (the gate outcome, the project threshold from
  `.claude/standards.env` `CRAP_THRESHOLD`, the maximum and the worst methods, honouring a committed
  `crap-triage.txt`). Cite that max CRAP (+ the worst method) in the Test Discipline Proof row, alongside
  coverage and the mutation score.
- For a cobertura file you already have, the shipped **`crap.sh <cobertura.xml> [CRAP_THRESHOLD]`** sends it to
  the bridge's `crap_score` verb and relays the verdict: it prints the worst offenders and **exits non-zero if
  any method exceeds the ceiling**. It never computes on its own: with no bridge to answer it stops (exit 2).
- **CI enforces the same gate** (see the CI templates' README, `crap-gate` in `coverage.yml`).

### A8 triage — cover / refactor / accept, BEFORE you justify an enabler

When a method is OVER the ceiling, "write a test" is not automatically the answer. Triage it FIRST — the
decision often kills a story that should not exist:

- **COVER** — write the test (justified only when the method is genuinely unit/integration-testable at a
  reasonable cost).
- **REFACTOR** — decompose to drop cyclomatic complexity; CRAP falls WITHOUT new test infra (often cheapest).
- **ACCEPT** — integration-only or untestable-by-design (e.g. an `msiexec` shell-out, an ADSI/LDAP path):
  record a **rationale** and exclude it honestly. This is the sanctioned alternative to green-washing by
  lowering `CRAP_THRESHOLD` or deleting the test — the exclusion is explicit, in git, and audited.

Record the decisions in a **triage ledger** (`crap-triage.txt` at the repo root, one line per method):

```
# <ClassName>.<Method>[(signature)] = COVER | REFACTOR | ACCEPT: <rationale>
DogmaSolutions.Setup.Installer.RunMsiexec = ACCEPT: shells out to msiexec; integration-only, unit-uncoverable
DogmaSolutions.Directory.AdsiQuery.Enumerate = REFACTOR: decompose the 20-branch switch to drop complexity
```

Then `crap.sh <cobertura.xml> [threshold] --triage crap-triage.txt` (locally) and the CI `crap-gate` job (see the CI
templates' README) treat a justified **ACCEPT as a pass** —
reported `ACCEPTED (A8 triage)` with its rationale — while **COVER/REFACTOR stay flagged as open debt**. An
`ACCEPT` with **no rationale fails loud** (a bare accept is a green-wash), and an over-threshold method with
**no** ledger entry is flagged `UNDECIDED — A8 triage required`. Cite the triage decision in the Test
Discipline / Risk Assessment Proof rows when a high-CRAP method is accepted rather than covered.

## How to collect

- **With the KyklosBridge MCP:** `get_coverage` (or `run_tests` given a `story`; see the bridge's tool
  descriptions) runs `dotnet test --collect:"XPlat Code Coverage"` and returns a **labeled single-TFM** line/branch
  slice + per-method rows. The label names the ONE target framework the host measured — it is **not** the CI CRAP union
  across every framework, so for a multi-targeted method CI reads ≥ this slice. It fails loud
  (`produced=false` + reason) when no cobertura is generated (e.g. `coverlet.collector` not referenced) —
  never a fabricated 0%. How to tell it is wired + all the tools: the [`using-the-bridge`] skill.
  - **Long runs do not time out.** If the run is still going after a bounded wait, `get_coverage` answers
    `pending=true` with a `jobId`; call `get_job_result` with that `jobId` until `pending=false`. The run keeps
    going on the host in the meantime, so nothing is lost. Repeating the same `get_coverage` call joins the run already
    queued or going rather than starting a second one. Reports are saved under `reportDir`
    (`.kyklos/coverage/<jobId>` in the solution) for `copy_file` or direct reading.
  - **Measure before you arm auto-merge:** arming auto-merge on a change that touches production C# needs this
    story's Test Discipline token (`hooks/kyklos-automerge-coverage-guard.sh` refuses the arm without it;
    `hooks/lib/proof-tool-gate.sh` defines what the token covers). A plain push to let CI run is still fine.
  - **Bind the proof token to your story:** pass `story` (e.g. `42`). Without it the Test Discipline token takes
    its story from the branch name or last commit, which finds none on a trunk such as `develop`. The result's
    `proofToken` field says whether a token was issued and, if not, why. A token is issued only for a GREEN run:
    fix the failures and measure again.
  - **Fixtures a project leaves out of coverage runs:** a project whose fixtures run their code in another process
    (no coverage can be captured from them) lists them in the bridge setting `KYKLOS_BRIDGE_COVERAGE_EXCLUDED_FIXTURES`. They
    are left out of `get_coverage` runs only (never `run_tests`), the result names them so the figure is never read as
    covering them, and the calling agent cannot change the list per call.
  - **Poka-yoke weld (bridge mode):** when `BUILD_EXECUTION=bridge`, `get_coverage` is the ONLY way to collect
    coverage — a raw local `dotnet test --collect` is already blocked by the `kyklos-build-execution-guard` hook
    (it fires on any local `dotnet test` invocation), so you cannot silently collect coverage off-bridge. The
    mistake is impossible by construction, not merely discouraged.
- **Plain `dotnet test`:**
  ```
  dotnet test <solution> --collect:"XPlat Code Coverage" --settings coverage.runsettings
  reportgenerator -reports:"**/coverage.cobertura.xml" -targetdir:coverage -reporttypes:TextSummary
  ```

- **From a fork or subagent in its own worktree:** do not call `get_coverage` / `get_mutation` — the bridge
  measures its own solution root, not your worktree. Read the coverage from your branch's CI pipeline instead
  (see [`using-the-bridge`], "Forks and parallel sessions").

## What coverage measures (the denominator)

Define exclusions once in `coverage.runsettings` (the `XPlat Code Coverage <Configuration>`), the same set
the fleet CI uses: generated code by `GeneratedCodeAttribute` plus generated-file patterns (`**/*.g.cs`,
`**/*.Designer.cs`, EF `**/Migrations/**`), record/DTO auto-properties by `SkipAutoProps`, and anything
marked `[ExcludeFromCodeCoverage]` — so a % reflects real hand-written logic, not data-holders.

**Do NOT exclude `CompilerGeneratedAttribute`.** The compiler moves the body of every `async` and iterator
method into a hidden compiler-generated state-machine class, so excluding that attribute silently removes real logic
from coverage and from the CRAP gate. The bridge's `get_coverage` already applies the fleet set.

Changing these exclusions shifts every assembly's denominator, so re-measure broadly to re-baseline
consistently.

## Trust checklist — what makes a test count

A test only counts toward trustworthy coverage if it can FAIL when the behaviour breaks:
- Every test makes ≥ 1 **behavioural** assertion (a value/state that only appears when the feature works)
  — not "the page loaded" or "the CSS class is present".
- Assert against a source of truth / expected values, not hardcoded structure.
- GUI: semantic locators only (`GetByRole`/`GetByText`/`GetByLabel`); no CSS-class / `nth-child` /
  column-index locators — use `data-testid` when a selector is unavoidable.
- No `Assert.Inconclusive`/`Assert.Ignore` to dodge a red (the `test-quality-guard` hook blocks these).

## Mutation testing — the trust check beyond coverage

Coverage proves the tests **execute** the code; it cannot prove they **assert** its behaviour. The mechanical trust
check is **mutation testing**: mutate the code under test (flip a `>` to `>=`, drop a `!`, return a constant) and see
whether a test **fails** — a **surviving mutant** is a line that is covered but not asserted (a vacuous test). The
**Stryker** family provides this per stack: **Stryker.NET** (.NET/C#), **StrykerJS** (JS/TS), **Stryker4s** (Scala).

- **Check first:** `mutation-due.sh check` (below) answers `NOT REQUIRED` when this project opted out of mutation
  testing in its launcher configuration (the managed policy's Testing section); then do not run it. Mutation runs by
  default everywhere else.
- In CI, mutation is a CI-template job; the CI templates' README (`mutation.yml`) says when it runs.
- Read the **mutation score** as the trust signal and triage surviving mutants; coverage stays the **floor**, the
  mutation score is the **trust**. Cite the score alongside coverage in the Test Discipline row, with the commit
  the run measured and its scope (see *When to run it* below for how long that citation stays valid).
- **Off-CI, read the score with the bridge `get_mutation` tool** (`mcp__KyklosBridge__get_mutation`, optional
  `filter` = the project to mutate): it runs `dotnet stryker` on a SINGLE project on the host and returns the score +
  killed/survived/no-coverage counts — the same way `get_coverage` gives coverage without the CI job. It **fails loud**
  (`produced=false` + reason) when no report is generated or zero testable mutants, never a fabricated score. Use it
  for a multi-project solution or a local fix loop where the single-project CI `mutation-test` job is not enough.

### When to run it — only for security-sensitive changes, once per merge intent

During development mutation testing is **required only when the story changes security-sensitive code**: a
production source file the branch changed (against its merge base with the trunk, plus uncommitted changes), in a
language a mutation tool can mutate (C#, JavaScript/TypeScript, Scala), has a changed line within ten lines of a
`[CySec]` annotation **comment** (the `ssdlc-cysec` convention: the annotation sits right above the code it guards).
A marker elsewhere in a large file, or the word inside a string, does not count. Test files, docs, config and scripts
never make it required.

- **Not required** (no changed production line near a `[CySec]` annotation): do not run it. The Test Discipline row states
  `Mutation: not required (no security-sensitive code changed)` next to the coverage and CRAP evidence, and every
  close gate accepts that. You may still run it voluntarily.
- **Required:** it is the **final guarantee** before the branch reaches its trunk, so it runs at that moment and not
  before.
- **Run it once, right before the push that opens or updates the merge request to `develop`/`main`** (or, with no
  merge request, right before the story close). That run is the one the Test Discipline row cites.
- **Do NOT run it** after each commit, after each fix, between adversarial-review iterations, or "to be safe". While
  you iterate, run the **tests** (and coverage when you need it); mutation waits for the merge intent.
- **A cited run stays valid** while no production or test **source** file of the branch changed since the commit it
  measured. Docs, CI, story, config and README changes do not invalidate it. Re-run only when source changed.
- **Ask the tool, do not guess:** `skills/measuring-test-coverage/mutation-due.sh check [DIR [PROJECT]]` prints
  `NOT REQUIRED` (no security-sensitive code changed), `DUE` (with the reason and the `[CySec]` files that make the
  run required) or `NOT DUE` (with the commit of the run that still holds); `mutation-due.sh required [DIR]` answers
  only whether a run is required. When the change window cannot be resolved it answers `REQUIRED` / `DUE`. A recorded run covers ONE
  project (`PROJECT`: the bridge `filter` / Stryker `--project`; empty when none is named) on ONE trunk commit, so a
  run is due again when source changed, when the trunk was merged in or the branch rebased, or for another project.
  A successful run is recorded automatically, and the `mutation-timing` hook tells you when a run you are starting
  is not required or not due (advice only, it never blocks).
- CI keeps its own schedule as the safety net (the CI templates' README, `mutation.yml`); a local run never
  replaces it.

### Which level runs where

Stryker's levels are `Basic` < `Standard` < `Advanced` < `Complete` (more mutants, longer runs). Stryker's own
default is `Standard`, so a run that names no level is heavier than it needs to be.

| Run | Level |
|-----|-------|
| Development run while writing tests (bridge `get_mutation`, a local `dotnet stryker`) | `Basic`, the lowest: the bridge defaults to it (`level` argument or the project's `KYKLOS_BRIDGE_MUTATION_LEVEL` to change it); locally pass `--mutation-level Basic` |
| The merge-intent run the proof cites | the project's `MUTATION_LEVEL` (default `Basic`): pass it as `level` / `--mutation-level` |
| CI runs | as the CI templates define them, reading `MUTATION_LEVEL` |

> **Not a Proof dimension.** Mutation score, coverage % and CRAP are **evidence cited inside the `Test Discipline`
> row**, never rows of their own. The row set comes from `story proof <id>` (see [`ssdlc-story-proof`]); never
> hand-author or reconstruct a Proof table.

## Citing numbers

When you cite coverage, cite its **commit + scope** ("70.8% as of `<sha>`, whole-suite run") — a bare
"GUI is 70.8%" is not allowed once the code has moved on. If in doubt, re-run.

## The loop

1. Run the relevant suite (coverage on) → read the least-covered list.
2. Ignore DTO/record noise; target real logic + real behaviours.
3. For each gap, write a **behaviour-anchored** test (checklist above), not a line-toucher.
4. Re-run; commit per increment (Conventional Commit, tests green).
