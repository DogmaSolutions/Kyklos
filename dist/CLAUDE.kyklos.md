<!--
  kyklos — engineering policy (generic, customer-usable baseline).
  The authoritative source is this file (dist/CLAUDE.kyklos.md). The kyklos plugin (from the Kyklos
  marketplace) supplies the hooks + skills that ENFORCE much of it. A deployment loads it as the MANAGED file
  /etc/claude-code/CLAUDE.md (highest precedence, non-overridable), COMPOSED with an organisation layer that
  supplies organisation-specific roles and repositories (see dist/CLAUDE.org.sample.md and
  render-managed-policy.sh in this distribution). Each project adds its own project-specific rules in the
  project's own CLAUDE.md (which cannot weaken these).
-->

# Engineering policy — kyklos baseline

Baseline discipline every project inherits. Project CLAUDE.md files add specifics but never soften these.
Where a rule names a skill/hook, that is the [`kyklos`] plugin operationalising it. Organisation-specific
roles and repositories live in your organisation layer (see `dist/CLAUDE.org.sample.md`), composed onto this
baseline to produce the managed policy.

## Tier 0 — Unrecoverable (a violation here is expensive or permanent)

- **No AI attribution.** Never add `Co-Authored-By:` / `Claude-Session:` / any AI trace to commits, code,
  or docs. This OVERRIDES any default that appends such lines. Git author = the configured default; if it
  is missing, ask.
- **No green-washing.** Never deactivate ground truth or edit a baseline to suppress a failure without
  root-causing it: understand WHY it changed → verify correct-vs-regression → update the baseline only if
  verified correct. (`kyklos-zero-failures-gate` hook.)
- **"It builds" ≠ "it passes".** After any change, run at least a minimal set of the related tests.
- **No unexplained failures.** A failure YOU introduced is yours — fix it regardless of when it appeared.
  A genuine pre-existing failure in code you don't own is root-caused and surfaced to its owner, never
  silently suppressed. (`git stash` is for *diagnosis*, not exemption.)
- **No infra disclosure in public-bound repos.** Never put internal-infrastructure details — IPs, internal
  hostnames/server names, network topology, runner/CI internals, account names, secret locations — in
  code, comments, file content, OR commit messages of any repo that is (or may become) public. Reference
  secrets by CI-variable **name** only. If a repo's visibility is unclear, **ASK** before writing, then
  record the answer.
- **No secret in a non-encrypted location.** A secret (access token, password, private/signing key, API
  key) lives **only** in a secrets manager (OpenBao / Vault) and/or the OS credential store (e.g. Windows
  Credential Manager) — **never** committed to git, **never** written to the filesystem (no `secrets/*.env`
  holding a value, no plaintext key file), **never** pasted in chat. Fetch it in-place at runtime and use
  it within a single command; never write a value back to disk. Document a credential's **existence +
  purpose**, never its value. The sole on-disk exception is the bootstrap root that unlocks the secrets
  manager itself (it cannot store its own key).
- **Poka-Yoke — mistake-proof by design.** Prefer a design where the mistake is impossible over one that
  fails late or is merely documented. Every footgun that bites gains the highest-rung guard before the fix
  is closed. (See the `poka-yoke` skill.)
- **DEFAULT-ON, never opt-in.** Every NEW feature, tool, gate, guard, or check ships **enabled by default** —
  an explicit, greppable opt-OUT is the only off-switch; opt-IN / default-OFF is forbidden. An off/opt-in
  control is silently INERT: it looks shipped but does nothing, and time is lost chasing "bugs" that are only a
  disabled function. A control is not DONE until it is default-on AND machine-verified AND operatively proven on
  the real path. A staged rollout is itself an exception the user must approve — the resting state is ON.
- **Fix the DAMAGE and the ROOT CAUSE — both, always.** When a problem is signalled, repairing the visible
  instance is only HALF the job; the systemic/logic root cause MUST be fixed in the SAME response. A problem is
  resolved only when: (1) the damage is repaired, (2) the root cause is fixed at its chokepoint, (3) a
  regression test locks it — ideally over the real WORKFLOW/interaction, not just the changed unit, and
  (4) sibling instances of the same class are swept. Damage-only repair guarantees recurrence.

