# How Kyklos chooses the next work

[← Back to the README](https://github.com/DogmaSolutions/Kyklos/blob/main/README.md)

An agent that works with Kyklos does not pick its next task by taste. It asks the [Kyklos Bridge](COMPONENTS.md#kyklos-bridge), and the Bridge applies one fixed rule to the open issues of the project. This page explains that rule for the person who sets Kyklos up, so you know what to expect, why an issue is or is not offered, and what to do to change the order.

A few words used below:

- A **story** is an issue that Kyklos manages (see [Stories, Epics, and how the agent works with them](AGILE.md)).
- The **phase** of a story is its step in the workflow: Requirements, Design, Implementation, Testing, Deployment, Review (see [The Kyklos workflow](WORKFLOW.md)).
- The **status** of a story says whether it is to do, in progress, blocked or parked (see [Storages](STORAGES.md)).
- The **severity** of an issue says how urgent it is: critical, high, medium or low. It is a label on the issue, for example `severity::high`.

## The three steps

The Bridge sorts the issues it can offer in this order, and in no other.

1. **Started work first.** An issue counts as started when its status is "in progress" or "blocked", or when its phase is past Requirements. Started work always comes before anything new, so a half-done story is finished before another one is begun. Among started issues, the one where someone other than the agent acted most recently comes first. "Acted" means a new comment, or a label or state change. The idea is that a person who just wrote to you is waiting for you.
2. **Then work not yet started, by severity.** Critical comes first, then high, then medium, then low.
3. **The oldest issue first** whenever two issues are otherwise equal. The one opened earlier wins; if the opening time is the same or unknown, the lower issue number wins. An issue whose opening time cannot be read is never taken for the oldest.

## Dependencies: a blocker comes before what it blocks

An issue that waits on another open issue is never offered before it. Three things make an issue wait:

- a "blocked by" link to another open issue;
- an open child story, when the issue is a parent story (a parent waits for each of its open children);
- the blocker recorded on the story when it was blocked (see below).

When an issue waits, the Bridge does not offer it. It offers the first issue on its chain of blockers that can be taken now, and says which issue that one unblocks. The waiting issue is listed as blocked, with the name of what it waits on.

A story can also be blocked on a person or on something outside the tracker. Such a story is never offered. The answer shows what it waits for and, when known, since when, so you can see a block that has gone stale. A block always names its kind: on an issue, on the user, or on something external.

If two issues wait on each other, neither can ever be taken. The Bridge does not guess: it lists both as a dependency cycle, so a person can break it.

## Set aside, or someone else's: listed, never taken

Some open issues are not the agent's to take. The Bridge never offers them, but it never hides them either. Each one is listed by name under "left out", with the reason:

- an issue **set aside** by its status: parked, won't fix, duplicate, invalid or archived. The owner decides what happens to it, so the agent does not;
- an issue assigned **only to someone else**.

If another issue waits on one of these, that issue is reported as blocked by it, with the reason (for example "parked: owner decision needed"). That way the person in charge sees what is held up and can decide.

Messages between agents (communication issues) are not work. They are answered from the inbox and only counted in the answer.

## Why every issue needs a severity

Step 2 sorts by severity, so an issue without one cannot be ranked. The Bridge does not rank it on a guess: it lists it apart as a defect, "needs a severity", and asks for a label before the order can include it. Give every issue exactly one severity the day it is opened:

| Severity | Meaning |
|---|---|
| critical | a live outage or exposure |
| high | a security gap, a check that fails open, or a fault that stops work or loses data |
| medium | a defect with a workaround, or a requested feature |
| low | polish or parked work |

The story tool enforces this at the source: creating a story without a severity is refused. The label values are created with the other labels in the backlog section of the [install and configuration guide](INSTALL_AND_CONFIG.md).

## How to see the order

Ask for it. Nobody has to sort the backlog by hand.

- The Bridge verb **`next_work`** answers for the project's stories. The agent calls it; you can ask the agent to show you the answer.
- From a shell, the story tool's command **`story next`** gives the same answer.

The answer is plain text. It starts with a line `NEXT:` naming the item to take, and then lists:

- the issues that **need a severity**, and the stories with a **block that names no kind** (old blocked stories; block them again with their kind);
- the stories **to adopt**: an issue that carries the story label but is not yet adopted (for example one created by hand in GitLab) is listed with the command that adopts it. Where it stands in the order does not change; the line only adds the adoption step (the [workflow glossary](WORKFLOW.md#glossary) explains adoptable and adopted stories);
- the issues that **need attention**: labels that cannot be read, a dependency cycle, or a read that failed;
- the **order** itself, one numbered line per issue with the reason it stands there;
- the **blocked** issues and what each waits on;
- what was **left out**, by name, with why;
- the **open asks to the owner** (see below);
- a count of the open communication issues.

If the answer says "nothing to offer", every open issue is blocked, left out or needs attention, and the lists below it say which and why.

## Open asks to the owner

An agent that needs your decision asks it as a comment on the story, with tick boxes. Its story is not always blocked: the
agent may keep working on the parts that do not depend on your answer. So the answer lists every ask that is still
waiting for you, on any open issue, blocked or not, each with its issue, a one-line summary and the link to the comment.
The [Doctor](COMPONENTS.md#kyklos-bridge) shows the same list.

- **What counts as an ask:** a comment that mentions one of the owner accounts (the Bridge setting
  `Agile:Acceptance:OwnerAccounts`, see [the Bridge settings](WORKFLOW.md#bridge-owner-settings)) and has at least one
  tick box. Your own comments are never asks. With no owner account set, the list says so instead of showing nothing.
- **When it stops waiting:** you tick a box; or you reply in words after it, in a comment that names it (its link, or
  "note" and its number) or that comes right after it; or the agent retires it.
- **Retiring:** when an ask was answered in words, was the wrong question or was replaced by another one, the agent
  retires it with the Bridge verb `story_ask_retire`: the comment gets the first line "Retired: <why>" and the rest stays
  as it was. A retired ask is never listed again.
- **Stale asks:** an ask with no tick and no reply for longer than the setting `Agile:Asks:StaleAfterDays` (2 days by
  default) is shown once, apart, as "stale: rewrite or retire", and is not repeated as a reminder. The agent then asks it
  again in a clearer form or retires it.

## Where the rule is written

The rule is part of the policy the agent loads, in the section "Choosing the next work" (see [The three policy levels](POLICY_LEVELS.md)). The Bridge is the one place that applies it, so the policy text and the answer cannot drift apart.
