# How the agent uses CI

[← Back to the README](../README.md)

The agent does not watch CI dashboards. It talks to CI through the [`Kyklos Bridge`](COMPONENTS.md):

- it reads pipelines, jobs, logs and test reports, and retries a job only for a known transient cause;
- it creates merge requests (see [Git](GIT.md)) and **arms** them (that is, marks them to merge automatically as soon as the pipeline is green); a red pipeline sends the work back, and a hung one is reported rather than waited on in silence;
- where the project lets it push, it pushes its own story branch and **watches the pipeline that push started**, closing the story only after the merge request has merged on green (the *closed
  loop*); where it may not push, a person pushes, and the story waits for that push;
- in a repository **without a pipeline**, the merge request is created unarmed and merged through the Bridge once it is mergeable; the story then carries no pipeline evidence, only the host
  test runs;
- when the agent's change would lower coverage or raise complexity beyond the project's ceilings, the pipeline refuses it, using the same rules the agent's local proof already applied (see the [Proof Table](PROOF.md));
- a CI capability that would affect every project is proven first in a dedicated test project, never directly on a real one.

How the push, the pipeline and the merge decide when a story can close, in each kind of project, is described in [The Kyklos Workflow](WORKFLOW.md).

## Related pages

[Git: branching and authorisation](GIT.md), [Secrets](SECRETS.md), [The Kyklos workflow](WORKFLOW.md), [The three components](COMPONENTS.md), and [the README](../README.md) for the full list.
