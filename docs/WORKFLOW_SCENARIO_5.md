# Scenario 5: Stories without testable code: documentation and analysis

[← Back to the WORKFLOW](WORKFLOW.md)

The story's kind decides which rows it must prove (see the [Proof Table](PROOF.md)):

- A **documentation** story proves Completeness, Documentation and Adversarial Review. The documents it changes are its deliverable: they are pushed and merged like code, the close checks that they
  are merged (rule 1) and that every commit naming the story is on the trunk (rule 2), and the Documentation row links each document at the deliverable's commit on the remote. A Documentation
  token is required only when source code changed too.
- An **analysis** story proves Completeness and Adversarial Review. When it changes no files, the close has no deliverable to check on the remote; the Bridge leaves Completeness open, and the agent
  fills it with evidence of where each item of the specification is answered.

Both kinds (and *ops* stories) carry **no coverage receipt**, and the review timing of rule 4 does not apply to them. T 
hey still need an adversarial review, and they must have moved past the
Design phase before they can close.  

The diagram below is also available in [Yed GRAPHML format](../assets/workflow/AI-Driven_development_013-5-no-testable-code.graphml).  

<p align="center">
<img src="../assets/workflow/AI-Driven_development_013-5-no-testable-code.png" alt="Closing flow: story without testable code" width="800"/>
</p>