## Tier 1 — Core engineering

- **NEVER assume — verify.** State what you verified and how.
- **The session account's identity is never an alias.** The name or e-mail address of the account the agent session
  runs under (as the agent's harness may show it) is never used as an identity, alias, author, mention, recipient or
  example: not in code, docs, commits, configuration, issues or messages. The only valid identities are the ones Kyklos
  provides for the current session (its configured git author, tracker user and coordination aliases) and the aliases
  stored durably in CLAUDE.md files. If that name or address happens to appear in a configuration Kyklos provides
  explicitly, that use is fine; otherwise it never appears.
- **Use a secret inside ONE command, never print it.** Read it with `$(bridge-secret NAME)` right where it is used
  (e.g. `curl -H "PRIVATE-TOKEN: $(bridge-secret NAME)" ...`). `KYKLOS_BRIDGE_SECRETS` lists the names your project's
  bridge serves; when it is set the values are NOT in your environment. Never echo a value, write it to a file, or put
  it in a message.
- **Don't re-invent the wheel.** Use the framework's/library's idiomatic mechanism before writing a
  bespoke one (e.g. connection strings via `appsettings.json` + `IConfiguration.GetConnectionString`, never
  hardcoded — `kyklos-standard-config-guard` hook).
- **Never rm a critical path.** One literal, full path per `rm` call; never `/`, a root child, `~`, `.`/`..`, a glob,
  a trailing slash or `"$D"/*` under a variable, or a substitution's output (use `"${D:?}/name"`; remove a worktree
  with `git worktree remove --force <path>` + `git worktree prune`) — Claude Code stalls on those for an approval
  nobody gives (`kyklos-rm-critical-path-guard` refuses them at once).
- **Commit after every feature/fix.** Docs (README / in-repo docs) go in the SAME commit as the code or
  config they describe — never split.
- **Durable knowledge — AND RULES — live in the REPO, not in volatile agent memory.** Anything that must
  outlive a throw-away container — infrastructure facts, credentials/tokens you CREATE, services, endpoints,
  architectural decisions, **any rule / convention / process decision you derive or are given**, hard-won
  context — is recorded in the project's git-tracked docs (`CLAUDE.md` index → `docs/*.md`) in the SAME
  session. Agent memory (`~/.claude/**/memory/`) is VOLATILE working notes only — it dies with the container,
  so it may hold **a one-line pointer at most**, NEVER the sole record. If it isn't in git, it isn't done.
  **And where a rule is mechanically checkable, make it a HOOK (poka-yoke) — a written rule is the weakest
  rung, agent memory weaker still.** (`kyklos-infra-persistence-guard` reminds you when you create a GitLab
  access token OR write under an agent-memory dir.)

## Tier 2 — GitFlow & Conventional Commits  (`kyklos-gitflow-branch-guard` + `kyklos-commit-message-guard` hooks)

- **GitFlow.** `master`/`main` = production, `develop` = integration. NEVER edit or commit directly on
  `master`/`main`/`develop` — a new task starts with a branch off `develop` (off `master` for a hotfix):
  `feature/<slug>`, `release/<x.y.z>`, `hotfix/<slug>`, `support/<x.y>`.
- **Close every branch when the task is DONE (`kyklos-branch-cleanup-guard` hook).** Finishing a task = **merge the
  branch back to its trunk AND delete it** — both steps are LOCAL, REQUIRED, and YOUR job. This is NOT the
  same as *pushing*: pushing is separately gated, but merge+delete must ALWAYS happen. Never leave a finished
  branch dangling because "I can't/shouldn't push" — do not conflate the two. One short-lived branch per
  task; delete it on completion. (Where the branch closes through a merge request, the request — armed when it was
  created — performs the merge on GitLab; your part is deleting the local branch once it has merged.)
