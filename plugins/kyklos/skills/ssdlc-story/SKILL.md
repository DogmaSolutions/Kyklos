---
name: ssdlc-story
description: Spec-driven, multi-file task planning for a repository backlog — one story folder per unit of work under `Stories/` (index `Stories/BACKLOG.md`), with EITHER GitLab issues or the local filesystem as the source of truth (chosen by STORY_BACKEND). Use when starting or continuing any multi-step task that could span a compaction, or when the user asks for a story/backlog. Stories live under the `Stories/` folder at the WORKSPACE ROOT.
---

# ssdlc-story — spec-driven task planning

A spec-driven story workflow: the backlog and stories are one folder per unit of work under the **`Stories/`** folder at
the **workspace root**, each with requirements + acceptance criteria + a checklist — replacing a single monolithic
`PLAN.md` with **user stories**. The **source of truth is either GitLab issues or the local filesystem**, selected by
`STORY_BACKEND` (with GitLab, the local `Stories/` tree is a generated offline **mirror** of the issues). The index is
`Stories/BACKLOG.md` — the single entry point (read it first, like `MEMORY.md`). Kyklos's
`session-continuation-guard` gates on it (a continuation re-orients through it to the ACTIVE story) and
`story-backlog-guard` keeps it internally consistent.

**Location rule (both project models):** `Stories/` sits at the **workspace root** regardless of internal vs
non-internal. For a non-internal (nested) project the workspace root is the **companion** (so `Stories/` lives in the
companion, never inside the nested public `Repo/`); for an internal project it is the single repo root. The tool
enforces it: run from inside the nested source, or with `CLAUDE_PROJECT_DIR` pointing into it, the default still
resolves to the companion's `Stories/`; and any invocation whose Stories directory (an explicit `--dir`, relative
or absolute, or the default) lies inside a companion's nested source repository is refused before anything is
written, naming the directory and the repository. A linked worktree of the nested source (`git worktree add`) counts
as the nested source wherever it lives (for example `<companion>/.wt/<name>/Repo`): run from it, the default resolves
to the companion's `Stories/` too.

## When to invoke

- Starting any multi-step task that could span a compaction (the old "must have a PLAN.md" trigger).
- Continuing work: read `Stories/BACKLOG.md` → find the **In-progress** story → read its `requirements.md` + `tasks.md`.
- The user asks for a story / backlog.

**When NOT to — trivial one-offs are not stories.** A self-contained, low-risk one-off (a typo, a one-line fix, a single
obvious edit) does **not** become a story — just do it. Stories are for work whose size/risk earns the ceremony
(multi-step, compaction-spanning, or SSDLC-gated). If a candidate story would only ever carry `NOT_PERTINENT` proof rows,
it isn't a story. This is the release valve for the [`ssdlc-story-proof`] gate: it fires only on real stories, so the
full proof never taxes trivial work.

## Anatomy

```
Stories/                           # at the WORKSPACE ROOT
  BACKLOG.md                       # the Epic header (goal + spawned stories) + one row per story; marks the ACTIVE one
  _TEMPLATE/                       # copy this to start a story
    requirements.md                # user story · Requirements (R1…) · Use cases to test · Failure modes handled · Fail-open vs fail-hard · Poka-yoke · Acceptance criteria (Given/When/Then, AC1…) · non-goals
    tasks.md                       # checklist (→ R/AC) + a Verification block that gates "Done"
    design.md                      # OPTIONAL: approach + verified facts (verify-before-plan) + compaction-fragile facts
    notes.md                       # OPTIONAL: dated decision/blocker log
    risk-assessment.md             # security risk register (numbered RA-##) — ON by default; see the ssdlc-risk-assessment skill
  STORY-<nnn>-<slug>/              # a real story
```

**Minimum structure (enforced, both backends).** Every SSDLC story — local OR GitLab — must contain these 7 items:
Requirements · Use cases to test · Failure modes handled · Fail-open vs fail-hard · Poka-yoke · Acceptance criteria
(Given/When/Then) · Risk assessment. The `_TEMPLATE` carries all 7 (so a tool-created story cannot lack them by
construction), and `story structure [<id>]` (no id → the current In-progress story) checks them MECHANICALLY (no
AI — marker/regex) on the story's combined text, exiting non-zero and naming any missing item. Physical placement
may differ by backend (a local story splits them across `requirements.md` + `risk-assessment.md`; a GitLab story
carries them in the issue body) but all 7 must be present. Once a story carries a spec (any 2a-2f section), the
same check also requires every spec section the close gate requires (Use cases, Failure modes, Fail-open vs
fail-hard, Poka-yoke, Enforcement, Anti-circumvention), each with content: `story structure`, the Requirements ->
Design advance of `story requirements`, `story close` and the raw-close guard apply one list, so a story that passes
the work-time check is never refused at close for a missing section. **Enforced fleet-wide** by the
`kyklos-story-structure-guard` Stop hook: it blocks the Stop while the current In-progress story is structurally
incomplete (fail-open on any uncertain state; disable per-container with `KYKLOS_STRUCTURE_GATE=0`). Restructure
the story to clear it.

On first use in a repo that has no `Stories/`, seed it by copying the template shipped with this skill:
`cp -r "${CLAUDE_PLUGIN_ROOT}/skills/ssdlc-story/_TEMPLATE" Stories/_TEMPLATE` (and create `Stories/BACKLOG.md`).

## The `story` tool — mechanized operations (use this; never hand-edit the index)

`BACKLOG.md` is a **generated projection** of the story folders — the single source of truth is each story's
`requirements.md` (its `Status`, `Epic`, `Branch`, `Summary` fields). A CLI shipped with this skill does every
mutation atomically and regenerates the index, so the two can never drift:

