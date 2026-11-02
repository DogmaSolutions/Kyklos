# Installing and configuring Kyklos on Windows

[← Back to the README](../README.md)

This guide takes you from nothing to a working agent on a small "Hello World" .NET project kept in GitLab, with its CI. It is a roadmap, not a reference: it names every piece you need, in the order you need it, and says what each one is for. The settings themselves are explained where you set them (each field of the Launcher's configuration page carries its own description).

The example project uses the **Private Companion + Public Sources** topology (see [Project topologies](TOPOLOGIES.md)): a private *companion* repository holds the agent's instructions and the backlog, and the public source repository is cloned inside it. It is the most complete set-up; the other topologies need a subset of the same steps.

Throughout the guide, `gitlab.example.com` stands for your GitLab address, `hello-world-sources` for the public source project and `hello-world-companion` for its private companion.

## What you will end up with

| Where | What |
|-------|------|
| **In GitLab** | a group with two projects (the companion, private, and the source, public), the labels and first milestone the backlog uses, a few purpose-built access tokens, and a runner for the CI |
| **On your Windows machine** | Docker Desktop, Git, the .NET SDK, the Dev Containers CLI, the `Kyklos Launcher`, a local clone of the companion with the source nested inside it, and the tokens stored in the Windows Credential Manager |
| **Running** | a development container with Claude Code and the `Kyklos Plugin`, connected to the `Kyklos Bridge` on the host, ready to take its first story |

---

## Part 1: GitLab

### 1.1 The instance

Any GitLab works: GitLab.com or a self-managed instance, Community Edition included (Kyklos uses milestones for epics so that no paid feature is needed; see [Storages](STORAGES.md)). You need an account that can create a group and projects, and that can create access tokens for them.

### 1.2 A group and two projects

1. Create a group, for example `hello`.
2. In it, create the **companion** project `hello-world-companion`, visibility **Private**. It will hold the agent's instructions, settings and the backlog (the stories are its issues). It is trunk-based: its default branch is `main`.
3. Create the **source** project `hello-world-sources`, visibility **Public** (or Private while you try things out). It will hold only the product's code: no agent file of any kind ever goes in it. It follows GitFlow: create a `develop` branch next to `main` and make `develop` the default branch.
4. Protect `main` and `develop` in the source project so that nobody pushes to them directly: changes reach them through merge requests only.
5. In the source project, require a successful pipeline before a merge request can be merged (*Settings > Merge requests > Merge checks > Pipelines must succeed*). The agent arms its merge requests to merge themselves as soon as the pipeline is green (see [How the agent uses CI](CI.md)), and this setting makes sure nothing red can merge.

### 1.3 The backlog: labels and the first epic

The stories live in the companion's issues. Kyklos drives them with a small set of labels (see [Storages](STORAGES.md) for what each one does).  
Create them in the group, so that both projects can use them. If you don't, *Kyklos Bridge* will progressively create them for you when they are needed. 

| Label | Values to create |
|-------|------------------|
| `story` | (a single label) |
| `kind::` | `kind::development`, `kind::analysis`, `kind::documentation`, `kind::ops` |
| `severity::` | `severity::critical`, `severity::high`, `severity::medium`, `severity::low` |
| `status::` | `status::todo`, `status::doing`, `status::blocked-on-issue`, `status::blocked-on-user`, `status::blocked-on-external`, `status::parked` |
| `ssdlc:phase::` | `ssdlc:phase::Requirements`, `ssdlc:phase::Design`, `ssdlc:phase::Implementation`, `ssdlc:phase::Testing`, `ssdlc:phase::Deployment`, `ssdlc:phase::Review` |
| `type::` | for example `type::feat`, `type::fix`, `type::docs`, `type::ci` |

Then create the first **epic**: a milestone in the companion project named `E01 First steps`. Every story belongs to an epic.

### 1.4 The access tokens

Kyklos splits credentials by purpose (see [Secrets](SECRETS.md)): the agent can push code, but anything that acts on GitLab goes through the `Kyklos Bridge`, which keeps those tokens on your machine and never hands them to the agent. Create these tokens (project or group access tokens work; give each an expiry date you will remember to renew):

| Token | Created on | Scopes | What it is for |
|-------|-----------|--------|----------------|
| **Story token** | the companion project (or the group) | `api` | The Bridge reads and writes stories, notes, labels and milestones, and creates and arms merge requests. Stays on the host. |
| **CI token** | the source project (or the group) | `read_api` (`api` if the agent should create and arm merge requests there) | The Bridge reads pipelines, jobs, logs and test reports of the source project. Stays on the host. |
| **Source push token** | the source project | `write_repository` only | The agent pushes its story branches to the source repository. The Launcher refuses to start a project whose push token could also call the API. |
| **Companion push token** | the companion project | `write_repository` only | The agent pushes its changes to the companion (instructions, settings, documents). |
| **Distribution read token** | wherever the Kyklos components are published for you | `read_api`, `read_repository` | The Launcher downloads the `Kyklos Bridge` and installs the `Kyklos Plugin` from the marketplace. Not needed when they come from the public Kyklos repository. |

Keep each value only until the next step, where it goes into your machine's credential store; you will not see it again in GitLab. Never put a token value in a file, a repository or a chat.

### 1.5 A runner for the CI

The pipeline of the source project needs a runner that can build and test .NET. A runner with the Docker executor and a .NET SDK image (for example `mcr.microsoft.com/dotnet/sdk`) is enough for the Hello World project. Register it for the source project or the group (*Settings > CI/CD > Runners*). On GitLab.com, the shared runners already work.

---

## Part 2: Your Windows machine

### 2.1 Prerequisites

Install, in this order:

1. **WSL 2** (Windows Subsystem for Linux), which Docker Desktop uses: in an administrator PowerShell, `wsl --install`, then restart.
2. **[Docker Desktop](https://www.docker.com/products/docker-desktop/)**, with the WSL 2 backend. Start it once and wait until it reports that the engine is running.
3. **[Git for Windows](https://git-scm.com/download/win)**.
4. **The [.NET SDK](https://dotnet.microsoft.com/download)** your project targets. The `Kyklos Bridge` builds and tests your code on the host, so the SDK must be here, not only in the container.
5. **[Node.js](https://nodejs.org/)** (the LTS version), then the **Dev Containers CLI**: `npm install -g @devcontainers/cli`. The Launcher uses it to build and start the development container.
6. **[PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows)** (recommended; the Launcher falls back to Windows PowerShell for the few steps that need a script).
7. A **Claude Code** subscription or API account: the agent inside the container signs in to it the first time it starts (see the [Claude Code documentation](https://code.claude.com/docs)).

### 2.2 The local clone

The companion is the working folder; the source is cloned inside it, as its own repository, in a folder named `Repo`:

```powershell
cd C:\work
git clone https://gitlab.example.com/hello/hello-world-companion.git
cd hello-world-companion
git clone https://gitlab.example.com/hello/hello-world.git Repo
```

Add one line to the companion's `.gitignore`, so the source is never committed into the companion:

```
/Repo/
```

Commit and push that `.gitignore` to the companion's `main`. The two repositories now sit one inside the other, each with its own history, and nothing links them except that line.

### 2.3 The Hello World project

In `Repo`, on a branch off `develop`, create a minimal solution with one library and one test project, for example:

```powershell
cd C:\work\hello-world-companion\Repo
git switch -c feature/initial-project develop
dotnet new sln -n HelloWorld
dotnet new classlib -n HelloWorld -o src/HelloWorld
dotnet new nunit -n HelloWorld.Tests -o tests/HelloWorld.Tests
dotnet add tests/HelloWorld.Tests reference src/HelloWorld
dotnet sln add src/HelloWorld tests/HelloWorld.Tests
dotnet add tests/HelloWorld.Tests package coverlet.collector
dotnet add tests/HelloWorld.Tests package JUnitXml.TestLogger
```

The two packages added at the end matter: Kyklos proves test coverage with a coverage collector, and reads test results as JUnit reports in CI. A test project without them cannot earn its proof (see the [Proof Table](PROOF.md)).

Add a `.gitlab-ci.yml` at the root of `Repo` that restores, builds and tests the solution with coverage, and publishes the test report, for example:

```yaml
stages: [test]

test:
  stage: test
  image: mcr.microsoft.com/dotnet/sdk:10.0
  script:
    - dotnet test HelloWorld.sln --collect "XPlat Code Coverage" --logger "junit;LogFilePath=test-results/{assembly}.xml"
  artifacts:
    when: always
    reports:
      junit: "**/test-results/*.xml"
```

Push the branch, open a merge request into `develop`, check that the pipeline is green, and merge it. From now on the agent takes over this kind of work.

### 2.4 The Kyklos Launcher

1. Download the `Kyklos Launcher` release from the [Kyklos GitHub repository](https://github.com/DogmaSolutions/Kyklos). The self-contained release needs nothing else installed: unzip it into a folder of its own, for example `C:\Tools\Kyklos`.
2. If the components are published for you somewhere else than the public Kyklos repository, put their addresses in an `appsettings.json` in the Launcher's folder (the GitLab address, the project that publishes the packages, the marketplace repository and the name of the distribution read token). The Launcher says at start-up which of these values are missing.
3. Start the Launcher. It prints a start-up link to its control panel, which listens on your machine only. Open it in your browser.

### 2.5 The secrets

On the control panel's home page, use the credentials form to store each token from step 1.4 in the Windows Credential Manager, under a name of your choice, for example:

| Name | Value |
|------|-------|
| `HELLO_STORY_TOKEN` | the story token |
| `HELLO_CI_TOKEN` | the CI token |
| `HELLO_SOURCE_PUSH_TOKEN` | the source push token |
| `HELLO_COMPANION_PUSH_TOKEN` | the companion push token |
| `KYKLOS_DISTRIBUTION_TOKEN` | the distribution read token, if you need one |

The configuration you create next refers to these **names**, never to the values. The values stay in the credential store; the Launcher reads them at launch time and hands them only to the component that needs them.

### 2.6 The project configuration

On the configurations page, create a configuration named `hello-world-sources`. The **Essentials** card lists every required setting; for this project, set:

- the **project name** (`hello-world-sources`) and the **workspace folder** (`C:\work\hello-world-companion`);
- the **GitLab address** (`https://gitlab.example.com`);
- the **story storage** set to GitLab, with the **story project** being the companion project's number (shown on its GitLab home page), and the story token's name (`HELLO_STORY_TOKEN`);
- the **source push repository** (the source project's clone address) with its push token's name, and the **companion push repository** with its push token's name;
- the **repository shape**: a companion with the source in the folder `Repo`, the source following GitFlow;
- the **CI project** (the source project's number) with the CI token's name;
- the **Kyklos Plugin** turned on.

Press **Save**. The validator either confirms that the configuration is valid or lists what is missing, field by field. The configuration's secrets view then shows each declared secret as available or missing: all of them must be available before the first launch.

### 2.7 The first launch

Press **Launch**. The Launcher checks the configuration, checks what each token is allowed to do, makes sure Docker is running, starts the `Kyklos Bridge` on the host, builds and starts the development container with Claude Code and the `Kyklos Plugin`, and opens the agent's session in a new terminal. The first launch takes a while, because it builds the container image; later launches reuse it.

In the session, sign in to Claude Code when asked. The agent is now connected to the Bridge: it can build and test your code on the host, and read and write the backlog in GitLab.

---

## Part 3: The first story

### 3.1 Declare the topology

Ask the agent to declare the project's repository model. It runs the `kyklos:ssdlc-repo-model` skill, which asks you a few questions and records the answer (Private Companion + Public Sources, the source in `Repo`, the companion trunk-based, the source on GitFlow) in the companion's settings. Every guard derives its behaviour from this declaration (see [Project topologies](TOPOLOGIES.md)). The agent commits it to the companion.

### 3.2 Ask for a change

Describe a small change in plain words, for example: "add a `Greeter` class that returns `Hello, <name>!`, with tests". The agent then follows the Kyklos workflow (see [The Kyklos workflow](WORKFLOW.md)):

1. it creates a story in the companion's issues, with its severity, its epic (`E01`) and a specification (requirements, use cases, failure modes, acceptance criteria and a risk assessment);
2. it works on a story branch of the source, builds and tests on the host through the Bridge, and earns the coverage proof for the lines it changed;
3. an adversarial review is run and recorded on the story;
4. it pushes the branch, opens a merge request into `develop` and arms it, so that it merges itself when the pipeline is green;
5. once merged, it fills the story's [Proof Table](PROOF.md) from the evidence the tools produced, and closes the story.

Anything the agent may not do on its own (publishing outward, deleting shared things, a new blocking gate) stops for you, with a question on the story itself.

## When something does not work

- **The Launcher refuses to launch:** the answer names the missing setting, secret or tool. The configuration's validator and secrets view show the same information before you launch.
- **A push token is refused:** it has more than `write_repository`. Create a new one with that scope only.
- **The container does not start:** check that Docker Desktop's engine is running, and that `devcontainer --version` works in a new terminal.
- **The agent cannot reach GitLab:** check the story and CI tokens' expiry dates and scopes, then store the new values under the same names in the credential store; the next request picks them up.

See also: [the three Kyklos components](COMPONENTS.md), [secrets](SECRETS.md), [how the agent uses Git](GIT.md) and [CI](CI.md).