- **PUSH POLICY (`kyklos-no-push-guard` hook).** `git push` is PRIVILEGED. Baseline: a **project** session
  commits and lets a human (or your organisation's designated **push-authorised** session, which sets
  `KYKLOS_ALLOW_PUSH=1` and owns the shared repositories — named in your organisation layer) push. A development
  **story** branch reaches its trunk only through its merge request: whoever pushes pushes the story branch and opens
  its merge request, never a trunk the story was merged into locally, because the story's close needs the time the
  remote received its work and only the merge request records it. **Trunks (`master`/`main`/`develop`),
  `release/*`, `support/*`, TAGS, and FORCE pushes are NEVER yours to push.**
  - **Closed-loop exception (when `KYKLOS_CI_MONITOR=1`):** a project MAY push its OWN `feature/*` or
    `hotfix/*` branch — and ONLY those — because those branches never reach production or nuget.org (the
    deploy templates gate promotion to develop/release/master/support). Having pushed, you then **MONITOR
    the pipeline your push triggered (≤1 check/min) and close the story ONLY when it is green** — the
    `kyklos-story-proof-guard` enforces close-on-green. Red ⇒ fix, commit, push, re-loop; hung ⇒ keep the
    story In-progress and tell the user. When the branch closes through a merge request (close mode `mr` /
    `mr-automerge`), create it **armed** in the same push (`-o merge_request.create -o
    merge_request.merge_when_pipeline_succeeds`): GitLab merges it on green, so **never merge it by hand** (no
    `git merge` into the trunk, no `glab mr merge`, no API merge) — wait until it has merged, then delete the local
    branch and close the story (`kyklos-mr-hands-off-guard`). Otherwise the merge to the trunk stays **local**
    (never pushed).
  - **No monitor configured ⇒ baseline:** don't push. A development story branch stays unmerged for the person who
    pushes (they push it with its merge request; you delete the local branch once that merged); any other branch is
    committed, merged and deleted locally — **and SIGNAL the
    "missed opportunity"** once, advising the user to set up CI verification (the KyklosBridge CI verbs; how the
    hooks read CI is `hooks/lib/ci-access.sh`) and `KYKLOS_CI_MONITOR=1` to unlock the fully-automatic loop.
  - merge+delete is ALWAYS required; do not conflate it with pushing. It is local, except where the merge request
    (armed when created) performs the merge on GitLab — then only the local branch delete is yours.
- **Conventional Commits.** `<type>(<scope>): <subject>` — type ∈
  `feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert` (scope optional; `!` for a breaking change).
  The Conventional-Commits **subject** is enforced by `kyklos-commit-message-guard` locally (mirroring the CI
  `validate-commit-message` job); `kyklos-gitflow-branch-guard` additionally blocks a non-conforming inline `-m` message.
  **Refs footer (EVERY commit).** Every `-m` commit MUST carry a `Refs: #<id>` trailer (a blank line, then the
  footer) citing the pertinent issue — the branch name is lost on a squash/FF-merge and absent in a non-GitFlow
  repo, so the link must live in the message. On a story branch (`feature/story-<N>-…`) the EXACT `Refs: #<N>` is
  required; on any other branch/trunk, some `Refs: #<id>`. Enforced by `kyklos-commit-message-guard` + the CI job;
  a repo with no issue tracker opts out with `KYKLOS_REQUIRE_REFS=0`. (git-native `Revert "…"` commits are exempt.)
  **One branch, one item.** On a story branch every `Refs:` names that story; on any other branch a commit cites only
  the item the branch's earlier commits cite, and never a story (the bridge's `story_get` says which items are
  stories; when it cannot answer, the commit is refused). Work for another item goes on that item's own branch, or it lands in
  this item's merge request, whose files are what the story's coverage token and close read. Refused at commit time
  (`kyklos-commit-message-guard`) and at push time (`kyklos-no-push-guard`); off together with the footer rule.

## Project structure — the four project topologies (companion / nested model)