```
# `story` is on PATH (the plugin's bin/ shim); it operates on $PWD/Stories (or --dir <path>)
story new <slug> --type <t> --kind <k> --severity <critical|high|medium|low> --epic <e> --title "<title>" [--parent <N>]   # next number, folder+files, then sync
story next                                                       # what to work on next (the bridge's next_work order)
#   --epic is REQUIRED: give an epic id (e.g. --epic E<nn>) OR --no-epic to DELIBERATELY leave it ungrouped.
#   Omitting both is rejected — a story must never be silently orphaned from an epic.
#   GITLAB backend: the epic MUST resolve to a milestone (--no-epic is NOT allowed) — a gitlab story is milestone-backed.
# --parent <N>: make this a CHILD of story #N. Closing ALL of #N's children auto-closes #N (see below).
#   --kind <k>: development (default) | analysis | documentation | ops — the story KIND right-sizes the SSDLC rigor
#   (analysis/documentation carry a reduced Proof set + a soft no-code nudge; ops carries the full set minus i18n and makes
#   Test Discipline metrics optional for untestable/destructive ops work). Absent -> development.
story parent <child> <N>                                         # set/re-point <child>'s parent to #N (self/cycle-rejected)
story adopt <N> --type <t> --epic <E0N> [--kind <k>] [--severity <s>]   # GITLAB: bring a USER-created issue #N into the lifecycle (--severity required unless it has one)
#   On adopt, a MECHANICAL structure check runs (no AI): if the issue lacks any of the 7 required SSDLC-story items
#   it WARNS (restructure it before working, then re-check). Run it anytime with `story structure <id>`.
#   Adoption PRESERVES an existing kind:: label; absent -> kind::development (stamped atomically with status/phase).
#   A --kind that CONFLICTS with a different existing kind:: label is refused (re-kind only via `story set kind=`).
story kind [<id>]                                                # print the story's kind (defaults to the active story)
story set <id> status=In-progress                                # edit the ONE place (requirements.md), then sync
story set <id> summary="<one concise line>" branch="<ref>"       # any of: status,type,epic,kind,target,branch,summary,title
story close <id> --branch "<ref>" --summary "<one-liner>"        # = set status=Done (+fields), then sync
story attach-coverage <id> <bashcov report or folder> [--tree <host tree>]  # SHELL coverage receipt: the bridge reads the change from its tree, posts ONE comment on the
#   story (summary, the changed scripts' coverage lines, the compressed report) and records its fingerprint in the story's
#   Test Discipline token; link the printed archive in the Test Discipline row. A .NET receipt is posted by the bridge's
#   own coverage run (get_coverage / run_tests with story). The close refuses a PROVEN Test Discipline row that does not
#   link the latest receipt of each kind the cited change needs (development stories; gitlab backend).
story set <id> status=Todo --reopen --reason "<why>"             # reopen a CLOSED story: explicit + explained (see below)
story reopen-root-cause <id> --reason "<why>" | --file <f>        # record why an ALREADY reopened story was reopened
story proof <id> --write                                         # GENERATE the canonical ## Proof table (the kind's dims, N/A pre-filled)
story proof <id> --format text                                   # the TERMINAL form of the stored table: what you show in a reply
story sync                                                       # regenerate BACKLOG.md from the folders (idempotent)
story check                                                      # exit 3 if the index has drifted (the Stop guard runs this)
story archive <e>                                                # a fully-done epic -> harvest lessons + fold to _archive/
story epic set <E0N> --title "<t>" [--goal "<g>"] [--start <yyyy-MM-dd|none>] [--due <yyyy-MM-dd|none>]  # create/configure
story epic list [--state active|closed|all] [--search "<text>"]  # find epics
story epic show <E0N> [--state open|closed|all] [--search "<text>"]  # one epic: goal, dates, progress, its stories
story epic close|reopen|delete <E0N>                             # close: all issues closed; delete: only an EMPTY epic
story set <id> epic=<E0N>                                        # MOVE a story to another (open) epic
```

**Epics: only through these commands / the bridge's epic verbs.** An epic is a GitLab milestone, but you never call
the milestone API yourself (curl, glab api, python, node): list, search, show, create, configure, close, reopen and
delete epics with `story epic ...` (or the bridge verbs `epic_list`, `epic_get`, `epic_set`, `epic_close`,
`epic_reopen`, `epic_delete`, `epic_archive`), and move a story between epics with `story set <id> epic=<E0N>`
(`story_field_set` field `epic`). They keep the milestone, the story's Epic header and its labels in agreement and
refuse what would orphan a story (closing an epic with open issues, deleting a non-empty one, joining a closed one).
`epic list|show|close|reopen|delete` and the dates of `epic set` run in every mode: in mode `on` through the bridge's
verbs, otherwise in the bash tool with the same rules (a due date never before the start date; close only when every
attached issue is closed, the refusal naming up to 20 of them; delete only an epic with no issue at all). The local
(filesystem) backend keeps an epic as a registry file with no state or dates, so there `close`, `reopen` and the dates
are refused with the reason. A container with no GitLab token of its own writes epics (like every story write) only
in mode `on`. `epic set` always takes `--title`: repeat the current title to change only the goal or the dates.
`story epic archive <E0N>` is the same as `story archive <E0N>`. A hand-made milestone write (or an issue write that sets `milestone_id`) is refused by the
Epic Gate guard (`kyklos-epic-gate-guard.sh`), which names these commands.

**Remote Truth at close.** A close is refused unless the deliverable its Branch field cites is MERGED onto an
integration trunk (`main`/`master`/`develop`) on the REMOTE — being pushed to its own feature branch is NOT enough
("closed but not shipped"). So a close is refused for: a commit no remote trunk contains, a branch that is unpushed
or pushed-but-unmerged, an `!N` merge request that is not `merged`, a `group/project@<sha>` not on that project's
trunk, or a commit that cannot be found at all. Cite what you shipped so it can be checked: a merged commit id, a
merged branch, `!N` for a merge request, or, for another repository, `group/[subgroup/]project@<sha>` (a commit) and
`group/[subgroup/]project!N` (a merge request) - always the project's full path: a bare project name is refused,
because the same name can exist in several groups. A trunk name
next to a commit (`main 3693dea`) is read as its location only. Stale remote-tracking refs are refreshed once before
refusing; a squash-merged, deleted branch is accepted when a merged merge request used it as its source. Fail-closed:
a lookup that cannot confirm "merged" refuses. There is no switch to turn it off.

