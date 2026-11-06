---
name: using-the-bridge
description: How the agent uses the KyklosBridge — the host-side MCP server that runs real builds/tests on the developer's machine (the container's "eyes and hands"). Use whenever you are about to build or test, need host-side actions the sealed container cannot do (drive a GUI, kill a stuck test host, inspect host processes/files), or need to tell whether the bridge is wired. Names the exact `mcp__KyklosBridge__*` tools, when they fire, and the raw `dotnet test` fallback when the bridge is absent.
---

# Using the KyklosBridge

The container is sealed: no host SDK, no GUI, no host process access. Anything that needs the real
host — building/running the solution, running the tests, killing a stuck test host, inspecting host
files/processes — is done by the **KyklosBridge**, an HTTP MCP server that runs on the host and is
exposed to the container as MCP tools. The `running-tests` and `measuring-test-coverage` skills, and the
enforcement hooks, all bind to these tools.

## Is the bridge wired?

Run `claude mcp list` — if a server named **`KyklosBridge`** is listed (connected), the tools below are
available and you should PREFER them over shelling out. If it is absent, see **No bridge** below.

## The tools

All are invoked as `mcp__KyklosBridge__<name>`. The **contract tools** the hooks/skills bind to are `run_tests`,
`build`, `cleanup`, `get_status` (`McpDispatcher.HookContractToolNames` in the bridge). Each tool's arguments,
defaults, limits and refusals are in the tool description the bridge serves with it; read that, not a copy. This
skill says only which tool to reach for:

| Tool | When to use it |
|------|----------------|
| `run_tests` | Whenever you run tests (the `running-tests` protocol). Pass `story` to collect coverage and the Test Discipline token in the same run. |
| `get_coverage` | Measuring coverage (the `measuring-test-coverage` protocol). |
| `get_mutation` | Reading a mutation score off-CI, when `mutation-due.sh check` says a run is due. |
| `get_job_result` | Collecting a run that answered `pending=true`. |
| `build` | Verifying a change compiles (solution-wide, so every analyzer runs). |
| `publish` | Producing a self-contained build of one project (`dotnet publish`) into the git-ignored `Publish/` folder of the tree. |
| `get_status` · `list_jobs` · `cancel_job` | Seeing whether the bridge is idle, who is using it, and abandoning YOUR run (never another session's). |
| `get_failures` · `get_logs` | Investigating a red or hung run (pass your own `runId`). |
| `cleanup` · `kill_process` · `restart` · `stop` | Bridge-wide operations (stale build output, a stuck test host, a wedged bridge). Never from a fork. |
| `list_files` · `copy_file` · `list_processes` · `diag` | Host-side inspection the sealed container cannot do. |
| `host_app_start` · `host_app_request` · `host_app_status` · `host_app_stop` | Work that needs the project's own app running on the host for a while. |
| `launcher_get` · `launcher_request` | Testing or driving the host's KyklosLauncher page and API. |
| `mode_get` · `mode_end` | The operating modes the person at the host set in the bridge GUI (for example `ci-unavailable`: arm, merge and close are queued, other CI verbs answer at once, so do not poll or wait for CI). `mode_end` (`mode`, `reason`) ends a mode early once you see CI answer; you can never set or extend one. |
| the `story_*`, `proof_*`, `advreview_*`, `coordination_*`, `epic_*` verbs | Called for you by the `story`, `advreview` and `agent-msg` tools; see their skills. |

**From the shell: the `bridge` command.** The read-only verbs (status, logs, failures, jobs, diagnostics, coverage
scoring, and, when the bridge has them, the story and CI reads) are also reachable from a shell or a script, with no
GitLab token: `bridge` lists the ones this bridge offers, `bridge <verb> '<json-arguments>'` calls one and prints its
answer (`bridge --json ...` prints the whole result instead; exit 0; 1 = refused or the verb reported an error;
2 = bad arguments or no bridge; 3 = no answer). It goes
through the bridge's `front_door` verb, and the BRIDGE decides what is read-only: `kill_process`, `cleanup`,
`restart`, `stop`, `copy_file`, the run verbs, the secret verbs and every story or CI write are refused, whatever the
command line says.

**GitLab issue reads without a token.** When the bridge has its coordination stack, the reads the Kyklos guards
need go through it with the bridge's own token: `coordination_issues` (issues of a project, a group or the instance, by
labels), `coordination_notes`, `coordination_label_events` and `coordination_whoami`. Use them (through
`hooks/lib/coordination-read.sh` in a script) instead of a `curl` with a token: once a project's API token is host-only,
the bridge is the only way to read GitLab, and a script that still reads it directly logs
`[kyklos] direct-token fallback: ...` while a bridge without these verbs is in use.
**The next work.** `next_work` (with `project`) answers what to work on next in that project, in the order of the
corporate policy's "Choosing the next work" rule, with a reason per issue, the issues missing a severity and what each
blocked issue waits on; issues set aside or someone else's are listed by name, never offered. It is read-only and
served whatever the project's story-stack mode.
**Epics** are changed only through the story tool's epic commands; see [`ssdlc-story`].

