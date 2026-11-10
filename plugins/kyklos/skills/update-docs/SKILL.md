---
name: update-docs
description: The doer for the ssdlc-story-proof "Documentation" dimension. Use whenever a change touches doc-impacting surface — a public API/CLI, config, a CI consumer-contract, or user-facing behaviour — even when the user only says "update the docs", "is the README still right?", or is about to close a story. Finds the docs a change impacts, updates them to EXIST/COHERENT/COMPLETE/AUDIENCE-proper, and runs an audience lint that fails on internal content leaking into a consumer-facing file. On first use in a project it interviews the developer for the doc conventions and persists them.
---

# update-docs — keep impacted docs true, complete, and audience-correct

The **doer** for the [`ssdlc-story-proof`] **Documentation** dimension (which is only the *auditor* — same
audit↔doer split as [`ssdlc-deduplicate`] ↔ Non-Duplication and [`running-tests`] ↔ Test Discipline). Recall it
the moment a change could have made a doc wrong — not just at story close.

## When to recall (pertinence)

PERTINENT when the change touches an **external contract or user-facing behaviour**: a public API/CLI surface, a
config key/default, a CI consumer-contract (a template/variable other repos include), an install/usage step, or
anything a consumer or a future maintainer must re-learn. A purely internal refactor with no observable change is
`NOT_PERTINENT` (say so, with the reason). When unsure, recall it — verifying "the docs are still true" is cheap.

## Step 0 — load the project's doc conventions (interview once, then never again)

The conventions are **persisted in the repo** so they are team-wide, survive context compaction, and are a
systematic part of the workflow — not re-derived each session. Read them from the project's **`CLAUDE.md`
`## Documentation conventions`** section (the source of truth; for a companion/nested-public project this is the
companion's `CLAUDE.md`, which never ships to the public source — so the conventions themselves never leak).

Decide mechanically with the gate (don't eyeball it):

    bash "$CLAUDE_PLUGIN_ROOT/skills/update-docs/has-doc-conventions.sh" CLAUDE.md   # exit 0 = present, 1 = absent

- **Exit 0 (section EXISTS)** → use it. Do **not** interview.
- **Exit 1 (ABSENT — first use in this project)** → run the **first-run interview** below, then **write** the
  section into `CLAUDE.md` (and drop a one-line pointer in the agent memory index for cross-session recall). This
  is a one-time onboarding; every later run's gate returns 0, so it just reads it.

**HARD-ENFORCED (not just guidance):** `kyklos-story-proof-guard` blocks closing a story that, this session, marks the
**Documentation** dimension **PROVEN** while `CLAUDE.md` has **no `## Documentation conventions`** section — i.e. the
first-run interview was skipped. So the audience policy + canonical locations must be established with the developer
before "audience-proper" can be claimed. (`NOT_PERTINENT` stays agent-decidable for a genuinely doc-less change.)

### First-run interview (agent ⇄ developer)

Ask the developer to confirm or override these **best-practice defaults** (propose them; their answers win and are
what you persist):

1. **Doc model / templates** — default **Diátaxis** (Tutorial · How-to · Reference · Explanation): each doc
   declares which mode it is, which fixes its audience and its "complete" bar. (Alternatives: lightweight
   README + `docs/<topic>.md` index; arc42 for architecture.)
2. **Canonical locations** per repo shape —
   - *internal* (single private repo): `README.md` + `docs/` + per-service `services/<name>/README.md`.
   - *companion / nested-public*: **consumer** docs live in the public source (`Repo/README.md`, `Repo/docs/`);
     **internal** docs live in the companion only (`docs/`, `CLAUDE.md`, `Stories/`) — never inside `Repo/`.
3. **Audience policy** — what is INTERNAL (never in a consumer-facing file): infra hostnames/IPs, runner/CI
   internals, account/secret locations, network topology, private repo/URL scaffolding ("DISTRIBUTION repo",
   "do-not-edit / CI-populated"), and agent-facing artefacts (agent-memory fragments, orphan planning titles like
   "Ships (v0.1)"). Confirm the project's specifics.
4. **Pertinence trigger** — default: external-contract or user-facing behaviour change (above). Confirm.

Persist the confirmed answers verbatim under `## Documentation conventions` in `CLAUDE.md`, then proceed.

## Step 1 — find the docs the change impacts

From the story/diff, list the docs that describe the touched surface: public READMEs, `docs/` topics, per-service
runbooks, CLI `--help`/usage, config references, CHANGELOG/HISTORY, and any consumer-facing index that links them.
Missing-but-required counts as impacted (criterion **EXIST**).

## Step 2 — update each to the four criteria

- **(a) EXIST** — create the doc the change requires if it is missing (at the canonical location for the repo shape).
- **(b) COHERENT** — reconcile every claim with the *shipped* behaviour: names, flags, defaults, versions, commands.
  A doc that contradicts the code is worse than none. Prefer showing the real, runnable command/signature.
- **(c) COMPLETE** — to the file's declared level/mode (a Reference page lists every option; a How-to covers the
  whole task). Don't half-document a new surface.
- **(d) AUDIENCE-PROPER** — write each file for **its** reader. Internal detail belongs in internal docs; a
  consumer-facing file gets only what a consumer needs. This is the failure this dimension exists to catch.

Docs describing a change go in the **same commit** as the change (policy rule) — never split.

## Step 3 — run the audience lint (poka-yoke)

`audience-lint.sh` greps a set of **consumer-facing** files for the INTERNAL patterns from the conventions and
**fails (exit 1)** on any hit — so an internal leak cannot silently ship. Run it over the files you touched:

    bash "$CLAUDE_PLUGIN_ROOT/skills/update-docs/audience-lint.sh" <consumer-facing-file>...

Extend its pattern set from the project's audience policy. A hit is a finding to fix (move the detail to an
internal doc), not to suppress. Passing the lint on every consumer-facing file is part of the dimension's PROVEN.

