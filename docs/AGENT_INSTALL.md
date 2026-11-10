# Installing Kyklos with an agent

[← Back to the README](../README.md) · Human guide: [Installing and configuring Kyklos](INSTALL_AND_CONFIG.md)

This page is written for a coding agent, for example Claude Code running **on the host machine** (not inside a container). A developer can tell their agent: *"Install and configure Kyklos by following docs/AGENT_INSTALL.md."* The agent then does the work it can do, checks every step, and stops to ask the developer wherever only a person may act.

The [human guide](INSTALL_AND_CONFIG.md) explains *why* each piece exists. This page says *what to run* and *what to check*. Both lead to the same result, a working agent on a project kept in GitLab. For the background of any step, read the human guide's section of the same name.

---

## Rules for the agent

Follow these rules for the whole procedure.

1. **Run the steps in order.** After each step, run its **Check**. If the output does not match **Expected**, go to **If it fails** for that step. Do not go on with a failed check.
2. **Never see, print, store or pass on a secret.** Access tokens, passwords and vault passphrases are typed by the person, into the Launcher's page or into the person's own terminal, never into this conversation. Never write a token into a file, a command line, a repository or the chat. If the person pastes a secret into the conversation, do not use it: tell them to revoke it and create a new one.
3. **Stop at every 🛑 STOP.** Ask the person exactly what that step says, explain why it needs them, and wait for their answer before going on.
4. **Ask before installing software or changing system settings.** Each prerequisite install is a 🛑 STOP: name what you would install and the command, and run it only after the person agrees.
5. **Shell.** Windows commands are PowerShell. If your shell tool is Bash (for example Git Bash), run each one as `pwsh -NoProfile -Command "<command>"`, or `powershell -NoProfile -Command "<command>"` when PowerShell 7 is not installed yet. Linux commands are Bash.
6. **Placeholders.** Replace each one with the real value before running a command:
   - `<project>`: the project name (step 1);
   - `<workspace-folder>`: the workspace folder (step 1);
   - `<launcher-folder>`: the folder the Launcher is unpacked into (step 1);
   - `<settings-root>`: the folder of reviewed Bridge settings (step 1);
   - `<settings-remote>`: the clone address of the settings root's remote project (step 3);
   - `<companion-clone-address>` and `<source-clone-address>`: the clone addresses of the companion and the source project (step 3);
   - `<user>`: the Linux user name the Launcher runs as;
   - `<address>`: the address of the secrets server, when the person uses one instead of the vault (step 7).

## Which operating systems each step targets