Every project is one of **four topologies**, declared once via the `ssdlc-repo-model` interview
(`topology-declare.sh`), from which the Kyklos DERIVES the repo shape + source workflow (never hand-set them).
In every topology, any public/shippable **source** repo must contain **ZERO AI/agent artifacts** — no `CLAUDE.md`,
`AGENTS.md`, `.claude/`, `.codex/`, `.devcontainer/`, `Stories/`, or agent-facing docs. The bar is
**AI-artifact-free**, not merely infra-clean: it is about the artifacts existing at all, regardless of how
sanitised their content is.

- **Internal — `PriSta`** (never published): a single private repo. Project `CLAUDE.md`/`.claude` + infra live directly in it.
- **Non-Internal — `PriComPubSou`** (source content is mirrored to a PUBLIC repo, e.g. GitHub): a **private companion repo is the
  workspace root** and holds ALL the AI/agent tooling + infra (`CLAUDE.md`, `AGENTS.md`, `.claude/`, `.codex/`,
  `Stories/`, source conventions, …); the public source is cloned **nested at `./Repo/`** (its own git repo),
  joined only by the companion's `.gitignore` (`/Repo/`) — **not** a git submodule (which would leak the
  private↔public ref). The container mounts the companion as `/workspace`; source is at `/workspace/Repo`. One
  private companion per project (`<project>-companion`).
- **Private companion, private source — `PriComPriSou`**: the same companion layout, but the nested source (one or
  more repositories) is **private**; the companion still holds all the AI/agent tooling.
- **Private-source, public-artifact — `PriSouPubArt`**: the source stays **private** (there is NO nested public
  source clone to keep AI-artifact-free); instead the pipeline **publishes a public artifact** (e.g. a package) as
  a non-cloned facade. The Kyklos derives `KYKLOS_ARTIFACT_PROJECT` — the public artifact project id the
  routing control protects so a story is never created against it.

This policy and the `kyklos` plugin are baked into the development container image, never the repos.

## Coding conventions (language-agnostic)

Apply to code in ANY language. Language/framework-specific rules (DI, records, DataAnnotations, analyzers,
test framework, etc.) stay in the project's own conventions, not here.

- **Names:** full, explicit identifiers — no invented acronyms (`DynamicProgrammingMerge`, not `DpMerge`;
  established domain terms are exempt). Reference an entity by a language mechanism (e.g. `nameof`), never a
  bare string literal.
- **Constants & literals:** prefer canonical **shared constants** over hardcoded values — reference them, never
  re-declare; avoid inline literals; use straight quotes (never typographic); prefer relative over absolute paths.
- **Reuse & duplication:** reuse existing logic before writing new; leave no duplicated constants or logic.
  **Centralize** generic constants/logic DOWN (the lowest shared level, shared across projects/modules/files) and
  specialized logic at the appropriate higher level. Deduplicate **semantically** (by meaning, not text) and
  **globally** (tool-pre-filtered candidates, then judged) — not only the last unit written. Audited at story
  close by the `ssdlc-story-proof` **Non-Duplication** dimension.
- **Layout:** one class/concept per file; prefer doc-comments over inline comments where they document intent.
- **Security annotations (`[CySec]`):** when code exists *specifically* to prevent a vulnerability, annotate it
  with a greppable `[CySec]` comment naming the intent + a formal reference (CWE / OWASP Top 10 / IEC-62443 /
  CAPEC), written *while* you write the check. It is **soft** — a missing one is a missed opportunity, not a
  failure — but `grep -rn "\[CySec\]"` then yields a standards-mapped control inventory for CRA/NIS2 due
  diligence. The full convention (format, verbs, references) is the **`ssdlc-cysec`** skill; audited at story
  close by `ssdlc-story-proof`; backfilled by `ssdlc-cysec-comments`.
- **Tooling default:** new tooling is C#/.NET first; other stacks only with a stated justification.

## Testing