**Trunk Reach at close.** A close is also refused while a commit whose message names the story in a `Refs:` trailer
sits off the trunk: on a local or remote branch, or on the detached HEAD of any worktree (a worktree made from a remote
ref is detached; a fix committed there still counts). The remote is fetched first, so a branch only another clone
pushed is seen; a failed fetch refuses (retry when the remote answers). A reference counts when a line starts with
`Refs:` (any case) and holds `#<id>` (leading zeros allowed) or this project's own path before it (`group/project#<id>`,
the path read from the origin URL). Not counted: `Closes:`/`Fixes:` trailers, `Refs` without the colon, an indented
line, a bracketed `[#<id>]`, another project's path; the commit-message guard demands `Refs: #<id>`, so these appear
only in hand-written commits. The trunk follows the repository model: for GitFlow `origin/develop` when it exists plus
every production trunk that exists (`origin/HEAD`'s target, `origin/main`, `origin/master`: a hotfix lands there
first); for a trunk-based repository the production trunk alone (`origin/HEAD`, else `origin/main`, else
`origin/master`). `origin/HEAD` is a local ref, so it is followed only when it names `main`, `master` or `develop`. In a companion, the nested source repository is checked too. A commit off the trunk still counts when
its change landed another way: the same patch (a rebase or cherry-pick), or a branch or worktree that carries it merges
into the trunk without changing anything (a squash merge, or a commit reverted later on its own branch, which counts as
abandoned). A squash merge whose lines the trunk changed again afterwards cannot be told apart from an unmerged change;
delete the merged branch and the close passes. One close merge-checks at most 40 branch tips; past that the commit is
refused as not judged (delete branches that are already merged), never passed. The refusal names each stranded commit
with what carries it, up to five (with more, the count reads "at least"). Escapes, none typed by the closing agent:
delete the branch of an abandoned commit; list its id (7+ characters) in `KYKLOS_TRUNK_REACH_ABANDONED`, or set
`KYKLOS_TRUNK_REACH=off`, in the `.claude/standards.env` COMMITTED ON THE TRUNK (read with `git show`; an environment
value or an uncommitted edit never counts, because inside the container the launcher's settings arrive through the same
process environment an agent can change); or the owner's override label, like every close gate. The origin judged
against must be the story project's: an origin rewritten by an `insteadOf` rule, or (on a GitLab-backed project) one at
another address than the project's `web_url`, refuses; the check runs with every environment variable that redirects
git (`GIT_CONFIG*`, `GIT_DIR` and the like) removed. In a companion, the nested source directory comes from the
trunk-committed `KYKLOS_SOURCE_DIR` too, and a declared source that is missing, not a repository or outside the
workspace refuses; a commit held by a worktree whose folder is gone still counts (the refusal says to run
`git worktree prune`). Fail-closed: an unreadable repository or model, a failed fetch, a check that stops abnormally, or
a story some commit names in a repository without a remote trunk, refuses. Residual risk, accepted: a tool running in
the container trusts that container's own `git` and the repository's on-disk configuration, so an agent that rewrites
those (another `git` on the PATH, a repointed origin of a nested source, which has no tracker address to compare,
replace refs or grafts that rewrite history, a fetch refspec narrowed so a branch is never fetched) is out of reach of
a shell-side check. In story-stack mode `on` the check runs in the story tool before the close is sent to the bridge; a direct call
of the bridge's close verb skips it (a known gap, to be closed in the bridge).

**A story shows who works it.** On a tracker (GitLab) project, `story new` and the move to `status=In-progress` assign the
story to the tool's own user when it has no assignee; an existing assignee is never overwritten, and an identity that
cannot be resolved only warns (the story is still created or started). To backfill stories created before this, or any
story left unassigned, run `story set <id> assignee=self`: `self` is the only value (never another account), a story that
already has an assignee is left unchanged (or refused, when that assignee is another user: see Own Lane below), and the
command fails loudly when it cannot resolve its own user. For many
stories: `for n in <ids>; do story set $n assignee=self; done`.
Two agents that claim the same unassigned story at the same moment both write, and GitLab keeps the last write (it has
no conditional update). Every claim therefore waits a short settle window (`STORY_CLAIM_SETTLE_SECONDS`, default 2) and
re-reads the issue: the agent whose claim was overwritten is told who owns the story; `assignee=self` then exits
non-zero, while `story new`, adoption and the move to In-progress only warn (an assignee never blocks the work).
The KyklosBridge story verbs claim the same way, with the same setting read by the bridge process (a value above 60
seconds is cut to 60): `story_field_set assignee=self` is refused when the claim was lost, and `story_new`,
`story_adopt`, `story_set_status`/`story_resume` into Doing and any save of an unassigned Doing story succeed with an
extra last line naming the owner. All of them resolve the tool's own user once and share it; when it cannot be resolved,
a claim that finds an assignee is reported as not confirmed (check the assignee yourself), never as lost to another user.

**Own Lane: an agent works only on stories assigned to it or to nobody.** The GitLab assignee is the one record of who
owns a story. On a tracker project, every story write (`adopt`, `set`, `resume`, `phase`, `close`, `parent` for the
child, `requirements`, `reopen-root-cause`, and `proof`/`ra` with `--set`, `--apply` or `--write`) is refused when the
story is assigned to another GitLab user: the refusal names the owner, nothing is changed, and the way forward is to ask
the owner to hand it over or have the project owner reassign it in GitLab. Reads are never refused. When the story has an
assignee but the tool's own user cannot be read, or the issue itself cannot be read (any error answer, even a passing
one), the write is refused too (ownership is never assumed); an
unassigned story is claimed on start exactly as above. The continue-guard applies the same rule: only issues assigned to
the agent or to nobody count as open work, the others are listed as `owned by <user>` (an issue whose ownership cannot be
told stays work). The KyklosBridge story write verbs, and its `story_reopen_root_cause`, `advreview_post` and `designreview_post` verbs,
refuse the same way. The one rule lives in
`hooks/lib/own-lane.sh` (the bridge's `OwnLaneRule`); both sides run the case table `tests/fixtures/own-lane.json`.
Default-on; the per-project opt-out is `STORY_OWN_LANE=off` in the project's `.claude/standards.env` (for the bridge, in
its process environment).

**A close that waits on a merge request says why it is stuck.** When a cited merge request (`!N`) is not merged yet, the
refusal reads the request's state from GitLab: if GitLab recorded a merge error (for example the user who armed it may
not merge into the target) or reports a blocking merge status (conflict, needs rebase, unresolved discussions, ...), the
refusal states it plainly instead of telling you to keep waiting.

**A closed story is never reopened by accident.** Giving a CLOSED story an open status (Todo, In-progress, Blocked,
Parked) would reopen it, so `story set` refuses it and changes nothing. To change the open/busy picture, change an
OPEN story instead. When the closed work really must be reopened, say so and why:
`story set <id> status=<status> --reopen --reason "<why the closed work must be reopened>"`. The tool reopens the
issue and posts the reason as a `Reopen-Root-Cause:` note, which is what the re-close gate asks for, so the reopened
story can close again once it is fixed. `--reopen` is refused without a reason, on a story that is not closed, and
without an open status. The check also sits in the GitLab write itself, which reads the issue's state first and never
writes blind. A story that was reopened some other way (by hand on GitLab, or before this check existed) records its
reason with `story reopen-root-cause <id> --reason "<why>"` (or `--file <f>`). The bridge's `story_set_status` and
`story_resume` refuse every status change on a closed story and point here.

**No agent-typed way around the Done gates.** For a tracker (GitLab) story, `story close` / `story set status=Done`
refuse `--no-proof-gate` and `--no-quality-gate`, and no environment variable turns the proof, phase-walk or Remote
Truth checks off. The only exception is the owner applying the `proof-override` label (a fixed name) to the issue: the tool honours it only when the label's latest event is an add by a
GitLab user other than this agent, read from the server-side label history, and only when the story names the cause
of its gap (Named Cause: an `Override cause: <reference>` line naming an OPEN story or triage item, or the owner's
`Override cause: accepted <figure>%` note; the bridge decides it through `proof_validate`). The two flags remain for local stories
only (the local backend has no tracker and no owner), for example when migrating a backlog.