The built-in pattern set is **generic**: it names nothing of any one organisation, so it can ship to anyone. Your
organisation's own markers (its domain, secret-store paths, CI variable names) are **configuration**, added to the
built-in set at run time from either or both of:

- `AUDIENCE_LINT_ORG_PATTERNS`: entries one per line, typically a CI/CD or launcher-provided variable;
- a pattern file, one entry per line: `AUDIENCE_LINT_ORG_PATTERNS_FILE`, or by default the project's own
  `.claude/audience-lint-org-patterns.txt` (keep it in a repository that is never published).

An entry is a plain pattern, a `re` entry (category, `cs` or `ci`, pattern) or a `sealed` entry: names given only as
salted SHA-256 hashes of the words (the launcher writes this form, so a container never holds the names in clear text);
the format is described in `audience-lint-org-patterns.sh`. A finding names the entry's category and the matched line,
never a pattern or a hash.

With neither configured, the generic set still runs and the lint prints one `NOTICE` line on stderr saying the
organisation patterns are absent. A named organisation file that cannot be read, or an invalid pattern, stops the
lint (exit 2). The cross-repository write guard reads the same organisation patterns (matching them regardless of
case) and blocks on the same configuration errors, so one configuration covers both.

The same engine checks other kinds of file through four more environment variables:

| Variable | Effect |
|---|---|
| `AUDIENCE_LINT_EXTRA_PATTERNS` | newline-separated extra patterns, added to the set in use |
| `AUDIENCE_LINT_PATTERNS_FILE` | another pattern set (one pattern per line) that REPLACES the built-in one, e.g. a set for test and CI files; the organisation patterns are not added to a replaced set (its caller brings its own) |
| `AUDIENCE_LINT_ALLOW_FILE` | a reviewed allow-list, one `<path glob><TAB><line pattern><TAB><reason>` per line; a hit is skipped only when both the path and the line match, and an entry without a reason stops the lint (exit 2) |
| `AUDIENCE_LINT_CASE_SENSITIVE=1` | match exact case (for upper-case id formats that ordinary lower-case prose must not trip) |

An allow-list entry is for test data or a format example, never for a real reference: fix those instead.

## Report (for the Proof Evidence)

Record: the docs updated (path + what changed), any created to satisfy EXIST, and the audience-lint result on the
consumer-facing files. That is the evidence the **Documentation** dimension cites for its `PROVEN` verdict.

## Emit the proof token (when the Documentation tool-gate is armed)

After the docs are updated + the audience lint passes, record a content-anchored token over the exact source files
the change touched, so the Documentation Proof row cannot be marked PROVEN without this pass having run over the
current file state:

```sh
"$CLAUDE_PLUGIN_ROOT/hooks/lib/proof-tool-gate.sh" emit "Documentation" <the source files the change touched>
```

Tokens are bound to ONE story, so stories proven in parallel in the same container never overwrite or satisfy each
other. The story is taken from the branch name (`story-<N>`) or the HEAD commit's `Refs: #<N>`; when neither names
it, pass it explicitly: `proof-tool-gate.sh emit --story <N> "Documentation" <files>`.

Any later edit to those files invalidates the token (the story-proof guard re-hashes them at close), so run this
LAST, after the docs are settled. The close gate checks this token by default (the check is in
`hooks/kyklos-story-proof-guard.sh`, the token in `hooks/lib/proof-tool-gate.sh`).
