---
name: running-tests
description: Protocol for running, investigating, and reporting .NET tests. Use whenever you are about to run tests, have changed code and need to verify it, are investigating a failing or flaky test, are deciding whether a failure is "pre-existing", or are about to report results — even when the user only says "run the tests", "check this passes", "why did this fail", or "is it green". Runs via the KyklosBridge MCP if it is configured, otherwise `dotnet test`.
---

# Running Tests

## Build channel — interviewed once (`BUILD_EXECUTION`, no default)

Before you build or test, this project must have declared HOW it builds — the `BUILD_EXECUTION` knob. It is read
from the session's environment first (the KyklosLauncher passes the project configuration's `BUILD_EXECUTION` there),
then from `.claude/standards.env`; a value in the environment wins. It has **no default**: a project that declares it
nowhere (no value in the environment, no file) is blocked from a local build until it does. Ask ONCE, persist the
answer, and reuse it every time.

```bash
bash "$CLAUDE_PLUGIN_ROOT/skills/running-tests/has-build-execution.sh" .claude/standards.env   # exit 0 = configured, 1 = interview
```

If unset (exit 1), ask the developer the single question and write the answer:

> **Do this project's builds/tests run via the KyklosBridge (the real host), or locally in this
> container?** → `BUILD_EXECUTION=bridge|local`

- `bridge` — every build/test runs on the host via the KyklosBridge; a local `dotnet build`/`test` in this
  container is **blocked** (it does not see the host SDK and fails on host-only target frameworks). The
  build-execution guard enforces this and `record-slnx-green.sh` routes the full-solution build to the bridge. A build that outlasts the bridge's bounded wait
  (pending + job id) is collected with `get_job_result`, polled once a minute for up to an hour
  (`RECORD_SLNX_GREEN_POLL_SECONDS`, `RECORD_SLNX_GREEN_WAIT_SECONDS`); a wait that runs out records nothing and exits non-zero. Run the recorder in the background (Bash `run_in_background`) or with the maximum tool time limit: a foreground Bash call is cut at 120-600 s.
- `local` — builds/tests run locally with `dotnet` in this container.

Persist it once to `.claude/standards.env` (e.g. `BUILD_EXECUTION=bridge`); it is runtime-editable, so a
later change needs no container restart. A project launched by the KyklosLauncher can set it in its configuration
instead; that value reaches the session's environment at the next launch and takes precedence over the file.

## Local strong-name builds — `InternalsVisibleTo` / CS0281 (secret-free)

If a build/test fails with **`error CS0281: Friend access was granted by '…', but the public key of the output
assembly ('') does not match … InternalsVisibleTo`**, the project is strong-named: its csproj declares
`<InternalsVisibleTo Include="…Test" Key="<public key hex>"/>`. CI signs with the real private key (from a CI
variable); locally there is no key file, so the unsigned build fails the friend-access check. Do **not** hunt for a
private key or a `.pfx` — you don't need one.

Build with the compiler's **PublicSign** mode, which marks the output strong-name-signed using ONLY the **public**
key already embedded in the csproj — no signature, no secret. The helper extracts that key and emits the flags:

```bash
# print the flags (reuse with any dotnet verb):
$(bash "$CLAUDE_PLUGIN_ROOT/skills/running-tests/public-sign-local.sh" src/Foo/Foo.csproj)
# -> -p:SignAssembly=true -p:PublicSign=true -p:DelaySign=false -p:AssemblyOriginatorKeyFile=/tmp/…snk

# or run the build/test directly (clean bin/obj first if a prior unsigned build is cached):
bash "$CLAUDE_PLUGIN_ROOT/skills/running-tests/public-sign-local.sh" src/Foo/Foo.csproj --test Foo.sln
```

Both the analyzer and its test assembly then carry the same org public key, so the friend check passes. `Foo.csproj`
is the project that *declares* the `InternalsVisibleTo` (the granting assembly). The same recipe closes the local↔CI
build-parity gap that lets a sign-only error (CS0281 / CS1726) slip past a local/bridge build and only surface in CI.

