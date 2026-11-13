---
name: ssdlc-adversarial-review
description: Run a MANDATORY, unfakeable adversarial self-review of the current story's work before its Proof Table is built and before it closes. Use before closing ANY story (the `ssdlc-story-proof` "Adversarial Review" dimension requires it), or whenever asked to adversarially review the work-so-far. Runs the review over the story diff, posts the findings as a GitLab comment, and mints a content-bound token that the close gate verifies — a review cannot be faked. If it finds anything, it drives a phase-enforced review+fix loop (bounded).
---

# ssdlc-adversarial-review — the mandatory pre-close self-review

The **doer** for the [`ssdlc-story-proof`] **Adversarial Review** dimension (which is only the *auditor*). Before a
story's Proof Table is built and before it may close, you MUST step back and adversarially review your own work — and
that review must be **unfakeable** (a token proves it ran) and **phase-enforced** (findings force a fix loop, no
skipping to close). The row is DEFAULT-ON and can NEVER be NOT_PERTINENT.

## The review — take a step back and try to break your own work

> Before we proceed further, take a step back, and make a full adversarial review of what we have done so far in this
> story. Focus on finding:
>
> - **Correctness issues** — logic errors, wrong results on real inputs, off-by-one, mishandled nulls/empties.
> - **Feature misalignments** — the implementation does not match what the story's requirements/AC actually asked for.
> - **Incongruences or conflicts with adjacent features** — a change that contradicts or breaks a sibling capability.
> - **Testing holes** — behaviour that no test can FAIL on; uncovered branches; a test that passes even when broken.
> - **Code duplications that should be refactored** — the same logic/constant re-implemented (semantic, not textual).
> - **Bad practices and bad smells** — fragile constructs, hidden coupling, magic values, silent failure paths.
> - **Missed opportunities in the application of good practices** — where a cleaner idiom / poka-yoke was available.
> - **Documentation misalignments** — docs/README/comments that no longer match the behaviour.
> - **Performance defects** — needless O(n²), repeated work, unbounded growth, per-item subprocess spawns.
> - **Obvious security vulnerabilities** — injection, missing validation, secret exposure, fail-open auth.

Start from the **story's actual diff** (what THIS story changed), then follow it into the system around it. Be
genuinely adversarial: for each changed unit ask "how do I break this?", not "does it look right?". Defects that
escape a review are usually outside the lines it read, so the review also covers:

- **Blast radius** — every caller and user of each changed function, endpoint, file format, setting or message, and
  every other story that changed the same files since this branch started (what would the combination break?).
- **Real external behaviour** — each assumption about a system the code talks to (GitLab, the operating system,
  Windows line endings and paths, a browser engine, a build tool, a runner under load) is checked against that
  system's real, captured behaviour, never against what the code's own fake assumes.
- **Conditions** — the target environment the spec names, a busy machine, stale or concurrent data, a restart in the
  middle.

**Who reviews.** Wherever the Workflow below says "you", the review is run by a fresh reviewer (a new agent, preferably
on a different model than the author) given the spec and the system, not the author's notes. The fresh reviewer writes
the report and runs `advreview` itself (step 2), so the token and the comment come from the reviewer's run; the author
fixes the findings and requests a new review. **What it must produce:** when the diff has testable behaviour, at least
one NEW test that tries to break the change and is kept (whether it passes or exposes a defect); a review made of
reading alone is not complete. A diff with no testable behaviour (policy text, documentation) states why no test
applies in the report. A kept test committed on a reviewer branch with the story's `Refs:` trailer blocks the author's close (Trunk Reach)
until it is merged or cherry-picked onto the story branch, or the reviewer branch is deleted; a probe that is not meant
to be kept carries no `Refs:` naming the story, or its branch is deleted after the review.

## Workflow — the review+fix LOOP (phase-enforced, bounded)