**The gates read whole lists.** GitLab answers a list one page at a time (20 items unless asked for more). Every list a
gate judges (the label history behind the phase walk and the owner override, the branches that contain a commit, the
notes, the open issues) is read through one shared reader, `gitlab_paged_walk` in `hooks/lib/gitlab-paged.sh`: 100
items per page, every page until an empty one (a short page before the last one does not end the walk). A page that
fails is asked once more. A list longer than the page cap (`GITLAB_PAGE_CAP` pages, default 50; a list of exactly that
many items is complete), a walk past its time limit (`GITLAB_PAGED_DEADLINE` seconds for the whole walk, default 60),
or a page that fails twice is refused with a message, never judged on the part that was read.

**Canary mode — a safe playground for hand/demo runs (GitLab backend).** An interactive or teaching run must NEVER
mint junk issues in the real tracker: GitLab's per-project issue-iid counter never decreases, so a deleted demo issue
leaves a permanent gap that later surfaces as a 4-digit story number (this has bitten the fleet before). Pass
**`--canary`** (or export `STORY_CANARY=1`) and every write is redirected to a throwaway canary project instead:

```
story --canary new demo --type fix --epic E<nn>        # writes land in the canary project, NOT production
#   Target = $STORY_CANARY_PROJECT (required; a canary run with it unset is refused).
#   Every canary run prints a loud [CANARY] banner naming the resolved id — a production run has NO banner.
#   FAIL-HARD: if STORY_CANARY_PROJECT is unset or empty, the run REFUSES (it never falls through to production).
# Sweep accidental canary fixtures (needs a token with api scope for the canary project; preserves real stories):
#   for iid in $(glab api "projects/$STORY_CANARY_PROJECT/issues?per_page=100" | jq -r '.[].iid'); do glab api -X DELETE "projects/$STORY_CANARY_PROJECT/issues/$iid"; done
```

**A broken install refuses, never closes.** The tool loads every library its gates depend on (the backends,
`story-lib.sh`, `proof-dimensions.sh`, `repo-role.sh`, and `proof-tool-gate.sh` at close) through `require_lib`
(`hooks/lib/require-lib.sh`): the file must exist, load without an error and define the functions the gates call.
Otherwise every command stops with `story: refusing to run: cannot load <library> completely`, because a library that
stopped part-way would leave its checks undefined and a close would skip them. The story-backend seam
(`lib/story-backend.sh`) keeps loading past a library it cannot load and records it in `STORY_LIB_LOAD_FAILED`, so
the tool and every hook that loads the seam go through `require_story_seam` (same file), which reads both. With such a
broken install (the seam itself, or a library it recorded) the story-proof Stop gate blocks the Stop naming the
library, the backlog gates fail closed naming it, and the GitFlow guard's adopted-story check warns naming it. The
raw-API close guard loads `story-lib.sh` through `require_lib` and blocks the close when it cannot.

**Hardened isolation (belt-and-suspenders for `--canary`).** `--canary` is opt-in, so forgetting it could still hit
production. Two guards close that gap:
- **`STORY_TEST=1`** — set it while exercising the tool by hand. Under the gitlab backend it **refuses** any run that
  is NOT isolated (no `--canary`, no `STORY_GL_STUB_DIR`) rather than let a forgotten flag reach production. So a
  demo session exports `STORY_TEST=1` once and then *cannot* pollute the real tracker even if it forgets `--canary`.
- **Junk-slug refusal** — on a REAL gitlab project, `story new` refuses an obviously-throwaway slug (a single
  character, or a demo-fixture name like `alpha`/`beta`/`grouped`/`orphan`/`x`). Exempt on the canary/stub/FS (where
  you test); override on production with `STORY_ALLOW_JUNK_SLUG=1`.

**Kebab-case slug (every backend, always on).** The slug names the story folder (`Stories/STORY-<nnn>-<slug>/`), so
`story new` refuses a slug that is not kebab-case (lowercase letters/digits joined by single dashes) or is longer than
40 characters, and prints the corrected command with a suggested slug. A human title goes in `--title`:
`story new clean-names --title "Clean Names: story new refuses a title as the slug" --type fix --epic E12`. Under the
gitlab backend the mirror applies the same rule: a legacy folder whose name is not kebab-case (a title used as the
slug, or an old cut that ended in `-`) is renamed to its slugified name by the next `story refresh`/`sync`, keeping
its files. Only a generated mirror folder is moved: if a clean folder for the same story already exists, or the legacy
folder is hand-made (not a generated mirror), it is kept and reported for a manual merge, never deleted.
An existing folder is reused for an issue only when it holds THAT story: a generated mirror names the issue's
instance-wide id in its banner, and an older folder must carry the issue's title. A folder that holds another story with
the same number is moved to `Stories/_archive/superseded/` (never deleted) and the issue gets a folder named from its
own title; a folder whose owner cannot be told is still reused. The mirror's `tasks.md` shows the proof table stored on
the issue in a generated `## Proof` section (refreshed when the issue changes); the Work checklist above it is kept.

**Project-label materialization.** On the gitlab backend, `story new` and `story close` first ensure every
label the story lifecycle uses (the list, with colours and descriptions, is `_GL_KNOWN_LABELS` in
`lib/story-backend-gitlab.sh`) EXISTS at project level — creating any that are missing (with
a colour + description) so a user creating a story by hand in the GitLab GUI can see and pick them. Purely mechanical,
idempotent, and FAIL-OPEN (a labels-API hiccup never blocks a create/close); no-op on the FS backend.

**Full spec before work.** Where the bridge serves this project's story stack (mode `on`, or `shadow`), a story
leaves **Requirements** only with every section of the story skeleton filled (User story, Requirements, the 2a-2f
sections, Acceptance criteria, Risk assessment; no `<FILL:` left): `story phase <id> <later phase>` and `story adopt
--work` are refused with the bridge's `spec-incomplete` message naming each missing or empty section, and the close
judges the same rule. The rule lives once, in the bridge. In mode `off` (no story stack) the story tool keeps its
older 2a-2f close check and prints a notice when a story leaves Requirements that the full check is not applied.

