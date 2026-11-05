# Scenario 3: A project with no CI pipeline

[← Back to the WORKFLOW](WORKFLOW.md)

> Before we explore the workflow and rules of this specific scenario, this is a memento of [the cardinal rules of the Kyklos SSDLC workflow](WORKFLOW.md):
> - Rule 1: The deliverable is on the remote, and merged
> - Rule 2: No commit of the story is left behind
> - Rule 3: The evidence describes the merged result
> - Rule 4: The review saw the finished code
> - Rule 5: A merge request merges itself, and only on the merged result



## Scenario 3 - High-level workflow

With no pipeline, an armed merge request would never merge, because no pipeline ever succeeds. So the merge request is created **unarmed**, and the agent merges it through the Bridge as soon as the
server reports it mergeable. The merged-result rule (rule 5) still applies.

The close works as in scenarios 1 and 2: the merge request must be merged (rule 1), and the Completeness row is drafted without a pipeline. What the project cannot prove is any **independent
build**: there is no run of the merged result on a clean machine, so all test evidence comes from the host run behind the Test Discipline token.  

The diagram below is also available in [Yed GRAPHML format](../assets/workflow/AI-Driven_development_013-3-no-ci-pipeline.graphml).  

<p align="center">
<img src="../assets/workflow/AI-Driven_development_013-3-no-ci-pipeline.png" alt="Closing flow: project without a CI pipeline" width="800"/>
</p>

