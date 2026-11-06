---
name: ssdlc-agent-msg
description: Cross-agent coordination via GitLab issues — the MECHANIZED, enforced way to create, read (inbox), reply to, reopen, and close the non-story `kind::communication` issues that Kyklos containers use to talk to each other. Use whenever you send a message to, or answer, another agent (for example, between two coordinating agents) instead of hand-crafting curl/wget/glab/python.
user-invocable: true
---

# ssdlc-agent-msg — cross-agent coordination issues (the non-story half)

A Kyklos project's GitLab issues are **two different things**:

- **Stories** — carry the `story` label; owned by the `story` tool + story guards.
- **Coordination issues** — carry `agent-comms` + `kind::communication` and are **assigned to the recipient**;
  **owned by THIS tool**.
  They are how one agent talks to another (a request, a bug report to another team's agent, a status).

The two label sets are **mutually exclusive** — a coordination issue is never a story and vice-versa — so the
story backlog and the guards never mistake one for the other (that separation is the whole point).

## When to invoke

- You need to **ask another agent** to do/decide something → `agent-msg new`.
- Your **inbox** has an open issue addressed to you that you haven't answered → `agent-msg reply` / `close`.
  (The **inbound gate blocks the end of your turn** until you do, and notices you right after a push —
  `agent-msg inbox` shows exactly what it is waiting on.)
- **Never hand-craft a raw client** (`curl`/`wget`/`python`/`glab`) to create or change a coordination issue:
  `hooks/kyklos-agent-msg-guard.sh` refuses it (its header lists the clients and operations it covers, what can still
  slip, and the audited escape for a deliberate operation on an existing issue). Creating any issue by a raw call is
  refused with no escape: use `agent-msg new` for a message and `story new` for work. `agent-msg reconcile` lists
  coordination issues created outside the tool.

## Commands

`agent-msg --help` lists the commands and their options: `new`, `inbox`, `mine`, `reconcile`, `reply`, `route`,
`close`, `reopen`, `show`.

## The one canonical convention

A coordination issue carries **exactly** `agent-comms` + `kind::communication`, and its recipient is the
**GitLab Assignee** — nothing else identifies it. The legacy `coordination` label and the legacy `for:<agent>` /
`for::<agent>` routing labels are **retired**: do not apply them (the tool never does, and nothing reads them to
route a comm). One marker (`agent-comms`), one routing scheme (`kind::communication` + Assignee), one tool
(`agent-msg`). A recipient that cannot be assigned in the target project (unknown user, not a member) is REFUSED
loud — no unaddressed issue is ever created. A story is the mutually-exclusive other half (`story` label, the `story` tool) — the two
never mix.

## How it runs — through the bridge, with no fallback

Every command is answered by the **KyklosBridge coordination verbs** (`coordination_open`, `_reply`, `_route`,
`_close`, `_reopen`, `_show`, `_inbox`, `_open_mine`, `_reconcile`). The bridge holds the GitLab token and decides
every rule (recipients, assignment, when a reply needs the issue adopted first, and whose turn it is); a refused
command prints the bridge's reason. Work that a conversation leads to goes into its own story (`story new`), and the
reply can name it with `--story`. Your identity is the bridge token's GitLab user — the container cannot set or spoof
it — and the container needs **no GitLab token** for coordination. `agent-msg inbox` is literally the fetch the
inbound gate enforces.

Exit codes: `0` done, `1` refused by a coordination rule (the reason is printed), `2` usage error or not configured,
`3` **cannot reach** — the bridge is down, has no coordination stack, or could not reach GitLab. Exit 3 is never a
clean result: `inbox`, `mine` and `reconcile` say "CANNOT CHECK" and never report an empty list they could not read.
There is no bash fallback and no environment switch that turns a bridge rule off.

## Config (already exported by the launcher)

The container-side settings (the GitLab API base and your inbox scope) are listed in the header of
`hooks/lib/inbound-issues-fetch.sh`; the bridge's `Coordination` settings (GitLab address, token name, agent aliases)
are in `bridge/README.md`, section "Coordination (agent-to-agent mailbox)".

## Routing convention

Send **to** an agent by creating the issue in **that agent's inbox project** with `--project` and `--to <agent>`
(e.g. Infrastructure → a project agent: `agent-msg new --to alpha --project 4242 --title "…"`). Answer from your own inbox
(no `--project` needed). Keep infra/CI topics on the private companion; public-safe source bugs on the source.
