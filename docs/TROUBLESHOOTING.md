# Troubleshooting: find your problem by what you see

[← Back to the README](../README.md)

This guide is organised by symptom. A message that has a section here ends with a line `Help: <address of this guide>#<section>` that leads straight to it. Otherwise, find the message you saw (the first words are enough), then read what it means, how to confirm the cause, how to fix it, and **who** applies the fix: the **agent** (the AI working in the project) or a **person** (you, on the host or in the project's settings).

Two rules apply everywhere:

- A refusal from a guard is a decision, not a fault. The message names what would allow the action. Never work around a guard by another route (a different command, a script, the web page): fix the cause.
- A message that says "cannot tell" or "cannot verify" is never a pass. Something the check needed (the Bridge, the issue tracker, the network) did not answer. Try again once it answers.

**First step for any problem: run the doctor.** The doctor checks the configuration actively (it reaches the addresses, tries the tokens, resolves the project numbers) and says what will and will not work. The agent runs it with the `health` skill (`/kyklos:health`), a person with the **Check** button of the Launcher or the **Health** tab of the Bridge. Many of the symptoms below are listed in its report with the same fix.

Contents: [Push refused](#push-refused) · [Push blocked: no recorded green full-solution build](#push-blocked-no-recorded-green-full-solution-build) · [Merge or arming blocked: branch behind its target](#merge-or-arming-blocked-branch-behind-its-target) · [Auto-merge arming blocked: coverage](#auto-merge-arming-blocked-coverage) · [Merge request create refused: unarmed](#merge-request-create-refused-unarmed) · [Local merge blocked: pipeline not green](#local-merge-blocked-pipeline-not-green) · [Story close blocked](#story-close-blocked) · [Proof draft refused](#proof-draft-refused) · [Commit blocked](#commit-blocked) · [Bridge unreachable](#bridge-unreachable) · [Broken install](#broken-install) · [The agent changed course and said nothing](#the-agent-changed-course-and-said-nothing) · [Still stuck: report it](#still-stuck-report-it)

## Push refused

**You see:** `Push refused: <kind>. Read for this push: topology ..., KYKLOS_CI_MONITOR=..., KYKLOS_ALLOW_PUSH=.... What would allow it: ...`

**Cause:** the push guard allows a project session to push only its own current `feature/*` or `hotfix/*` branch, without force, and only when `KYKLOS_CI_MONITOR=1` is set (so the agent watches the pipeline its push starts). Everything else is for the push-authorised session (`KYKLOS_ALLOW_PUSH=1`) or a person. The `<kind>` tells which case you are in:

| `<kind>` in the message | What it means | Fix | Who |
|---|---|---|---|
| it pushes the feature or hotfix branch ... | the allowance is not switched on | set `KYKLOS_CI_MONITOR=1` in the project's configuration and relaunch; if already set, push only the current branch, by name or as `HEAD`, without force | person (setting), agent (the push) |
| the command pushes the branch X, but the checked-out branch is Y | the allowance judges the checked-out branch | `git switch X`, then push from there | agent |
| it pushes a trunk (`main`, `master`, `develop`) | trunks are never pushed by a project session. In a trunk-based repository, `KYKLOS_CI_MONITOR=1` allows the project's own `main` or `master` | work on a `feature/*` branch and let its merge request reach the trunk; or set `KYKLOS_CI_MONITOR=1` for a trunk-based repository | agent / person |
| it pushes a `release/*` or `support/*` branch, or a tag | only the push-authorised session may | ask the person who owns the shared repositories to push it | person |
| it is a force push | no setting lets a project session force-push | push a new commit instead | agent |
| no branch is checked out (a detached HEAD), or not a `feature/*` or `hotfix/*` branch | the branch name does not qualify | move the work to a `feature/<slug>` branch and push that | agent |

**Confirm:** the message prints the values it read (topology, `KYKLOS_CI_MONITOR`, `KYKLOS_ALLOW_PUSH`). Compare them with the project's configuration (the doctor lists every missing push setting, with the setting's name).

**A companion project cannot push its trunk although the token has the rights:** a companion (a private repository next to the nested source) pushes its own trunk only when the session is configured for it: `KYKLOS_ALLOW_PUSH=1`, `KYKLOS_REPO_SHAPE=companion`, the push repository addresses, `KYKLOS_PUSH_TOKEN_ENV`, `KYKLOS_CI_MONITOR=1` and `FEATURE_BRANCH_CLOSE_MODE` as declared for the project. The doctor reports each one that is missing. Person: set them in the configuration, then relaunch. See [Git: branching and authorisation](GIT.md) and [Wiring a project by hand](INSTALL_AND_CONFIG.md#wiring-a-project-by-hand-without-the-launcher).

**A single exception** (only when the person decides so): a one-shot override, set by the person with the plugin's override tool in a separate command; the message prints the exact command.

## Push blocked: no recorded green full-solution build

**You see:** `Push BLOCKED — the pushed <branch> @ <sha> needs a recorded green full-solution build for N solution(s) ...`

**Cause:** the branch touches a .NET solution, and no full build of that solution is recorded for exactly the commit being pushed. A build of one project does not run the solution's code-style rules, but the pipeline's build does, so the push would fail there.

**Confirm:** the message says either "no recorded green full-solution build" (never built) or "the recorded green build is for <old sha>" (new commits since the build).

**Fix (agent):** run the recorder the message names (`record-slnx-green.sh <solution>`). It builds the whole solution and records the current commit only when the build is green. A build can take longer than a foreground call: run it in the background. With `BUILD_EXECUTION=bridge` it builds on the host through the Bridge; with `BUILD_EXECUTION=local` in the container; with neither set it cannot choose, so a **person** sets `BUILD_EXECUTION` first. If the build is red, fix the code, commit and record again (the push then passes).

## Merge or arming blocked: branch behind its target

**You see:** `Merge BLOCKED: merge request !N is X commit(s) behind <target>. Its pipeline tested the branch without them ...`, or `Merge BLOCKED: this branch does not contain the current head of <target>, and the target's new commits change files this branch also changes ...`

**Cause:** the pipeline tests the branch, not what would result after the merge. When the target moved on, the result that would land was never tested. A branch behind the target is allowed only when none of the missing commits touches a file the branch changes, nor a build-wide file (the pipeline definition, shared build properties).

**Confirm:** `git fetch origin && git log --oneline HEAD..origin/<target>` lists the commits the branch lacks.

**Fix (agent):** merge the target into the branch (`git fetch origin && git merge origin/<target>`), run the tests of the merged result, push, wait for the new pipeline, then arm again. Where the message says "shallow clone" run `git fetch --unshallow`. Where it says the target "cannot be resolved", run `git fetch origin`, or set `KYKLOS_CHANGE_BASE_REF` to the target (for example `origin/develop`). Where it says the target cannot be told apart, name it in the push: `git push -o merge_request.target=<branch> ...`.

**"cannot read" / "GitLab did not say":** the Bridge or GitLab did not answer. The guard never lets a merge through unchecked; see [Bridge unreachable](#bridge-unreachable) and retry.

## Auto-merge arming blocked: coverage

**You see:** `Auto-merge arming BLOCKED: this change touches C# (...) and neither the content ledger nor a token settles it for story N.` (also: `the Test Discipline coverage token for story N does not cover these changed C# files`, `has the right content, but ...`)

**Cause:** the change touches C# production code and there is no evidence that tests ran every changed line at the commit being armed. "Arming" a merge request means telling GitLab to merge it by itself once its pipeline is green. Evidence is either the *content ledger*, the Bridge's record of which changed lines a passing test has run (filled by its coverage runs), or a *Test Discipline token*, a signed note from a whole-suite coverage run that says the changed files are covered. A plain push without arming is still allowed.

**Confirm (agent):** call the Bridge verb `test_facts` for the story; it lists each changed line, and marks a line with GAP (a gap in coverage) where no passing test ran it, and the message's `Ledger:` part says why the ledger does not settle it.

**Fix (agent):** run `get_coverage` through the Bridge without a story and with a filter over the tests that run the changed lines (runs add up) until `test_facts` shows no GAP at this commit, then arm again. For a file with a listed gap, add or extend a test that runs it. If the message says the branch must be checked out, check it out in the Bridge's solution folder. If the token is "not signed by this host's key", measure again on the host. A one-shot override exists only for the case no token can settle (the person decides).

## Merge request create refused: unarmed

**You see:** `Merge request create REFUSED: a story merge request must be armed to merge itself in the same push that creates it ...`, or `Hand merge REFUSED ...`

**Cause:** a story's merge request merges itself on a green pipeline (armed) and is never merged by hand. A request created without arming sits idle after a green pipeline; a hand merge skips the check.

**Fix (agent):** push the one story branch with the options the message prints (`git push -o merge_request.create -o merge_request.merge_when_pipeline_succeeds ... origin <branch>`), written out in full (no variables, no `--all`). Then only watch the pipeline; when GitLab has merged it, delete the local branch and close the story. If the repository has no readable `origin`, a person adds the remote.

## Local merge blocked: pipeline not green

**You see:** `Merge BLOCKED. Branch X is being merged into trunk Y but its latest pipeline is ..., not success.` or `Merge BLOCKED — cannot verify branch X is green: ...` or `Local merge REFUSED: branch X closes through merge request !N ... open but NOT armed.`

**Cause:** a merge into a trunk needs a green pipeline first. When the project closes branches through merge requests, the merge happens on GitLab, not locally.

**Fix (agent):** wait for or repair the pipeline; for the "not armed" case arm the request (push again with the arm option, or the Bridge's `mr_auto_merge` verb). Then, once merged, pull the trunk and delete the local branch. A person decides any one-shot override.

## Story close blocked

**You see:** `BLOCKED (story-close-guard): you are closing issue #N (project P) as done, but it is NOT a conforming, proven SSDLC story (...)`

**Cause:** closing a development story needs its required sections and a Proof table with no UNPROVEN row. The parentheses name what is missing: `missing required SSDLC section(s): ...`, `the Proof note has an UNPROVEN Quality Dimension`, or `no canonical Proof note`.

**Confirm (agent):** `story structure <id>` lists the missing sections; `story proof <id> --format text` shows every row and its verdict.

**Fix (agent):** add the missing sections, fill every row (see [the Proof Table](PROOF.md)), and close with `story close <id>`, not by closing the issue directly. If the work is not development at all, close it through the tool with its reason (`story set <id> status=wontfix|duplicate|invalid`).

Other close refusals name their own cause: a commit citing the story that is not yet on the trunk (merge it first), a deliverable not on the remote (push it), or `cannot verify the close` (the Bridge or tracker did not answer: retry; `BLOCKED (story-close-guard): ... JSON reader ... did not load` is a [broken install](#broken-install)). A gap in a measured row (coverage below the floor) is settled by tests; an override is the owner's decision.

## Proof draft refused

**You see:** `proof_draft refused: this bridge has no evidence reader, so no row can be drafted. Nothing was changed.`, or `proof_draft refused: the evidence of story N could not be read: ... Run proof_draft on a bridge that serves project P as its own project, keeps its tokens and can read its tracker. Nothing was changed.`

**Cause:** the Bridge serving this session cannot read the evidence (coverage, reports, review notes) a draft is built from; usually an older Bridge, a project it does not serve (or does not keep the tokens of), or an issue tracker that did not answer. A draft built from unreadable evidence would hold only open rows, so it is refused and nothing is stored.

**Confirm:** `get_status` shows the Bridge version; the doctor's report shows which projects the Bridge serves.

**Fix:** a **person** relaunches the project so the current Bridge starts (the Launcher updates it). Until then the agent fills the rows with `proof_set`, citing real evidence. A drafted row is never edited by hand: when its evidence changes, run `proof_draft` again.

## Commit blocked

| You see | Cause | Fix (agent) |
|---|---|---|
| `commit subject is not Conventional Commits` | the subject must be `<type>(<scope>): <subject>`; the scope is one token | rewrite the subject, for example `fix(parser): handle empty input` |
| `commit ... is missing its 'Refs: #N' footer` / `missing a 'Refs: #<id>' footer` | every commit cites its item after a blank line | add `Refs: #<id>` as the last paragraph |
| `no AI attribution` | the message or author names an AI | remove the line; the author stays the configured git identity (no override exists) |
| `the story this work's branch names is NOT a ready story` | work started before the story was adopted and written | adopt and author it first (`story adopt <id> ...`) |
| `BLOCKED (story-before-coding): a KyklosBridge build/run_tests without a ready in-progress story` | a build or test run through the Bridge before any story is adopted and in progress | adopt and author the story first; for a deliberate build that belongs to no story, the message prints the one-shot override (the person decides) |

## Bridge unreachable

**You see:** `the bridge did not answer within N seconds`, `the bridge is not configured for this session`, `the bridge that answered is not this session's bridge`, `the bridge could not be asked`, `this bridge does not know the doctor verb (an older bridge)`, or a guard saying `retry once the bridge answers`.

**Cause:** the Bridge (on the host) is stopped, still starting, or on another port; the session lost its connection; or the Bridge is older than the plugin.

**Confirm (agent):** call `get_status`. In Claude Code `/mcp` shows whether the Bridge server is connected. **Person:** the Launcher's Check and the Bridge page show whether it runs.

**Fix:** **agent:** reconnect through `/mcp` (Reconnect), then retry. **Person:** restart the project from the Launcher (it starts the Bridge); after a restart of the Bridge, the session must reconnect through `/mcp`. An older Bridge is updated by the same relaunch. A guard that cannot reach the Bridge refuses rather than guessing, so nothing is lost by waiting.

## Broken install

**You see:** `BLOCKED (<hook name>): the JSON reader hooks/lib/json-answer.sh did not load (broken install) ...`

**Cause:** the plugin's files are incomplete (an interrupted update). **Fix (person):** reinstall or update the plugin (`claude plugin install kyklos@dogmasolutions`) or relaunch the project so the Launcher pins the current version.

## The agent changed course and said nothing

**You see:** the agent skipped the stories, did not follow the workflow, or did not tell you about a failed check.

**Cause:** usually the settings the session needs did not reach it, or the doctor's findings were not shown. **Check (person):** run the Launcher's **Check**; a setting that is set but would not reach the session, or a missing story store, is a finding. **Fix:** correct the configuration, relaunch, and ask the agent to run the `health` skill and report every finding before doing anything else.

## Still stuck: report it

If no section above solves it, the agent loads the skill *Kyklos reference and troubleshooting*, which drafts a report for you to review and submit on the [Kyklos GitHub repository](https://github.com/DogmaSolutions/Kyklos/issues). The agent never submits it. The draft holds the Kyklos versions, the doctor report with secrets removed, the exact messages and the steps already tried; it leaves out your project's names, addresses and source code.