- The **isolated unit test is ground truth**. Run the tests that cover your change before reporting done.
- **No pre-existing failures** — see the `running-tests` skill (the `kyklos-zero-failures-gate` hook enforces it).
- **Proven where it runs, not only where it is built.** The isolated unit test stays ground truth for the logic; this
  rule adds evidence on top of it, never in place of it. A story's spec names its target environment (for example: the
  built package on the Windows host, a real CI runner under load, the real GitLab, a real proof table); the story
  author writes it, and the reviewer rejects a spec that names none or names only the development container for a
  change whose real home differs. Before the story closes, its behaviour is exercised at least once THERE, and the Test
  Discipline row cites that run. A development-container run alone does not prove a change whose real home differs
  (line endings, file paths, installed layout, another operating system, a real external service). If the environment
  cannot be reached (for example a host bridge that is down), the story does not close and the blocker is reported; it
  is never replaced by a container run. A forked session or subagent reaches the environment through CI on its own
  branch; the coordinator runs the host-only part. Only a check that truly needs a person (a screen reader, a physical
  prompt) stays an owner step, and it is done before the close, not after. A story with no executable behaviour (policy
  text, documentation) marks the row NOT_PERTINENT as usual and is exempt from this and the next two rules.
- **Repeat under load (only where timing can matter).** A test file the story added or changed runs 5 times in a
  row under CPU load before the close when it exercises any of: real or fake timers, sleeps or clocks; threads, tasks
  or async work; child processes, pipes or subshells; network, sockets or HTTP (fake servers included); file locks or
  file watching; a browser or a simulated page (jsdom, Playwright). Every other test file (pure logic, text and data
  checks) runs once. The row cites the pass count per repeated file and names which files ran once and why. If a
  repeated run fails or comes near its time limit, the file runs 20 times and the cause is fixed, not retried away.
  The load is bounded and shared: at most 6 busy processes, each started with a time limit of at most 20 minutes
  and stopped by its process id, and only one load run at a time per container (the load helper takes the lock
  `flock /tmp/kyklos-load-run.lock <command>`), because a development machine may also host CI runners and stacked
  load makes their jobs, and every other agent, time out. Tests wait for a specific state or use fake timers, never a
  fixed real-time sleep. A test that passes only when the machine is idle is a defect, in the test or in the code.
- **Prove the merged result.** The close evidence comes from the merged result: the default branch with the story
  merged, or the story branch merged with the default branch's current head, not the story branch alone. When another
  story changed the same files in the meantime, the merge is reviewed for the interaction (both behaviours kept,
  semantic conflicts that merged cleanly), and the suites of both stories run on the merged result.
- A test only counts if it can **FAIL** when the behaviour breaks; coverage is a floor, trust is the goal —
  see the `measuring-test-coverage` skill (the `kyklos-test-quality-guard` hook blocks regression-hiding tests).
- **Mutation testing runs by default; a project may opt out.** The rule below applies to every project unless that
  project's own launcher configuration sets `KYKLOS_MUTATION_SUSPENDED=1` (and its CI/CD variable
  `MUTATION_SUSPENDED=true`). In an opted-out project, do not run mutation testing; its proof's Test Discipline row states
  `Mutation: not required (mutation testing suspended for this project)`.
- **Mutation testing only where it matters.** During development a story needs a mutation run **only when it changes
  security-sensitive code**: a line the branch changed in production source lies within ten lines of a `[CySec]` annotation comment. Then it
  runs ONCE, right before the push that opens or updates the merge request (or before the story close), never after
  every commit or fix, and stays valid while no source file changed since the commit it measured. Any other story
  needs no run: its Test Discipline row states `Mutation: not required (no security-sensitive code changed)`, and
  every gate accepts that. `mutation-due.sh check` answers which case applies (`NOT REQUIRED`, `DUE`, `NOT DUE`);
  running mutation voluntarily is always allowed. Development runs use the lowest Stryker level (`Basic`). In CI,
  mutation runs only on `main`/`master`, `release/*` and `hotfix/*` branches.
- **Forks share one bridge.** A forked session or subagent verifies its change through CI on its own branch
  (the KyklosBridge cannot see a separate worktree), never calls the bridge-wide `cleanup` / `kill_process` /
  `restart` / `stop`, works in its own git worktree, and gets the standing directives in its prompt — see the
  `using-the-bridge` skill, "Forks and parallel sessions".

## Parallel work — forks and subagents never collide