**SSDLC phase.** A story carries exactly one `ssdlc:phase::<Phase>` label. The ordered set is
**`Requirements|Design|Implementation|Testing|Deployment|Review`** (the FIRST phase is **Requirements** — the
pre-Design structuring/authoring stage; `Prerequisites` is kept as a recognised **legacy alias** of Requirements so
older stories/labels still resolve). `story new` auto-sets **Requirements** (you start by structuring + writing the
spec). Move it with **`story phase <id> <Phase>`**, which ENFORCES order: a **forward** move is free; a
**backward / out-of-order** move is **refused unless justified** with **`--reason "<why>"`** — the escape hatch for a
legitimate regress (a reopened story, back-to-Implementation on a late-found bug, back-to-Design on updated specs),
and the reason is recorded as an issue note so the override cannot be silently abused. **The phase auto-advances at
each lifecycle event** (all MONOTONIC via `--advance`; a backward target is a no-op, needs no reason): tool-owned —
`story new`→Requirements, `story requirements` (authored+conforming)→Design, `story close`→Review; guard-owned (the
`kyklos-phase-advance` PostToolUse hook; it runs after the git command and never undoes it) — a **commit** on a
`feature/story-<N>-*` branch→Implementation, a **push**→Testing. The hook resolves the story settings like the story
tool: the repository's `.claude/standards.env`, plus any `STORY_BACKEND=`/`STORY_GITLAB_PROJECT=` the git command itself
carries, by shell rules (written directly in front of the git command, or `export`ed earlier in the same command;
a prefix of another command does not count, and the hook never sees your shell's environment). In a
worktree without settings, write them on the command: `STORY_BACKEND=gitlab STORY_GITLAB_PROJECT=<id> git commit ...`.
When a story event cannot advance its phase (no backend resolves, the story tool is missing or fails), the hook
answers `decision: block` with the reason and the fix: stop and advance the phase before continuing. The one event with no clean client-side trigger — **CI-green→Deployment** ('CI
green' is async and the merge is server-side auto-merge) — is an EXPLICIT step: right after you confirm the pipeline
is GREEN (before merge/close), run **`story phase <id> Deployment --advance`**. `story close` then advances→Review.
Mutually exclusive (other phase labels removed). Migration/track-finding do NOT auto-phase. Gitlab-only; no-op on FS.

**Status, phase and branch stay in step.** A story nobody has started (`todo`, `parked`, or no status) may be
specified — Requirements and Design — but a phase **past Design is refused** until it is started
(`story set <id> status=In-progress`, or `story adopt` for a raw issue); `--advance` on such a story is a no-op, like
on a blocked one. The same rule holds on every path that writes a phase: the bridge's `story_phase` verb refuses it too, and
a complete proof leaves a story nobody started at its phase (saying why) instead of moving it to Review. Starting or adopting a story while on its own `feature|hotfix/story-<id>-*` branch records that
branch in the **Branch** field. Status and phase labels are written **only by the story tool** — a raw API label edit
(including adding or removing `status::parked`) is blocked by the tool-first guard, because status is a mutex the tool
enforces and a hand edit leaves two statuses or none. **`story audit`** lists every open story that contradicts
itself — not exactly one status, a phase past Design on a not-started story, in progress with no phase or no branch,
or still `todo` after its own branch merged — one `#<id> <rule> <detail>` line each, exit 1 when anything is found;
repair each finding with the story tool.

**Parent-child stories + auto-close-parent.** GitLab CE has **no native Issue-parent-of-Issue** (the work-item
hierarchy rejects it; Epics are Premium) and a `relates_to` link is **symmetric/untyped** (it cannot express
direction), so the relationship is a **tool-managed canonical bullet** — `- **Parent:** #<N>` in the child's metadata
header — which is the **sole source of truth**. Set it with `story new --parent <N>` or `story parent <child> <N>`;
both **fail-hard** on a malformed N, a non-existent parent, a self-parent, or a **cycle** (walking the ancestor chain).
On **`story close`**, once **every** child of a parent is closed, the parent is **auto-closed** too (recursively up the
chain), with an audit note naming the children as its evidence. The parent close bypasses the per-story proof gate
(the children — each of which passed its own gates — are the evidence); it degrades **toward not closing** if a child's
state can't be read (a visible to-do beats a silently-lost one). Children are enumerated by scanning the story issues
for the canonical bullet — no duplicated `Children:` list to drift.

Registry files the generator reads (author these by hand): `Stories/_backlog-header.md` (preamble), optional
`Stories/_backlog-footer.md` (usage notes), and `Stories/_epics/<e>-<slug>.md` (each epic's title + `> **Goal:**`).
**Rule:** change status/rows ONLY through the tool — a hand-edit to the table is caught by `story-backlog-guard`
(it runs `story check` at Stop and blocks on drift). The manual anatomy below is the underlying model the tool maintains.

**Derived-mirror transparency (GitLab backend).** When `STORY_BACKEND=gitlab`, GitLab is the source of truth and the
local `Stories/` tree is a **derived, offline MIRROR** — every mirror file is stamped `GENERATED MIRROR … DO NOT EDIT`.
`story refresh` (run automatically at SessionStart, and by `story check`) re-syncs it from the live issues; if GitLab
is **unreachable** it keeps the last-good mirror but prints a **STALE** warning and drops a `.mirror-stale` marker —
never a silent stale pass. A hand-edit to a mirror file does not persist (the next refresh overwrites it). Under the
`local` backend `refresh` is a no-op — there the files ARE the record. **One project per mirror:** a call for ANOTHER GitLab project than the one the workspace declares (an exported `STORY_GITLAB_PROJECT` that differs from the workspace's `.claude/standards.env`) mirrors under `${XDG_CACHE_HOME:-~/.cache}/kyklos-story-mirror/<project>/Stories` instead, so another project's stories never collide by number with the workspace's own; an explicit `--dir` still wins.

**The mirror stays out of git.** Because every refresh rewrites the mirror, it must never be tracked (except in a
companion or trunk-model repository, whose mirror is committed on purpose as bookkeeping). After every mirror write the
tool lists any untracked, not-ignored generated copy (`BACKLOG.md`, the `STORY-*/` folders, `.mirror-stale`) in the
repository's local `info/exclude`, so it never shows as a leftover and cannot be swept into a commit. A generated copy
that is already TRACKED gets one warning naming the one-time fix: `git rm -r -q --cached -- 'Stories/BACKLOG.md'
'Stories/STORY-*'` in a commit, plus `/Stories/BACKLOG.md` and `/Stories/STORY-*/` in `.gitignore`. The session-start
leftover scan reports tracked copies on their own line with the same fix. Hand-written files under `Stories/` (no
banner) are never touched. Opt out: `STORY_MIRROR_GIT_HYGIENE=off`.

### Working a USER-created issue (GitLab backend) — you MUST `adopt` it first

When the SSoT is GitLab, an **adopted** story is an issue carrying the `story` label **and** the tool-written
metadata block (the `Story-Type` bullet that `story adopt` / `story new` write). The label alone is NOT adoption: a
human can file an issue with the `story` label pre-applied, and it still has no metadata, status, phase or proof
scaffold. An un-adopted issue is *outside* the SSDLC lifecycle: work it as-is and it closes with **no milestone and no
Proof** (the exact hole this enforces against). So before you touch it:

- `story adopt <N> --type <t> --epic <E0N>` — stamps the `story` label, attaches the epic's **milestone** (REQUIRED),
  and injects the canonical metadata block (preserving the user's title + body). Now #N is a first-class story: the
  proof gate sees it on close, and it has a milestone.
- Every command that changes the story refuses an un-adopted issue and names the same remedy: `set`, `proof`,
  `phase`, `close`, and the body writers `requirements`, `parent` and `ra --apply`. So adopt BEFORE authoring the spec:
  a spec written first would leave the story with no type, epic or status, and adoption would then quote it as the
  requester's original words.
- The **gitflow branch guard HARD-BLOCKS** a `feature/story-<N>` commit when issue #N is not adopted (raw, or
  label-only) — it names the remedy (`story adopt <N> …`). It judges the story config of the TARGET repo, and for a
  nested public source repo (which carries no `.claude/`) the workspace project's. So you cannot accidentally freelance
  on a user's issue. (Transient-safe: if the API can't confirm, it warns and allows rather than wedge a commit.)
- When a repo inside the workspace (the project, or its nested source repo) is on a branch that names a story, the
  **story-start guard** requires THAT story to be In-progress, and the
  **before-coding guard** requires THAT story to be ready (`story structure <N>`) before a bridge build — another
  active story does not count.
- Milestone is **mandatory** for `new`/`adopt` under GitLab: the epic must already resolve to a milestone (create it
  with `story epic set <E0N> --title "…"` first). There is no milestone-less gitlab story.

### Bash or the bridge's story stack (per project, host-side)

`new`, `adopt`, `requirements`, `structure <id>`, `kind <id>`, `track-finding`, `set <id> status=...`, `set <id>
<field>=<value>` (one or more header fields), `parent`, `phase`, `resume`, `close`, a plain `proof <id>`, the proof
writes (`proof --set`, `--apply`, `--write`), the risk-register write (`ra --apply`), `epic set` and `archive` go
through a switch whose mode the project's bridge reports
(`ssdlc_mode`); the agent cannot change it. The mode is per GitLab project: the bridge's story stack serves the
projects its host settings list (usually one; several for a session that develops several projects) and answers `off`
for any other (a local-backend story is always `off`), every routed call names the project
it is for, and the bridge refuses a call for another project, so an issue number is never resolved in the wrong one:
- **off** (no story stack on the bridge, or no bridge): the bash mechanics only, as always.
- **shadow**: the bash mechanics stay authoritative. The bridge's C# verb runs first on the unchanged story (it never
  writes in this mode), then bash runs, and the two outcomes (status, phase, close allowed or refused, proof
  verdicts) are compared. Every comparison is appended to `$KYKLOS_STATE_DIR/ssdlc-shadow.jsonl`; a divergence is
  also printed. `story shadow-report` summarises them (`--all` lists agreements too). A bridge that cannot be reached
  never blocks bash; the comparison is recorded as "c# unavailable".
- **on**: those operations go to the bridge's verbs and bash does not write them; a refusal fails the command with
  the bridge's findings. If a bridge last seen `on` cannot be reached, the command fails (exit 3) instead of silently
  falling back to bash. The `story-proof-guard` Stop hook does the same for a story closed in this session, on every Stop (no
  local marker stands for the bridge's verdict; a close from an earlier session is not asked again, since the bridge judged it at its own close): it asks the bridge
  (`proof_validate`: the proof table, spec, risk register, correlation and Adversarial Review row, with the owner's
  label read by the bridge) and blocks on a refusal or on no answer; it does not re-judge the proof in bash. It still
  checks what only the container sees: the table shown in the reply and the CLAUDE.md interview sections. Proof writes are forwarded as typed: every `--set` goes, unparsed, in one `proof_set` call
  (the bridge parses the `Dimension=VERDICT|evidence|metrics` grammar, `\|` for a literal pipe), `--apply` sends the
  whole table, `--write` re-saves the stored one, `--draft` asks `proof_draft` to assemble the proof from the evidence
  the bridge holds (mode `on` only: start there, then `--set` only the rows it leaves open); a plain read with `--format text` asks `proof_get` for the terminal
form. The bridge checks every row first and reports all refusals at once
  with nothing written; a table with no UNPROVEN row moves the story to Review. `ra --apply` stores the register in
  the same marked note the bash tool uses (`ra_set`, refused when it has neither a numbered RA-## item nor a `Risk-Assessment-Waived:` line), and the close reads
  it from there. Creating, adopting and authoring are the bridge's too: `new` checks the slug (kebab-case, not a
  fixture name), the type, the kind, the epic's milestone and the parent, and refuses a number far above the highest
  existing one; `adopt` keeps the issue's original words; `requirements` keeps the header and the original request;
  several header fields in one `set` are one write, and a status together with another field is refused (two writes).
Other operations (gate-bypass flags, `phase --advance`, `proof --template`, reading `ra`, `structure`/`kind` with no
id, sync, materialize, audit) always stay bash.
A close under `on` (`close`, or `set <id> status=Done` with at most `branch=` and `summary=`) sends the cited branch and
summary with it, and the bridge refuses everything the bash close refuses; it is stricter where bash lets a close
through on an unreadable history or checks a token only at the Stop hook. The shared cases are in
`tests/fixtures/close-parity.json`, run by both `tests/test-story-close-parity.sh` and the bridge's tests.
Shadow compares decisions, not every side effect. Under `on` the bash-only side effects of a close do not happen:
closing a parent story when its last child closes, the flow-status strip, and the Done-to-Review phase advance of
`set status=Done`. Before a project goes `on`, compare the end state of a story the bridge drove with one bash drove.
A fresh container remembers no previous mode, so with the bridge down it runs bash even for an `on` project; bash
writes the same records, so this is safe but not loud.

## From a plan: the Epic

A `PLAN.md` (or Claude's **plan mode**) is an **Epic** — scaffolding used ONCE to *generate* stories, not the thing that
drives execution. A big plan goes stale the moment reality diverges, and evaporates at compaction; the stories + BACKLOG
survive both. So a plan is the *thinking* step only; hand execution to the stories:

> **Plan → stories → collapse the plan into an Epic header → delete `PLAN.md`.**

1. Draft or receive the plan (plan mode is fine — that is exactly its job).
2. **Decompose** it into stories (`STORY-<nnn>-<slug>/`), each with its own requirements + acceptance criteria + tasks.
3. **Collapse** the plan into a short `# Epic <id> — <title>` block at the TOP of `BACKLOG.md`: the distilled goal, the
   stories it spawned, and any **cross-cutting** decisions/dependencies that span stories (the connective tissue a single
   story does not hold). Format:

   ```markdown
   # Epic <id> — <title>
   > Goal: <one-paragraph distillation of the plan>.
   > Stories: STORY-<a>, STORY-<b>, STORY-<c>.
   > Cross-cutting: <the few decisions/dependencies that span stories>.
   ```

4. **Delete the standalone `PLAN.md`** — the Epic header + the stories now carry everything execution needs, so the verbose
   plan is redundant and would only rot. (If you want to keep the full plan as history, archive it OUT of the way — e.g.
   `Stories/_epics/<id>.md` — but it must NOT drive execution: the BACKLOG Epic header + the stories are the single source
   of truth.)

From here, execution is regulated by the **stories** (the one ACTIVE In-progress story), never by the plan.

## Workflow

0. **Choose** — the next item to work on is the one `story next` (the bridge's `next_work` tool) names first.
   It applies the corporate policy's "Choosing the next work" rule and lists every open issue without a severity as a
   defect to fix first; do not pick work by any other order.
1. **Create** — `story new <kebab-slug> --title "<title>" --type <t> --kind <development|analysis|documentation|ops> --severity <critical|high|medium|low> --epic <e>` (creates the folder from templates + regenerates the index). On a tracker `--severity` is required: it becomes the `severity::` label the next-work order ranks by. `--epic` is mandatory (an epic id, or `--no-epic` for a deliberately ungrouped story) so a story is never silently orphaned.
   **Create or adopt the story BEFORE the first edit of the work**, so its phases follow the work as it happens. If the
   work already exists (you wrote code first), create the story, push the work on a branch named `story-<N>` (or with
   commits carrying `Refs: #<N>`), then `story adopt <N> ... --work <that branch | commit | !MR>`: the story starts at
   Implementation and records why. Work that is not the story's own (a trunk, an unrelated commit, another story's
   branch) is refused, and so is `--work` on `story new` (a new story has no number its work could name yet). `--work`
   needs the bridge to serve the project's stories; elsewhere it is refused and the next commit on the story's branch
   starts it instead.
   Then fill `requirements.md`: capture the user's **verbatim** request, write Requirements (R1…) and **checkable**
   Acceptance Criteria in Given/When/Then (each AC should name the test/observation that proves it), and fill `tasks.md`.
2. **Activate** — `story set <id> status=In-progress` (the row + the ACTIVE marker are DERIVED from status now, not
   hand-kept). Keep **exactly one** *actively-worked* In-progress story at a time — **with one exception: a story that
   is only AWAITING CI** (its phase is Testing/Deployment, so its branch is pushed and the pipeline is the sole
   remaining wait) **no longer holds the active-work slot.** While it runs you SHOULD start the next story instead of
   idle-waiting on the pipeline: the `story structure`/`kind` no-id resolvers and the before-coding guard skip
   awaiting-CI stories and treat the newly-started one as the active story, and `story check` prints the standing
   "the active-work slot is FREE — start the next story" permission. Come back to close the awaiting-CI story when its
   pipeline lands. Default-on; `KYKLOS_AWAITING_CI_SLOT_FREE=off` restores the strict single-story rule.
3. **Work** — tick `tasks.md` (`[ ]`→`[~]`→`[x]`, `[!]` blocked with a reason). Put verified assumptions + call-site
   inventories in `design.md` (verify-before-plan: state what you verified and HOW); log decisions in `notes.md`.
4. **Block** — `story block <id> --on <issue, story or merge request> --reason "<what blocks it + what would unblock
   it>"`, then move to the next tractable story (never halt and wait, per CLAUDE.md). The bridge records the blocker
   once (a `Blocked-On:` header bullet), marks each open task `(waits on <reference>)`, sets Blocked and posts one note;
   `story block <id>` alone re-checks it, and the block lifts by itself (status back, note posted) once the reference
   closes or merges. Never write a wait into task text or the local `tasks.md` to express a block: the continue-guard
   reads only the recorded bullet (a Blocked story without one is open work), and `story set <id> status=Blocked` is
   refused. The full rule: `docs/SSDLC-WORKFLOW.md` section 17. Opt-out: `KYKLOS_BLOCKER_CHECK=off`.
5. **Finish** — every `tasks.md` Verification box checked (build + tests for the whole surface + any poka-yoke scans +
   docs in the same commit + merged), **and the final quality gate passed** — run the [`ssdlc-story-proof`] skill.
   **Generate** the story's `## Proof` table with `story proof <id> --write` (the canonical dimensions of its kind, N/A
   rows pre-filled) — never hand-author the rows — then fill EVIDENCE + flip verdicts so no Quality Dimension is `UNPROVEN`
   (each is `PROVEN` by a named test or a justified `NOT_PERTINENT`). Only then → `Status: ✅ Done`, update the
   `BACKLOG.md` row. The `story-proof-guard` Stop hook blocks closing a Done story that still has UNPROVEN dimensions
   OR whose Proof rows miss (or duplicate) a required dimension of its kind (extra rows are accepted); only the user
   may override. Docs (HISTORY/README)
   still go in the **same commit** as the code (CLAUDE.md rule). **Then SHOW the close in your reply**: the proof
   exactly as `story proof <id> --format text` prints it (its terminal form, which `story close` also prints; the
   stored markdown table stays the GitLab form) + its tally, and a one-line summary of the files/commits touched — the
   user may be remote with no filesystem access, so a proof saved only to `tasks.md` is not one they can see (see
   [`ssdlc-story-proof`] Closing rule).

### Closing the loop — commit → (push?) → monitor → close-on-green

> **Commit trailer.** Every commit on a story branch carries the `Refs: #<N>` footer the corporate policy requires
> (Tier 2; `kyklos-commit-message-guard` enforces it). The close uses the same trailer to find the story's own commits
> when the branch name carries no story number (`hotfix/<slug>`) or the merge was squashed: the Test Discipline token is judged there. The trailer places the story only after its named
> merge and branches found nothing, and only through the story's OWN commits: a commit whose every `Refs:` line names
> this story and nothing else (a commit that also names another story, on the same line or on another `Refs:` line,
> never places it), and that is no merge named for another story. EVERY place those commits landed is judged: each
> merge that brought them in (when every commit of that merge carries `Refs: #<N>`), and each run of consecutive trunk
> commits carrying the trailer (a squash), against its parent. So a later docs commit or merge with the same trailer
> cannot stand in for an earlier one that changed C#. A place
> that changes no C# never counts as success: when no placed change with C# was judged and held (a squash naming no
> story or several, a merge mixing other work, only a docs commit carrying the trailer), the token is judged at the
> trunk's head, where every file it records must be what was measured (file contents byte for byte; a recorded change
> must be the last change the trunk made to that file). A token measured on the merged result always passes there.
> Any doubt refuses: a shallow clone, a failing `git diff`, an unreadable object.
>
> **A story merged more than once: measure on its latest merge.** The token step and the close find the story's
> places with the same resolver, and the latest of them (`proof_tool_story_latest_place`) is the story's result. A
> coverage run on a tree that does not contain that latest merge (a checkout or work tree still at the first merge) gets
> no token: the bridge answers that the change window could not be determined and names the latest merge. When a run
> keeps a record of an earlier run that no longer matches its file (this run's tests did not cover it), the bridge's
> answer carries a WARNING naming the file, and the close names the earlier merge the record comes from.

Whether you may push, and the push → monitor → close-on-green loop, are the corporate policy's PUSH POLICY; CI is
read through `hooks/lib/ci-access.sh`. What the story adds:

- Once the branch is pushed the story is only *awaiting CI* (its phase is now Testing), so its active-work slot is
  free: arm the watcher in the background and **start the next open story** while the pipeline runs (the
  `idle-work` nudge suggests one; the awaiting-CI slot-free rule in step 2 lets you start it).
- **green** → fill the Proof table, mark `✅ Done`, then close the branch per its close mode (below). The
  `story-proof-guard` independently re-checks the branch pipeline and BLOCKS a close that is not green.
- **red**, or **hung** past a sane budget → keep the story `🔵 In-progress`; fix and re-enter the loop, or tell the
  user. Never close on red.

### Branch close-mode — how a green feature/hotfix branch is actually closed

The close method is a per-branch-type project setting (`FEATURE_BRANCH_CLOSE_MODE`, `HOTFIX_BRANCH_CLOSE_MODE` in
`.claude/standards.env`). The modes, their defaults and the exact close command for each are owned by
`hooks/kyklos-branch-cleanup-guard.sh` (`_mode_hint`): it prints the command for the project's mode, and asks you to
interview the user when the setting is missing. Under `mr`/`mr-automerge` GitLab merges the request itself on green;
`hooks/kyklos-mr-hands-off-guard.sh` refuses a hand merge and an unarmed create, and says why. To arm an existing
merge request, use the bridge's `mr_auto_merge` verb (its tool description lists what it refuses).

When a merge request closes several issues, put one `Closes #N` per line in its description (a comma list closes only
the first few). An HTTP 405 when arming means the project's CI creates merge-request pipelines; its `workflow:` rules
must suppress them (a CI-template concern).

### Flow-strip — show the user "where in the global flow" (at transitions only)

At a **state transition** (activate · committed · pushed · CI result · closed) render a one-line ground-truth
status strip so the human isn't lost in the distributed flow (local story x remote CI x repos). Do NOT author it
by hand and do NOT emit it every turn — **generate** it:

```
flow-strip.sh STORY-nnn      # one story:  STORY-nnn  spec✓ code✓ commit✓ push✓ CI● merge· release·  pipeline <id> ▶ running
flow-strip.sh --all          # a checkpoint dashboard (one line per story) — use sparingly
```

`story set <id> status=…` (and `story close`, which is a status transition) **auto-emit this strip** to stdout — so a
status transition always surfaces "you are here" from truth without you remembering to call it. Surface that line to the
human. Call `flow-strip.sh` yourself only for a NON-status checkpoint (e.g. after a push/CI result) or `--all`.

It reads the BACKLOG status + (when `KYKLOS_CI_MONITOR=1`, through `hooks/lib/ci-access.sh`) the live pipeline, so it can't drift or contradict
reality — a hand-typed status that says "green" while CI is red poisons your own later context. Rules: **1 line,
generated, at transitions, replace-don't-accumulate**; glyphs `✓ ● · ✗ ⛔` only (no box-drawing). Never wire it into a
per-turn hook.

## Rules that carry over

- One story per task/branch; short-lived; GitFlow branch names as ever (and closed — merged + deleted — when done).
- The story files are **living** — keep the checklist and Status honest (a stale plan is the failure mode this prevents).
- `Stories/BACKLOG.md` is the SSoT index on the FS backend; under `STORY_BACKEND=gitlab` **GitLab is the SSoT** and
  `Stories/` is the GENERATED mirror (mutate via the `story` tool, never hand-edit). Don't scatter parallel task
  lists elsewhere.
- Acceptance criteria are failable and behaviour-anchored — the same bar as tests (no "vibe done").

## Mirror freshness & phase choreography (keeping the visible state honest)

The GitLab issues are the source of truth; `Stories/` is a derived mirror. To stop the committed mirror and the
SSDLC phase from lagging the real work:

- **Mirror auto-commit.** In a companion/trunk-model repo, after a state-changing op (`set` / `phase` /
  `requirements` / `ra` / `adopt`) the `kyklos-story-mirror-commit` hook regenerates `Stories/` and commits it (only
  the `Stories/` pathspec) — so the companion repo never shows in-progress work as `Todo` for hours. It commits only
  at a declared root: a repository toplevel holding `.claude/standards.env`, resolved from the working directory
  (a nested source or a worktree of it resolves to its companion) or else from the session project. It never commits
  inside a nested source or a worktree of it, nor into a repository that merely encloses the directory; when no
  declared root can be proven it commits nothing and says so (`[mirror-commit] not committed: ...`). DEFAULT-ON;
  opt out with `KYKLOS_MIRROR_AUTOCOMMIT=off`.
- **Stale-read surfacing.** `story check` drops a `.mirror-stale` marker when the mirror differs from the SoT (and
  `story refresh` clears it); reading a `Stories/` file while that marker is present prints a loud STALE warning
  (`kyklos-story-mirror-stale-surface`), so a stale Status/phase/branch read is never silent.
- **A not-started story is started by its work.** A commit or a push that git really recorded (not a dry run or an
  up-to-date push), or a story-bound test run, on the branch of a Todo story starts it (`status In-progress`) and then
  advances it, and says so; a story created after its code therefore still enters Implementation with its first commit
  instead of jumping at the close. A Parked or Blocked story is never resumed by work: the hook tells you instead.
- **A jumped history is repaired at close from evidence (bridge-served projects).** When the labels never entered
  Implementation but a cited deliverable is merged on the trunk, the proof is complete and the note of the authentic
  adversarial review the proof presents is newer than the newest work the remote received (the cited deliverables and
  every trunk commit carrying `Refs: #<N>`, timed by the merge request that carried them, never by a commit date), the
  bridge's close records `Phase-History: reconstructed at close
  from evidence ...` on the story and closes it; without that evidence it refuses and names what is missing. Where no
  bridge serves the project's stories, the bash close keeps the strict phase-walk refusal.
- **Phase on a coverage/test run.** The `kyklos-phase-advance` hook advances a story to `Testing` on a story-bound
  coverage/test run (bridge `get_coverage` / `run_tests` with a `story`), not only on a push — so a story pushed
  just before merge does not sit in `Implementation` through its whole test stage. When the run names a `tree`, the story
  is looked up in the repository that tree belongs to: a relative tree is the session's own project; a host path
  (`R:\<Repo>\...`) is the repository mounted beside the workspace under the same folder name (`/mnt/<Repo>`),
  whose own story settings decide the project; a tree not visible in the container advances nothing.
