# Scenario 1: A project with CI, where the agent pushes (the closed loop)

[← Back to the WORKFLOW](WORKFLOW.md)  

This is the ideal scenario; and complete and autonomous CI-driven workflow:

1. The agent commits on `feature/story-<id>-<slug>`, builds and tests on the host through the Bridge, and collects the Test Discipline token and coverage receipt, the duplication report and the
   documentation pass.
2. It pushes its own branch and creates the merge request in the same push, **armed**. If arming is refused (rule 5), the request is created unarmed and armed once the reason is fixed.
3. The adversarial review runs on the pushed change (rule 4). A finding sends the work back; the fix is pushed and reviewed again.
4. The agent watches the pipeline. Red: it fixes, commits, pushes and loops. Hung: the story stays open and the agent tells the people involved, instead of waiting in silence.
5. Green: the server merges the request. The agent deletes its local branch, has the Bridge draft the proof from the merged state, fills the judgement rows, and closes.  

The diagram below is also available in [Yed GRAPHML format](../assets/workflow/AI-Driven_development_013-1-ci-agent-push.graphml).  

<p align="center">
<img src="../assets/workflow/AI-Driven_development_013-1-ci-agent-push.png" alt="Closing flow: project with CI, the agent pushes" width="800"/>
</p>