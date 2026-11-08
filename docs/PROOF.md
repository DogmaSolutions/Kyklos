# The Proof Table

[← Back to the README](../README.md)

Every story ends with a **Proof Table**: one row per quality dimension, in four columns: **Quality Dimension**, **Verdict** (PROVEN, NOT_PERTINENT with a reason, or UNPROVEN), **Evidence** (what was
checked, where, and how) and **Metrics**. The table lives on the story, where reviewers can read it. The agent cannot close a story while any required row is UNPROVEN; only a person can override that,
and the override is recorded.

**Every dimension carries metrics**: short, labelled figures, each naming the tool that produced it, for example `Coverage (host run): 96.4%` or `Duplication (jscpd): 0 clones`. A verdict without them
is refused (a NOT_PERTINENT row carries its reason instead). Every item of the story's specification (each requirement, use case, failure mode and acceptance criterion) must also appear as its own metric in the row that proves it, so nothing in the
specification can be left silently unproven.

**Four rows are drafted from the remote, merged state**: Completeness, Test Discipline, Non-Duplication and Documentation read the cited deliverable on the remote (its changed files, its commit,
its pipeline), so they cannot be proven while the change exists only on the agent's machine. The close then certifies the **merged result**: the deliverable merged into the trunk, every commit
naming the story on the trunk, the tokens judged where the story landed. See [The Kyklos Workflow](WORKFLOW.md).

