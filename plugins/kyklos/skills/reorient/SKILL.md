---
name: reorient
description: User-invoked. Re-orient the agent after a container restart — drop cached/inherited assumptions and re-discover the current tools, skills, MCP servers, governing instructions, and backlog before resuming work. Invoke as /kyklos:reorient.
disable-model-invocation: true
---

# reorient — start again from the current reality, not last session's map

You have (most likely) just been **restarted inside a fresh container**: a new image, newly pinned plugin
versions, and a session whose history may carry **stale assumptions** from a previous run. Do not trust cached
or inherited mechanics — the tool you "remember", the path you "know", the gate that "used to" behave a certain
way may all have changed. Re-orient from scratch **before** doing any work, in this order:

1. **Re-read the governing instructions.** Read the managed and project `CLAUDE.md` again (the Kyklos
   requires a recent read before it will let you act anyway). Treat them as the current source of truth and let
   them override anything you think you remember.

2. **Re-discover your tools, skills, and MCP servers — versions may have changed.** Note the loaded plugin
   version and its skill catalogue from the session-start context. Search the live MCP tool inventory rather
   than assuming a tool exists, and confirm the build/test bridge and any other MCP servers are actually
   connected this session. Never invoke a tool from memory without confirming it is present now.

3. **Restore your task context from the source of truth, not memory.** Re-sync the backlog and stories from the
   tracker (`story refresh`) so you act against current state, not a stale local mirror, and read the story and
   branch you are currently on.

4. **Load the pending work through the project's mandated loader** — whatever the project rules designate as the
   one sanctioned way to enumerate open work — and identify the next item. Do not hand-assemble the query; the
   mandated loader exists precisely so a scope can't be silently missed.

5. **Resume.** Ask the bridge which item comes next (its `next_work` tool, with the project; the engineering policy's
   "Choosing the next work" rule is the order it applies) and take that item, honouring every gate — branch
   discipline, SSDLC phases, proofs — as freshly re-read, not as remembered.

If any step reveals a **changed mechanism** — a renamed tool, a new gate, a moved path, a bumped version — adopt
the new one. Surfacing and absorbing those changes is the entire point of re-orienting; running on last
session's map is the failure this command exists to prevent.

If the user typed anything after the command, treat it as additional focus for what to resume once you are
re-oriented: $ARGUMENTS
