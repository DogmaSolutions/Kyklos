---
name: kyklos-reference
description: Kyklos reference and troubleshooting. Load it whenever anything about Kyklos fails, is refused by a guard, or is unclear: a refused push, merge, commit or story close, a bridge that does not answer, a doctor finding, a setting that seems ignored, or a question about how the workflow, policy, proof table or components work. It holds the index of the guides and, when no guide solves a problem, drafts a report for the person to submit.
---

# Kyklos reference and troubleshooting

Use this when something about Kyklos fails or is unclear. Do not guess and do not work around a guard: find the symptom in
the guides, apply the fix that is yours, and tell the person plainly what only they can do.

## Where the guides are

The installed plugin carries the guides of exactly its own version, in the `guides` folder next to this plugin
(`${CLAUDE_PLUGIN_ROOT}/guides/`). Read only the one you need, on demand. If that folder is missing (a plugin from a
source checkout, or an older plugin), the same guides are in `dist/public/docs/` of the Kyklos source, or online at
https://github.com/DogmaSolutions/Kyklos/tree/main/docs.

## Index

| You have | Read |
|---|---|
| A message from a guard or the bridge (refused, blocked, cannot verify) | `TROUBLESHOOTING.md`: find the message by its first words |
| A push refused | `TROUBLESHOOTING.md`, section "Push refused"; the rules in `GIT.md` |
| A story that will not close, a proof row, a draft | `TROUBLESHOOTING.md` ("Story close blocked", "Proof draft refused"); `PROOF.md`, `PROOF_DIMENSION_*.md`, `AGILE.md` |
| Merge, arming, coverage, merged result, pipeline | `TROUBLESHOOTING.md`; `WORKFLOW.md`, `CI.md`, `PROOF_DIMENSION_TEST_DISCIPLINE.md` |
| The bridge does not answer | `TROUBLESHOOTING.md` ("Bridge unreachable"); `COMPONENTS.md` |
| A setting that seems ignored, a missing capability | the `health` skill (run the doctor first); `INSTALL_AND_CONFIG.md`, `POLICY_LEVELS.md`, `TOPOLOGIES.md`, `STORAGES.md`, `SECRETS.md` |
| How the hooks and skills work | `HOOKS_AND_SKILLS.md` |
| What is supported (languages, tools) | `SUPPORT_MATRIX.md` |
| Concepts and standards | `KB.md`, `COMPONENTS.md`, `WORKFLOW.md` |
| Several people on one project: what is shared, what stays personal | `TEAMS.md` |
| Why an issue is or is not offered as the next work, the order, severity | `NEXT_WORK.md` |

## Steps

1. **Read the exact message.** Quote it in full when you report. Never paraphrase an error away.
2. **Run the doctor** (the `health` skill) when the problem might be configuration or the bridge. Its report is the
   fact base: say what it found, before you propose a fix.
3. **Find the symptom** in `TROUBLESHOOTING.md` and follow it: the cause, the confirming check, the fix, and who applies it.
   Do the agent's part. For a person's part (a setting, a token, a relaunch, an override) give them the exact step and
   why only they can do it; never apply an override yourself.
4. **Report to the person** what failed, what you tried and what you need from them, before any other work.
5. If the guide does not solve it, **draft an issue** (below).

## Drafting an issue when the guide does not solve it

The person reviews and submits the report; you never post it, open it, or send it anywhere. Write it to a file in the
session's scratch folder, show its full text, and tell the person where to submit it
(https://github.com/DogmaSolutions/Kyklos/issues). The draft holds, in this order:

1. **Summary**: one sentence, what you wanted to do and what happened.
2. **Versions**: the plugin version (its `plugin.json`), the bridge version (`get_status`), the launcher version if the
   person knows it, the operating system of the host and of the container.
3. **Doctor report**: the plain-text report of the `health` skill, as it came, after removing secrets (below).
4. **Exact messages**: each refusal or error, copied in full.
5. **Steps tried**: what you did from the guide and what each step answered.
6. **Expected and actual**: what should have happened and what happened instead.

**What the draft never contains.** It is built to be safe to publish:

- no token, password, key or any secret value, and no environment value that could be one: only the names of settings
  and the scopes a token was found to have;
- none of the customer's or organisation's own names: company, project, group, repository, branch and story titles;
- no host names, addresses, ports or file paths of the person's machines: write `<host>`, `<address>`, `<path>`;
- no source code and no file contents of the project;
- no personal identities: people's names, e-mail addresses, GitLab or other user names, and the git author (write `<person>`, `<email>`, `<user>`);
- no internal issue or story numbers of the project.

Replace each such item with a neutral placeholder (`<project>`, `<host>`, `<token>`), then read the whole draft once more
as a stranger would. Tell the person what you replaced, so they can check it before submitting. If you cannot tell
whether something is private, remove it and say so.