The `story` tool follows the same rule by itself: with no GitLab token of its own it reads through `story_read`
(issues, notes, events, labels, milestones, merge requests of the story project) and writes through the story verbs,
so it keeps working once the project's API token is host-only.

**Which tokens the agent can still read.** At launch the Kyklos reports the scopes of every GitLab token the
agent can read (names and scopes only; `hooks/kyklos-api-scope-surface.sh`, whose header names its off-switch).
`hooks/lib/api-scope-check.sh` gives the same report on demand; its header lists its options.

`kill_process` only kills names on the bridge's allow-list and never PID 1 or itself — so you cannot
accidentally take the host/container down by killing an init or keepalive process.

## When they fire

- **Building / testing** — the `running-tests` protocol drives `run_tests` (then `get_status`,
  `get_failures`, `get_logs` on a red run); `measuring-test-coverage` drives `get_coverage` (the labeled
  single-TFM slice). Prefer these over a raw `dotnet` shell-out whenever the bridge is connected.
- **Clearing a stuck run** — `cancel_job` stops a run in flight and names any process that survived. For a
  survivor of a FINISHED run, `kill_process` with that run's id ends the processes the bridge recorded for
  that run, and nothing else (`list_processes` marks them `this bridge, run <id>`); then `cleanup`, then
  re-run. A process marked `not this bridge` is never yours to stop.
- **Host-side inspection** — `list_files` / `copy_file` / `diag` for files and config the sealed
  container cannot reach.

## Forks and parallel sessions

A session may spawn forks or subagents that each work on a different story in their own git worktree. They
all share **one** bridge: one host process per project, one solution root, one run at a time. A separate
worktree does not make bridge runs independent. Rules for any session that forks:

- **Verify a fork's change through CI on its own branch.** Without a `tree` argument the bridge builds and tests
  its own solution root. It cannot see a worktree the container created elsewhere (such as the scratchpad), so a
  run verb for such a worktree is refused rather than silently checking the shared code. A worktree created UNDER
  the solution root can be named with `tree=<path relative to the solution root>`; the bridge then runs there.
- **The parent owns bridge-wide operations.** `cleanup`, `kill_process`, `restart` and `stop` act on every
  session sharing the bridge and can wreck a run another session has in progress. A fork never calls them.
- **One worktree per fork; never switch a shared checkout.** A fork creates its own `git worktree` and removes it
  when done. It never changes the branch of a shared checkout, and never leaves uncommitted edits in one: other
  sessions read that tree, and the story close gates grade its diff.
- **Pass standing directives into every fork prompt.** A fork does not see the parent's conversation, so repeat
  the rules the user has already settled (for example: re-measuring coverage is zero-risk and never needs
  permission) and the always-stop items.

Two hooks back this up; each one's header states what it refuses or warns about and its settings:
`hooks/kyklos-fork-bridge-surface.sh` (a bridge run verb called from a different git tree without `tree`) and
`hooks/kyklos-shared-checkout-surface.sh` (uncommitted or stray work left in a shared checkout).

### Fork-prompt snippet

Paste this into the prompt of any fork or subagent that will build, test, or close a story:

```
Shared-state rules for this fork:
- Work in your OWN git worktree (git worktree add ...); never switch a shared checkout's branch and never
  leave uncommitted edits in a shared checkout. Remove your worktree when done.
- Verify your change through CI on your own branch. Do NOT call the KyklosBridge build / run_tests /
  get_coverage / get_mutation for a worktree outside the solution root: the bridge cannot see it and refuses.
- NEVER call the bridge's cleanup, kill_process, restart or stop: they affect every session. Leave them to
  the parent session.
- Re-measuring coverage (re-running tests or a pipeline, merging cobertura, recomputing CRAP) is zero-risk:
  just do it, never ask.
- Never print a secret value.
```

## Secrets

When a project's launcher serves secrets through the bridge, the values are not in the container environment:
`KYKLOS_BRIDGE_SECRETS` lists the names the bridge serves. Read a value inside the ONE command that uses it, and
hand a header to curl on its stdin so it never appears in the process list:
`printf 'header = "PRIVATE-TOKEN: %s"\n' "$(bridge-secret NAME)" | curl -K - ...`. `bridge-secret` asks the bridge
first and falls back to an environment variable of the same name, so the same command works in every project. Never
echo a value, store it in a file or variable that outlives the command, put it in a message, or run a command that
handles one with shell tracing (`bash -x`, `set -x`): a trace prints every expanded value. In hooks and skills, call
GitLab through `gitlab_curl NAME <curl args>` (`hooks/lib/gitlab-curl.sh`), which takes the setting's NAME, switches
tracing off while the value is in scope and sends the header on stdin; the test suite refuses a token header on a
curl command line and a secret copied into a variable.

## No bridge

When `claude mcp list` does not show `KyklosBridge`, `dotnet test` and `dotnet build` run in the container only when
the project declared `BUILD_EXECUTION=local` (the `running-tests` skill; `hooks/kyklos-build-execution-guard.sh` refuses
a local build otherwise). The `running-tests` discipline is unchanged and the zero-failures gate fires on both paths.
