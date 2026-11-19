# Working as a team

[← Back to the README](https://github.com/DogmaSolutions/Kyklos/blob/main/README.md)

Kyklos is installed **per computer**: each person runs their own [Kyklos Launcher](COMPONENTS.md#kyklos-launcher), their own [Kyklos Bridge](COMPONENTS.md#kyklos-bridge) and their own agent container. A team works on one project by sharing what lives on a server (the Git repositories, the GitLab project, optionally a secrets manager) while each person keeps the part that belongs to their computer and their identity. This page says which side each piece is on, why, and what that means in daily work.

## Friction points and how to handle them

Most prominent first. Each one is a property of the product today; the way to live with it is given beside it.

1. **The proof signing key is per computer by default.** The proof tokens, the adversarial-review tokens and the coverage ledger lines a Bridge signs verify only with the key that signed them, so evidence made on one computer does not verify on a teammate's. **Handle it:** set up one shared key in a secrets manager from day one: one person presses **Export to the secrets manager**, every computer switches its key source to `secrets-manager` (or presses **Import from the secrets manager**), and everyone checks that the panels show the same fingerprint (see [below](#a-story-that-moves-between-computers)).
2. **Proof evidence stays on the computer that made it.** The ledger and the Test Discipline tokens live in each Bridge's state folder and are never shared. **Handle it:** closing a teammate's story means running once the tests that cover its changed lines (only those, not the whole suite); with a shared key, a posted coverage receipt can be imported instead.
3. **The project values are entered per Launcher.** Each computer keeps its own configuration, and a change on one does not reach the others. **Handle it:** keep the team's exported configuration file in one shared private place (for example the companion repository or a private team repository; not a public source repository, because it names folders and settings of a person's setup), import it, and hand over a new export after every change (see [below](#handing-over-the-configuration)).
4. **The Bridge settings file lives on each computer.** **Handle it:** keep it in a Git repository, commit and push every change, and have each person pull their clone; the Launcher warns while a clone differs from its upstream copy.
5. **Own Lane keeps agents off each other's stories.** A teammate's agent cannot change a story assigned to you. **Handle it:** reassign the story in GitLab before a teammate's agent takes it over (see [below](#who-works-on-what-own-lane)).

## What the team shares

| What | Where it lives | Why it is shared |
|---|---|---|
| **The project's own files**: the project `CLAUDE.md` ([Level 2 of the policy](POLICY_LEVELS.md)), the repository model in `.claude/standards.env`, `.gitignore`, `.gitattributes`, the default scenario | the project's repository (in a companion [topology](TOPOLOGIES.md), the companion), pushed to its shared remote | every person's agent reads the same project rules and the same repository model. The first launch writes only the files that are missing, so a person who joins gets the team's files from the clone and nothing is overwritten |
| **Stories, epics, proofs, reviews, risk registers and coverage receipts** | the GitLab story project ([GitLab storage](STORAGES.md#gitlab-storage-the-ssot-for-team-projects)) | GitLab is the single source of truth: everyone sees the same backlog, and the evidence a close needs is posted where every team member can read it. The `Stories/` folder in the workspace is only a copy generated from GitLab |
| **Pipelines and merge requests** | the GitLab projects of the source (and the companion) | every agent follows the same pipelines and merges only through them (see [CI](CI.md) and [Git](GIT.md)) |
| **The Corporate policy** (Level 1) | a Git repository named by `KYKLOS_CORPORATE_POLICY_URL` (with its branch, path and token name, see [Policy levels](POLICY_LEVELS.md#settings)) | each Launcher reads it on its own computer at every launch, so a change pushed once reaches every person's next launch. The alternative, a local file (`Launcher:Projects:PolicyOrganisationLayer`), exists on one computer only |
| **The Bridge settings file**, when the project needs one | a Git repository that each person clones on their computer and names as the Launcher's settings folder (`Launcher:Projects:SettingsRoot`), holding `projects/<project name>/appsettings.Production.json` (formerly `bridge.appsettings.json`, which the Bridge renames) (see section 6.1 of [Installing and configuring Kyklos](INSTALL_AND_CONFIG.md)) | the file decides what the agent may reach, so a change to it should be recorded and reviewed. The Launcher warns (never refuses) when the file is not committed, has local changes or differs from its upstream copy |
| **The proof signing key** (optional) | one entry in a secrets manager every team member's Bridge can read (`KYKLOS_PROOF_KEY_SOURCE=secrets-manager`) | evidence signed by one Bridge verifies only with the same key. With one shared key, a story proven on one computer can close on another (see [below](#a-story-that-moves-between-computers)) |
| **The project values of the configuration** | agreed by the team, handed over as an exported configuration file (see [below](#handing-over-the-configuration)) | the GitLab address, story project, CI project, push addresses, topology, source folder, story store, secrets mode and build channel describe the project, not the person, so they are the same for everyone |

## What stays personal

| What | Where it lives | Why it stays personal |
|---|---|---|
| **The Launcher configuration** | on each computer, one file per project, by default in `%APPDATA%\KyklosLauncher\configs` | it holds what only fits one computer and one person: the workspace folder (`WORKSPACE_PATH`), extra folders (`EXTRA_MOUNTS`), how the agent is started (`KYKLOS_AGENT_ARGUMENTS`, for example whether it runs without permission prompts), the names under which this person stored their credentials, the agent's name and the commit author |
| **The agent's identity** | the GitLab user the person's tokens belong to (`KYKLOS_AGENT_NAME`), the commit author (`KYKLOS_GIT_AUTHOR_NAME`, `KYKLOS_GIT_AUTHOR_EMAIL`), and the account the agent program signs in to | each change, note and merge request should say whose agent made it, and [Own Lane](#who-works-on-what-own-lane) tells agents apart by their GitLab user |
| **Credentials** | each computer's credential store (the Windows Credential Manager, or a secrets manager or the encrypted vault on Linux): the story token, the push token, the Launcher's login, and the proof signing key when it is kept per computer | a token acts as its user; sharing one would make every person's agent the same user. See [Secrets](SECRETS.md) |
| **Machine-bound evidence** | the Bridge's state folder on each computer (`KYKLOS_BRIDGE_STATE_DIR`): the content ledger, the Test Discipline tokens and the trunk-base cache | each record is signed by the Bridge that watched the run; see [Where the evidence lives, and what a team shares](PROOF_DIMENSION_TEST_DISCIPLINE.md#where-the-evidence-lives-and-what-a-team-shares) |

**Give each person's agent its own GitLab user.** Two people whose agents act as the same GitLab user cannot be told apart: their stories look like the same owner's, and Own Lane cannot keep their agents off each other's work.

## Who works on what: Own Lane

With the GitLab story store, an agent works only on stories **assigned to its own GitLab user or to nobody** (setting `STORY_OWN_LANE`, on by default).

- **Claiming.** A story nobody is assigned to is claimed by the agent that starts it. GitLab cannot refuse a second writer, so when two agents claim the same story at the same moment, the claim reads the story again after a short wait (`STORY_CLAIM_SETTLE_SECONDS`, 2 seconds by default) and the agent that lost is told.
- **Another person's story.** Every change to it (status, phase, specification, proof, review, close) is refused, naming its owner. The next-work answer lists such stories by name, as left out, so nothing is hidden.
- **Handing a story over.** Reassign it in GitLab; the new owner's agent can then continue it.
- **Ownership that cannot be read** is never assumed: the change is refused until GitLab answers.

**Limitation: the file-system story store has no assignees**, so Own Lane does not apply, and the stories reach other people only through commits and pushes. For a team, use the GitLab story store.

## Handing over the configuration

There is no shared configuration store: each Launcher keeps its own. To give a team member the project values, the person who set up the project opens the saved configuration in the Launcher and presses **Export** (the configuration must be saved first). The downloaded file holds the stored values without any secret: settings that hold a secret value are left out, and the export is refused if a value equals a stored credential. The team member presses **Import…** on their configurations list, picks the file (a name that already exists can be imported under another name), then changes the personal values listed above before the first launch. The Launcher's **Check** then tests the result on their computer.

A configuration change made later on one computer does not reach the others: tell the team, or hand over a new export.

## Daily consequences

### A story that moves between computers

The coverage evidence a close needs is signed by the Bridge that ran the tests, with that computer's key.

- **Each computer keeps its own key** (the default, `KYKLOS_PROOF_KEY_SOURCE=host`): a story measured on one computer closes most easily from that computer. Closed from another, that Bridge finds no evidence of its own, and the agent runs once the tests that cover the story's changed lines. Nothing is lost: the evidence is keyed by file content, so only those tests run, not the whole suite.
- **The team shares one key** through a secrets manager: when the coverage run posted a receipt on the story, the agent on the other computer can import the receipt's facts (`coverage_receipt_import`); the Bridge checks them against the shared key and the story needs no new run. Everyone who can read the shared entry can sign, so the entry is restricted to the team and denied to every agent. How to set it up, and how to check that every computer holds the same key (the panels show the same **fingerprint**): [the proof signing key in Secrets](SECRETS.md#the-proof-signing-key-where-it-comes-from), and section 4.5 of [Installing and configuring Kyklos](INSTALL_AND_CONFIG.md).

### When a shared piece changes

| Change | When it reaches each person |
|---|---|
| Project files (`CLAUDE.md`, `.claude/standards.env`) | when they pull the repository. If the configuration's values disagree with the committed `.claude/standards.env`, the **Check** warns (`configuration.standards-drift`) |
| Corporate policy | at each person's next launch; when the repository cannot be read, the Launcher uses its last good copy and says so ([details](POLICY_LEVELS.md#when-the-repository-cannot-be-read)) |
| Bridge settings file | when each person pulls their clone of the settings repository; until then their Launcher warns that the file differs from its upstream copy |
| Shared proof signing key | at each Bridge's next start |
| Stories, proofs, receipts | at once: they are read from GitLab |

## Set up a project for a team

1. Use the **GitLab story store**, and add each team member's agent user to the story project (and in a companion topology to the source project) with the Developer role.
2. Choose the [topology](TOPOLOGIES.md) and launch once, then commit and push the project files the first launch wrote (`CLAUDE.md`, `.claude/standards.env` and the others it lists).
3. If your organisation has a Corporate policy, keep it in a Git repository and set `KYKLOS_CORPORATE_POLICY_URL` (see [Policy levels](POLICY_LEVELS.md)).
4. If the project needs a Bridge settings file, keep it in a shared place outside every workspace (for example a Git repository every member pulls), and use the same project name everywhere: the folder name under `projects/` must equal it.
5. If stories should close from any team member's computer, share the proof signing key through a secrets manager (**Export to the secrets manager**).
6. **Export** the configuration and give the file to the team, with the list of personal values each person must set.

## Join a team project

1. Install Kyklos on your computer ([human guide](INSTALL_AND_CONFIG.md), or [with an agent](AGENT_INSTALL.md)).
2. Get your own agent user on GitLab, added to the project by the team, and create its tokens (story token, push token).
3. Clone the project's repositories into your workspace folder; the team's project files come with the clone.
4. **Import…** the team's exported configuration, then set your own values: workspace folder, extra folders, agent arguments, the agent's name, the commit author and the names of your credentials. Store your tokens under those names.
5. If the team keeps a Bridge settings repository, clone it and name your clone in `Launcher:Projects:SettingsRoot`.
6. If the team shares the proof signing key, set the key source to `secrets-manager` (or press **Import from the secrets manager**) **before the first launch**.
7. Press **Check**, fix what it names, and launch.

## Related pages

[Storages](STORAGES.md), [Secrets](SECRETS.md), [Policy levels](POLICY_LEVELS.md), [Project topologies](TOPOLOGIES.md), [Test Discipline](PROOF_DIMENSION_TEST_DISCIPLINE.md), [Installing and configuring Kyklos](INSTALL_AND_CONFIG.md), and [the README](https://github.com/DogmaSolutions/Kyklos/blob/main/README.md) for the full list.
