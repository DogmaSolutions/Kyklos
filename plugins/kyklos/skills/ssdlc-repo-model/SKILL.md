---
name: ssdlc-repo-model
description: Declare a project's REPOSITORY MODEL once (internal single-repo vs companion+nested-public vs a trunk-based tooling repo) so the GitFlow / push / branch-cleanup / close-on-green guards enforce the RIGHT discipline per repo instead of guessing. Use at project onboarding, or whenever a guard reports the wrong workflow (a trunk repo blocked as if it were GitFlow, or a companion's nested source miscounted). On first use it interviews the developer and persists the model to .claude/standards.env + a CLAUDE.md '## Repository model' section; later runs just read it.
---

# ssdlc-repo-model — declare the repository model once, then reuse

The **doer** that ESTABLISHES a project's repository shape so the enforcement guards
(`kyklos-gitflow-branch-guard`, `kyklos-no-push-guard`, `kyklos-branch-cleanup-guard`, and the
`kyklos-story-proof-guard` close-on-green path) each enforce the workflow that actually applies to the repo the
operation targets — rather than assuming GitFlow everywhere. Declaring the model is a one-time onboarding; every
later run reads the persisted answer.

## Why declare it (the guards read it)

A project is one of a few shapes, and they need DIFFERENT discipline:

- **internal** — a single private repo that IS the product. It runs its declared source workflow (usually
  GitFlow: branch off `develop`, merge back, delete). A purely-tooling internal repo may instead be **trunk**
  (commit straight to the trunk on purpose — no per-task branch).
- **companion** — a private companion repo at the workspace root holds all the agent/infra tooling and the
  story backlog and is **trunk-based bookkeeping** (commit the trunk on meaningful events — story opened /
  closed, epoch change); the shippable product source is cloned **nested** at a sub-directory (the SOURCE_DIR)
  and runs its own workflow (usually GitFlow + the CI loop). Committing straight to the companion's trunk is
  CORRECT there, not a GitFlow violation — but the guards can only know that if the model is declared.
  The nested source is **AI-artifact-free** (it is mirrored to a public repo, so it carries NO `.claude/` of its
  own). It does **not** declare its own model and must never be given a `.claude/standards.env` (that would leak an
  AI artifact into the public mirror). Instead the guards read the source's model from the **parent companion's**
  `.claude/standards.env` (`KYKLOS_SOURCE_DIR` + `KYKLOS_SOURCE_WORKFLOW`), intrinsically from the on-disk
  companion+source nesting — so `KYKLOS_REPO_MODEL_REQUIRED` (on by default) never false-blocks work under the nested source.
  A linked worktree of the nested source (`git worktree add`, wherever it lives) resolves through its main checkout,
  so every guard treats it as the source too; the `public-push-artifact-guard` then refuses any push into a public
  source that carries an AI artifact.

If the model is **unset**, every guard falls back to plain GitFlow (the back-compatible default): nothing
blocks that used not to, and nothing is silently loosened. Declaring the model is what unlocks the
trunk-aware and companion-aware behaviour.

## The persisted variables (the machine-read source of truth)

Persisted in **`.claude/standards.env`** (runtime-editable — edit a line mid-session with no restart) and
mirrored as human-readable prose in the **`CLAUDE.md` `## Repository model`** section. You **declare one
TOPOLOGY** via `topology-declare.sh`; it DERIVES the rest (**declare once → derive everything**, so the set can
never be internally inconsistent). Do not hand-set the derived knobs — re-run the interview to change them:

| Variable | Meaning | Values |
|----------|---------|--------|
| `KYKLOS_PROJECT_TOPOLOGY` | **the declared topology** (the one input; everything below is derived) | `PriComPubSou` (companion + nested public source) \| `PriComPriSou` (companion + nested private source(s)) \| `PriSta` (single private repo) \| `PriSouPubArt` (private source + public artifact facade) |
| `KYKLOS_REPO_SHAPE` | *(derived)* the project shape | `internal` \| `companion` |
| `KYKLOS_SOURCE_DIR` | *(derived; the companion topologies PriComPubSou/PriComPriSou)* the nested source dir, relative to the workspace root (the CI loop pushes HERE) | e.g. `Repo` |
| `KYKLOS_SOURCE_WORKFLOW` | *(derived)* the product/source repo's discipline | `gitflow` \| `trunk` |
| `KYKLOS_ARTIFACT_PROJECT` | *(derived; PriSouPubArt only)* the public artifact project id the routing cross-check must protect | e.g. `1` |
| `KYKLOS_CI_SELF_DRIVE` | *(separate, not topology-derived)* whether THIS container's token can self-drive real CI (a push yields a config-resolved, non-empty pipeline) | `true` \| `false` |

