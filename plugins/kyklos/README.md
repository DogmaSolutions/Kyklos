# kyklos

Engineering discipline for AI coding agents: enforcement hooks and skills that check tests, reviews, branching
and proof before work counts as done (mechanisms only; project specifics live in each project's `.claude/standards.env`).

> **One owner per concern.** Kyklos owns the baseline guards; a consuming project deletes its
> duplicate rather than double-blocking. The ownership table and escape paths are in **[`GOVERNANCE.md`](GOVERNANCE.md)**.

> **New here?** Start with the workflow guide, `docs/WORKFLOW.md` at the root of the marketplace repository: how the
> Kyklos turns an agile Secure SDLC into an enforced GitLab workflow (stories, labels, phases, the hooks that enforce
> them, the Kyklos Bridge and the Proof Table).
> This README below is the mechanism-level companion.

## Ships

- **Commands on PATH** (`bin/`) — Claude Code puts the plugin's `bin/` on PATH, so the CLIs the skills and hooks name
  work as bare commands: `story`, `agent-msg`, `advreview` and `bridge`. They are one shim (`bin/story`; the other
  three are symlinks to it) that runs the real CLI next to its skill and fails with exit 127 when that CLI is missing.
  `bridge` lists the KyklosBridge's read-only verbs and forwards a call to one of them (`bridge <verb> '<json>'`)
  through the bridge's `front_door` verb, which refuses every verb that writes or acts on the host.
- **Hooks** (`hooks/*.sh`). Which hook runs on which event is `hooks/hooks.json`. Each hook states its own behaviour,
  its settings, its default and its one-shot override in its header comment; read the header, not a copy of it. The
  per-project settings are listed in `standards.env.sample`, the one-shot overrides in `hooks/lib/override-marker.sh`.
  What each hook is for:

  | Hook (`kyklos-` prefix dropped) | What it enforces |
  |---|---|
  | `gitflow-branch-guard` | GitFlow branch names, no edit or commit on a protected branch, a story-named branch, a Conventional-Commits inline `-m` message |
  | `commit-message-guard` | the commit subject, the `Refs:` footer (one item per branch: a story branch cites only its story) and no AI attribution, at commit time |
  | `no-push-guard` | `git push` only where the container is authorised to push, and only a branch whose commits cite one item |
  | `branch-cleanup-guard` | a finished branch is closed (merged and deleted) by the declared close mode |
  | `merge-green-guard` | no merge of a feature or hotfix branch into a trunk unless its pipeline is green, looked up in the project the merged repository's origin belongs to (a companion's nested source project, not the default one); its refusal names that project and the override that is honoured |
  | `mr-hands-off-guard` | a story merge request is armed when created and never merged by hand |
  | `automerge-coverage-guard` | no auto-merge arming on changed production C# unless the content ledger shows every changed C# line run at that commit (or a valid Test Discipline token), plus the merged-result check (the rule itself lives in `hooks/lib/merged-result.sh`) |
  | `slnx-green-guard` | no push of a branch touching a solution without a recorded green full-solution build (`hooks/lib/record-slnx-green.sh`) |
  | `script-lint-guard` | the script formal check (`hooks/lib/script-lint/`) on the scripts a pushed branch changes |
  | `public-push-artifact-guard` | no AI/agent artifact pushed into a public source repository |
  | `public-source-refs-guard` | no internal tracker reference written into a public source or another repository |
  | `source-readonly-guard` | no commit-creating git verb in a source declared read-only for the agent |
  | `rm-critical-path-guard` | an `rm` on a critical path is refused at once, naming the safe forms |
  | `piped-script-guard` | a script fetched from the network and run in the same command without being saved first (`curl ... \| sh`, `wget -qO- ... 2>&1 \| bash`, `curl ... \| tr -d '\r' \| bash`, `bash <(curl ...)`, `sh -c "$(curl ...)"`, `curl ... \| python3 -`, `curl ... \| pwsh`, also behind sudo, su -c, env or a shell's `-c`) is refused, naming the fix: download to a file, read it, then run it. Package installs (apt, pip, npm, gem, dotnet tool, cargo, go), a download saved to a file and a download piped into a program that reads it as data (`curl ... \| jq .`) pass. Off switch `KYKLOS_PIPED_SCRIPT_GUARD=off` (audited). What it does not catch is listed below the table |
  | `ask-first-guard` | a change that switches a workflow control off, weakens it or switches a grant on (an edit of `.claude/standards.env`, a shell write to it or to another settings file, or the switch given inline to a command) is asked of the user in Claude Code's own permission dialog; an approved change posts one audit note on the story being worked. The controls are derived from the code (`hooks/lib/control-inventory.sh`); a change it cannot read, and a check that cannot run (broken install, unreadable input, unknown tool), is refused at once with what to write instead, never put to the user (an unattended agent must not wait on a dialog; a plain search of a switch's name with grep or jq passes silently); only a readable loosening is asked; a loosening it did not ask about is put back after the call and the turn is blocked (the backstop, `hooks/lib/ask-first-snapshot.sh`). Off only by `KYKLOS_ASK_FIRST=off` in the environment the launcher starts Claude Code with |
  | `standard-config-guard` | no credential-bearing connection string in code, and no plaintext secret (a password, key, token or credential, unless the whole value is a placeholder) in a config file (appsettings, local overlays, secrets.json, sample copies); a key path that holds no secret is declared once in `KYKLOS_CONFIG_SECRET_ALLOW_KEYS` (standards.env, audited). It judges what the Edit, Write and MultiEdit tools write; a file written by a shell command (a heredoc, tee, cp, sed -i) is not seen by this guard |
  | `test-quality-guard` | no regression-hiding test anti-pattern |
  | `zero-failures-gate` | progress stops after any test run that reports failures |
  | `build-execution-guard` | builds and tests run the way `BUILD_EXECUTION` declares (bridge or local) |
  | `scenario-gate` / `scenario-init` | a valid working scenario before build or test in a scenario-enabled project; first-run seeding |
  | `tool-first-guard` / `tool-catalog-surface` | a story issue's lifecycle runs through the `story` tool; the capability catalog at session start |
  | `agent-msg-guard` | coordination issues only through `agent-msg`; no issue created by a raw API call (a POST, or a write whose method it cannot see, to an issues collection, or a GraphQL `createIssue`/`workItemCreate` mutation or GraphQL write whose document it cannot see; a note, a note edit or a PUT is no creation; a placeholder that ends the route, such as `/issues/$E`, is the collection) |
  | `inbound-issues-guard` / `inbound-monitor-init` | a coordination issue with the ball in your court is answered before the turn ends; the idle monitor |
  | `epic-gate-guard` | an epic (GitLab milestone) is changed only through the epic verbs |
  | `proof-table-guard` | a proof table is written only through `story proof` |
  | `story-close-guard` | no raw-API close of a story issue without a clean proof table |
  | `story-proof-guard` | the final Done gate: no close with an UNPROVEN Quality Dimension, the tool-gate tokens, close-on-green |
  | `story-structure-guard` | a story carries the required structure items |
  | `story-start-guard` / `story-before-coding-guard` | no substantial work without an active, ready story |
  | `story-backlog-guard` | In-progress means somebody is working on it |
  | `story-mirror-edit-guard` / `story-mirror-refresh` / `story-mirror-commit` / `story-mirror-stale-surface` | the on-disk `Stories/` mirror of GitLab: read-only, refreshed, committed, stale reads surfaced |
  | `phase-advance` | a story's `ssdlc:phase::` advances as the real work happens |
  | `proof-show-nudge` | after a `story close`, show its proof in the reply |
  | `continue-guard` / `ask-user-guard` | no unmotivated stop on the agent's own or unassigned work (another user's issues are listed as owned elsewhere); no question that is not a genuine always-stop decision |
  | `idle-work-nudge` | use a long pipeline wait for independent work |
  | `session-continuation-guard` | `CLAUDE.md` is re-read periodically |
  | `session-boundary-stamp` | records the session start for the close-time gates |
  | `infra-persistence-guard` | reminds to record a created token, or a rule written to volatile notes, in the repository |
  | `fork-bridge-surface` | a bridge run verb from another git tree must name its `tree` |
  | `override-bind` | a one-shot override belongs to the agent that set it |
  | `mutation-timing` | advisory: whether a mutation run is required or due (`skills/measuring-test-coverage/mutation-due.sh`) |
  | `clone-staleness-surface` / `fetch-latest-surface` / `shared-checkout-surface` / `api-scope-surface` | session-start notices: a stale plugin clone, branches behind their upstream, work left in a shared checkout, the tokens the agent can read |

  Ask First works in two layers. The FIRST layer reads each command or edit before it runs and asks the user, so the
  user chooses up front. It judges each statement on its own: a statement that names no settings file (`git branch`,
  `git push`, `base64`, `story ...`) is not judged, and one that only reads the file (`grep`, `cat`, `git add`,
  `git commit`) is no change. The `.claude` folder rules apply to the workspace's own `.claude` folder only, never to
  the user's `~/.claude/projects` or plugin cache. It asks for: a settings file written by any program other than echo, printf, cat, tee, sed,
  mkdir and touch, or with text taken from another file or produced by another program (`git show`, `sort -o`, ...);
  an expansion, an escape other than `\n` and `\t`, a printf format other than `%s\n`, or a name assembled from quoted
  pieces in the written text; a line written in pieces (`echo -n`, a format that does not end the line, an append to a
  file without a final line break); a switch set without a plain NAME=value (read, printf -v, let, a nameref, export of
  a bare name, `${NAME:=...}`, `+=`); a switch named in code it cannot read (python, perl, node, awk, ksh, busybox, ...);
  a settings file or the `.claude` folder reached through another command (a shell's `-c` string, a string piped into a
  shell, `eval`, `xargs`, `find -exec`, `env -S`, ssh, docker exec, ...); a program that copies, moves, links, unpacks,
  patches, restores or edits in place on the `.claude` folder (`cp -r prep/. .claude/`, `rsync`, `tar -C .claude`,
  `unzip -d .claude`, `cpio`, `git checkout`/`git restore` of the folder); a switch written to a file named by a pattern
  or an expansion; a crash anywhere in the check, an input it cannot read as JSON, and a tool it does not know. A sed
  program that rewrites `.claude/standards.env` in place is judged by its effect: it runs on a copy (`sed --sandbox`)
  and the switches before and after are compared.

  What the first layer cannot read before the call (listed in `hooks/lib/ask-first.sh`): a settings file named through
  a glob, a variable or an encoded name; a script written now and run later, or a shell started with `BASH_ENV` or
  `ENV` naming one; a bulk rewrite over files listed at run time (`git ls-files | xargs sed -i ...`); whole-tree git
  and patch commands that bring in another version of the file (`git checkout <branch>` or `-- .`, `git restore .`,
  `git merge`, `git cherry-pick`, `git rebase`, `git stash pop`, `git reset --hard`, `git apply`, `git am`, `patch`);
  an unpack in place that names no file (`cpio -idm < archive`); an edit of any other file, or of a link made earlier
  to the settings file under another name. The SECOND layer, the backstop (`hooks/lib/ask-first-snapshot.sh`), covers
  these: it keeps ONE baseline of the settings file per workspace in a private state folder outside the workspace, and
  compares the file with it, by the hooks' own parser and only on the lines that name a switch, at the pre and post step
  of every Bash, Edit, Write, MultiEdit and NotebookEdit call (and at `PostToolUseFailure`, for a call that failed). A
  harmless change (another key, a tighter value) becomes the new baseline; a loosening moves it only when the user
  confirmed it, and only for a FILE change the question named whose final switch and value match it exactly (the post
  step of the call Ask First asked about); a switch given inline to one command never authorises a change of the file.
  Any other loosening the same call made is put back, switch by switch (the rest of the change stays), and the turn is
  blocked naming what was put back; a question the user declined never lets its change into the baseline. Known limit:
  a question about a change it could not read (an "unreadable change" line, such as `cp` of a prepared file) confirms
  the whole resulting file, whatever it holds, because the user approved a change whose content the question could not
  show. Any other loosening is put back from the baseline at
  once (a link put in place of the file or the folder is undone too, and so is any change to the lines that hold a NUL
  or another control byte, which is never read as a harmless change; switches are compared as the hooks' parser reads
  them, NUL bytes dropped) and the call is refused or the turn blocked, with
  a message naming the switch, its old and new value and the command. A harmless call that overlaps a confirmed one
  never undoes the confirmed change (a loosening that a call asked about in the last ten minutes names exactly is left
  to that call's own post step). A baseline that cannot be written refuses the call; a file that cannot be put back
  blocks the turn, saying so. Known limits of the backstop, both to be closed by a baseline held by the host bridge,
  out of the agent's reach: a command that deliberately rewrites the hook's own state folder can move the baseline;
  and a writer left running in the background that changes the file after the post step is caught only at the next
  pre or post step. The same exact change by another route within ten minutes of a question the user declined waits
  for those ten minutes before it is put back. Not covered by either layer: a switch set only in the environment of a later command (`source` of a
  file written earlier, a name assembled from pieces such as `n=NAME; export $n=0`), numeric thresholds (a coverage
  floor, a CRAP ceiling), and a guard's own inline variable that is not read through `kyklos_control_off` (such as
  `STORY_ALLOW_JUNK_SLUG=1 story new`), which is no derived control.

  **What the piped-script guard does not catch.** The guard reads the command text before it runs
  (`hooks/lib/piped-script.sh`) with the shared command normaliser: quotes and backslashes inside a word are removed,
  the text of a quoted string the shell may run (a shell's `-c`, `eval`, PowerShell's `-Command`, an echo piped into
  a shell) is read as a command of its own, a `|`, `;`, `&`, `(`, `)` or backtick inside a quoted string that is only
  text (a commit message, `x="..."`, an address holding `&`, the program of `python3 -c '...'`) splits nothing, a
  comment is dropped (`curl u | bash # run` is still refused), a quoted string that goes on over several lines is one word (`python3 -c '<newline><program>'` reads its
  input as data; a quote that never closes hides no later line), redirections are not arguments (`2>&1`, `>&2`,
  `&>f`, `> log`; `|&` is a pipe), a line ending in `|` continues on the next line, and a plain-text here-document
  body (a quoted closing word, no shell on its line reading it; a body handed to another language's interpreter is that language's code) is data. A download
  counts at every later stage of its pipeline (`curl u | tr -d '\r' | bash`), also out of a `( ... )` or `{ ...; }`
  group; `bash -n` (a syntax check) is not a run. The command run by a wrapper is read, with or without a directory
  (sudo, su -c, env, timeout, nice, xargs, `xargs -I{} sh -c '{}'`, a `find -exec`, GNU `parallel` and the others listed
  in that file). A command word computed when the command runs, or held in a variable (`| $SHELL`), is refused only
  when a download is piped into it; a variable assigned a download and run later in the same command
  (`x=$(curl u); eval "$x"`, `sh -c "$x"`) is refused; an output process substitution (`| tee >(sh)`) is a stage of
  the pipeline; an inline program that hands its own input to an evaluator (`python3 -c 'exec(open(0).read())'`) runs
  the download; lua, `deno run -` and `awk -f -` are interpreters too. A download reaches only programs known to read
  it as data (an allow-list in that file: jq, grep, head, tail, cut, tr, wc, sort, uniq,
  checksum and archive tools, tee, and a shell's read, whose variables are followed into a later eval); every
  interpreter and shell receiving it is refused, with one narrow exception: a small inline program that only parses the
  JSON on its input (python `-c` importing nothing but json and sys and calling `json.load(sys.stdin)`, node `-e` using
  only `process.stdin` and `JSON.parse`, with no exec, eval, require, import, getattr, open, os or subprocess) is a reader
  of data and passes (read other data with `| jq ...` or from a saved file); so is refused any other program, a command reached through `sh -c`, `eval` or
  `xargs`, sed and awk (programmable), a compound command (`| while ...`, `| if ...`, `| { ...; }`), and a variable
  such as `$0`. A download saved to a file and run later is out of scope by design: saving first is the remedy.
  `env -S` / `--split-string` carries the command. It does not see: a download tool or shell called
  through an alias, a function or a variable (`$FETCH u | sh`); a script saved to a file and run
  later (this is the intended way); a download run by a program's own code (`python -c "import urllib..."`); a fetcher
  it does not know (only curl, wget, iwr, irm, Invoke-WebRequest, Invoke-RestMethod and a WebClient call); a group
  whose download is followed by another command inside it (`(curl u; echo) | sh`); a stage that runs its input as code
  but is not a shell, an interpreter (python, node, perl, ruby, php), PowerShell, `su`, `iex` or a shell's `-c` (for
  example `at`, `ssh host`, `script`, `expect`); an interpreter option that takes a value and is not listed in that
  file. It is a deterrent, not a sandbox. Off switch: `KYKLOS_PIPED_SCRIPT_GUARD=off` (audited).
  A static check of shell text cannot follow names computed at run time in general. For the tools whose behaviour an
  environment variable changes (tar, bsdtar, rg, the grep family, less, more) the guard is conservative: a download
  piped into one of them is refused when the name of a variable that tool reads appears anywhere in the command, when
  the command sources a file, or when it contains `eval`, an expansion where a variable name stands (`${v}OPTIONS=`,
  `export "$(...)=..."`, `env "$(...)"`), or an escape sequence such as `\x54`. Beyond that listed coverage the guard
  promises nothing: it is a deterrent, not a sandbox.

  **Which CI project a lookup reads.** Every pipeline, job, artifact and merge-request lookup of the guards and skills
  passes the origin address of the repository the branch or number belongs to (`hooks/lib/ci-access.sh`), and the
  Kyklos Bridge reads the configured project that repository belongs to; through the bridge, a repository without an
  origin, or of a project the bridge does not serve, is refused by name rather than read in the default project. The
  close-on-green gate judges the branch in every repository that holds it (all must be green); a branch no repository
  holds is judged in the project's only repository, and refused by name when there are several. A
  test (`hooks/tests/test-right-project.sh`) fails when a call site omits the repository. Limits:
  - The declared direct-token exception (`KYKLOS_CI_DIRECT_TOKEN=1`) still reads the one project it declares
    (`KYKLOS_CI_PROJECT_ID`), whatever repository a lookup names.
  - The launcher serves one nested source project per companion (the one `KYKLOS_PUSH_REPO_URL` names); a
    companion with several nested source repositories gets the others' lookups refused as "not served" until they
    are added to the bridge's `ContinuousIntegration` projects.

  Two shared pieces are not hooks of their own: the close and merge gates read the pipeline's `ai-review` job through
  `hooks/lib/ai-review-verdict.sh`, and every CI read goes through `hooks/lib/ci-access.sh`. The C.R.A.P. score and its
  triage ledger are the bridge's (`bridge/README.md`).