1. **Run the review** over the story diff; write EVERY finding to a report file in the **review template** below (one
   finding per bullet, with its severity, file:line and why). The bridge refuses a report that does not follow it,
   before any token is minted, and its refusal names the line and repeats the template.
   ```
   ### Summary
   <n> findings (<b> blocker, <m> major, <k> minor), <h> hygiene items, <t> new adversarial tests. <free text>

   ### Findings
   - **F1** · blocker · `path/to/file.cs:42` — what is wrong, why it matters, the fix
   - **F2** · major · `path/to/file.sh:7` — ...
     (an indented line continues the bullet above)

   ### Hygiene
   - **H1** · `path/to/file.cs:10` — ...

   ### New adversarial tests
   - **T1** · expected to FAIL · `TestName` — what it locks

   ### Checked, no finding
   (optional) what was checked and found sound
   Not checked: <ids> — why (optional, one line for what you did not check)
   ```
   - On a documentation, analysis or ops story, name each spec item you checked (`R1`, `AC1`, `UC1`, `FM1`, `RA-01`,
     `FAIL-HARD`, ...) in `### Checked, no finding`: there the review is what covers those items.
   - Anything you did not check goes on a `Not checked: <ids> — why` line in `### Checked, no finding` (an optional
     `- ` or `* ` before it, the label may be bold); the line runs on until a blank line or a new bullet. Or put
     `(not checked)` right after an id (`UC1 (not checked)`): one id per `(not checked)`; for a list use the
     `Not checked:` line. Only that marker, or an item named in a `### Findings` bullet, takes an item's cover away:
     prose elsewhere ("the second page was not checked") is not read as a veto, so an item it names still counts as
     checked.
   - **Severity:** `blocker` (must be fixed before the merge), `major` (a real defect or gap), `minor` (small, low
     impact). Findings are listed blocker first, then major, then minor, numbered F1, F2, ... in that order, so a
     search for `· blocker ·` finds every blocker.
   - A list section with no item holds the single line `- none`; the counts in the summary's first line must equal
     the lines listed. A new test is `expected to PASS` when it already holds and is kept as a guard.
   - A line indented with spaces or a tab continues the bullet above it. A bold item number (`**F2**`) or a severity
     tag (`· blocker ·`) appears only in the leading tag of its own bullet: anywhere else (a continuation, the rest of
     the bullet line, a quote, another list form, a comment, fenced code, the Summary or Checked text) it is refused,
     so every item a search finds is counted. Name another item without bold (F2). A lone carriage return or a Unicode
     line or paragraph separator starts a new line. Code inside a list section is fenced and indented under its item;
     a heading is not allowed inside a list item, nor indented anywhere; in the Summary and Checked sections a fence is
     free text, and a `#` line inside a fence is not a heading. Item numbers start at 1 with no leading zero, and every
     backticked path or name holds visible text.
   - Do not add a title: the posted note gets its heading from the bridge, `Adversarial review (round N) — STORY-<id>`,
     with the round counted from the story's earlier review notes (also in the hidden marker
     `<!-- kyklos:adversarial-review story=<id> round=N -->`). A note counts when it starts with that marker and carries
     the review token line (CRLF line ends included), so a comment that quotes the marker does not. The round is a
     reading aid, not a lock: two reviews posted at the same moment, a deleted review note, or a comment that copies a
     whole review note's marker and token line can shift or repeat a number; the token is the proof.
   - The template is enforced by the bridge (at mint and at post). A bridge older than the template mints and posts any
     report, and the helper's fallback for a bridge without `advreview_post` posts it unchecked; follow the template
     anyway, so the note reads alike once the bridge is updated.
