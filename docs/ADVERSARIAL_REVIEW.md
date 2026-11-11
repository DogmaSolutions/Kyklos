# Adversarial reviews

[← Back to the README](../README.md)

Before a story closes, a **fresh reviewer** attacks the change: a new agent, preferably running on **a different model** than the one that wrote the code, given the specification and the system, not
the author's notes. It looks for correctness errors, mismatches with the requirements, conflicts with neighbouring features, tests that cannot fail, duplication, bad practices, documentation drift,
performance defects and security holes. It also looks beyond the changed lines: every caller of what changed, other stories that touched the same files, the real behaviour of external systems (not
what a fake assumes), and behaviour under load. It writes at least one new test meant to break the change.

**Where it sits:** in phases *(5) Deployment* and *(6) Review* of the [workflow diagram](WORKFLOW.md): after the tests, the coverage receipt, the documentation pass and the risk assessment. A review that is not a *clean bill* sends the work back to development (the red path in the diagram). The review is posted on the story with its token,
and the close verifies that token (see the [Proof Table](PROOF.md)): a story cannot close on a review that never ran, or on a report edited after it was signed.

**It must see the finished code:** for a development story whose change touches code that coverage measures, the review on record must be **newer than the moment the remote received the last
change to that code** (the time the merge request carrying it received it, recorded by the server). In practice the review runs on the change once it is pushed with its merge request, and a fix
pushed after the review needs a new review before the close (see [The Kyklos Workflow](WORKFLOW.md)). Documentation, analysis and ops stories are not held to this timing, but still need their review.

**Loops:** each finding is classified *blocker*, *major*, *minor* or *hygiene*. Blockers and majors must be fixed, and the fix is reviewed again. The loop ends when a review finds nothing relevant to
fix, or after **3 rounds**; whatever is left is listed for the people to decide, never silently dropped. If blockers or majors remain after the last round, the story cannot close on its own: a person can allow more review rounds, or accept the residual risks and let the workflow continue, and that decision is recorded. Each round is posted on the story as its own numbered note.

A realistic review report (the format the [Bridge](COMPONENTS.md) accepts and signs):

```markdown
### Summary

2 findings (0 blocker, 1 major, 1 minor), 1 hygiene items, 2 new adversarial tests. The retry is
correct for the documented failures, but a shutdown during a wait leaves the export running for up
to 4 seconds. Verdict: findings

### Findings

- **F1** · major · `src/Export/UploadRetry.cs:31` — the wait between attempts ignores the
  cancellation token, so stopping the service during a wait does not stop the export. Fix: pass the
  token to the delay and treat cancellation as a final, non-retried outcome.
- **F2** · minor · `src/Export/RetryOptions.cs:12` — `MaxAttempts = 0` is accepted but means "never
  upload"; the documentation says it means "no retry". Fix: define 0 as one attempt, or reject it.

### Hygiene

- **H1** · `tests/Export/UploadRetryTests.cs:88` — the test sleeps 2 s; a fake clock would make it
  fast and deterministic.

### New adversarial tests

- **T1** · expected to FAIL · `A_shutdown_during_a_wait_ends_the_export_at_once` — locks F1.
- **T2** · expected to PASS · `A_server_error_after_the_last_attempt_is_reported_once`.
```

*Expected to FAIL* means the test reproduces a finding: it fails until the fix is made, and then keeps the fix from regressing (T1 above). *Expected to PASS* means it checks behaviour that must already work.

## Related pages

[The Proof Table](PROOF.md), [The Kyklos workflow](WORKFLOW.md), [Hooks and skills](HOOKS_AND_SKILLS.md), and [the README](../README.md) for the full list.
