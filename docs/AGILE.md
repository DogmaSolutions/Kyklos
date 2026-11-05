# Stories, Epics, and how the agent works with them

[← Back to the README](../README.md)

Like the traditional *Agile SDLC* workflow, the *Agile SSDLC* is based on **"stories"** and **"epics"**.
Many *stories* are contained inside an *epic*.
A Kyklos unit of work is a *story*, an issue in the tracker (see [Storages](STORAGES.md)) with:

- a short, memorable name
- a kind (`development`, `ops`, `analysis` or `documentation`)
- a severity (`critical`, `high`, `medium` or `low`)
- a specification composed of:
    - Requirements
    - Use cases
    - Failure modes
    - Acceptance criteria
- a risk register

The agent works through it in **phases** that it cannot skip (see the [complete workflow](WORKFLOW.md)):

```
Requirements → Design → Implementation → Testing → Deployment → Review → Close
```

## General criteria

- **Choosing work.** The agent does not pick what it likes. Started work comes first, then new work by severity, oldest first; blocked work is listed with what it waits on. The [`Kyklos Bridge`](COMPONENTS.md)
  computes this order (see [How the process is enforced](HOOKS_AND_SKILLS.md#forced-productivity)).
- **Branching.** Every task starts on its own branch ([GitFlow](https://nvie.com/posts/a-successful-git-branching-model/)); trunks are never edited directly. Commits follow [Conventional Commits](https://www.conventionalcommits.org/) and carry a reference to their story (see [Git](GIT.md)).
- **Building and testing.** Builds, tests and coverage run on the real host through the `Kyklos Bridge`, not in the agent's imagination. A failure the agent introduced is the agent's to fix; a failure
  that existed before is traced to its cause and reported, never suppressed.
- **Reviewing.** Before a change merges, a fresh reviewer, ideally another model, attacks it: blast radius, real external behaviour, behaviour under load, and at least one new test meant to break it.
  The review is posted to the story with a content-bound token, so it cannot be faked or reused (see [Adversarial reviews](ADVERSARIAL_REVIEW.md)).
- **Merging.** A change merges only on a green pipeline over the merged result (see [CI](CI.md)). When two stories touch the same files, they merge one after the other, and both test suites run on the combined result.
- **Closing.** The story closes only when its [Proof Table](PROOF.md) is complete and every gate agrees, and only once its change is **merged into the trunk on the remote**: the close certifies
  the merged result, never a local or merely pushed branch (see [The Kyklos Workflow](WORKFLOW.md)).
- **Grouping.** Stories are aggregated into **Epics**: an epic is a theme with a goal and, optionally, start and due dates; progress is read per epic, and an epic closes only when all its stories are
  closed. On [GitLab](https://about.gitlab.com/) every story must belong to an epic; with the file storage, leaving a story ungrouped must be an explicit choice, never an accident.

For more details, see the [complete workflow](WORKFLOW.md).