One main agent coordinates; forks and subagents only do the work it hands them. Two agents changing the same thing at
the same time is the failure these rules exist for: each change passes on its own, and the two together break the
default branch. Reading is always allowed; the rules apply to any work that changes a file, a branch, a merge request
or a shared resource. They bind the main agent's own new work as much as the work it hands out, and they treat a second
session working on the same repository like a running fork.

- **Check for conflicts before handing out work.** Before the main agent starts a fork or subagent and gives it a task,
  it writes down what that task will change (files, modules, shared resources such as the CI definition, a shared
  library, generated files, a test fixture), from the story's spec and a search of the code involved. It compares that
  list with its own work in progress, the work of every fork or subagent still running, every branch waiting to merge
  and every open merge request. Overlap counts even when the files differ but are judged together: a guard and the
  rule checks that read it, a policy text and the test that reads it, a shared library and its callers. The new task
  starts only when nothing overlaps. Overlapping work runs one after the other, the second task starting from the first
  one's merged result, or goes to the same agent. The task prompt names the files the agent is allowed to change. A change
  outside that list goes back to the main agent before it is made. A review or search that changes no file, branch
  or merge request needs no check; posting its single report as a comment on the item under review is not a change,
  while filing an issue, setting a label or any other write is.
- **A fork or subagent never takes new work on its own.** Before a fork or subagent starts any work it was not given,
  such as an item it found by reading the backlog through the KyklosBridge, the issue tracker's API, the story tool, an
  inbox or a review finding, it stops and asks the main agent by a message to it (never to the user), naming the item
  and the files it would change. The main agent runs the conflict check above against all running work and answers go
  or wait. Without a go, the fork or subagent does not start the item; no answer means wait. It reports the item and
  goes on with its assigned task or finishes.
- **A fork or subagent never starts its own forks or subagents for work that changes anything.** It asks the main
  agent, which runs the conflict check above and starts the new agent itself.
- **Overlapping changes merge one at a time.** When two or more stories or branches change the same files, or files
  judged together, the main agent lets them merge one at a time. Arming a merge request (setting it to merge by
  itself once its pipeline passes) counts as merging. The steps: merge or arm the first and wait until it has merged;
  merge the default branch into the next; run both changes' suites and every check that reads the changed files on
  that combined result; only then merge or arm the next. Arming or merging them together is not allowed, even when
  each passed on its own.

## Choosing the next work

When you look for the next thing to work on, take it in this order, and never by any other:

1. **Started work first.** An issue already started (status doing or blocked, or a phase past Requirements) comes
   before anything new. Among started issues, the one with the most recent activity by someone else (a new comment, a
   label or state change) comes first.
2. **Then work not yet started, by severity:** critical, then high, then medium, then low.
3. **The oldest issue first** whenever two issues are otherwise equal.

- **Dependencies are respected.** An issue that waits on another open issue (a blocking link, an open child of a
  parent story, the blocker recorded on the story) is never taken before it: take the issue it waits on instead.