- **Skills** — `poka-yoke`, `running-tests`, `measuring-test-coverage`, `using-the-bridge`, `ssdlc-agent-msg`
  (the mechanized cross-agent coordination-via-GitLab-issues workflow),
  `ssdlc-repo-model` (declare the repository model once, then every model-aware guard reads it),
  `ssdlc-inbound-monitor` (arm the ~hourly idle monitor that re-runs the inbound-issues check so a late reply
  from another agent is picked up without the user prompting). The **SSDLC story lifecycle**: `ssdlc-story`
  (the `story` tool — new/adopt/set/close + the generated BACKLOG mirror), `ssdlc-story-proof` (the 17
  Quality-Dimension Proof gate + `story-type-profile.sh`), and the per-dimension DOER skills the tool-gate binds
  to — `ssdlc-deduplicate` (Non-Duplication), `ssdlc-i18n` (i18n — promote user-facing strings into the project's i18n resources, with the reusable `scan-strings.sh` candidate scanner), `update-docs` (Documentation), `ssdlc-cysec` +
  `ssdlc-cysec-comments` (the `[CySec]` annotation convention — SOFT by design), `ssdlc-risk-assessment` (the
  RA register), `ssdlc-adversarial-review` (the review the Adversarial Review dimension requires, through the
  `advreview` command), and `ssdlc-ai-fix-loop` (act on an AI-review failure). One skill is **user-only** — `reorient`
  (`disable-model-invocation: true`), the `/kyklos:reorient` command a person runs after a container
  restart to make the agent drop cached assumptions and re-discover the current tools, skills, MCP servers, and
  backlog before resuming.

## The Kyklos Bridge

The hooks' matchers (`mcp__KyklosBridge__*`) bind to the **Kyklos Bridge**, the host-side MCP server that runs real
builds and tests on the developer's machine. How the agent uses it is the `using-the-bridge` skill; what it is, its
verbs and its settings are in `bridge/README.md`.

## Config

All project specifics are externalized to `.claude/standards.env` (see `standards.env.sample`): a plain file the hooks
parse at runtime. No forks: one canonical script + per-project values.

### The Test Discipline token and its receipt

The bridge judges a story's coverage on its story lines (at least 95 % of them run under a test or carry a limit); the
plugin compares no figure with a floor. The proof tool gate sends the receipt format it reads (`version`) with every
`coverage_receipt_check` call, so a receipt newer than the plugin is refused by name (`RECEIPT-VERSION`: update the
plugin) and never read by older rules. The proof CLI writes each token's `.measured` sidecar (the commit each change
fingerprint was measured against, handed in by the bridge) with the token and its `.base` in one step, and its verifier
tries that commit before its own fork point, so a local trunk ref older than the one the bridge fetched no longer makes a
good token stale. The CLI's `changed-lines` is a thin call to the bridge's `story_lines` verb: without a reachable bridge it
fails closed with "bridge unreachable: changed lines unknown" (BRIDGE-UNREACHABLE). The rules themselves are the bridge's
(its README, "Story lines and the token's question").

### Repository model

A project declares its **repository model** once through the `ssdlc-repo-model` skill. The interview records one
**project topology** through `skills/ssdlc-repo-model/topology-declare.sh`, which derives every knob the guards read
(declare once, derive everything) and writes them to `.claude/standards.env` and a `## Repository model` section in
`CLAUDE.md`. The topologies and what each derives are in that script's usage line and in `hooks/lib/topology.sh`; never
hand-set a derived knob. How the gate hooks read CI (bridge verbs first, the direct-token exception) is
`hooks/lib/ci-access.sh`.