2. **Mint the token + post the report** — do NOT hand-craft either, and never hand the report text to the author or the
   coordinator to carry. The reviewer posts its own report with two bridge verbs that take the report text as a
   parameter, so no file is needed: `advreview_mint` (`project`, `story`, `report`) has the **KyklosBridge** mint the
   content-bound token with its host-only signing key, kept under the story's own project (a bridge serving several
   projects refuses a call without `project` with `PROJECT-REQUIRED`), then `advreview_post` (`iid`, `report`, `token`, `project`)
   posts the report **plus the token** as a GitLab comment on the story with the bridge's own token (so the container
   needs no GitLab token) and answers `{note_id, url}`; the comment's browser link is that `url`. The two values the
   Proof row needs are that `url` (Report) and the token. An unreachable or keyless bridge refuses the mint, and
   nothing is posted.
   The helper `advreview <story-id> <report-file>` (on PATH through the plugin's `bin/`; the script itself is
   `skills/ssdlc-adversarial-review/advreview`) makes the same two calls from a report file and prints
   `Report=<comment-url>` and `Token=<token>`; it is the fallback for a shell that cannot call the verbs (an older bridge
   without `advreview_post` makes it post with the container's token and say so on the direct-token fallback
   ledger). Its settings (the GitLab API, the token variable and the story's project) come from the environment, else from the
   workspace's `.claude/standards.env`; the story project falls back to `STORY_GITLAB_PROJECT`, so a repository that
   declares its story backend needs nothing more.
3. **If the report has findings** (anything relevant to fix):
   - the story goes back to Implementation (`story phase <id> Implementation --reason "<the findings>"`) — you may
     NOT skip phases.
   - **fix ALL the findings.** Only after they are fixed does the workflow resume — then go back to step 1 (a fresh
     review over the new diff). Each iteration posts its OWN comment.
4. **The loop stops** only when a review finds **nothing relevant to fix**, OR after **3** iterations in this story.
   If the third iteration still has residual findings, STOP and surface the residual to the user — never silently
   close.
5. **Fill the Proof row** from the FINAL (clean) run's helper output:
   `story proof <id> --set 'Adversarial Review=PROVEN|clean self-review, N iteration(s)|<kbd>Report:</kbd> <comment-url><br><kbd>Token:</kbd> <token><br>'`
   The close gate has the bridge re-verify the Token with its key (MCP tool `advreview_check`, under the story's
   project); a hand-typed Token, a token of another project's story, a missing Report link, an unreachable bridge or a
   bridge too old to key review tokens by project (`BRIDGE-TOO-OLD`) refuses the close.

## Why it can't be faked

The token is bound to the exact findings-report content and HMAC-signed with a key that only the bridge holds: the
container can neither compute it from the report nor check it, so both the mint and the close-time check go through
the bridge. A plain hash of the report (what a container could compute) never verifies. So the row is physically
un-fillable without a real skill run over a real report — the mistake (closing without a genuine adversarial review)
is made impossible, not merely requested.

## Design reviews — the reviewer posts its own report with `designreview_post`

A review of a written design (a story's description or spec, before any code) is a design review. It has no diff, no
token and no Proof row of its own; its report is a note on the story. The same rule holds as for a code review: **the
reviewer posts its own report, and the coordinator never carries the text.** What keeps a report unaltered is that
the author never handles it; the verb claims no detection (any agent holding the bridge can call it).

- The reviewer calls the bridge verb **`designreview_post`** (`iid`, `report`, `project`) with the report text. It posts
  the text exactly as sent (trimmed of leading and trailing whitespace only; the bridge adds nothing), mints no token and
  touches neither the code review note, its token nor its round count. It answers `{note_id, url}`.
- The report follows the design review shape (the bridge refuses anything else, naming the line and repeating the
  template): an optional first line `<!-- kyklos:design-review story=<n> round=<k> -->`, the heading
  `## Independent design review (round <k>) <any text>`, any preamble, `### Summary` (free text), `### Findings`
  (`- **F<n>** · <blocker|major|minor> · <location> — <text>`, or the single line `- none` for a clean round), optionally
  `### Hygiene`, `### New adversarial tests <any text>` (``- **T<n>** `<name>` — <text>``), optionally
  `### Checked, no finding` (what you did not check goes on a `Not checked: <ids> — why` line there, as in a code
  review).
- The round is the design review notes the bridge's account already posted on the story, plus one. A report whose marker
  or heading names another round is refused with `DESIGN-ROUND-MISMATCH`, naming the expected round: renumber the marker
  and the heading and post again. A refusal `DESIGN-OFF-TEMPLATE` names the offending line; an issue that is not a story is
  `NOT-A-STORY`.
- A line that starts, in its first column and outside fenced code, with a slash and a command GitLab recognises
  (`/close`, `/label`, `/assign`, ...) is refused as `DESIGN-OFF-TEMPLATE`, in a code review report too: GitLab runs
  such a line as a quick action and strips it from the note. Rewrite the line (never escape it); a slash line inside a
  fence, an indented one, or one starting with an unknown word such as a path (`/mnt/foo`) is fine.
- **VERB-UNAVAILABLE.** The verb missing from the reviewer's tool list, or any unknown-tool or no-such-tool answer, in
  particular the bridge's `unknown tool: designreview_post`, means "verb unavailable" (an older bridge, or a reviewer
  without the bridge). It is not a failure of the report: the reviewer **returns its report text** as its final answer,
  and the coordinator then posts it with the line "transcribed by the coordinator from the reviewer's returned text"
  under the heading. Any other refusal is the reviewer's to fix and post again; never answer a refusal by sending the
  text through the coordinator.
- The agent prompt for a design review therefore says: "post your report yourself with `designreview_post`; on
  `unknown tool: designreview_post`, return the report text instead; the coordinator never carries it."