**Which rows are mandatory depends on the story's kind**, its `kind::` label (see [Storages](STORAGES.md)); the `type::` label is informational and plays no part. A row outside a kind's set is not required, and a lighter table can never be used for a development story. When the kind
cannot be read, the full development set applies (and a story adopted without a kind is given `development`, see [Storages](STORAGES.md#adoption-of-existing-issues)): an error can only raise the bar.

The table below lists, for every dimension, the **metrics** its row must carry, and for every story kind whether those metrics are **mandatory**:
✅ = the row and all its metrics are mandatory; 🟡 = the row is mandatory, the marked metrics are optional; – = the row is not required for that kind.

| Dimension            | Metrics the row must carry                                                                                                | Development |                                                       Ops                                                       | Analysis | Documentation |
|----------------------|---------------------------------------------------------------------------------------------------------------------------|:-----------:|:---------------------------------------------------------------------------------------------------------------:|:--------:|:-------------:|
| Completeness         | one metric per requirement, use case, failure mode and acceptance criterion, naming the test (or document) that proves it |     ✅      |                                                       ✅                                                        |    ✅    |      ✅       |
| Feature Availability | one metric per requirement, naming the end-to-end test that reaches it through the public interface                       |     ✅      |                                                       ✅                                                        |    –     |       –       |
| Input Validation     | the rejection tests of each entry point                                                                                   |     ✅      |                                                       ✅                                                        |    –     |       –       |
| Robustness           | one metric per failure mode, plus the boundary and edge-case tests                                                        |     ✅      |                                                       ✅                                                        |    –     |       –       |
| Resilience           | the failure-injection tests and the retry or recovery settings they cover                                                 |     ✅      |                                                       ✅                                                        |    –     |       –       |
| Security Posture     | the controls added or touched, each with its formal reference (CWE, OWASP, IEC 62443, CAPEC)                              |     ✅      |                                                       ✅                                                        |    –     |       –       |
| Defense in Depth     | for each control, the fallback layer (or the reason there is none)                                                        |     ✅      |                                                       ✅                                                        |    –     |       –       |
| Observability        | the failure paths added and the signal each one emits                                                                     |     ✅      |                                                       ✅                                                        |    –     |       –       |
| Thread Safety        | the concurrency tests, and the repeat-under-load count of each timing-dependent test file                                 |     ✅      |                                                       ✅                                                        |    –     |       –       |
| Configurability      | the configuration tests, including the refusal of invalid configuration                                                   |     ✅      |                                                       ✅                                                        |    –     |       –       |
| Test Discipline      | changed-line coverage from the host receipt, highest CRAP score, **the attached receipt archive**, the mutation statement (whether mutation testing ran, or why it was not required) |     ✅      | 🟡 coverage and CRAP figures optional when the deliverable cannot be tested, or testing it would be destructive |    –     |       –       |
| Non-Duplication      | clones found and duplicated share, **the attached duplication report**                                                    |     ✅      |                                                       ✅                                                        |    –     |       –       |
| Documentation        | the documents updated, the audience-lint findings                                                                         |     ✅      |                                                       ✅                                                        |    –     |      ✅       |
| Poka-Yoke            | each footgun introduced and the rung of its guard                                                                         |     ✅      |                                                       ✅                                                        |    –     |       –       |
| Risk Assessment      | the register items, and the mitigations marked in code against those claimed                                              |     ✅      |                                                       ✅                                                        |    –     |       –       |
| i18n                 | candidates, promoted and ignored texts (promoted + ignored = candidates)                                                  |     ✅      |                                                        –                                                        |    –     |       –       |
| Adversarial Review   | the rounds run, the open blocker and major findings (must be 0), the review note                                          |     ✅      |                                                       ✅                                                        |    ✅    |      ✅       |

Adversarial Review is in every kind's set and the agent can never waive it. As for every row, only a person can override it, and the override is recorded.

## The owner's Proof Discipline

Every story's header holds a **Proof Discipline** section, filled when the story is created or adopted, from its kind and the
values in force:

```markdown
# Proof Discipline

* [ ] **i18n**
* [x] **Test Discipline**
  * Max CRAP Score: 50
  * Min Coverage: 85%
* [x] **Documentation**
```

The section belongs to the owner of the project, and it applies to that one story. Unticking a dimension disables it, ticking one
requires it, and writing a number changes a threshold, relaxed or tightened. The Bridge alone reads it. An agent can read it and
ask for a change, and cannot change it: an edit by the agent's own account is no change, and the section is restored.

A disabled dimension needs no evidence. A threshold relaxed past the last measured result satisfies the dimension at once, with
no new run, as long as the code is still the code that was measured. Every change is shown in the row it touches, with the
original value, the new value, who decided and when, so a reader never takes it for a measured pass. A change that cannot be
verified counts as no change.

## The dimensions, one by one

Each dimension below says **what** it checks, **how** the check is made, **how its metrics are enforced**, and **why**.

### Completeness

- **What:** every behaviour the story adds has at least one *named* automated test that shows it working and one that shows it refusing what it should refuse; every acceptance criterion is shown.
- **How:** the specification's items (requirements, use cases, failure modes, acceptance criteria) are matched to the tests that name or tag them.
- **Metrics enforced:** one metric per item, naming its test. The close compares the specification with the metrics: an item with no metric is reported as uncovered and the row stays UNPROVEN.
- **Why:** a requirement nobody tested is a requirement nobody knows is met.

### Feature Availability

- **What:** every feature is reachable through its real public interface (the command, the endpoint, the tool call).
- **How:** an end-to-end test drives the public interface; a unit test against a mock does not count.
- **Metrics enforced:** one metric per requirement, naming its end-to-end test.
- **Why:** a feature that only exists behind an internal call is not delivered.

### Input Validation

- **What:** every public entry point rejects malformed input at the boundary.
- **How:** a test sends the malformed input and asserts the rejection.
- **Metrics enforced:** the rejection tests of each entry point.
- **Why:** bad input that travels inward fails later, far from its cause, and is the root of most injection flaws.

### Robustness

- **What:** boundary, rare, improbable and unexpected inputs and states are handled, not only the happy path.
- **How:** tests at the limits (empty, maximum, zero, duplicates, interruptions).
- **Metrics enforced:** one metric per failure mode of the specification, plus the boundary tests.
- **Why:** production traffic finds the corners that a happy-path test never visits.

### Resilience

- **What:** network, disk and dependency failures are handled and recovered from.
- **How:** a test injects the failure and asserts the recovery; where the mechanism is a retry, it must be configurable (attempts, back-off) and disableable for tests.
- **Metrics enforced:** the failure-injection tests and the settings they cover.
- **Why:** transient failures are normal; an unhandled one becomes an outage.

### Security Posture

- **What:** the change's attack surface (inputs and trust boundaries, secret handling, deserialisation, authentication paths, dependencies, least privilege).
- **How:** each control is cited at its file and line with the threat it handles; security code carries a `[CySec]` annotation with a formal reference.
- **Metrics enforced:** the controls, each with its reference ([CWE](https://cwe.mitre.org/), [OWASP](https://owasp.org/), [IEC 62443](https://www.isa.org/standards-and-publications/isa-standards/isa-iec-62443-series-of-standards), [CAPEC](https://capec.mitre.org/)). A row with no concrete, change-anchored finding is refused.
- **Why:** security reasoning that is not written down did not happen; the annotations also make the control inventory searchable for audits.

### Defense in Depth

- **What:** for each control, "if this were bypassed, what still stops the attack?"
- **How:** the fallback layer is named, or the absence of one is justified; redundant layers are annotated so nobody removes them as "already validated upstream".
- **Metrics enforced:** one fallback per control.
- **Why:** a single control is a single point of failure.

### Observability

- **What:** when this breaks in production, can an operator tell why?
- **How:** each failure path the change adds is cited with the signal it emits: an error with actionable context (operation, input summary, cause), never a silently swallowed exception.
- **Metrics enforced:** the failure paths and their signals.
- **Why:** an incident you cannot diagnose is an incident you cannot report or fix in time (a [NIS2](https://eur-lex.europa.eu/eli/dir/2022/2555/oj) concern).

### Thread Safety

- **What:** behaviour under parallel calls, concurrent access and shared state.
- **How:** concurrency tests; and every test file that depends on timing, threads, processes, the network or files runs several times in a row **under CPU load** before the close.
- **Metrics enforced:** the concurrency tests and the repeat-under-load count per file (for example 5/5).
- **Why:** a test that passes only on an idle machine is a defect, in the test or in the code.

### Configurability

- **What:** configuration is defaulted, loaded, validated and overridable.
- **How:** tests prove each, including that invalid configuration is refused at start-up.
- **Metrics enforced:** the configuration tests, including the refusal case.
- **Why:** a wrong setting must stop the program loudly, not make it misbehave quietly.

### Test Discipline

- **What:** the lines the story changed meet the coverage floor in a **real host run**, every method stays under the CRAP ceiling, and the tests can actually fail.
- **How:** the [`Kyklos Bridge`](COMPONENTS.md) runs the tests with coverage on the host, posts a **coverage receipt** on the story (a summary, the changed files' line-by-line coverage and the full compressed report
  set) and issues a **Test Discipline token**.
- **Metrics enforced:** changed-line coverage and the highest CRAP score from the receipt, the mutation statement, the repeat-under-load counts, and **a link to the attached receipt archive**. The
  close refuses a row that links any other archive than the one the token records.
- **The token cannot be faked:** the token is computed by the Bridge with a **signing key the agent never sees**: the key is stored in the Windows Credential Manager (see [Secrets](SECRETS.md)) and loaded only into the Bridge
  process, never into the container or the test processes. The token is bound to the exact content of the changed files and to the receipt's fingerprint, so editing a file afterwards makes it stale,
  and no token can be produced by hand.
- **Why:** "the tests pass" is the claim agents fake most often; a signed, content-bound receipt makes it checkable.

#### Where the evidence lives, and what a team shares

A coverage run leaves three things behind, in three places. Only the first is evidence other people need to read.

| What | Where | Shared? | What it is for |
|------|-------|---------|----------------|
| **Coverage receipt** | A comment on the story in the issue tracker, with the compressed report set attached; the comment records the archive's SHA-256 | Yes, by construction: everyone who can open the story sees it | The evidence itself: the figures, the changed files' line-by-line coverage and the full reports. The close downloads the archive again and checks it still matches its fingerprint. |
| **Test Discipline token** | A small file in the token folder of the working copy, by default `<solution root>/.kyklos/proof-tokens` (setting `KYKLOS_PROOF_TOKEN_DIR`) | No: it belongs to the machine whose Bridge signed it | The link between one run and one receipt: it records the receipt's fingerprint and the content of the changed files, signed with the Bridge's signing key from that machine's credential store. The close reads it through the Bridge to know which receipt is the right one, and that the files did not change since. |
| **Trunk-base cache** | The Bridge's state folder, by default `%LOCALAPPDATA%\KyklosBridge\base-coverage` (setting `KYKLOS_BRIDGE_STATE_DIR`) | No, on purpose | Not evidence and not a token: a cache of coverage runs of the trunk commit a story started from, used to compare each changed file with its coverage before the story and to tell which failing tests already failed at that commit. It is rebuilt when missing (at most 24 entries, each kept 14 days). Sharing it would let one machine's broken base run (a database or host that was down) judge every developer's stories. |

**What this means for a team today.** The receipt is shared, the token is not. A story measured on one developer's
machine closes from that machine. Closed from another machine, the close finds no token for the story and that developer
measures again, which posts a new receipt. The work is never lost, since the receipt stays on the story for everyone to
read, but the second measurement costs time.

**Could the tokens live in a shared folder, such as a companion repository?** The folder is a setting, so technically
yes, but a shared folder alone does not make tokens portable:

- A token verifies only with the key that signed it. Sharing tokens means every developer's Bridge holds the **same**
  signing key, read from a shared secrets manager instead of each machine's credential store. That keeps the guarantee
  that matters (the agent never sees the key) and adds an organisational one: everyone who holds the key can sign.
- A companion repository is a folder the agent writes to. A forged token there still fails verification without the key,
  so integrity holds, but committed tokens add commits and merge conflicts on every measurement.
- The cleaner direction is to put the signature **into the receipt comment** itself, so the issue tracker becomes the one
  shared store and no file has to travel between machines. It still needs the one team signing key described above.
  This is a design direction, not yet built.

### Non-Duplication

- **What:** the story copies no logic or constant, and removes duplication its work exposes.
- **How:** a duplication detector (for example [jscpd](https://github.com/kucherenko/jscpd)) scans the changed code; candidates are triaged by meaning, not by text, and real duplicates are centralised.
- **Metrics enforced:** the clone count and duplicated share, a **tool token** over the scanned files, and **a link to the attached duplication report**; a summary without the attachment is refused.
- **Why:** duplicated logic is fixed in one copy and stays broken in the other.

### Documentation

- **What:** every document the change affects exists, agrees with the shipped behaviour, is complete, and suits its audience.
- **How:** the documentation pass (`kyklos:update-docs`, see [Skills](HOOKS_AND_SKILLS.md#how-the-agent-knows-what-to-do-skills)) updates the documents and runs the audience lint (no internal hostnames, history or scaffolding in a public document).
- **Metrics enforced:** the documents updated and the lint findings, backed by a **tool token** bound to the files judged.
- **Why:** a document that disagrees with the code is worse than no document.

### Poka-Yoke

- **What:** every new footgun (an easy, damaging mistake) gets the highest feasible guard.
- **How:** the ladder, best first: impossible by design, refused at the boundary, a loud failure at run time, and only as a last resort a documented convention.
- **Metrics enforced:** each footgun with the rung of its guard.
- **Why:** a rule people must remember will eventually be forgotten; a design that makes the mistake impossible will not.

### Risk Assessment

- **What:** the change is measured against the story's numbered risk register, cited to the project's declared regulations.
- **How:** a new or raised risk must be added to the register; every mitigated risk must have its mitigating code marked `[RiskMitigation RA-nn]`.
- **Metrics enforced:** the register items and the mitigations marked against those claimed; the row stays UNPROVEN until the register exists and every claimed code mitigation carries its marker.
- **Why:** regulations ask for evidence that risks were identified and treated; the markers turn that into a search.

### i18n

- **What:** every user-facing text the story added or changed (labels, validation and error messages, API messages) is in the project's localisation resources, without duplicates.
- **How:** a scanner lists the candidate texts; each one is moved or excluded with a reason (log lines and agent-facing messages are excluded by rule).
- **Metrics enforced:** candidates, promoted and ignored counts, which must add up (promoted + ignored = candidates); on a development story the row can never be waved away, even when all three are 0.
- **Why:** a text left in the code cannot be translated, and a duplicated one drifts.

### Adversarial Review

- **What:** an independent reviewer tried to break the change (see [Adversarial reviews](ADVERSARIAL_REVIEW.md)).
- **How:** the review report is posted on the story; the Bridge signs a token bound to its exact content with the same host-only key, and refuses a report that does not follow the template.
- **Metrics enforced:** the rounds, the open blocker and major findings (must be 0), the review note; the close verifies the token.
- **Why:** the author is the worst judge of their own work; a tamper-proof review on record makes the second opinion real.

**What makes the table trustworthy:** the mechanical rows cannot be filled by typing. Their tokens are computed by the `Kyklos Bridge` with a key the agent cannot read, bound to the exact content
they judged, so a later change makes them stale and a forged one does not verify. Where a row needs an **attached file** (the coverage receipt archive for Test Discipline, the duplication report
for Non-Duplication), the row must link exactly that attachment.

### Example

A realistic, complete Proof Table of a small development story ("Retry Export": a failed upload is retried with growing waits):

| Quality Dimension    | Verdict          | Evidence                                                                                                                                                                                                    | Metrics                                                                                                                                                                                                                        |
|----------------------|------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Completeness         | ✅ PROVEN        | R1 by `A_failed_upload_is_retried_three_times_with_growing_waits` (positive) and `A_fourth_failure_stops_the_export_with_the_last_error` (negative); UC1, FM1 and AC1 by their named tests.                 | <kbd>R1 (named tests):</kbd> pass<br><kbd>UC1 (The_second_attempt_succeeds_and_both_attempts_are_logged):</kbd> pass<br><kbd>FM1 (Every_attempt_failing_writes_nothing_partial):</kbd> pass<br><kbd>AC1 (UC1 test):</kbd> pass |
| Feature Availability | ✅ PROVEN        | Reached through the public `export` command; the end-to-end test runs the command against a local test server that fails once.                                                                              | <kbd>R1 (The_export_command_retries_a_failed_upload):</kbd> pass                                                                                                                                                               |
| Input Validation     | ✅ PROVEN        | `RetryOptions` rejects attempts outside 0–10 and a negative wait at start-up (`RetryOptionsValidator.cs:18`).                                                                                               | <kbd>Rejection tests (RetryOptionsValidatorTests):</kbd> 4 pass                                                                                                                                                                |
| Robustness           | ✅ PROVEN        | Boundaries 0 and 10 attempts, a zero wait, a server that closes the connection in the middle of an upload.                                                                                                  | <kbd>FM1 (named test):</kbd> pass<br><kbd>Boundary tests:</kbd> 6 pass                                                                                                                                                         |
| Resilience           | ✅ PROVEN        | The retry itself is the recovery: attempts and back-off are settings; tests inject a timeout and a reset connection and assert recovery; a test setting disables waits.                                     | <kbd>Failure-injection tests:</kbd> 3 pass<br><kbd>Retry settings covered:</kbd> 2/2                                                                                                                                           |
| Security Posture     | ✅ PROVEN        | Attack surface: the upload URL and credentials. The URL is validated against the allowed scheme before the first attempt (`UploadTarget.cs:27`, `[CySec]` CWE-918); no secret is logged in a retry message. | <kbd>Controls (with reference):</kbd> 1 (CWE-918)<br><kbd>Secrets in log lines:</kbd> 0                                                                                                                                        |
| Defense in Depth     | ✅ PROVEN        | If the URL check were bypassed, the HTTP client's allow-list still refuses other hosts (`HttpSetup.cs:40`, `[CySec] Hardens`).                                                                              | <kbd>Controls with a fallback layer:</kbd> 1/1                                                                                                                                                                                 |
| Observability        | ✅ PROVEN        | Each failed attempt logs the attempt number, the wait and the cause; the final failure is surfaced with the export id.                                                                                      | <kbd>Failure paths with a signal:</kbd> 2/2                                                                                                                                                                                    |
| Thread Safety        | ⬜ NOT_PERTINENT | The retry runs inside one export; no shared state is added.                                                                                                                                                 | –                                                                                                                                                                                                                              |
| Configurability      | ✅ PROVEN        | `MaxAttempts` and `FirstWait` have defaults, are validated, and can be overridden per environment; an invalid value stops the start-up.                                                                     | <kbd>Configuration tests:</kbd> 5 pass (2 refusals)                                                                                                                                                                            |
| Test Discipline      | ✅ PROVEN        | Host run on the merged result issued the token; the receipt is attached. The timing-dependent test file ran 5 times under CPU load. Mutation: not required (no security-sensitive code changed).            | <kbd>Coverage (receipt, changed lines):</kbd> 97.6% (41/42)<br><kbd>CRAP (max, receipt):</kbd> 12.0<br><kbd>Repeat under load (UploadRetryTests):</kbd> 5/5<br><kbd>Receipt:</kbd> `coverage-receipt-dotnet.zip` (attached)    |
| Non-Duplication      | ✅ PROVEN        | jscpd over the 3 changed files: no clone; the existing back-off helper was reused instead of a new one.                                                                                                     | <kbd>Duplication (jscpd):</kbd> 0 clones, 0%<br><kbd>Report:</kbd> `jscpd-report.json` (attached)                                                                                                                              |
| Documentation        | ✅ PROVEN        | The README's export section documents the two new settings; the audience lint is clean.                                                                                                                     | <kbd>Docs updated (update-docs):</kbd> 1<br><kbd>Audience lint:</kbd> 0 findings                                                                                                                                               |
| Poka-Yoke            | ✅ PROVEN        | Footgun: a retry loop with no limit. Guard: the attempts are a validated range, so an unbounded loop cannot be configured (rung: refused at the boundary).                                                  | <kbd>Footguns introduced:</kbd> 1<br><kbd>Guard rung:</kbd> refused at the boundary                                                                                                                                            |
| Risk Assessment      | ✅ PROVEN        | RA-01 (a retry storm against the server) mitigated by the capped attempts and growing waits, marked `[RiskMitigation RA-01]` in `UploadRetry.cs:22`; RA-02 (no new public exposure) process-only.           | <kbd>Register items:</kbd> 2<br><kbd>Mitigations marked:</kbd> 1/1                                                                                                                                                             |
| i18n                 | ✅ PROVEN        | The new user-facing error message is in the resources (English and Italian); the two log lines are excluded by rule.                                                                                        | <kbd>Candidates (scanner):</kbd> 3<br><kbd>Promoted (scanner):</kbd> 1<br><kbd>Ignored (scanner):</kbd> 2                                                                                                                      |
| Adversarial Review   | ✅ PROVEN        | Round 1 found one major (the wait was not cancelled on shutdown), fixed; round 2 clean. Token verified by the Bridge.                                                                                       | <kbd>Rounds:</kbd> 2<br><kbd>Open blockers or majors:</kbd> 0<br><kbd>Review note:</kbd> round 2, clean                                                                                                                        |

**Tally: 16 PROVEN · 1 NOT_PERTINENT**
