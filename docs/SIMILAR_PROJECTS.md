# Similar projects, and how Kyklos compares

[← Back to the README](../README.md)

Kyklos is not the only project that tries to make AI coding agents safer or more disciplined. Other projects work on nearby problems: some structure how an agent plans its work, some check the code an agent writes, some isolate the agent from the machine it runs on. This page lists the ones we know of, says what each one does in its own words, and compares them honestly with Kyklos. Where another project is better at something, this page says so.

Every description below comes from the project's own page or repository, read when this page was written. Projects change quickly: check their pages before you rely on a detail here. If you maintain one of these projects and something here is wrong, please tell us and we will fix it.

## What Kyklos is, in one paragraph

Kyklos makes a coding agent ([Claude Code](https://code.claude.com/docs)) follow a secure development lifecycle and prove its work. Its parts:

- **Stories.** Every piece of work is a story with a specification: requirements, use cases, failure modes, acceptance criteria and a risk assessment.
- **Proof.** A story closes only when its [Proof Table](PROOF.md) has a verdict for every quality dimension. The verdicts rest on evidence that tools produced: signed tokens and attached reports.
- **Review.** An [independent adversarial review](ADVERSARIAL_REVIEW.md) is run and recorded on the story.
- **Gates.** The [Plugin's hooks](HOOKS_AND_SKILLS.md) refuse a forbidden action at the moment the agent tries it: a commit on a protected branch, a push that is not allowed, a close without proof.
- **The Bridge.** The `Kyklos Bridge` runs real builds, tests and coverage on the developer's own machine and records coverage facts per file. It holds the issue-tracker and CI tokens, so the agent never does.
- **The Launcher.** The `Kyklos Launcher` starts one isolated development container per project.

Kyklos's limits today: it works with Claude Code only, with GitLab as tracker and CI, and with .NET projects for host builds and tests. Windows is its primary platform (see [Current scope](INSTALL_AND_CONFIG.md#current-scope)).

## Spec-driven agent workflows

These projects structure *how* an agent turns a request into code: specification first, then plan, then tasks.

- **[GitHub Spec Kit](https://github.com/github/spec-kit)** (MIT). The project calls itself an open-source toolkit for Spec-Driven Development.
  - Its loop is constitution, specify, plan, tasks, implement, converge. Extensions add commands, quality gates or whole processes (bug fixing, for example), and there are presets and a community catalog.
  - It works with many coding agents. Its catalog and its custom flows are broader than anything Kyklos offers.
  - Its page does not describe gates that refuse an action, builds or tests run by the toolkit itself, or a proof per quality dimension.
- **[Kiro](https://kiro.dev)** (a commercial product). It describes itself as an AI engineering system, available as an IDE, a CLI, a web app and a mobile app.
  - It turns requests into specifications (bug-fix specifications included) and uses property-based tests. It describes workflows that keep agents from skipping failed tests.
  - It runs each task in a fresh isolated clone, locally or in the cloud, and offers parallel agents and hooks.
  - It is a complete product with its own execution environment, and its property-based testing goes further than Kyklos's coverage facts. It is not an open plugin on top of an existing agent.
- **[BMad Method](https://github.com/bmad-code-org/BMAD-METHOD)** (MIT). The project calls itself an open-source framework for planning and building software with AI coding tools, which scales the amount of process to the size of the work.
  - It has specialist agent roles (product, architecture, user experience, development, testing) and workflows from the first idea to a reviewed implementation.
  - Its planning stage is richer than Kyklos's, and it has a light path for small changes.
  - Its README does not describe gates that block a commit or a push, nor builds run on the host.

## Process plugins and modes for coding agents

These projects steer the agent from inside its session, as Kyklos's Plugin does.

- **[Superpowers](https://github.com/obra/superpowers)** (MIT). It describes itself as a complete software development methodology for coding agents, built from composable skills.
  - It covers design, planning, test-driven development, one subagent per task, code review between tasks, worktrees, debugging and verification before completion.
  - It installs in about sixteen agent tools, Claude Code among them. It is much lighter and easier to adopt than Kyklos, and it is the project closest to Kyklos in method.
  - Its workflows are called "mandatory workflows, not suggestions", but its page describes them as instructions to the agent. Its hooks load the instructions at session start, and the page does not describe hooks that refuse an action. It has no proof tokens, no host build server and no launcher.
- **[Roo Code modes](https://roocodeinc.github.io/Roo-Code/basic-usage/using-modes)**. Roo Code's modes are task-specific personas (Code, Ask, Architect, Debug, Orchestrator, and custom ones).
  - Each mode limits which groups of tools the agent may use (read, edit, command, MCP). That is real enforcement, built into the agent itself.
  - Modes do not cover stories, proofs, reviews or close gates.
- **[Aider](https://aider.chat/docs/usage/lint-test.html)** (Apache-2.0). Aider is a terminal coding assistant that works with many models.
  - It loads a conventions file as read-only context and lints the files it edits by default. It runs the tests after each change when it is told how (`--test-cmd` with `--auto-test`), and then tries to fix the failures.
  - Its edit, lint, test and fix loop is simple and direct. The conventions are guidance, the tests are off until configured, and there is no story workflow, review or gate.
- **[OpenHands](https://github.com/All-Hands-AI/OpenHands)** (MIT). It describes itself as a self-hosted control center for coding agents.
  - It runs its own agent or others, Claude Code among them, without a sandbox, in one Docker sandbox, or in one container per conversation. It has a REST API and automations started by a schedule or a webhook.
  - It runs many more kinds of agents than Kyklos, and its automation server has no Kyklos counterpart. Its README does not describe a development lifecycle, proofs or review gates.

## Quality and security scanners for agents

These projects check the *code* an agent writes. They are complements to Kyklos more than alternatives: a Kyklos story can use any of them as the evidence behind a quality dimension.

- **[Codacy Guardrails](https://www.codacy.com/guardrails)** (commercial; a free tier is offered). It checks code, AI-generated code included, against your rules as the code is generated, through an MCP server and a local command-line tool.
  - It looks for secrets, vulnerable dependencies, security flaws found by static analysis, duplication, complexity and style, in many languages.
  - Its set of analysers is far broader than what Kyklos runs itself. It is a scanner, not a process: no stories, no proof table, no review step, no builds or tests.
- **[SonarQube MCP Server](https://github.com/SonarSource/sonarqube-mcp-server)** (SONAR Source-Available License). This is SonarSource's official MCP server, which connects agents to SonarQube Server or SonarQube Cloud.
  - It exposes quality-gate status, issues, security hotspots, coverage, duplication and dependency risks to the agent.
  - SonarQube's quality gates are an industry standard. The server reports results to the agent. It does not stop the agent at commit or close, and it needs a SonarQube instance.
- **[Snyk Studio](https://docs.snyk.io/integrations/snyk-studio-agentic-integrations)** (commercial). It adds security guidance to AI-assisted coding.
  - The agent can run Snyk's code, open-source dependency and infrastructure-as-code scans through a local MCP server.
  - It is backed by a commercial vulnerability database, which Kyklos does not have. It covers security only, with no process or gates on the agent's own commits.

## Agent sandboxes and development-container tools

These projects isolate the agent's *environment*. They overlap with the Kyklos Launcher, not with the Plugin or the Bridge.

- **[NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell)** (Apache-2.0). A runtime that confines an agent to what a policy allows, with network policy per destination and credentials the agent never sees. It has its own section in [the components page](COMPONENTS.md#what-about-openshell).
- **[Claude Code development containers](https://code.claude.com/docs/en/devcontainer)** (Anthropic). Anthropic's reference set-up for running Claude Code in a dev container.
  - It provides a Dev Container Feature that installs Claude Code, managed settings for an organisation's policy, and an example egress firewall.
  - Anthropic presents it as a working example rather than a maintained base image, and warns that, when Claude Code runs in it with its permission prompts skipped, the container does not stop a malicious project from sending out anything reachable inside it. It works with any editor that supports dev containers.
  - The Kyklos Launcher builds on the same Dev Containers tooling. On top of it, the Launcher adds per-project configurations, a check before every launch, credential handling and the wiring to the Bridge. Kyklos does not ship an egress firewall.
- **[Docker Sandboxes](https://docs.docker.com/ai/sandboxes/)**. Isolated environments for agents, local or in the cloud; Docker's architecture guide describes isolation with microVMs.
  - The isolation boundary is stronger than the plain container Kyklos uses. It covers isolation only, not a development lifecycle.
- **[container-use](https://github.com/dagger/container-use)** (Apache-2.0, by Dagger, described by the project as in early development). An MCP server that gives each agent a fresh container and its own Git branch, with a command history you can inspect and a terminal you can step into.
  - It handles parallel agents on isolated branches out of the box. It has no gates, proofs or host-side tests.
- **[E2B](https://github.com/e2b-dev/E2B)** (Apache-2.0). Isolated cloud sandboxes driven by JavaScript and Python SDKs, which can also be self-hosted.
  - It provides sandboxes on demand at a scale Kyklos does not address. It is infrastructure, not a process.
- **[Dev Containers CLI](https://github.com/devcontainers/cli)** (MIT). The reference tool that builds and starts containers from a `devcontainer.json`. The Kyklos Launcher uses it.

## Side by side

✅ covered · ◐ partly covered, or by guidance only · ❌ not covered, or not described on the project's page. "Not described" means the project's own page did not say so. It may exist without being documented there.

| Project | Specs and stories | Proof per quality dimension | Independent review | Gates that refuse an action | Real builds and tests on the host | Isolated environment | Agents supported |
|---|---|---|---|---|---|---|---|
| **Kyklos** | ✅ | ✅ | ✅ adversarial, recorded and checked at close | ✅ commit, push, merge, close | ✅ through the Bridge | ✅ one container per project | Claude Code |
| GitHub Spec Kit | ✅ | ❌ | ❌ | ◐ | ❌ | ❌ | many |
| Kiro | ✅ | ❌ | ❌ | ◐ | ◐ inside its own environment | ✅ a clone per task | its own |
| BMad Method | ✅ | ❌ | ◐ a review workflow | ❌ | ❌ | ❌ | many |
| Superpowers | ◐ plans | ❌ | ◐ a review between tasks | ◐ by instruction | ❌ | ◐ worktrees | many |
| Roo Code modes | ❌ | ❌ | ❌ | ◐ tool limits per mode | ❌ | ❌ | its own |
| Aider | ❌ | ❌ | ❌ | ❌ | ◐ when configured | ❌ | its own, many models |
| OpenHands | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ | many |
| Codacy Guardrails | ❌ | ◐ code quality and security | ❌ | ◐ merge gates on paid tiers | ❌ | ❌ | many |
| SonarQube MCP Server | ❌ | ◐ code quality and security | ❌ | ❌ | ❌ | ❌ | many |
| Snyk Studio | ❌ | ◐ security | ❌ | ❌ | ❌ | ❌ | many |
| NVIDIA OpenShell | ❌ | ❌ | ❌ | ✅ network and file policy | ❌ | ✅ | many |
| Claude Code dev containers | ❌ | ❌ | ❌ | ◐ example firewall | ❌ | ✅ | Claude Code |
| Docker Sandboxes | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ microVM | many |
| container-use | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ a container per agent | many |
| E2B | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ cloud sandbox | many |

## Where others are stronger

- **Breadth of agents.** Almost every project above works with more agents than Kyklos, which supports Claude Code only.
- **Analysis depth.** Codacy, SonarQube and Snyk run far more analysers, over more languages, than Kyklos. Kyklos is designed to use such tools as evidence, not to replace them.
- **Isolation.** OpenShell, Docker Sandboxes and E2B isolate the agent more strongly than a plain development container: network policy per destination, microVMs, credentials kept out of the agent's reach.

## Why Kyklos's combination suits a secure development lifecycle

None of the pages we read describes all of the following together, and a secure development lifecycle (SSLDC) needs all of them at once.

- **Work is traceable.** Every change belongs to a story with requirements, use cases, failure modes and a risk assessment, kept in the issue tracker where people can see it.
- **Claims are proven, not asserted.** A story closes only with a verdict per quality dimension, and the verdicts rest on tokens and reports that tools produced. The agent's word is not enough.
- **Someone else looks.** An independent adversarial review is recorded on the story, and the close checks for it.
- **The process cannot be skipped.** Gates refuse the forbidden action when the agent attempts it, instead of reminding it afterwards.
- **Tests run where the code will live.** The Bridge builds and tests on the developer's real machine, and records coverage facts for each file.
- **Credentials stay out of reach.** The tokens that act on the tracker and CI stay on the host.

That combination is what standards such as [IEC 62443-4-1](https://www.isa.org/standards-and-publications/isa-standards/isa-iec-62443-series-of-standards) and the [NIST SSDF](https://csrc.nist.gov/pubs/sp/800/218/final) ask a development process to show (see the [Knowledge base](KB.md)). Kyklos is narrower than most of the projects above in what it runs on, and deeper in what it can prove.

## Related pages

[The three components](COMPONENTS.md), [The Kyklos workflow](WORKFLOW.md), [The Proof Table](PROOF.md), [Adversarial reviews](ADVERSARIAL_REVIEW.md), and [the README](../README.md) for the full list.
