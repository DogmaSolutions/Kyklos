# The complete Kyklos (Agile SSDLC-based) workflow

[← Back to the README](../README.md)

From an idea to a merged, proven change, every step below is either done by a tool or checked by one.

> **[✨ Start]** → (1) Requirements & (2) Design → (3) Implementation → (4) Testing → (5) Deployment & (6) Review → **[🎉 Close]**


**Kyklos behaviour and underlying rules change to fit the needs of the story kind, the project topolology, and many other parameters**.

While the phases *(1) Requirements*, *(2) Design* and *(3) Implementation* are almost identical for all scenarios, the phases *(4) Testing*, *(5) Deployment* and *(6) Review* are handled differently to
guarantee the maximum level of trust in the final result for that specific scenario.

> In the charts below, you will realize how in *Kyklos* the workflow is more focused on the **Quality Assurance** area.  
> The *(4) Testing*, *(5) Deployment* and *(6) Review* phases are more decision-driven and contain many more steps than *(1) Requirements*, *(2) Design* and *(3) Implementation*.  
> **This is by design, and it's exactly what an Agile SSDLC workflow entails.**

## Glossary

Before we start, let's clarify some terms used in the diagrams below:

- [**Code coverage**](https://en.wikipedia.org/wiki/Code_coverage) counts which lines the tests executed. Kyklos judges the lines the story itself changed, measured on the real host, and also refuses
  a change that lowers the coverage of a file it
  touches. Coverage is treated as a floor; whether the tests can actually fail is checked separately.
- [**CRAP score**](https://testing.googleblog.com/2011/02/this-code-is-crap.html) (Change Risk Anti-Patterns) combines a method's complexity with how well it is tested:
  `CRAP = complexity² × (1 − coverage)³ + complexity`, with coverage expressed as a fraction between 0 and 1. A simple, well-tested method scores low; a
  complex, untested one scores very high. Any method above the project's ceiling (for example 35) fails the gate, so complex code has to be either simplified or tested.
- [**Mutation testing**](https://en.wikipedia.org/wiki/Mutation_testing) deliberately introduces small faults into the code (flip a comparison, drop a line) and checks that at least one test fails for
  each. It measures whether the tests really check
  behaviour, not just run it. Because it is expensive, Kyklos requires it only for changes to security-sensitive code (code annotated as a security control), once per story before the merge; a
  project's policy can suspend it.
- **Risk assessment**: each story keeps a numbered risk register (see [Storages](STORAGES.md)), judged against the regulations the project declared (for
  example [IEC 62443-4-1](https://www.isa.org/standards-and-publications/isa-standards/isa-iec-62443-series-of-standards) secure development
  practice, [NIS2](https://eur-lex.europa.eu/eli/dir/2022/2555/oj) risk management, the
  [EU Cyber Resilience Act](https://eur-lex.europa.eu/eli/reg/2024/2847/oj)). Each mitigating piece of code carries a marker naming its risk item, and security controls are annotated with a formal
  reference ([CWE](https://cwe.mitre.org/), [OWASP Top 10](https://owasp.org/www-project-top-ten/), IEC 62443, [CAPEC](https://capec.mitre.org/)), so
  the control inventory can be listed with a single search.
- **Commits and merge requests**: all the work of a story happens on its own `feature/story-<id>-<slug>` branch, in commits that follow [Conventional Commits](https://www.conventionalcommits.org/) and
  name the story. The trunk is never
  edited directly: the branch is pushed with a merge request that is created already *armed* (set to merge automatically as soon as the pipeline is green), and CI merges it into the trunk only when the pipeline is green. Arming is refused unless the branch
  already contains the trunk's current head (or the trunk's new commits touch none of the branch's files), so what the pipeline tested is what lands. A repository with no pipeline merges the
  request through the Bridge once it is mergeable; a project where the agent may not push has a person push it (see the diagrams below).
- **Documentation generation**: before the review, a documentation pass finds every document the change affects (README, user manual, API and configuration references) and brings it up to date; a
  lint then checks that each document suits its audience, so a public document never carries internal details.
- **Adversarial review**: a fresh reviewer, preferably on a different model, tries to break the change. Findings send the work back to development; the loop runs at most **3 rounds** (see [Adversarial
  reviews](ADVERSARIAL_REVIEW.md)). For code that coverage measures, the review on record must be newer than the last change of that code the remote received, so it runs on the pushed change.
- **Proof generation**: at the end, the [Bridge](COMPONENTS.md) assembles the story's [*Proof Table*](PROOF.md) from the evidence it holds (receipts, tool tokens, the review token, the pipeline) and
  leaves only the judgement
  rows to the agent; the close verifies every token before the story can be closed. The proof is drafted from the **remote, merged** state: the deliverable must be merged into the trunk on the
  remote, every commit naming the story must be on the trunk, and the tokens are judged on the merged result (see the diagrams below).
- **Legal frameworks**: the risk assessment and the security annotations are judged against the frameworks the project declares. Kyklos supports [**IEC
  62443-4-1**](https://www.isa.org/standards-and-publications/isa-standards/isa-iec-62443-series-of-standards) (secure product development
  lifecycle), the [**NIS2 Directive**](https://eur-lex.europa.eu/eli/dir/2022/2555/oj) (cybersecurity risk management and incident handling) and the [**EU Cyber Resilience
  Act**](https://eur-lex.europa.eu/eli/reg/2024/2847/oj) (security requirements for products with digital elements), with controls
  referenced to [**CWE**](https://cwe.mitre.org/), [**OWASP Top 10**](https://owasp.org/www-project-top-ten/), **IEC 62443** and [**CAPEC**](https://capec.mitre.org/).

# Agile story SSDLC workflow

A story is not done when its code works on the agent's machine, and not even when its branch is pushed.  
In *Kyklos* a story closes only when its change is **merged into the trunk on the remote** (the shared Git server, for example [GitLab](https://about.gitlab.com/)), and the evidence for the close is
taken from that merged state.  
This page explains the rules the close applies, which rows of the [Proof Table](PROOF.md) depend on them, and how the flow works in each kind of project.

## The rules the workflow applies

The workflow is enforced by hooks, skills and driven through the [`Kyklos Bridge`](COMPONENTS.md), which **checks every rule below mechanically**. A fact the Bridge cannot read (the remote does not answer, a history cannot be read)
refuses the close: it is never read as "fine". The only way past rules 1 to 4 (below) is an *override label* that a **person** applies on the story, and that override is recorded; the conditions
listed under *Other close conditions* cannot be overridden at all.

### 1. The deliverable is on the remote, and merged

The workflow names the story's **deliverable**: the merge request, the commit or the branch that carries the change. It may live in the story's own project or in another one (written
`group/project!<number>` for a merge request, `group/project@<commit>` for a commit). Every item named must be **merged into a trunk on the remote**:

- a commit that exists only in a local checkout is refused ("push it");
- a branch or commit that is pushed but whose merge request has not merged yet is refused ("wait until it merges");
- a merge request that is still open is refused, and when it is stuck the refusal says why.

Being pushed is not enough: a story closed while its merge request was still open would record "done" for work that never shipped.

### 2. No commit of the story is left behind

Every commit whose message names the story in its `Refs:` line must be reachable from the trunk: `develop` or `main` in a [GitFlow](https://nvie.com/posts/a-successful-git-branching-model/)
repository (a hotfix lands on `main` first), `main` in a [trunk-based](https://trunkbaseddevelopment.com/) one. The check fetches from the remote first, then looks at every local branch, every remote
branch and every worktree, and in a companion topology (see [Project topologies](TOPOLOGIES.md)) it checks the nested source repository too.  
A change that reached the trunk through a rebase, a cherry-pick or a squash merge counts as reached. A commit that was abandoned on purpose is settled by deleting its branch.

This catches the fix that was committed, named after the story, and then forgotten on a branch nobody merged.

### 3. The evidence describes the merged result

What the close certifies is the **trunk with the story merged**, not the story branch on its own:

- **Test Discipline** is judged where the story landed on the trunk. A coverage token measured on the story branch still holds after the merge, as long as no conflict resolution and no later
  commit (another story's merge included) changed a line it measured; otherwise the coverage must be measured again on the trunk.
- **The tool tokens** (Test Discipline, Non-Duplication, Documentation) are judged over the files the cited deliverable changes, as the remote reports them, and are checked against the host's copy
  of the project at the moment of the close. That copy must hold the story's files as merged (for example, the trunk after the merge): a copy on another commit makes the tokens stale, and the
  close waits until it is put back.
- When another story changed the same files in the meantime, the merge is reviewed for the interaction (both behaviours kept, no conflict hidden by a clean textual merge) and the test suites of
  both stories run on the combined result.

### 4. The review saw the finished code

For a development story whose change touches code that the coverage run measures, the [adversarial review](ADVERSARIAL_REVIEW.md) on record must be **newer than the moment the remote received the
last change to that code**. That moment is taken from the merge request that carried the commit, a time the server records and the author cannot set.

Two consequences:

- a fix pushed after the review needs a new review before the close;
- such code must reach the trunk **through a merge request**: a code commit that arrived on the trunk without one has no recorded arrival time, and the close refuses it.

### 5. A merge request merges itself, and only on the merged result

Where the repository has a pipeline, the agent never merges by hand:

- the merge request is created **armed** ("merge when the pipeline succeeds"), and the server merges it once the pipeline is green; a hand merge of an armed, merged or closed request is refused;
- arming is refused unless the branch already contains the trunk's current head, or the trunk's new commits touch none of the branch's files and no build-wide file (the CI definition, build and
  package configuration, project and solution files, tool versions) changed on either side. A merge request pipeline tests the branch, not the branch merged into today's trunk, so this rule makes
  sure that what the pipeline tested is what lands;
- arming is also refused when the change touches production C# code that no fresh Test Discipline token covers. When arming is refused for one of these reasons, the merge request is created
  unarmed, and the agent arms it once the reason is fixed.

### Other story close conditions

The story close also refuses a story that never left the Requirements or Design phase, a reopened story with no note explaining why the earlier proof passed, and a fix story that does not record the
rule it violated and where else the same mistake was looked for.

## Which Proof Table rows depend on the remote

The Bridge drafts part of the [Proof Table](PROOF.md) itself, from the evidence it holds (`proof_draft`). Four of the drafted rows read the cited deliverable **on the remote**, so they cannot be
proven while the change exists only on the agent's machine:

| Row                 | What it needs from the remote                                                                                                                                               |
|---------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Completeness**    | the cited deliverable is on the remote; when it has a pipeline, that pipeline is green; the tests (or the review) name every item of the specification                      |
| **Test Discipline** | the files the deliverable changes, read from the remote; the Test Discipline token and the attached coverage receipt over those files; judged at the merged result (rule 3) |
| **Non-Duplication** | the Non-Duplication token over the files the deliverable changes, and the attached duplication report                                                                       |
| **Documentation**   | the changed documents, linked at the deliverable's commit on the remote; the Documentation token when source code changed too                                               |

The **Adversarial Review** row depends on the remote too, through rule 4. The other rows are judgements the agent writes with its evidence; the close still applies rules 1 to 5 to the whole story.

A row the Bridge cannot prove stays open, with the reason: for example *"no cited deliverable is on the remote"*. So an agent that says "these rows can only be proven once the code is on the
remote" is right.

---  


# The scenarios

How the flow works depends on two things the project declares: whether the agent may **push**, and whether the repository has a **CI pipeline**. The topology adds a third (see [Project
topologies](TOPOLOGIES.md)).

The agent may push only its own `feature/` and `hotfix/` branches (and, in a trunk-based repository such as a companion, that repository's own trunk), and only where the project lets it watch its
own pipelines through the Bridge. Trunks, release and support branches, tags and force pushes are never pushed by the agent. See [Git](GIT.md).

| Scenario                                    | Where the work happens                                                | Who pushes                                                        | What merges it                                                                           | When the story closes                                                                   | Rows that need the remote, merged state                                           | What the project cannot prove                                                                       |
|---------------------------------------------|-----------------------------------------------------------------------|-------------------------------------------------------------------|------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------|
| [**1. CI, the agent pushes**](WORKFLOW_SCENARIO_1.md)                 | the story branch; builds, tests and coverage on the host              | the agent, its own story branch                                   | the server, through the armed merge request, on a green pipeline                         | after the merge request merged; the agent watches the pipeline and closes only on green | Completeness, Test Discipline, Non-Duplication, Documentation, Adversarial Review | nothing is missing by design                                                                        |
| [**2. CI, a person pushes**](WORKFLOW_SCENARIO_2.md)                  | the story branch, committed locally; tests and coverage on the host   | a person                                                          | the server, through the armed merge request, on a green pipeline                         | only after the person's push and the merge; until then the story waits on the person    | the same                                                                          | nothing about the change can be proven before the push                                              |
| [**3. No CI pipeline**](WORKFLOW_SCENARIO_3.md)                       | the story branch; tests and coverage on the host                      | as in 1 or 2                                                      | the agent, through the Bridge, as soon as the server reports the merge request mergeable | after the merge                                                                         | the same, without pipeline evidence                                               | that the merged result builds and passes on a clean machine: the only test evidence is the host run |
| [**4. Companion, source pushed by a person**](WORKFLOW_SCENARIO_4.md) | backlog in the companion; code on a story branch in the nested source | the agent pushes the companion; a person pushes the nested source | the source repository's armed merge request, on its green pipeline                       | only after the source change is merged on the source's remote                           | the same, all read from the source repository                                     | nothing about the source change can be proven before the person's push                              |
| [**5. No testable code**](WORKFLOW_SCENARIO_5.md)                     | documents, or an analysis recorded on the story                       | as in 1 or 2, when there are documents to push                    | as in 1 to 4                                                                             | after the documents are merged; an analysis with no files closes on its own evidence    | Completeness and Documentation, when documents changed                            | no coverage or duplication evidence exists, so those rows are not part of these kinds               |

