# Governance ownership — one owner per baseline concern

A consuming project and the `kyklos` plugin can each ship a guard for the same concern (GitFlow
branch names, session continuation, standard config, test quality, zero-failures, merge-on-green). When
both fire they **double-block**, and it becomes ambiguous which layer's rule and which file clears the gate.

This document is the single source of truth for **which layer owns each concern**. The rule is simple:

> **Kyklos OWNS every baseline concern below. A consuming project MUST NOT ship its own guard
> for an owned concern — it deletes the duplicate and relies on Kyklos.** A project keeps only guards for
> concerns Kyklos does not cover (its own domain-specific discipline).

The plugin is baked into the container image and is the same for every project, so making Kyklos the
single owner means one canonical rule, one escape path, and one state directory across all projects.

## Owned concerns (Kyklos is canonical — drop the project duplicate)

| Concern | Kyklos guard (canonical) | What the project drops |
|---|---|---|
| GitFlow branch names | `kyklos-gitflow-branch-guard.sh` | its own gitflow/branch-name guard |
| Session continuation (read `CLAUDE.md` + restore task context) | `kyklos-session-continuation-guard.sh` | its own "read CLAUDE.md / restore context" guard |
| Standard config (idiomatic config, no hardcoded connection strings) | `kyklos-standard-config-guard.sh` | its own standard-config guard |
| Test quality (no regression-hiding tests) | `kyklos-test-quality-guard.sh` | its own test-quality guard |
| Zero pre-existing failures | `kyklos-zero-failures-gate.sh` | its own zero-failures gate |
| Merge-on-green | `kyklos-merge-green-guard.sh` | its own merge-green gate |
| Measure before auto-merge (changed C# needs the content ledger's answer with no GAP and no EXPIRED line at the armed commit, or a Test Discipline token, to arm auto-merge; one-shot, repository-bound, audited override `automerge-coverage-ok` for a change to the token builder itself, or one no proportionate token can measure yet) | `kyklos-automerge-coverage-guard.sh` | its own "measure before you let it merge" rule |
| Hands off (a story merge request is armed in the push that creates it; a hand merge of an armed, merged or closed request is explained, not attempted; in a repository with no CI pipeline the request is created unarmed and merged through the API once mergeable, still under the merged-result check; opt-out `KYKLOS_MR_AUTOMERGE=off`, audited) | `kyklos-mr-hands-off-guard.sh` (+ the hand-merge checks in `kyklos-automerge-coverage-guard.sh` and `kyklos-merge-green-guard.sh`) | its own "the merge request merges itself" rule |
| Merged result (before auto-merge is armed or a merge request is merged through the API, the branch must contain its target's current head, or the target's new commits must touch none of its files and no build-wide file) | `kyklos-automerge-coverage-guard.sh` | its own "test what lands" rule |
| Safe remove (an `rm`/`rmdir` on a critical path - root, a root child, home, the working directory or a parent, a glob or trailing slash under a variable, a substitution-only recursive target - is refused at once with the safe form, never left to stall on Claude Code's built-in approval prompt; nested and `bash -c` forms included; opt-out `KYKLOS_RM_CRITICAL_PATH_GUARD=off`, audited) | `kyklos-rm-critical-path-guard.sh` (+ `lib/rm-critical-path.sh`) | its own "careful with rm -rf" rule |
| Read before run (a script fetched from the network and run in the same command - piped, substituted or printed into a shell or interpreter, also behind sudo, env or a shell's `-c` - is refused, naming the fix: download to a file, read it, then run it; package installs, saved downloads and downloads read as data pass; a broken library or a missing jq refuses a command naming a download tool; opt-out `KYKLOS_PIPED_SCRIPT_GUARD=off`, audited) | `kyklos-piped-script-guard.sh` (+ `lib/piped-script.sh`) | following a `curl ... \| sh` install instruction |
| Bounded test runs (a shell command that starts a test runner - `dotnet test`/`vstest`, `vstest.console`, `npm test`, `vitest`, `pytest`, Pester, `bun test`, `cargo test`, `go test`, the plugin battery, a CI shell suite - without a `timeout <limit>` bound is refused, showing the corrected command, also through any wrapper (a runner among a command's later words) or fed to a shell as a heredoc, here-string, pipe or `< file`; a runner only named as text, or a syntax check, passes; a broken library refuses a command naming a runner; opt-out `KYKLOS_TEST_RUN_BOUND_GUARD=off`, audited) | `kyklos-test-run-bound-guard.sh` (+ `lib/run-bound.sh`, `lib/shell-scan.sh`) | starting `dotnet test` from the shell with no limit, so a hung run burns CPU for hours |
| Test-host reaper (at every end of turn, the test hosts of the container that ran longer than `KYKLOS_TEST_RUN_LIMIT`, default `60m`, with no `timeout` of their own of at most 2 hours still running, are ended by process id with the processes they started, each reported with its command and its starter; the start time read with the process list is checked before every signal and a zombie counts as gone; a process that is not a test host is never touched; opt-out `KYKLOS_TEST_HOST_REAPER=off`) | `kyklos-test-host-reaper.sh` (+ `lib/run-bound.sh`) | a test run that escaped the bound (the guard off, a run started by a tool) left running for hours |
| Ask First (an agent switching a workflow control off, weakening it or switching a grant on - in `.claude/standards.env`, another settings file, or inline to a command - needs the user's confirmation in Claude Code's own permission dialog; each approved change leaves one audit note on the story; a change that cannot be read is refused at once, never put to the user; a loosening it did not ask about is put back after the call and the turn is blocked; off only by `KYKLOS_ASK_FIRST=off` in the launcher-set environment, never from `standards.env`) | `kyklos-ask-first-guard.sh` (+ `lib/ask-first.sh`, `lib/ask-first-snapshot.sh`, `lib/control-inventory.sh`) | its own "confirm before disabling a gate" rule |
| Tool-First discipline (use a kyklos/MCP tool before hand-crafting) | `kyklos-tool-first-guard.sh` + `kyklos-tool-catalog-surface.sh` | its own "use the tool" reminder/guard |
| Cross-agent coordination issues (create/reply/reopen/close via the `agent-msg` tool, not raw HTTP) | `kyklos-agent-msg-guard.sh` (shares `lib/issue-api-detect.sh` with the tool-first guard) | its own agent-comms/coordination convention |

### Canonical facts a project must align to

- **Tool-First norm.** *Look before you leap:* the FIRST step of any task is to consult the auto-generated
  capability catalog injected at SessionStart (`kyklos-tool-catalog-surface.sh`) and to `ToolSearch` the live MCP
  inventory — **before** hand-crafting anything. Hand-crafting is justified ONLY with an explicit "no tool fits
  because …". This operationalizes the Tier-1 "don't re-invent the wheel" rule so the right tool is the path of
  least resistance, not a reactive discovery after a guard blocks you. The reactive backstop for the worst
  UNGUARDED footgun — hand-driving a **story** issue's lifecycle by raw `curl` to the GitLab API instead of the
  `story` tool — is `kyklos-tool-first-guard.sh` (fail-open on what it cannot classify, never on a broken detector; one-shot escape `bash hooks/lib/override-marker.sh set tool-first-ok <your-working-folder>`).
  Epics (GitLab milestones) have their own guard, `kyklos-epic-gate-guard.sh` (Epic Gate, default-on): a hand-made
  write to the milestones API, or a raw issue write that sets an issue's milestone, is refused and routed to the
  `story epic ...` commands / the bridge's epic verbs (one-shot, audited escape: the override marker `epic-api-ok`).
  Footguns already owned by a dedicated guard are NOT re-covered: raw `dotnet build|test` →
  `kyklos-build-execution-guard.sh`; hand-editing a generated `Stories/` mirror → `kyklos-story-mirror-edit-guard.sh`.
  Those guards' block messages also cite this norm, so every such block teaches tool-first.

- **Restructure-before-work covers BOTH channels.** `kyklos-story-structure-guard.sh` blocks work while the
  In-progress story is structurally incomplete on **Edit/Write** (`edit` mode) AND on **Bash** (`bash` mode — it
  gates only a real `git commit` invocation, via the shared `lib/git-cmd-detect.sh` command-position detector, so a
  Bash-driven workflow can no longer bypass the gate; a mere *mention* of `git commit` is never gated). Fail-open on
  everything else; disable with `KYKLOS_STRUCTURE_GATE=0`. Scope is H2 (a known non-conforming active story) only —
  the bare-non-story-issue case is deliberately not inferred (too false-positive-prone).

- **One Door for issue writes.** There is ONE mechanized way to touch the GitLab issues API for
  the two governed concerns: the **`agent-msg`** tool for cross-agent **coordination** issues (create/reply/reopen/
  close) and the **`story`** tool for **story** issues. A raw client (`curl`/`wget`/`glab`/`python`) that writes to
  the issues API is blocked by `kyklos-agent-msg-guard.sh` (coordination) or `kyklos-tool-first-guard.sh` (story) —
  both share the single detector **`lib/issue-api-detect.sh`** (one detector, two policies; no duplicated parse).
  Every guard that decides with that detector (also the Epic Gate and the proof-table guard) arms the EXIT trap of
  `lib/guard-prologue.sh` first and loads the detector through `guard_load` (`require_lib`): when it is missing,
  fails to load, lacks a function the guard calls or ends the shell while loading, the guard refuses every command
  and names the library, instead of letting a raw write through (Edit and Write still work for a repair).
  The **one** coordination convention is `agent-comms` + `kind::communication` with the recipient as Assignee (the
  legacy `coordination` and `for:<recipient>` labels are retired); a story is the mutually-exclusive `story`-labelled half. Honest scope: string inspection is a
  **deterrent + detectability** posture, not a sandbox — a bespoke/compiled client or a multi-statement `python -c`
  can still slip; every tool-made coordination issue carries `agent-comms` so an out-of-band one is detectable.
  **Front Gate (no escape):** a raw write that CREATES an issue - any issue, whatever its labels - is refused before
  any escape is read; issues are created only with `story new` (work) or `agent-msg new` (a message). A read is never
  refused: data flags (`-d`, `--data*`, `--json`) beside a genuine curl `-G`/`--get` option only build a search's query
  string, so that request is a read. `-G` is genuine only as curl's own option word in a request the detector can read
  without doubt (no backslash, unbalanced quote, comment, background `&`, parenthesis or backtick; not another option's
  value; not a redirect target; no word that could be `--next` anywhere in the command; every word curl could read as an option or a
  method known text: no unquoted `$X`/`$@`/`$*`/`$(...)` and no quoted `"$M"` there (a redirect target, a quoted value such
  as `-d "page=$p"`, and a quoted `"$URL/path"` are known positions; an unquoted `-d page=$p` can split, so it is not), no glob that can match `-...`, and the client not run through `xargs`, `find -exec`, `parallel`, `eval`, `bash -c` or a `curl` function or alias); otherwise the data flags count
  as a write. Option clusters are read the way curl reads them (`-GX POST` is `-G -X POST`), quoted or not, and any method other than
  `GET` or `HEAD` (by `-X`, `--request` or an abbreviation) is a write. A request still writes with a mutating method (quotes and backslashes in it are removed first), an upload
  (`-T`), a form (`-F`, `--form*`), an abbreviated write option (`--jso`), a wgetrc command that posts (`wget -e
  post_data=`), or what the command does not show: a method in a variable, any config file (`-K`, `--config`, also
  `-K -` on stdin; a token header goes with `-H`), a config home assigned before the client (`CURL_HOME=`, `HOME=`,
  `WGETRC=`), a brace expansion or `$'...'` quoting. Statements split as the shell splits them (quoted or escaped `;`
  is text; a backslash-newline continues), and routes match as the server reads them (percent-decoded, `//` and `/./`
  collapsed, any format suffix). The one escape,
  `AGENT_MSG_RAW_OK=1` (in the environment or inline, always audited), covers only a deliberate operation on an
  EXISTING issue (a note, an admin edit, close, reopen or delete); no comment in the command counts as an escape. A
  refused raw note names the right tool for the issue it targets: `agent-msg reply` for a coordination issue, the
  story verbs (`story reopen-root-cause`, `story proof`, `story ra`, `story set --reason`) for a story.

- **Un-self-grantable outward overrides.** The two OUTWARD, irreversible-facing overrides
  — `push-ok` (`kyklos-no-push-guard`) and `merge-ok` (`kyklos-merge-green-guard`) — must not be self-grantable by a
  (possibly prompt-injected) agent. The hardened path is a **USER-applied** `push-override` / `merge-override` label
  on the pushed/merged branch's **story issue** (checked by `lib/user-applied-label.sh` `override_user_applied`, the
  same authorship rule as the parked/grandfather leniencies — an agent cannot author a label as another GitLab
  user). `KYKLOS_HARDEN_OVERRIDE` is ON by default: the self-set one-shot override is IGNORED (only the user label
  authorizes). An unset value or a typo keeps it on; only an explicit off value (`0`/`off`/`false`/`no`) lets the
  marker count again, **loudly deprecated**. The launcher sets it per project
  (the shared settings catalog, `ProjectParameters.cs` under `shared/`, owns the default). (Story-lifecycle self-set overrides like `story-start-ok`/`gitflow-ok` stay agent-usable — they gate
  local, reversible work, not an outward push/merge.) `automerge-coverage-ok` (`kyklos-automerge-coverage-guard`) is
  a marker an agent can set, so it is kept narrow: it is for the user's decision only, it lifts the coverage verdict
  alone (never the merged-result check, and never the pipeline gate that still has to go green before the merge), it
  admits one arm in one repository for the agent that set it, it expires, and every use is written to the
  escape-audit log.

- **GitFlow prefixes.** The canonical branch-prefix set is **`feature | release | hotfix | support`**.
  `bugfix/` is **not** a canonical GitFlow prefix — a project that documented or allowed `bugfix/` removes it
  from its `CLAUDE.md` / `AI_TOOLS.md` and drops its own gitflow guard. One-shot escape:
  `bash hooks/lib/override-marker.sh set gitflow-ok <repo-dir>`.

- **One-shot overrides are scoped, bound to their agent, and expire.** Every guard's one-shot override is set with
  `bash hooks/lib/override-marker.sh set <name> <repo-dir>` (or `<your-working-folder>` for guards that are not about one repository),
  in a separate command before the one the guard would block. The override records the repository it is for and the
  AGENT that set it, and expires after `KYKLOS_OVERRIDE_TTL_SECONDS` (default 600). Several agents share one
  container (a session and the subagents it starts), so the agent is never named on the command line: the PreToolUse
  hook `hooks/kyklos-override-bind.sh` sees which agent runs the `set` command (the hook input's `agent_id`; the
  session's main agent has none and is `main`) and hands that identity to the CLI through a short-lived handoff; a
  `set` run outside an agent's tool call binds to `main`. Each agent's override is its own file, so one agent never
  overwrites another's. A guard spends an override only when the agent calling it set it, for the same repository, and
  only when it is about to block; any other agent sees it left in place (and is told who holds it), and a call that
  is not blocked never spends it. A guard that cannot identify its caller grants no override. A bare `touch` of a
  marker file, or an old-style marker not bound to an agent, is ignored and removed, with a message saying how to set
  one. No command may touch the handoff store (the bind hook refuses it), and no guard reads a marker file directly:
  all go through `hooks/lib/override-marker.sh` (`override_take <name> <scope> <hook-input>`), which
  `hooks/tests/test-override-marker.sh` enforces.

- **Single state directory.** All Kyklos hooks read and write **`$KYKLOS_STATE_DIR`** (default
  **`/tmp/kyklos-state`**). Do not introduce a second per-project state dir (e.g. `/tmp/<project>-test-state`);
  point any surviving project hook at `$KYKLOS_STATE_DIR`. Once the duplicated project guards are removed the
  split dissolves on its own.

- **Session continuation — canonical file set.** `kyklos-session-continuation-guard.sh` is the ONE gate that
  requires start-of-session context. It clears when the agent has read, this session:
  1. **`CLAUDE.md`** (always), and
  2. **task context** — under the GitLab story backend this is satisfied by interrogating the source of truth
     directly (`story list|show|refresh|check`, or a direct issues-API read); the local `Stories/BACKLOG.md`
     mirror is only a projection and reading it is the fallback, and
  3. **`AI_TOOLS.md`** if the project ships one.
  A project MUST NOT add a second continuation guard on top of this — that is exactly the double-block this document exists to prevent.

  > **Not the same as `kyklos-continue-guard.sh`.** The *continuation* guard (above) runs at session **start**
  > (PreToolUse) to load context. The *continue* guard runs at **Stop** to forbid an unmotivated pause while
  > scope work remains. Different event, different purpose — both stay in Kyklos; neither is duplicated by a
  > project.

- **Merge-on-green and the push model are two separate switches.** The switches, their defaults and when the
  merge-green gate stands aside are stated in the header of `kyklos-merge-green-guard.sh` (its own flag,
  `KYKLOS_MERGE_GREEN`, default on; inert when the container has no CI access) and of `kyklos-no-push-guard.sh`
  (`KYKLOS_CI_MONITOR`, which only opens the push of a project's own `feature/*` / `hotfix/*` branch). A project
  sets them in its launcher to match its push/merge model; it does not re-implement the gate.

## What stays project-side

A project keeps guards for concerns Kyklos does **not** own — its own domain discipline (e.g. GUI-test
completeness, a poll-rate limiter, a DB-mutation guard). Generic discipline that *should* apply to every project
(e.g. no-parallel-tests, process-cleanup-after-test) is migrated **into** Kyklos (bound to the
`mcp__KyklosBridge__(run_tests|build)` matcher) so every project inherits it; the project then deletes its copy.
Until such a guard is lifted, the project may keep it — the rule above forbids duplicating an **owned** concern,
not owning a concern Kyklos lacks.

## Migration checklist for a consuming project

1. Delete the project's own guard for each **owned concern** in the table above.
2. Remove any `bugfix/` allowance from `CLAUDE.md` / `AI_TOOLS.md`; canonical prefixes are
   `feature|release|hotfix|support`.
3. Point any remaining project hook at `$KYKLOS_STATE_DIR` (default `/tmp/kyklos-state`); delete any
   second state dir.
4. Ensure only **one** continuation guard exists (Kyklos's) and that `CLAUDE.md` names the canonical
   context files a reader must load.
5. Set the push/merge switches in the launcher to match the push/merge model (see the headers of
   `kyklos-no-push-guard.sh` and `kyklos-merge-green-guard.sh`).