## How to run

If the **KyklosBridge** MCP is configured (check with `claude mcp list`), use its tools (`run_tests`,
`get_status`, `get_failures`, `get_logs`, `cleanup`) — prefer them over shelling out. `dotnet test` runs directly
in the container only when the project declared `BUILD_EXECUTION=local` (see *Build channel* above). Either way the
discipline below is identical; the
`zero-failures-gate` hook fires on both. The tools, when they fire, and the fallback are detailed in the
[`using-the-bridge`] skill.

## Run the full solution, filter the tests

Build/test the **whole solution** (`.sln`/`.slnx`), never individual projects: solution-wide analyzers
only run on the full graph, so a per-project build hides real errors. Build in **Release** unless you
specifically need Debug. Then narrow the *tests* with `dotnet test --filter` syntax — run only what your
change touches:
- single fixture: `--filter FullyQualifiedName~BaselineServiceTests`
- a namespace: `--filter FullyQualifiedName~Classification`
- everything: (no filter)

## One run at a time

Never run your own tests concurrently: not two runs of your project, fixture or test at once. Overlapping runs
of the same project contend for the same resources (ports, files, DBs, devices) and produce results that are
neither reproducible nor meaningful. Your bridge's run gate keeps your own runs one at a time.

Runs of different projects MAY run in parallel on a shared host: each bridge serves its own project. Before a
new run, check `list_processes`: block only on a process it marks as `this bridge` (a leftover of your own run).
A process marked `not this bridge` (another project's test host, a person's process) is reported with its pid,
start time and command line, and never blocks your run.

This holds across forked sessions too (the managed policy's Testing section, "Forks share one bridge"; details in
[`using-the-bridge`], "Forks and parallel sessions").

## "It builds" is not "it passes"

After any code change, run the tests that cover it before reporting the task done. A change is not
complete until those tests are green.

## Investigating failures — the part that matters most

**There are no pre-existing failures.** If a test fails or a behaviour regresses, the default assumption
is that YOUR change caused it — you either broke it or implemented it poorly. This default exists because
"it was already broken" is the easiest way to wrongly declare victory, and it is almost always wrong.

To claim a failure predates your work you must *demonstrate* it, not assert it:
1. `git stash` your changes.
2. Run the same failing test against the clean tree (same filter).
3. Show the output.
4. `git stash pop`.

If it fails on the clean tree too, it is genuinely pre-existing — say so with that evidence attached. If
it passes clean, it is your regression: fix it. The last commit on the branch is the baseline. Failing or
flaky tests are never ignored, rerun-until-green, or waved through — a failure always has a cause (an
ill-conceived test or fragile logic; both are bugs). Fix the real one.

**`git stash` is for diagnosis, never exemption** — what a demonstrated pre-existing failure then requires is the
managed policy's Tier-0 rule "No unexplained failures" (the `kyklos-zero-failures-gate` hook enforces it).

## Long-running suites

If a run may exceed the tool timeout, launch a background monitor **and** actively re-poll yourself
(~once/min) — do not disappear for the whole run trusting a single notification. When it ends, re-confirm
the outcome with a fresh status/logs check rather than a captured summary line.

## Writing tests (when the task needs new ones)

- AAA structure (Arrange / Act / Assert); assert the actual observable outcome so the test can FAIL when
  the behaviour breaks (never `Assert.Inconclusive`/`Ignore` to dodge a red — the `test-quality-guard`
  hook blocks that).
- The test environment must replicate production; share configuration/data between production and test so
  behaviour cannot diverge.
- Settings validation: a default-constructed settings object must FAIL `ValidateDataAnnotations(recursive:
  true)`; real values must pass.
- The isolated unit test is the ground truth.
- Locate GUI elements semantically (`GetByRole`/`GetByText`/`GetByLabel`), never by position (`.Nth`,
  `nth-child`) or layout CSS class.