## Step 0 — is the model already declared? (interview once, then reuse)

Decide mechanically with the gate (don't eyeball it):

    bash "$CLAUDE_PLUGIN_ROOT/skills/ssdlc-repo-model/has-repo-model.sh" --authorize-interview CLAUDE.md   # exit 0 present, 1 absent

- **Exit 0 (section EXISTS)** → the model is declared; just read it. Do **not** interview.
- **Exit 1 (ABSENT — first use)** → run the **first-run interview** below, then **write** the section into
  `CLAUDE.md` AND `.claude/standards.env` by running the declarer (Step 1).
  (The `--authorize-interview` flag above makes this gate authorize the next question on an ABSENT model, so
  the first-run interview passes the ask-user-guard by construction — no hand-crafted override. A guard that only
  DETECTS the model omits the flag.)

## First-run interview (agent ⇄ developer)

Ask the developer the SINGLE **Project Topology** question — their answer is all you need; the Kyklos DERIVES
every knob from it (the agent sets none by hand). The derivation is `hooks/lib/topology.sh`; the policy side is the corporate policy's Project structure section.

1. **Project Topology** — which of the four is this User project?
   - **PriComPubSou** (Private Companion + Public Sources) — a private companion at the workspace root holds the
     AI/infra tooling + backlog + pipeline (**trunk**), and the shippable **public** source is cloned **nested**
     at a sub-dir (default `Repo`), running **gitflow**. *Example: an open-source library with a private companion.*
   - **PriComPriSou** (Private Companion + Private Sources) — like PriComPubSou (private companion at the root, its
     nested source at a sub-dir, default `Repo`, **gitflow**), but the nested source is **PRIVATE** and may be **many**
     private repos whose remotes are off our GitLab (e.g. a customer's). Because the source is private, it is **not**
     held to the public source's AI-artifact-free bar. *Example: a customer companion whose `Repo/` holds many private
     source repos.*
   - **PriSta** (Private Standalone) — ONE private repo holds everything, **gitflow**. *Example: an internal tooling repository.*
   - **PriSouPubArt** (Private Sources + Public Artifacts) — a **private** source repo holds everything incl. the
     source (**gitflow**); only build **artifacts** are published to a separate **public façade** repo that is
     **never cloned**. *Examples: a plugin marketplace, a shared CI-template repository.*

   (For PriComPubSou/PriComPriSou, also confirm the nested source dir if it is not `Repo`.)
   (For **PriSouPubArt**, also capture the **public artifact project** — the GitLab project id of the façade — so the
   derived-routing cross-check can refuse ever routing a story/issue into it: `--artifact-project <id>`.)

## Step 1 — persist (ONE deterministic call — the agent sets no knob by hand)

Run the declarer; it writes `.claude/standards.env` (the topology **and** the derived knobs the guards read) AND
the `CLAUDE.md` `## Repository model` section, **atomically and idempotently**, from the topology alone:

    bash "$CLAUDE_PLUGIN_ROOT/skills/ssdlc-repo-model/topology-declare.sh" \
        <PriComPubSou|PriComPriSou|PriSta|PriSouPubArt> \
        [--srcdir Repo]              # PriComPubSou/PriComPriSou: the nested source dir \
        [--artifact-project <id>] # PriSouPubArt only: the public façade project id routing must avoid

Do **NOT** hand-edit the derived knobs — the topology derivation (`hooks/lib/topology.sh`) is the single source of
truth, and a hand-set knob that contradicts the topology is refused downstream (the derived-routing cross-check). To change the model later, re-run the declarer with the new topology.

## Report (for the Proof Evidence)
State the declared shape + the values the declarer wrote, and confirm the `## Repository model` section is present
(the gate returns 0). That is the evidence a guard's model-aware behaviour is grounded in a real declaration.
