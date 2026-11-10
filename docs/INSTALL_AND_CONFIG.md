# Installing and configuring Kyklos on Windows

[← Back to the README](../README.md)

> **Want your agent to do it?** This page is written for people. [Installing Kyklos with an agent](AGENT_INSTALL.md) gives the same procedure as numbered steps with a check after each one, so that an agent running on the host can follow it and stop to ask you wherever only a person can act.

## Current scope

Kyklos is young. Today it works with one stack, and it is proven mainly on one platform:

- **AI agent:** [Claude Code](https://code.claude.com/docs).
- **Issue tracker and CI:** [GitLab](https://about.gitlab.com/) (GitLab.com or self-managed, Community Edition included). A standalone or offline project can keep its stories in plain files instead (see [Storages](STORAGES.md)); the CI features then stay off.
- **Projects the Bridge builds and tests on the host:** .NET (the .NET SDK on the host).
- **Host operating system:** Windows is the primary platform. Linux support is in development. macOS is not supported.

The table shows each component and its main features per host operating system. ✅ supported · 🚧 in development (it may already be in the release, but it is not yet proven to the same standard as Windows) · ❌ not supported. Where a feature works differently on a platform, the cell says how.

| Component | Feature | Windows | Linux (x86-64) | macOS |
|-----------|---------|---------|----------------|-------|
| **🚀 Launcher** | Runs, with its control panel in the browser | ✅ (signed program) | 🚧 a bundle is released, best effort, not signed (check it against `SHA256SUMS.txt`) | ❌ no build |
| | Container engine | Docker Desktop (WSL 2 backend) | 🚧 Docker Engine 20.10 or later, no Docker Desktop needed | ❌ |
| | Credential store for tokens and for the control-panel login | Windows Credential Manager | 🚧 a self-hosted secrets server or an encrypted file vault, named in the Launcher's settings (see step 2.7 below); the process environment is read only when neither is configured, and then the login cannot be set up | ❌ |
| | One isolated development container per project, with the `Kyklos Plugin` and the wiring to the `Kyklos Bridge` | ✅ | 🚧 (the container reaches the Bridge through Docker's host gateway) | ❌ |
| | Checks a configuration before launch (settings, folders, tokens' scopes, reviewed Bridge settings) | ✅ | 🚧 | ❌ |
| | Downloads the `Kyklos Bridge` and checks it | ✅ checksum and code signature | 🚧 checksum only | ❌ |
| | Opens the agent's session | ✅ in a new console window | 🚧 in the configured terminal, else the first of `x-terminal-emulator`, `gnome-terminal`, `konsole`, `xterm`; without a desktop session, the page shows the command to attach | ❌ |
| | Unlocks BitLocker-encrypted drives a launch needs (workspace, extra mounts, drives you name) before the launch, then mounts them into Docker Desktop's virtual machine (see [Encrypted and extra drives](#encrypted-and-extra-drives-windows-only)) | ✅ you type the password in Windows' own elevated prompt | not applicable (skipped) | not applicable |
| | PowerShell script fallbacks for the launch steps | ✅ | ❌ native steps only | ❌ |
| **🔀 Bridge** | Real builds, tests and coverage on the host | ✅ | 🚧 runs, best effort | ❌ built, never run or tested |
| | Proof tokens, Proof Table checks, coverage facts, story and epic actions | ✅ | 🚧 | ❌ built, never run or tested |
| | Issue-tracker, merge-request and CI actions | ✅ GitLab | 🚧 GitLab | ❌ |
| | Secret providers | Windows Credential Manager, a self-hosted secrets server, an encrypted file vault | 🚧 a self-hosted secrets server, an encrypted file vault | ❌ |
| | Stops the processes it started when it ends | ✅ bound to the Bridge's lifetime (Windows job object) | 🚧 each run leads its own process group; leftovers of a killed Bridge are ended at its next start | ❌ |
| | Builds documents and takes screenshots of a running app (`doc_build`, `host_app_screenshot`) | ✅ Microsoft Edge | 🚧 Microsoft Edge, Google Chrome or Chromium | ❌ |
| | Installed by the Launcher from the Kyklos releases page | ✅ | 🚧 | ❌ |
| | Installed as a .NET tool from NuGet.org (`DogmaSolutions.Kyklos.Bridge`, see [Getting the Bridge from NuGet.org](#getting-the-bridge-from-nugetorg)) | ✅ | ✅ (the Bridge itself is best effort on Linux) | ❌ the Bridge is not tested on macOS |
| **🔌 Plugin** | Hooks and skills inside the agent's session | ✅ | 🚧 (follows the Launcher) | ❌ no Launcher |

The Plugin always runs inside the development container, which is Linux on every host, so its own code does not depend on the host's operating system. Its platform support follows the Launcher and the Bridge.

Also in development or planned:

- **In development:** a layered agent policy (Kyklos, corporate and project levels, with the corporate level fetched by the Launcher from an optional Git repository); a two-tier CI model (a fast integration branch, a full release check); the document builder as a standalone .NET tool for developers and CI; a small local model that helps the Bridge read long logs (advisory only).
- **Planned:** support for other agents and other issue trackers and CI systems. No macOS work is scheduled today.

The components are distributed through the Kyklos marketplace, published in the [Kyklos GitHub repository](https://github.com/DogmaSolutions/Kyklos).

## About this guide

This guide takes you from nothing to a working agent on a small "Hello World" .NET project kept in GitLab, with its CI. It is a roadmap, not a reference: it names every piece you need, in the order you need it, and says what each one is for. The settings themselves are explained where you set them (each field of the Launcher's configuration page carries its own description).

The example project uses the **Private Companion + Public Sources** topology (see [Project topologies](TOPOLOGIES.md)): a private *companion* repository holds the agent's instructions and the backlog, and the public source repository is cloned inside it. It is the most complete set-up; the other topologies need a subset of the same steps.

Throughout the guide, `gitlab.example.com` stands for your GitLab address, `hello-world-sources` for the public source project and `hello-world-companion` for its private companion.

## What you will end up with

| Where | What |
|-------|------|
| **In GitLab** | a group with two projects (the companion, private, and the source, public), the labels and first milestone the backlog uses, a few purpose-built access tokens, and a runner for the CI |
| **On your Windows machine** | Docker Desktop, Git, the .NET SDK, the Dev Containers CLI, the `Kyklos Launcher` with your organisation's settings, a reviewed settings folder for the `Kyklos Bridge`, a local clone of the companion with the source nested inside it, and the tokens stored in the Windows Credential Manager |
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

Then create the first **epic**: a milestone in the companion project whose title starts with the letter `E` and a two-digit number, then a short name (for example "First steps"). Every story belongs to an epic.

### 1.4 The access tokens

Kyklos splits credentials by purpose (see [Secrets](SECRETS.md)): the agent can push code, but anything that acts on GitLab goes through the `Kyklos Bridge`, which keeps those tokens on your machine and never hands them to the agent. Create these tokens (project or group access tokens work; give each an expiry date you will remember to renew):

| Token | Created on | Scopes | What it is for |
|-------|-----------|--------|----------------|
| **Story token** | the companion project (or the group) | `api` | The Bridge reads and writes stories, notes, labels and milestones, and creates and arms merge requests. Stays on the host. |
| **CI token** | the source project (or the group) | `read_api` (`api` if the agent should create and arm merge requests there) | The Bridge reads pipelines, jobs, logs and test reports of the source project. Stays on the host. |
| **Source push token** | the source project | `write_repository` only | The agent pushes its story branches to the source repository. The Launcher refuses to start a project whose push token could also call the API. |
| **Companion push token** | the companion project | `write_repository` only | The agent pushes its changes to the companion (instructions, settings, documents). |
| **Distribution read token** | wherever the Kyklos components are published for you | `read_api`, `read_repository` | The Launcher downloads the `Kyklos Bridge`, and installs the `Kyklos Plugin` from a preview marketplace on a GitLab server. Not needed when they come from the public Kyklos repository: the public marketplace on GitHub is freely accessible, without a token. |

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

1. Download `kyklos-launcher-win-x64.zip` from the [Kyklos releases page](https://github.com/DogmaSolutions/Kyklos/releases/latest). To check the download, compare `Get-FileHash kyklos-launcher-win-x64.zip` with its line in `SHA256SUMS.txt` on the same page; the programs inside are signed by Dogma Solutions.
2. The self-contained bundle needs nothing else installed (no .NET runtime): unzip it into an empty folder of its own, for example `C:\Tools\Kyklos`.

Do not start it yet: it first needs your organisation's settings and a settings folder for the Bridge, the next two steps.

### 2.5 The organisation settings

The Launcher reads a few values that describe where your Kyklos components come from. They are not secrets: addresses, a project number and the **names** under which the tokens are stored (step 2.7), never the token values. Put them in an `appsettings.json` in the Launcher's folder, next to the Launcher program (`DogmaSolutions.Kyklos.Launcher.exe` on Windows, `DogmaSolutions.Kyklos.Launcher` on Linux):

```json
{
  "Launcher": {
    "Projects": {
      "PolicyOrganisationLayer": "C:\\KyklosSettings\\CLAUDE.org.md",
      "SettingsRoot": "C:\\KyklosSettings"
    },
    "Marketplace": {
      "RepositoryUrl": "https://github.com/DogmaSolutions/Kyklos.git"
    }
  }
}
```

**The marketplace and its token.** Most users install the `Kyklos Plugin` from the public marketplace on GitHub, which is freely accessible without a token: set `Marketplace:RepositoryUrl` to its clone address and nothing else. Some users reach early previews through a preview marketplace on a GitLab server, which needs a token: also set `"TokenName": "KYKLOS_DISTRIBUTION_TOKEN"` in the `Marketplace` section, and store that token in the credential store (step 2.7) like any other secret. So the token is an explicit, optional setting that you apply only for the marketplace you use. The Launcher gives it to the plugin install inside the container only; you do not list it among a project's secrets.

| Setting | What it is |
|---------|------------|
| `Marketplace:RepositoryUrl` | the clone address of the marketplace the `Kyklos Plugin` is installed from |
| `Marketplace:TokenName` | optional: the name of the token that clones a preview marketplace on a GitLab server (usually the distribution read token); leave it out for the public marketplace on GitHub |
| `Projects:PolicyOrganisationLayer` | your organisation layer: the file that completes the generic engineering policy with your organisation's facts (start from the sample layer the marketplace ships, `dist/CLAUDE.org.sample.md`) |
| `Projects:SettingsRoot` | the folder that holds each project's reviewed `Kyklos Bridge` settings (step 2.6) |

**Where the `Kyklos Bridge` comes from.** The Launcher downloads it from the [Kyklos releases page](https://github.com/DogmaSolutions/Kyklos/releases), checks it against the checksum published with the release, and needs no token and no setting for it. `Bridge:ReleaseUrl` holds that address. To use a GitLab package registry instead (for early previews), set these three settings, and the Launcher reads that registry:

| Setting | What it is |
|---------|------------|
| `Bridge:GitLabUrl` | the GitLab address the `Kyklos Bridge` packages are downloaded from |
| `Bridge:PackageProjectId` | the number of the project whose package registry publishes the `Kyklos Bridge` |
| `Bridge:TokenName` | the name of the token that reads that package registry (the distribution read token) |

The normal route is the one above: the Launcher downloads the Bridge from the [Kyklos releases page](https://github.com/DogmaSolutions/Kyklos/releases), checks it against the release checksums and starts it for you. The same page carries Bridge builds for Windows, Linux and macOS (Apple silicon). Of these, only the Windows Bridge program and the Windows Launcher program inside `kyklos-launcher-win-x64.zip` carry a code signature from Dogma Solutions; the Linux and macOS builds and the Linux Launcher are not signed, so check them against `SHA256SUMS.txt` on the same page.

Write the two paths as **absolute** paths (in JSON, every `\` is written `\\`). A relative path is never read from the folder you start the Launcher in: a relative `Projects:SettingsRoot` is read from the Launcher's own folder, and a relative `Projects:PolicyOrganisationLayer` from the settings root (or from the Launcher's own folder when no settings root is set). An absolute path leaves no doubt. A path written for Windows (with a drive letter, or a `\\server\share` path) is taken as it is written on every operating system: on a Linux or macOS host it is never joined under another folder, so such a file is reported as missing, naming the path exactly as you wrote it.

#### Getting the Bridge from NuGet.org

The `Kyklos Bridge` is also published on NuGet.org as the .NET tool package `DogmaSolutions.Kyklos.Bridge` (command name `kyklos-bridge`), the same version as the public release. It needs the .NET 10 SDK, no feed and no token. NuGet.org signs every package it serves (check it with `dotnet nuget verify --all`), and the Bridge's own assemblies inside it carry Dogma Solutions' code signature.

```powershell
dotnet tool install --global DogmaSolutions.Kyklos.Bridge
```

Or run it without installing, with the .NET 10 `dnx` command:

```powershell
dnx DogmaSolutions.Kyklos.Bridge --port <port> --solution <solution>
```

The Launcher does not need this package: it keeps taking the Bridge from the public release. Use the package to run the Bridge yourself, for example on a machine where you wire a project by hand (see the [components](COMPONENTS.md)).

#### Encrypted and extra drives (Windows only)

A launch needs every drive its container binds: the workspace drive, the drive of each extra mount, and any drive you list in `Launcher:Launch:AlwaysUnlockDrives`. On Windows, the Launcher prepares them before it starts anything, in two phases:

1. **Unlock**, before Docker is checked, so that Docker Desktop's virtual machine starts with the drives open. A drive that is already open is left alone. A drive that is locked with BitLocker gets an unlock in Windows' own elevated prompt, where **you** type the BitLocker password: the Launcher never reads, stores or logs it. One drive at a time, up to `BitLockerUnlockAttempts` tries. The drive Windows runs from is never unlocked, because it is always open.
2. **Mount**, after the Docker engine is up: each drive is mounted into Docker Desktop's virtual machine with writable file metadata, so that Git can change file modes. A failed mount is retried.

A drive that stays locked, is missing, or cannot be mounted **stops the launch** before any container starts, naming the drive and why the launch needs it. On Linux there is nothing to unlock or mount: both phases report "not applicable on this host" and the launch goes on.

These settings go in the same `appsettings.json`, under `Launcher:Launch`:

| Setting | What it is | Default |
|---------|------------|---------|
| `Launcher:Launch:AlwaysUnlockDrives` | Drive letters to unlock and mount on every launch even when no project path names them, for example `D` when Docker's data or your tools live on an encrypted drive | empty (none) |
| `Launcher:Launch:BitLockerUnlockAttempts` | How many times the elevated unlock is offered for one drive | `3` |
| `Launcher:Launch:DriveMountAttempts` | How many times a failed or empty mount is retried | `5` |
| `Launcher:Launch:DriveMountRetryDelaySeconds` | The wait between two mount attempts, in seconds | `3` |

If Docker Desktop never comes up and no drive was unlocked first, check whether Docker keeps its data on an encrypted drive that nothing names: add that letter to `AlwaysUnlockDrives`.

Then start the Launcher. It opens its control panel in your browser (it listens on your machine only; the address is printed too). The first time, the page asks you to choose a username and a password of at least 12 characters. **Do this right after the first start, before anything else.** Until a login exists, the page offers the form to whoever reaches it first, and that person chooses the login. On a machine other people use, set the login before anyone else can open the address. Once it is set, the form is gone and everyone must log in. The Launcher keeps the username and a salted hash of the password in the Windows Credential Manager (entries `Kyklos:Launcher:Username` and `Kyklos:Launcher:Password`), never the password itself. From then on, open the same address and log in; the **Account** link changes the password or logs out. Forgot the password? Delete those two entries in the Windows Credential Manager and reload the page to choose a new login. If a value above is missing, the Launcher says which one.

### 2.6 The Bridge settings, reviewed

Each project's `Kyklos Bridge` runs with its own settings file. Because those settings decide what the agent may reach, the Launcher uses only a **reviewed** version: the file must be committed in a git repository, unchanged since that commit, and identical to the version on its remote branch. A file the agent could edit, or an edit nobody committed, is refused.

1. Create the settings root (`C:\KyklosSettings` above) as a git repository with a remote, for example a private project in your GitLab group. Keep it outside every project's workspace folder: the agent's container must not be able to write it.
2. For each project, add the file `projects/<project name>/bridge.appsettings.json`, where `<project name>` is exactly the project name you give the configuration in step 2.8. The smallest file is:

   ```json
   { "Bridge": { "Role": "Project" } }
   ```

3. Commit it and push it. After any later change, commit and push again before the next launch.

### 2.7 The secrets

On the control panel's home page, use the **Credentials and tokens** section to store each token from step 1.4 in the Windows Credential Manager, under a name of your choice, for example:

| Name | Value |
|------|-------|
| `HELLO_STORY_TOKEN` | the story token |
| `HELLO_CI_TOKEN` | the CI token |
| `HELLO_SOURCE_PUSH_TOKEN` | the source push token |
| `HELLO_COMPANION_PUSH_TOKEN` | the companion push token |
| `KYKLOS_DISTRIBUTION_TOKEN` | the distribution read token, if you need one (a preview marketplace, or the `Kyklos Bridge` from a GitLab package registry) |

The configuration you create next, and the organisation settings of step 2.5, refer to these **names**, never to the values. The values stay in the credential store; the Launcher reads them at launch time and hands them only to the component that needs them.

**On Linux** there is no Windows Credential Manager: the same names are stored in OpenBao (`Launcher:Secrets:OpenBaoUrl`) or in the encrypted file vault (`Launcher:Secrets:VaultPath`), and the control panel says which one took each value. Once either is configured, they are the only places a secret is read from: a token that exists only in the Launcher's environment is reported as missing. That includes the registry token the Launcher itself uses to download the `Kyklos Bridge` (for example `KYKLOS_DISTRIBUTION_TOKEN`): with a vault or OpenBao configured, store it there too. The environment is read only on a host that configures neither.

### 2.8 The project configuration

On the configurations page, create a configuration named `hello-world-sources`. The **Essentials** card lists every required setting; for this project, set:

- the **project name** (`hello-world-sources`). It must match the folder name of step 2.6, and it also decides the port of the project's `Kyklos Bridge`. Two different names can lead to the same port; the Launcher then refuses the second project and names the first, and you rename one of them. When you leave it empty, the project takes the configuration's name;
- the **workspace folder** (`C:\work\hello-world-companion`). The folder must already exist: the Launcher does not create it;
- the **GitLab address** (`https://gitlab.example.com`). It is needed because this project keeps its stories in GitLab and uses the Bridge's CI verbs. A project that keeps its stories in files (`STORY_BACKEND=filesystem`) and turns the CI verbs off (`KYKLOS_BRIDGE_CI_OFF_REASON` set to the reason, in the configuration or in the project's reviewed Bridge settings file) needs no GitLab address;
- the **story storage** set to GitLab, with the **story project** being the companion project's number (shown on its GitLab home page), and the story token's name (`HELLO_STORY_TOKEN`);
- the **source push repository** (the source project's clone address) with its push token's name, and the **companion push repository** with its push token's name;
- the **repository shape**: a companion with the source in the folder `Repo`, the source following GitFlow;
- the **CI project** (the source project's number) with the CI token's name: the project whose pipelines the plugin's CI gate watches after a push (`KYKLOS_CI_PROJECT_ID`, `KYKLOS_CI_TOKEN_ENV`). The `Kyklos Bridge`'s own CI verbs take their project and token from the story settings above (the story project and the story token's name), whatever the story storage, unless you turn them off with `KYKLOS_BRIDGE_CI_OFF_REASON`;
- the **Kyklos Plugin** turned on (`KYKLOS=1`). It is installed from the marketplace of step 2.5; a project can use another one in the editor's **Plugin marketplace** section (`KYKLOS_MARKETPLACE_URL`, and `KYKLOS_MARKETPLACE_TOKEN_NAME` for a preview marketplace that needs a token). The marketplace token is not one of the project's secrets: do not add it to `KYKLOS_SECRETS`.
- optionally, the **agent arguments** (`KYKLOS_AGENT_ARGUMENTS`). Left empty, which is the default, the agent starts with Claude Code's normal permission prompts: it asks before it acts, and no remote-control session is opened. To run it unattended, set `--dangerously-skip-permissions`; the agent then acts with no prompts inside its container, so use it only on a project whose container and tokens you are content to leave to the agent. To follow the session from another device, add `--remote-control`. With `--dangerously-skip-permissions` the Launcher also records, inside the container, that the agent's one-time warning about that mode was accepted, so the session starts without waiting for you; without the flag it records nothing, and removes an earlier record. Only these two flags are handled that way: `--permission-mode bypassPermissions` and `--allow-dangerously-skip-permissions` are accepted but record nothing, so a session started with them waits at the agent's warning. The project's value replaces the Launcher's host-wide default (`Launcher:Launch:ClaudeSession:ClaudeArguments`, also empty) for that project; only letters, digits, spaces and `. _ = / : @ + -` are accepted, and the configuration check names the setting when the value is refused;
- optionally, the project's **own names** (`KYKLOS_OWN_NAMES`): the product and customer names this project may write in its own source although they are on the organisation's disclosure list. They are exempted only there, as whole names, and from that one check; with no list, nothing is exempted.

Press **Save**. The configuration check runs before anything is launched and reports **every** problem it finds in one answer, field by field: a missing setting, a workspace folder that does not exist, a Bridge settings file that is missing or not committed, a project name whose Bridge port another project already uses, a missing organisation setting. Fix them all, then save again until the check confirms the configuration. The configuration's secrets view then shows each declared secret as available or missing: all of them must be available before the first launch.

These checks are part of the Launcher from the release that carries them; an earlier release reports some of these problems only when the launch reaches them, one at a time.

### 2.9 The first launch

Press **Launch**. The Launcher checks the configuration, checks what each token is allowed to do, makes sure Docker is running, starts the `Kyklos Bridge` on the host, builds and starts the development container with Claude Code and the `Kyklos Plugin`, and opens the agent's session in a new terminal. The first launch takes a while, because it builds the container image; later launches reuse it.

The launch page shows each of these steps. If the launch stops, the step that failed is marked and shows the reason; fix it and press **Launch** again.

In the session, sign in to Claude Code when asked, and check with `/plugin` that the `Kyklos Plugin` (`kyklos`) is installed. The agent is now connected to the Bridge: it can build and test your code on the host, and read and write the backlog in GitLab.

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

- **The Launcher refuses to launch:** the configuration check names every missing setting, secret, folder or tool in one answer, and the configuration's secrets view shows which secrets are missing; both are available before you launch. A launch that stops later marks the step that failed and shows the reason on it.
- **An organisation setting is reported missing:** check that `appsettings.json` sits next to the Launcher program (`DogmaSolutions.Kyklos.Launcher.exe` on Windows, `DogmaSolutions.Kyklos.Launcher` on Linux), that its keys are under `Launcher:Bridge`, `Launcher:Projects` and `Launcher:Marketplace` exactly as in step 2.5, and that its paths are absolute. A file written for an earlier Launcher, with the marketplace keys under `Launcher:Projects`, is moved to `Launcher:Marketplace` when the Launcher starts (a backup of the file is kept beside it).
- **The Bridge settings file is refused:** it is missing, its folder name differs from the project name, or it is not exactly the committed and pushed version. Commit and push it in the settings root (step 2.6), and keep the settings root outside the workspace folder.
- **The project name is refused because of its Bridge port:** another project's name leads to the same port. Rename one of the two projects, and rename its Bridge settings folder to match.
- **The launch stops because a drive is unavailable (Windows):** the drive stayed locked (the BitLocker prompt was closed or the password was wrong `BitLockerUnlockAttempts` times), is not present, or could not be mounted. Unlock or connect it and press **Launch** again (see [Encrypted and extra drives](#encrypted-and-extra-drives-windows-only)).
- **The workspace folder is refused:** create the folder (or clone the companion into it) before launching.
- **The `Kyklos Plugin` is not installed in the session:** the container could not clone the marketplace. Check the marketplace address. For the public marketplace on GitHub, no token is needed: leave `Marketplace:TokenName` empty. For a preview marketplace on a GitLab server, check that `Marketplace:TokenName` names the token, that the token is stored under that name (the configuration check reports a token that is not) and that it can read the marketplace repository, and launch again.
- **A push token is refused:** it has more than `write_repository`. Create a new one with that scope only.
- **The container does not start:** check that Docker Desktop's engine is running, and that `devcontainer --version` works in a new terminal.
- **The Launcher says a Bridge on the project's port did not answer its stop request:** to move a project to a newer Bridge or newer settings, the Launcher asks the Bridge that is already running to stop, using the project's current credential. A Bridge that was started with an older credential does not accept that request. The Launcher then leaves it running, does not start a second Bridge on the same port, and does not end the process itself, so the launch does not go on with the new Bridge. The message does not yet name the process; a later release will. Until then, end that Bridge yourself (in Task Manager, the `Kyklos Bridge` program that listens on the project's port) and press **Launch** again.
- **The agent cannot reach GitLab:** check the story and CI tokens' expiry dates and scopes, then store the new values under the same names in the credential store; the next request picks them up.

See also: [the three Kyklos components](COMPONENTS.md), [secrets](SECRETS.md), [how the agent uses Git](GIT.md) and [CI](CI.md).