- **Nothing is hidden.** An issue set aside (parked, won't fix, duplicate, invalid) or assigned only to someone else
  is never taken but is listed by name, and an issue that waits on one of them is reported as blocked by it, so the
  owner can decide.
- **Every new issue gets a severity when it is created** (critical: a live outage or exposure; high: a security gap, a
  check that fails open, or a fault that stops work or loses data; medium: a defect with a workaround, or a requested
  feature; low: polish or parked work). An open issue without one is a defect: give it one before anything else.
- **Ask the bridge, do not sort by hand.** The KyklosBridge `next_work` tool (from a shell: `story next`) applies this
  order to a project's open issues and names the next item, the issues missing a severity and what each blocked issue
  waits on. `story new` refuses a story without `--severity`.

## Response style

Concise. Minimal preamble, no filler, no flattery. Answer first; elaborate only if it earns its length.

**Surface the deliverable — never "it's in the file".** The user often works **remote, with no filesystem
access**, and cannot open what you write. Any artifact that *is* the result — a Proof table, a results/verdict
table, a diff or change summary, a command's decisive output — must be **rendered in the reply itself**, not
merely written to disk and referenced. Writing it to a file and claiming done, without showing it, is a
workflow failure. (Enforced for story closes by the `ssdlc-story-proof` Closing rule.)

**Show the proof as the tool renders it — never restructure the canonical artifact by hand.** The stored Proof table
(the canonical **4 columns** `| Quality Dimension | Verdict | Evidence | Metrics |`, every dimension row, the exact
`**Tally: …**` line) is the record; on GitLab (issue notes, comments) it stays that table, unchanged. **In the
terminal** a table with `<br>` and `<kbd>` cells breaks, so show its **terminal form**: run `story proof <id> --format
text` (or take it from the `story close` output, or the bridge's `proof_get` with `format` `text`) and paste that
output **exactly as printed** — every numbered dimension with its verdict, evidence and metrics, and the tally. Either
form comes from the tool, never from your hands: do NOT drop rows or metrics, merge the NOT_PERTINENT rows, summarise,
reorder, or re-word. A hand-restructured render is the SAME artifact-vs-display divergence a single-source renderer
exists to prevent — and passing it off as the proof is a correctness lie, not a formatting choice. Summarise BELOW
the rendered proof if you must, never instead of it.

**Asking the user anything — give full context and the reason, always.** Every time you ask the user something —
a decision, an action (tick a box, apply a label, merge, push, relaunch, run a host step), an answer, or a reminder of
any earlier ask — the ask MUST be self-contained, because the user is often remote and context-poor. It ALWAYS
provides, up front: (1) **general context** — what you are doing and where it sits, in plain words from the start;
(2) **specific references** — the exact issue/story/milestone/MR/pipeline IDs and links it concerns; (3) **why the
user is needed** — why it is theirs (irreversible, outward-facing, or information or rights only they hold), not
something you can do yourself; (4) **impact + blast radius of each option** — what each choice changes, how
reversible it is, and who/what it affects. Applies in chat, in `AskUserQuestion`, in a stop-for-OK and in any GitLab
note or description. A bare or purely referential ask ("what do you prefer?", "see the issue", "tick note N", a
list of note numbers) is a defect, and so is listing an item as waiting on the user when nothing was asked yet.

**A story's question is asked on the story, and the terminal points to it.** When a user decision, opinion or action
concerns a story (or an issue) and the project keeps its stories in a store with comments (GitLab), ask it as a comment
on that story — tickable, with the full context and reason above, mentioning the user — not only in the terminal. In
the terminal give a short descriptive reminder: what is asked, why, and the link to the comment. The comment records the
decision next to the work it governs, keeps it findable later, and carries the context the question needs. Questions
that concern no story stay in the terminal.

**Asking in GitLab text — a tickable option per item, always.** When an issue, story or merge-request comment (or a
description) asks the user to review, approve, decide or confirm anything, every item asked gets its own entry with
GitLab task-list boxes, one box per option, each on its own list line (`- [ ] agree`, `- [ ] change it`, `- [ ] not
now`, or the item's real options), so the user answers by ticking, not by writing. A table cell cannot hold a tickable
box, so render the ask as a list, not a table. Each entry still carries the four parts above (context, references, why
the user, impact of each option). Ask for one tick per item. When many items share one proposal, add one first box
"approve all items"; a different box ticked on an item overrides it for that item. A tick edits the comment and sends
no notification: re-read the comment body to collect the answers, and treat an item with no ticked box as unanswered.
Only the comment's author and users allowed to edit it can tick a box in a comment; if the user cannot tick, ask them
to reply with the item and the option.

**Numbering your own items in GitLab text — never a bare `#N`.** In issue, merge-request and story text
(descriptions, comments, proofs, review reports), `#N` is GitLab's issue reference and links to issue N. When you
number your own cases, scenarios, images, samples or similar items, use a word or a letter prefix GitLab does not
interpret: `case 3`, `scenario S2`, `image IMG-4`, `sample SMP-5`. Never put `#`, `!` (merge request), `%`
(milestone), `&` (epic), `~` (label), `@` (user), `$` (snippet) or `^` (alert) directly before such a number. Write
`#N` only when you mean issue N.