Windows is the primary platform. Linux (x86-64) support is in development and best effort. **macOS is not supported: if the host is macOS, stop and tell the person.** See [Current scope](INSTALL_AND_CONFIG.md#current-scope).

Inside the steps, an OS-specific part is headed **🪟 Windows** or **🐧 Linux**. Run only the part for the host's system.

| Step | 🪟 Windows | 🐧 Linux | macOS |
|---|---|---|---|
| 1. Collect the decisions | ✅ | ✅ | ❌ |
| 2. Check the prerequisites | ✅ own commands | ✅ own commands | ❌ |
| 3. GitLab projects and tokens | ✅ same | ✅ same | ❌ |
| 4. The local clone | ✅ | ✅ same commands, `/` paths | ❌ |
| 5. Download and check the Launcher | ✅ own commands | ✅ own commands | ❌ |
| 6. The reviewed Bridge settings | ✅ | ✅ same commands, `/` paths | ❌ |
| 7. Organisation settings and first start | ✅ (plus encrypted drives, if any) | ✅ (plus the secret store; the person starts the Launcher) | ❌ |
| 8. Login and secrets | ✅ same | ✅ same | ❌ |
| 9. The project configuration | ✅ same | ✅ same | ❌ |
| 10. The first launch | ✅ (a BitLocker prompt may appear) | ✅ | ❌ |

---

## Early access: the repository is private (do this first)

During early access the GitHub repository `DogmaSolutions/Kyklos` is private: only invited GitHub accounts can see it, and every anonymous download from it answers **404 Not Found**. That affects three things the normal steps take for granted: downloading the release files, the Launcher fetching the `Kyklos Bridge` from the release, and the container installing the `Kyklos Plugin` from the marketplace. Until the repository is public, do the following on top of the normal steps. When it is public, skip this section.

**What the person needs (🛑 STOP: ask the person, never handle the token yourself):**

1. A GitHub account that Dogma Solutions invited to `DogmaSolutions/Kyklos` (the invitation was accepted).
2. The GitHub CLI `gh`, signed in with that account: the person runs `gh auth login` in their own terminal. **Check:** `gh repo view DogmaSolutions/Kyklos --json name`. **Expected:** `{"name":"Kyklos"}`.
3. A read-only GitHub access token for the plugin install: on github.com, *Settings*, *Developer settings*, *Fine-grained tokens*, *Generate new token*, resource owner `DogmaSolutions`, repository `Kyklos` only, permission *Contents: Read-only*. (Dogma Solutions may have to approve the request; tell them if it stays pending.) The person stores it in the Launcher's credential store under the name `KYKLOS_MARKETPLACE_TOKEN` (step 8, like any other secret), and you add `"TokenName": "KYKLOS_MARKETPLACE_TOKEN"` to the `Marketplace` section of the Launcher settings (step 7). The Launcher gives this token only to the plugin install inside the container; the agent never sees it.

**Download the release files with `gh` instead of the plain download (replaces the download commands of step 5; the checksum and signature checks of step 5 stay the same):**

🪟 Windows:

```powershell
Set-Location <launcher-folder>
gh release download --repo DogmaSolutions/Kyklos --pattern kyklos-launcher-win-x64.zip --pattern kyklos-bridge-win-x64.exe --pattern SHA256SUMS.txt --clobber
```

🐧 Linux:

```bash
cd <launcher-folder>
gh release download --repo DogmaSolutions/Kyklos --pattern kyklos-launcher-linux-x64.zip --pattern kyklos-bridge-linux-x64 --pattern SHA256SUMS.txt --clobber
```

**Check:** the checksum check of step 5 for the Launcher zip, and the same check for the Bridge file (its line is in `SHA256SUMS.txt` too). **Expected:** both match.

**Give the Launcher the Bridge (after step 5, before the first launch).** The Launcher fetches the Bridge from the release without a login, which fails while the repository is private. When it cannot reach the release, it starts the newest Bridge in its cache folder whose checksum file matches, so put the downloaded Bridge there. Use the version of the release you downloaded (shown on the release page and in `gh release view --repo DogmaSolutions/Kyklos`), written below as `<version>`, for example `0.2.23098`.

🪟 Windows:

```powershell
$d = "$env:LOCALAPPDATA\KyklosBridge\<version>"
New-Item -ItemType Directory -Force $d | Out-Null
Copy-Item <launcher-folder>\kyklos-bridge-win-x64.exe $d
(Get-FileHash "$d\kyklos-bridge-win-x64.exe" -Algorithm SHA256).Hash.ToLower() | Set-Content -NoNewline "$d\kyklos-bridge-win-x64.exe.sha256"
```

🐧 Linux:

```bash
d="${XDG_DATA_HOME:-$HOME/.local/share}/KyklosLauncher/KyklosBridge/<version>"
mkdir -p "$d" && cp <launcher-folder>/kyklos-bridge-linux-x64 "$d/" && chmod +x "$d/kyklos-bridge-linux-x64"
sha256sum "$d/kyklos-bridge-linux-x64" | cut -d' ' -f1 | tr -d '\n' > "$d/kyklos-bridge-linux-x64.sha256"
```

If the Launcher settings set `Launcher:Bridge:CacheDirectory`, use that folder instead of the default above. **Check (at the first launch, step 10):** the launch log says the Bridge was started from the cache because the release could not be reached. **Expected:** the launch goes on and the Bridge answers. A message that the release manifest answered HTTP 404 is expected during early access.

**The Bridge as a .NET tool (optional).** `DogmaSolutions.Kyklos.Bridge` on NuGet.org is public and needs no GitHub access: `dotnet tool install --global DogmaSolutions.Kyklos.Bridge`. The Launcher does not use it; it is for running the Bridge by hand.

---

## Step 1: collect the decisions (🛑 STOP)

**Ask the person** for the values below, and explain that you need them to fill in the configuration. None of them is a secret.

| Value | Example | Why |
|---|---|---|
| Host operating system | Windows 11 / Ubuntu 24.04 | chooses the commands below |
| GitLab address | `https://gitlab.example.com` | the issue tracker and CI Kyklos works with |
| Project topology | Private Companion + Public Sources | decides which repositories exist (see [Project topologies](TOPOLOGIES.md)) |
| Project name | `hello-world-sources` | names the configuration, the Bridge settings folder and the Bridge's port |
| Workspace folder | `C:\work\hello-world-companion` | the folder mounted into the agent's container; the companion is cloned into it in step 4, so it must be empty or not exist yet |
| Launcher folder | `C:\Tools\Kyklos` | where the Launcher is unpacked; must be empty or new |
| Settings root | `C:\KyklosSettings` | a Git repository, with a remote, that holds the reviewed Bridge settings; it must be outside the workspace folder |
| Remote for the settings root | a private GitLab project, created in step 3 | the settings are used only when committed and pushed |

**Check:** write the values back to the person as a list and ask them to confirm.

**Expected:** the person confirms every value.

---

## Step 2: check the prerequisites

### 🪟 Windows

Run each command:

```powershell
wsl --status
docker version --format '{{.Server.Version}}'
git --version
dotnet --list-sdks
node --version
devcontainer --version
pwsh --version
```

**Expected:**

- `wsl --status` names WSL version 2 as the default.
- `docker version` prints a server version (this means the Docker Desktop engine is running).
- `git` and `node` print versions; Node.js must be 18 or later.
- `dotnet --list-sdks` lists the SDK your project targets.
- `devcontainer` prints 0.80.2 or later.
- `pwsh` prints a version. It is recommended but optional.

**If it fails:** for each missing or too old tool, 🛑 **STOP** and ask the person whether you may install it. Name the tool and the command:

| Missing | Command (ask first) | Note |
|---|---|---|
| WSL 2 | `wsl --install` | needs an administrator terminal and a restart: the person must do both |
| Docker Desktop | `winget install --id Docker.DockerDesktop -e` | the person starts Docker Desktop once and waits until it says the engine is running |
| Git | `winget install --id Git.Git -e` | |
| .NET SDK | `winget install --id Microsoft.DotNet.SDK.10 -e` | or the SDK version the project targets |
| Node.js | `winget install --id OpenJS.NodeJS.LTS -e` | |
| Dev Containers CLI | `npm install -g @devcontainers/cli` | after Node.js; open a new terminal afterwards |
| PowerShell 7 | `winget install --id Microsoft.PowerShell -e` | optional |

If `docker version` prints a client version but an error for the server, the engine is not running. Ask the person to start Docker Desktop, then check again.

### 🐧 Linux (best effort)

```bash
docker version --format '{{.Server.Version}}'
id -nG
git --version
dotnet --list-sdks
node --version
devcontainer --version
unzip -v | head -1
jq --version
```

**Expected:**

- Docker Engine 20.10 or later prints a server version.
- `id -nG` lists `docker`, or the person uses rootless Docker.
- Git, the .NET SDK and Node.js 18 or later print versions.
- `devcontainer` prints 0.80.2 or later.
- `unzip` and `jq` print versions (steps 5 and 7 use them).

**If it fails:**

- **Docker is missing or stopped.** Installing or starting it needs root. 🛑 **STOP** and ask the person to install Docker Engine and start it with their service manager.
- **`permission denied` on the Docker socket.** 🛑 **STOP** and ask the person to add their user to the `docker` group (`sudo usermod -aG docker $USER`, then log out and in again) or to use rootless Docker.
- **Dev Containers CLI missing.** Ask first, then run `npm install -g @devcontainers/cli`.
- **`unzip` or `jq` missing.** Installing them needs root. 🛑 **STOP** and ask the person to install them with their package manager (for example `sudo apt install unzip jq`).

---

## Step 3: GitLab projects and tokens (🛑 STOP)

Creating GitLab projects and access tokens needs the person's GitLab account, and the token values must never pass through you.

**Ask the person** to do the following, and to tell you when it is done. Give them the human guide's Part 1 ([GitLab](INSTALL_AND_CONFIG.md)) for the details.

1. Create the projects the chosen topology needs: for Private Companion + Public Sources, a private companion and a source project. Also create the private project that will hold the settings root.
2. Create the access tokens: a story token (`api`, on the companion), a CI token (`read_api`, on the source), a source push token and a companion push token (`write_repository` only).
3. Keep the token values **to themselves** until step 8, where they type them into the Launcher's page.
4. Choose a credential-store **name** for each token (for example `HELLO_STORY_TOKEN`, `HELLO_CI_TOKEN`, `HELLO_SOURCE_PUSH_TOKEN`, `HELLO_COMPANION_PUSH_TOKEN`) and tell you the **names** only.

5. Do the rest of the human guide's Part 1, which the story workflow still needs: protect `main` and `develop` in the source project and require a successful pipeline before a merge (step 1.2); create the backlog labels and the first epic, a milestone in the companion (step 1.3); and register a CI runner for the source project (step 1.5). See [Installing and configuring Kyklos](INSTALL_AND_CONFIG.md).

Then ask for the companion project's number (shown on its GitLab home page), the source project's number, and the clone addresses of the companion, the source and the settings root's remote project.

**Check:** the person confirms that the projects, tokens, labels, first epic and runner exist, and has given you the token names, project numbers and clone addresses.

**Expected:** all of them, and no token value.

---

## Step 4: the local clone (🪟 Windows and 🐧 Linux)

Use the human guide's step 2.2 (Private Companion + Public Sources). On Windows:

```powershell
git clone <companion-clone-address> <workspace-folder>
git -C <workspace-folder> clone <source-clone-address> Repo
```

Add the line `/Repo/` to `<workspace-folder>\.gitignore` with your file-editing tool, then commit it. If the person allows you to push, push it as well.

On Linux the commands are the same, with `/` paths.

**Check:**

```powershell
git -C <workspace-folder> status --short
git -C <workspace-folder>\Repo remote -v
```

**Expected:** `status` shows nothing to commit and does not list `Repo/`. The nested repository's remote is the source project.

**If it fails:** if `git clone` asks for credentials, 🛑 **STOP**. The person must sign in, through Git's own credential prompt or helper, not through you.

---

## Step 5: download and check the Launcher

> **Early access:** while the repository is private, the plain downloads below answer 404. Download with `gh` as described in [Early access](#early-access-the-repository-is-private-do-this-first), then run the checks below on the downloaded files.

### 🪟 Windows

```powershell
New-Item -ItemType Directory -Force <launcher-folder>
Set-Location <launcher-folder>
Invoke-WebRequest -Uri https://github.com/DogmaSolutions/Kyklos/releases/latest/download/kyklos-launcher-win-x64.zip -OutFile kyklos-launcher-win-x64.zip
Invoke-WebRequest -Uri https://github.com/DogmaSolutions/Kyklos/releases/latest/download/SHA256SUMS.txt -OutFile SHA256SUMS.txt
(Get-FileHash kyklos-launcher-win-x64.zip -Algorithm SHA256).Hash.ToLower()
Select-String -Path SHA256SUMS.txt -Pattern 'kyklos-launcher-win-x64.zip'
```

**Check:** compare the hash printed by `Get-FileHash` with the first field of the matching line in `SHA256SUMS.txt`.

**Expected:** the two hashes are identical.

Then unpack:

```powershell
Expand-Archive -Path kyklos-launcher-win-x64.zip -DestinationPath <launcher-folder> -Force
Test-Path <launcher-folder>\DogmaSolutions.Kyklos.Launcher.exe
(Get-AuthenticodeSignature <launcher-folder>\DogmaSolutions.Kyklos.Launcher.exe).Status
```

**Expected:** `True`, then `Valid`. The program is signed by Dogma Solutions.

### 🐧 Linux

```bash
mkdir -p <launcher-folder> && cd <launcher-folder>
curl -fLO https://github.com/DogmaSolutions/Kyklos/releases/latest/download/kyklos-launcher-linux-x64.zip
curl -fLO https://github.com/DogmaSolutions/Kyklos/releases/latest/download/SHA256SUMS.txt
sha256sum -c --ignore-missing SHA256SUMS.txt
unzip -q -o kyklos-launcher-linux-x64.zip
test -x DogmaSolutions.Kyklos.Launcher && echo executable
```

**Expected:** `kyklos-launcher-linux-x64.zip: OK`, then `executable`. The Linux build is not code-signed; the checksum is its check.

**If it fails:**

- **A hash mismatch.** Delete the downloaded zip and download it again once. If it still differs, 🛑 **STOP** and tell the person. Do not unpack a file whose hash does not match.
- **A download answers 404.** The release may not carry that file. Open `https://github.com/DogmaSolutions/Kyklos/releases` and tell the person what you see.
- **Keep the unpacked folder intact.** The program needs the files beside it (`appsettings.json`, `engine/`, `Parameters/`), so do not move it out of the folder.

**Note: the Bridge from NuGet.org (🪟 Windows and 🐧 Linux, optional).** The Launcher downloads the `Kyklos Bridge` itself from the public release, so this procedure does not need anything else. If the person wants the Bridge as a .NET tool too (for example to run it by hand), it is published on NuGet.org as `DogmaSolutions.Kyklos.Bridge`, command `kyklos-bridge`, and needs the .NET 10 SDK. Ask first, then run `dotnet tool install --global DogmaSolutions.Kyklos.Bridge`. **Check:** `dotnet tool list --global`. **Expected:** a line for `dogmasolutions.kyklos.bridge` with the command `kyklos-bridge`. See [Getting the Bridge from NuGet.org](INSTALL_AND_CONFIG.md#getting-the-bridge-from-nugetorg).

---

## Step 6: the reviewed Bridge settings (🪟 Windows and 🐧 Linux)

The Bridge uses a project's settings file only in a committed, pushed version, kept outside the workspace. On Windows:

```powershell
git clone <settings-remote> <settings-root>
New-Item -ItemType Directory -Force <settings-root>\projects\<project>
```

Cloning an empty project is fine: Git warns that the repository is empty, and the first push below creates its branch.

Write the file `<settings-root>\projects\<project>\bridge.appsettings.json` with your file-editing tool:

```json
{ "Bridge": { "Role": "Project" } }
```

Also download the sample organisation layer into the settings root, and tell the person they should later fill it with their organisation's facts:

```powershell
Invoke-WebRequest -Uri https://raw.githubusercontent.com/DogmaSolutions/Kyklos/main/dist/CLAUDE.org.sample.md -OutFile <settings-root>\CLAUDE.org.md
```

Commit both files, then 🛑 **STOP** and ask the person whether you may push the settings root to its remote. If they agree, push it:

```powershell
git -C <settings-root> add -A
git -C <settings-root> commit -m "chore: add the Kyklos Bridge settings"
git -C <settings-root> push -u origin HEAD
```

On Linux the commands are the same, with `/` paths and `mkdir -p` in place of `New-Item`. For the download, use `curl -fL -o <settings-root>/CLAUDE.org.md` followed by the same address as in the Windows command.

**Check:**

```powershell
git -C <settings-root> status --short
git -C <settings-root> log '@{u}' -1 --oneline
```

**Expected:** `status` prints nothing, and the remote branch (`@{u}`) shows your commit.

**If it fails:**

- **The sample download answers 404.** Look for `CLAUDE.org.sample.md` in the `dist` folder of the Kyklos repository on GitHub, and tell the person where it is.
- **The clone or the push needs credentials.** 🛑 **STOP**: the person signs in, through Git's own prompt or helper, not through you.

---

## Step 7: the organisation settings and the first start

`<launcher-folder>\appsettings.json` already exists: it ships with the Launcher, and its `"Launcher"` object already contains the `"Projects"`, `"Marketplace"` and `"Secrets"` objects, with empty values. **Edit it, do not replace it, and add no new objects.** With your file-editing tool, set these keys inside the existing objects, and leave every other key as it is:

| Key (inside `"Launcher"`) | Value |
|---|---|
| `Projects` → `PolicyOrganisationLayer` | `<settings-root>\CLAUDE.org.md` |
| `Projects` → `SettingsRoot` | `<settings-root>` |
| `Marketplace` → `RepositoryUrl` | `https://github.com/DogmaSolutions/Kyklos.git` |
| **Linux only**, for the encrypted file vault: `Secrets` → `VaultPath` | `/home/<user>/.config/kyklos/vault` |
| **Linux only**, for a secrets server instead: `Secrets` → `OpenBaoUrl` | `<address>` |

Use absolute paths. In JSON, write every `\` as `\\` (for example `"C:\\KyklosSettings"`).

**🪟 Windows only: encrypted drives.** Run `Get-BitLockerVolume | Select-Object MountPoint, ProtectionStatus, LockStatus` (it needs an administrator terminal: if it is refused, 🛑 **STOP** and ask the person which drives are BitLocker-encrypted). The Launcher unlocks the drives that the workspace and the extra mounts are on by itself. If Docker Desktop's data or the person's tools are on another encrypted drive, set `Launch` → `AlwaysUnlockDrives` to its letter (for example `D`); leave it empty otherwise. The other drive settings keep their defaults (see [Encrypted and extra drives](INSTALL_AND_CONFIG.md#encrypted-and-extra-drives-windows-only)). On Linux this does not apply.

**🪟 Windows check:**

```powershell
Set-Location <launcher-folder>
(Get-Content appsettings.json -Raw | ConvertFrom-Json).Launcher.Projects
(Get-Content appsettings.json -Raw | ConvertFrom-Json).Launcher.Marketplace
```

**🐧 Linux check:** `jq '.Launcher.Projects, .Launcher.Marketplace, .Launcher.Secrets' appsettings.json`

**Expected:** the values you set, and no parse error.

**Start the Launcher.**

- **🪟 Windows.** Run it from its own folder, as a background process: `Set-Location <launcher-folder>; .\DogmaSolutions.Kyklos.Launcher.exe --no-browser`.
- **🐧 Linux.** The Launcher needs the vault passphrase (or the token of the secrets server) in its environment, and you must never see that value. 🛑 **STOP** and ask the person to start the Launcher in their own terminal:

  ```bash
  cd <launcher-folder>
  read -rs KYKLOS_SECRETS_VAULT_PASSPHRASE && export KYKLOS_SECRETS_VAULT_PASSPHRASE
  ./DogmaSolutions.Kyklos.Launcher --no-browser
  ```

  With a secrets server, the variable is `KYKLOS_OPENBAO_TOKEN` instead.

**Check:**

```powershell
Invoke-RestMethod http://127.0.0.1:8787/api/health
```

(Linux: `curl -s http://127.0.0.1:8787/api/health`)

**Expected:** an answer with `status` and the Launcher's `version`. The console also prints `Kyklos Launcher listening on http://127.0.0.1:8787`.

**If it fails:**

- **The console names another port.** Port 8787 was busy, so the Launcher took the next free one, up to 8796. Use the printed port.
- **It says another instance is running.** Only one Launcher runs per machine, so use the running one.
- **On Linux, it refuses to start and names a script step.** A `StepImplementations` entry asks for a script step, which only Windows runs. Remove that entry.
- **The health check does not answer.** Read the console output and tell the person what it says.

---

## Step 8: login and secrets (🛑 STOP)

This step is the person's alone: it sets the control panel's password and stores the token values.

**Ask the person** to do the following:

1. Open `http://127.0.0.1:8787/login` **now**, before anyone else can, and choose a username and a password of at least 12 characters. Until a login exists, whoever opens the page first chooses it.
2. In the control panel's **Credentials and tokens** form, store each token from step 3 under the name agreed there (for example `HELLO_STORY_TOKEN`).
3. Tell you when it is done. Do not tell you any value.

**Check:** ask the person whether the form shows each name as stored.

**Expected:** every name is stored.

**If it fails:**

- **The login page says no credential store is usable.** On Linux, `Launcher:Secrets` is missing or the passphrase was not in the Launcher's environment: go back to step 7.
- **The person forgot the password.** On Windows they delete the entries `Kyklos:Launcher:Username` and `Kyklos:Launcher:Password` in the Windows Credential Manager, then reload the page.

---

## Step 9: the project configuration (🛑 STOP)

The configuration is created on the control panel, behind the person's login.

**Prepare the values** and give them to the person as a list:

- configuration name and project name: `<project>`;
- workspace folder;
- GitLab address;
- story storage GitLab, with the story project (the companion's number) and the story token's name;
- source push repository and its push token's name;
- companion push repository and its push token's name;
- repository shape: a companion with the source in `Repo`, the source on GitFlow;
- CI project (the source's number) and the CI token's name;
- Kyklos Plugin on.

Leave the agent arguments empty unless the person asks otherwise. The human guide's step 2.8 explains each value.

**Ask the person** to create the configuration on the configurations page with these values, press **Save**, and tell you what the configuration check reports.

**Check:** the person reports the result of the check, and the configuration's secrets view.

**Expected:** the check confirms the configuration, and every secret is shown as available.

**If it fails:** the check lists every problem in one answer, field by field. Fix what lives on the host:

- **A missing folder.** Create it, or go back to step 4.
- **A missing or uncommitted Bridge settings file.** Go back to step 6. The folder name must be exactly the project name.
- **A missing organisation setting.** Go back to step 7.

Ask the person to fix the rest (a missing secret, a token with the wrong scope), then to save again.

---

## Step 10: the first launch (🛑 STOP)

**Ask the person** to press **Launch** on the configuration. The first launch builds the container image, so it takes a while.

**🪟 Windows:** tell the person that if a drive the launch needs is locked with BitLocker, Windows shows an elevated prompt (the launch page names the drive): they approve it and type the BitLocker password there. You never see it.

**Check:**

```powershell
docker ps --format '{{.Names}}  {{.Status}}'
```

**Expected:**

- A running container whose name contains the project name.
- The launch page marks every step as done.
- In the new agent session, the person signs in to Claude Code, and `/plugin` lists `kyklos` as installed.

**If it fails:** the launch page marks the failed step and shows its reason. Common cases:

- **A drive is unavailable (🪟 Windows).** It stayed locked, is missing, or could not be mounted. The person unlocks or connects it and launches again.
- **"The Docker engine is not running".** Start Docker (Windows: Docker Desktop; Linux: the person, with their service manager).
- **A Dev Containers CLI and Docker version pair known to hang.** Run `npm install -g @devcontainers/cli` to get 0.80.2 or later.
- **A push token refused.** It has more than `write_repository`. The person creates a new one and stores it under the same name.
- **A Bridge on the project's port does not answer its stop request.** An older Bridge is still running. The person ends that `Kyklos Bridge` process (Task Manager on Windows) and launches again.
- **The Plugin is not installed in the session.** Check `Marketplace:RepositoryUrl` from step 7. The public marketplace needs no token.

For anything else, see the human guide's [When something does not work](INSTALL_AND_CONFIG.md).

---

## Done

Tell the person:

- what was installed;
- where the Launcher, the settings root and the workspace are;
- that the organisation layer (`<settings-root>\CLAUDE.org.md`) is still the sample and should be filled in;
- that the next step is the first story: in the new agent session, declare the topology, then ask for a small change. This is Part 3 of the [human guide](INSTALL_AND_CONFIG.md).

## Related pages

[Installing and configuring Kyklos](INSTALL_AND_CONFIG.md), [The three components](COMPONENTS.md), [Secrets](SECRETS.md), [Project topologies](TOPOLOGIES.md), and [the README](../README.md) for the full list.
