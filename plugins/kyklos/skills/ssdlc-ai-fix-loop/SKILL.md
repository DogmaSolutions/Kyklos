---
name: ssdlc-ai-fix-loop
description: The LOCAL half of the closed-loop AI code review — a human-approved, BOUNDED fix loop. Use after an AI review has run on a merge request and posted findings, when you want to work through those findings and fix them. Polls the findings for the current branch's MR, ranks them by severity, proposes a fix for EACH, applies ONLY on explicit human approval, re-triggers the review, and STOPS on a bound. Reuses /code-review + /security-review; it is NOT a bespoke review engine.
---

# ssdlc-ai-fix-loop — the human-approved AI-review fix loop

The closed loop is: **an `ai-review` CI job reviews a merge request → findings are posted to the MR → THIS skill,
running locally, works through them under your approval → re-review → repeat until converged.** This skill owns the
last step. It exists so the review actually improves the code, not just decorates the MR with comments.

Two hard rules define it — they are the acceptance criteria, not decoration:

- **AC3 — nothing is applied without your approval.** Every fix is PROPOSED and shown first; a code change happens
  ONLY after you say yes to that specific fix. The loop never auto-applies, never pushes on its own.
- **AC4 — the loop always terminates.** It is bounded: it stops when findings reach zero, when it hits the round
  cap, or when the finding count stops strictly decreasing (a non-converging ping-pong). It never loops forever
  and never runs up unbounded API cost.

## When to use

After you have pushed a branch, opened a merge request, and the `ai-review` job has run and posted findings (see the
`ai-review` template of the fleet CI templates). Invoke this to triage and fix those findings. If the
review has not run yet, push + open the MR first — there is nothing to fetch otherwise.

## The mechanical helper (deterministic — do NOT reimplement in prose)

`ai-fix-loop.sh` (next to this file) owns the parts that must not be left to judgement. It NEVER edits code, applies a
fix, or pushes — so it cannot break AC3.

- `ai-fix-loop.sh fetch` → the current branch's open-MR findings as ranked JSON
  (`{branch, mr_iid, count, by_severity, findings:[{severity,file,line,title,detail}]}`), most-severe first. A
  reviewer that errored (credit/rate-limit/unparseable) is surfaced as an error, NOT as "no findings".
- `ai-fix-loop.sh bound <count>` → records the round and prints `CONTINUE …` or `STOP …` (AC4). Consult it once per
  round with the CURRENT finding count; obey a `STOP`.
- `ai-fix-loop.sh reset` → clears the round history to start a fresh loop.

`fetch` reads the merge request, its pipeline and the review's findings through the Kyklos's shared CI access
(`hooks/lib/ci-access.sh`, which owns how CI is reached); when they cannot be read it says so and never reports "no
findings".

Config: the `AI_FIX_MAX_ROUNDS` environment variable (default 3; `ai-fix-loop.sh` reads only the environment).

## The protocol (follow in order, every round)

1. **Fetch.** Run `ai-fix-loop.sh fetch`. If it errors that the reviewer did not complete, stop and tell the user to
   re-run the `ai-review` job — do not proceed as if there were zero findings.
2. **Bound check.** Run `ai-fix-loop.sh bound <count>` with the fetched `count`. If it says `STOP`, report the reason
   (clean / max-rounds / not-decreasing) and END — on a non-clean stop, hand the remaining findings to the user.
3. **Triage, most-severe first.** Address `blocker` before `major` before `minor` before `nit`. For each finding,
   understand it with the SAME lenses the reviewer used — reuse **`/security-review`** for a security/taint finding
   and **`/code-review`** for a correctness one. Do NOT invent a separate review method.
4. **Propose — then STOP and ASK (AC3).** For each finding, show: the finding (severity, file:line, why), the exact
   fix you propose (a diff or a precise description), and its risk. Then WAIT for the user's explicit approval of THAT
   fix. Never edit a file before the user approves that specific change.
   - If the finding is a **false positive**, do not "fix" it — propose the `[AiReviewIgnore]` code-comment escape (see
     the `ai-review` gate) with a concrete reason, for the user to approve, so the gate stops flagging it.
   - If a real finding should be **deferred** (out of this change's scope, or too large to fix in the loop), propose
     **TRACKING** it instead: on approval, file it as a first-class story with
     `printf '<finding-json>' | story track-finding` — it becomes an `[ai-review]` story labelled
     `severity::<severity>` and `ai-review`, so the review debt is SCHEDULED in the backlog, not silently dropped.
     Re-tracking the same finding is a no-op (the story tool owns the deduplication). (This is the loop's reconcile
     step.)
5. **Apply — only what was approved.** Make exactly the approved change. Nothing the user did not approve.
6. **Mark what you addressed.** Reply to each AI-review thread you fixed with the fix reference and resolve it
   (bridge verbs `mr_reply` and `mr_thread_resolve`). Reply to a human reviewer's thread, but leave resolving it to
   them.
7. **Re-trigger.** Once the round's approved fixes are committed, run the review again: retry the `ai-review` job
   (bridge verb `ci_job_retry`) or push the branch, as your push policy allows.
8. **Repeat** from step 1 on the fresh review — until `bound` says `STOP`.

## Poka-Yoke / boundaries

- The apply is ALWAYS agent-made and human-approved; the helper deliberately has no write capability, so "the tool
  applied a fix without asking" is impossible by construction.
- The loop is bounded in the helper, not by the model remembering to stop — `bound` is the single source of the
  termination decision.
- Fix-in-place is the default; DEFERRING a real finding is allowed only by TRACKING it as a story
  (`story track-finding`), never by silently dropping it.
