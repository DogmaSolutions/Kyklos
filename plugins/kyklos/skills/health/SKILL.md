---
name: health
description: Run the full Kyklos doctor on demand: the bridge's checks (the same engine as the launcher's Check button) plus the session's own checks (the tokens the agent can read, the story mirror). Use when a bridge verb fails or answers oddly, when a guard refuses and the cause may be a setting, before long host work (a build, a coverage run, a close) on a bridge you have not used yet, when the person asks "is everything set up right?" or "is the bridge healthy?", or runs /kyklos:health. Shows the reports as they are.
---

# health: run the full doctor now

The full set has two parts, both read-only, and this skill runs both on demand (at session start they run on their own):

- the **bridge's checks**: which project the bridge's token cannot read, whether the host's test runner (`dotnet`)
  answers, whether CI access works for each project, whether the content ledger can be read (steps 1 to 4 below);
- the **session's own checks**: whether the agent can read a token that can call the GitLab API, and whether the story
  mirror may lag the tracker (step 5).

Use it instead of guessing why a verb fails. For the checks only the host can run (disk, Docker, policy files, launch
configuration) the person uses the Launcher's Check button. If a finding or a refusal is not explained here, load the skill
`kyklos-reference` and look the message up in its troubleshooting guide.

## At session start

The plugin asks the same verb when a session starts (`hooks/kyklos-doctor-surface.sh`, bounded by
`KYKLOS_DOCTOR_TIMEOUT_SECONDS`, 15 seconds at most). Every finding it makes is in your starting context with its fix: your
first message to the person reports each one before any other work, and you never reorient silently. The same hook runs two
health checks itself that used to warn on their own, the tokens you can read that can call the GitLab API (limited to 15
seconds; one that runs out of time is reported as failed) and a story mirror that may lag GitLab. Every start, resume and
compact checks afresh. A bridge that does not answer or does not know the verb gives one short line instead. The report
stays one run: ask again with the steps below, not by reproducing the checks.

A `NO` that stands is also the one reason, besides a real question to the person, that lets you end your turn while open work
remains: report it by name in your closing message (the check's identifier, what it found, its fix line) and the continue
guard allows the stop for this session. It checks again with the bridge at that moment, so a problem you have fixed no longer
counts; a doctor that could not run (no answer, an older bridge) is not a `NO` and never allows a stop.

## Steps

1. Call the bridge verb `mcp__KyklosBridge__doctor` (no arguments). From a shell: `bridge doctor`. It starts a run, or
   joins the one already going (for example one the person started with the Check button on the bridge's Health page), and
   waits for it to end; allow it up to about a minute when GitLab is slow.
2. Show the answer's text exactly as it came (the plain-text report: a summary line, then one line per check as
   `[YES]`, `[NO]`, `[CANNOT TELL]`, `[N/A]` or `[WARN]` with what it found and, indented, how to fix it). Do not drop lines,
   merge them or reword them. Add your own summary below it if it helps.
3. Read the report this way:
   - `[NO]` is a problem the check found; its fix line names what to change.
   - `[CANNOT TELL]` is never a pass: the check could not read what it needed (GitLab did not answer, the check ran out
     of time, the run was cancelled). Run it again, or read the reason.
   - `[NOT VISIBLE]` lines are checks the bridge cannot run from where it stands (the host's disk, Docker, the policy files
     and the project's launch configuration). They are not counted as passing. The launcher's Check button on the host
     covers them; tell the person that, do not try to run them yourself.
4. A bridge without the verb answers "unknown tool" (an older bridge): say so, name the bridge version `get_status`
   reports, and do not try to reproduce the bridge's checks with other tools; go on to step 5.
5. Run the session's own checks as well, whatever the bridge answered. Run this one command (it reads only, and prints
   nothing when both checks pass) and show its output as it is:
   `bash -c '. "${CLAUDE_PLUGIN_ROOT}/hooks/lib/session-health.sh"; kyklos_health_api_scope; kyklos_health_story_mirror "$(kyklos_health_project_dir)"'`
   It takes up to 30 seconds. A line about a token or a stale mirror is a finding: report it with its fix like a `[NO]`.
   Then say plainly which parts ran and answered (the bridge's report, the session's own checks), so the person knows what
   was covered.

## What it does not do

The verb only reads: it changes nothing on the host, and neither does this skill. It does not repair what it finds: a fix
that needs the host (a token, an installed SDK, a relaunch) is the person's, so give them the fix line and what it concerns.
Never put a token or a secret value in what you pass on; the report never holds one.
