#!/usr/bin/env bash
# kyklos-branch-cleanup-guard.sh (Kyklos) — Stop hook. Enforces GitFlow branch CLOSURE.
#
# Finishing a task = CLOSE the branch (default: MERGE it back to its trunk AND DELETE it). Both steps are
# LOCAL, REQUIRED, and the agent's job — and are NOT the same as pushing (pushing is separately gated).
#
# Close METHOD is per-branch-type configurable via FEATURE_/HOTFIX_BRANCH_CLOSE_MODE in .claude/standards.env
# (local|push|mr|mr-automerge). UNSET => the block demands a one-time interview (no silent default); for the
# mr/mr-automerge modes the block instructs a Merge-Request push (GitLab merges) instead of a local merge.
#
# Two failure modes this blocks:
#   (1) MERGED-but-not-deleted: a branch fully merged into a trunk (develop/main/master) but left alive.
#   (2) DANGLING-unmerged: a finished story's branch whose merge was DEFERRED (e.g. wrongly lumping the whole
#       merge into a "batch close", or conflating "don't push" with "don't merge"). Detected by tying open
#       branches to the story workflow's In-progress state: if there are more open task-branches than
#       In-progress stories, at least one finished story's branch was never closed.
#
# Scope: inspects the project itself AND, for the companion/nested model, the nested public source at
# KYKLOS_SOURCE_DIR (default `Repo/`; the code branches live there while Stories/ lives in the companion).
# The set of repos is chosen by the declared REPOSITORY MODEL (lib/repo-role.sh). The active-story count
# (In-progress + Blocked) comes from resolve_backlog (lib/backlog-lib.sh: the local BACKLOG.md or the GitLab
# projection). If there is no backlog, only rule (1) applies (no false positives in repos that don't use the story
# workflow).
#
# Wired: Stop.  One-shot escape: bash hooks/lib/override-marker.sh set gitflow-ok <your-working-folder>.
# [json-answer-required] Every answer this hook reads goes through the JSON reader; without it a check would exit 127
# and fall into a fail-open path, so the hook refuses by name instead (a broken install). [CySec] CWE-636
. "$(dirname "${BASH_SOURCE[0]}")/lib/json-answer.sh" 2>/dev/null
if ! command -v json_test >/dev/null 2>&1; then
    printf '{"decision":"block","reason":"BLOCKED (%s): the JSON reader hooks/lib/json-answer.sh did not load (broken install), so this check cannot run. Reinstall or repin the kyklos plugin."}\n' "$(basename "$0")"
    exit 0
fi
set +e -u +o pipefail

_cfg="${CLAUDE_PROJECT_DIR:-$(pwd)}/.claude/standards.env"
# PARSE, never source (CWE-829): a malformed line can't execute (would break the guard + spam the TUI).
. "$(dirname "${BASH_SOURCE[0]}")/lib/standards-env.sh"; load_standards_env "$_cfg"
STATE_DIR="${KYKLOS_STATE_DIR:-/tmp/kyklos-state}"; mkdir -p "$STATE_DIR" 2>/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/override-marker.sh"   # override_take: the scoped, expiring one-shot override
OK_NAME=gitflow-ok
OK_SCOPE_HINT="<your-working-folder>"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
INPUT="$(cat 2>/dev/null || true)"   # the Stop payload: only its .cwd is used (the override scope)

# NB: the one-shot `gitflow-ok` escape is consumed LATER — only if this guard would actually block (see below).
# Consuming it up-front (the old behaviour) wasted it when this guard would pass anyway: the Stop event runs
# several hooks together, so if ANOTHER hook blocks and the Stop retries, an up-front consume ate the marker on
# the first pass and this guard then re-blocked with no escape left. Only spend the escape when we use it.

is_task_branch() { case "$1" in feature/*|release/*|hotfix/*|support/*) return 0;; *) return 1;; esac; }
_clean() { printf '%s' "$1" | sed 's/^[*+ ]*//; s/[[:space:]]*$//'; }

# _has_own_work <repo> <branch> <trunk> -> rc 0 iff the branch ever carried a commit of its own. `git branch --merged`
# lists every branch whose tip is reachable from the trunk, which includes a branch created from the trunk a moment
# ago: reporting that one as "merged, delete it" would have an agent delete live work. The branch reflog says whether
# anything was ever committed on it; without a reflog only a tip that differs from the trunk tip counts as evidence.
_has_own_work() {
  local r="$1" b="$2" t="$3" gs
  gs="$(git -C "$r" reflog show --format=%gs "refs/heads/$b" -- 2>/dev/null)"
  if [ -n "$gs" ]; then
    printf '%s\n' "$gs" | grep -cE '^(commit|merge|cherry-pick|rebase|pull|am)[ :(]' >/dev/null
    return
  fi
  [ "$(git -C "$r" rev-parse -q --verify "refs/heads/$b" 2>/dev/null)" != "$(git -C "$r" rev-parse -q --verify "refs/heads/$t" 2>/dev/null)" ]
}

# Repos to inspect, chosen by the declared REPOSITORY MODEL (KYKLOS_REPO_SHAPE / KYKLOS_SOURCE_DIR, sourced
# from .claude/standards.env above) so the dangling-branch count is judged against the RIGHT repo(s):
#   companion : the companion trunk repo (bookkeeping) + the nested source at KYKLOS_SOURCE_DIR (where the
#               GitFlow task-branches actually live). A hardcoded `Repo` miscounts when the source dir differs.
#   internal / unset : the single project repo (unset => back-compat). We still probe the default `Repo`
#               sub-dir when present so an as-yet-undeclared companion is not silently miscounted (fail-open:
#               declaring the model narrows this, it never widens a false block).
# [RiskMitigation RA-01] the guard inspects the model's real source repo, never a sibling that happens to sit
# under the workspace root.
_shape="${KYKLOS_REPO_SHAPE:-}"; _srcdir="${KYKLOS_SOURCE_DIR:-Repo}"
case "$_shape" in
  companion) _candidates="$PROJECT_DIR $PROJECT_DIR/$_srcdir" ;;
  internal)  _candidates="$PROJECT_DIR" ;;
  *)         _candidates="$PROJECT_DIR $PROJECT_DIR/$_srcdir" ;;   # unset => probe the default nested dir too (back-compat)
esac
repos=""
for d in $_candidates; do
  git -C "$d" rev-parse --git-dir >/dev/null 2>&1 && repos="$repos $d"
done
[ -z "$repos" ] && exit 0

merged_leftovers=""   # rule (1): merged into a trunk but not deleted
open_branches=""      # every open task-branch (merged or not), for the count rule
for repo in $repos; do
  for trunk in develop main master; do
    git -C "$repo" show-ref --verify --quiet "refs/heads/$trunk" || continue
    while IFS= read -r line; do
      b="$(_clean "$line")"; [ -z "$b" ] && continue
      case "$b" in develop|main|master) continue;; esac
      is_task_branch "$b" || continue
      # A branch checked out in another worktree ('+') is someone else's live work: never report it for deletion here.
      case "$line" in '+'*) continue;; esac
      _has_own_work "$repo" "$b" "$trunk" || continue
      merged_leftovers="${merged_leftovers}${repo##*/}:${b} (merged into ${trunk})
"
    done <<EOF
$(git -C "$repo" branch --merged "$trunk" 2>/dev/null)
EOF
  done
  while IFS= read -r line; do
    b="$(_clean "$line")"; [ -z "$b" ] && continue
    case "$b" in develop|main|master) continue;; esac
    is_task_branch "$b" || continue
    open_branches="${open_branches}${repo##*/}:${b}
"
  done <<EOF
$(git -C "$repo" branch 2>/dev/null)
EOF
done

merged_leftovers="$(printf '%s' "$merged_leftovers" | sed '/^$/d' | sort -u)"
open_branches="$(printf '%s' "$open_branches" | sed '/^$/d' | sort -u)"
open_count="$(printf '%s' "$open_branches" | sed '/^$/d' | grep -c . )"

# [RiskMitigation RA-01] A branch with an OPEN merge request is being closed VIA that MR (the mr/mr-automerge
# flow: GitLab merges + removes the source branch on green, or a human merges) — it is an IN-FLIGHT valid open
# state, NOT a dangling Done branch the agent forgot to merge. Excluding it stops the guard from forcing a
# `gitflow-ok` escape on every in-flight mr-automerge story. Query GitLab through lib/ci-access.sh. FAIL-OPEN: if the API is unconfigured/unreachable/unparseable,
# KEEP the branch in the count (never HIDE a real dangling branch on uncertainty) — the strict check still stands.
# Transport: the bridge-first CI seam (the bridge Control Tower CI verbs). PREFERS the mr_list verb (no container token);
# falls back to a direct token ONLY under the launcher's direct-token exception (KYKLOS_CI_DIRECT_TOKEN=1).
. "$(dirname "${BASH_SOURCE[0]}")/lib/ci-access.sh"   # ci_access_*: the token never leaves its helpers
_ci_tokok=""; ci_access_configured && _ci_tokok=1
if [ -n "$open_branches" ] && [ -n "$_ci_tokok" ] \
   && command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  _kept=""
  while IFS= read -r _ob; do
    [ -n "$_ob" ] || continue
    _bname="${_ob#*:}"                                   # strip the "repo:" prefix -> the bare branch name
    # Ask in the project of the very repository the branch was listed from (its "repo:" prefix), named by its origin:
    # never another repository that happens to hold a branch of the same name. No origin => no project => no answer =>
    # keep, unless the declared direct-token exception can answer (it reads its declared project).
    _bdir=""
    for _r in $repos; do [ "${_r##*/}" = "${_ob%%:*}" ] && _bdir="$_r"; done
    _repo_addr=""
    [ -n "$_bdir" ] && { _repo_addr="$(ci_access_repository_address "$_bdir")" || _repo_addr=""; }
    _mrn=""
    { [ -n "$_repo_addr" ] || ci_access_direct_usable; } && _mrn="$(ci_access_merge_requests "$_bname" opened "$_repo_addr" 2>/dev/null | jq '.merge_requests | length' 2>/dev/null || echo "")"
    # KEEP unless we CONFIRMED an open MR (_mrn is a positive integer). No MR ("0") or any failure/cannot-verify
    # ("") => keep (conservative: never HIDE a real dangling branch on uncertainty).
    if [ "${_mrn:-0}" = "0" ] || [ -z "$_mrn" ]; then _kept="${_kept}${_ob}
"; fi
  done <<EOF
$open_branches
EOF
  open_branches="$(printf '%s' "$_kept" | sed '/^$/d' | sort -u)"
  open_count="$(printf '%s' "$open_branches" | sed '/^$/d' | grep -c . )"
fi

# In-progress story count — the SSoT for active work. Count a row if ANY of its cells IS the In-progress
# status cell, i.e. after stripping leading non-letters (spaces / a status emoji / glyph) it STARTS WITH the
# token. This is column-position-INDEPENDENT (the Status column is $3 in the infra 4-col tables but a later
# column in the companion's wider batch tables — a hardcoded $3 always counted 0 there, falsely flagging every
# open branch as dangling) and prose-safe (a Summary cell that merely mentions "in-progress" mid-sentence does
# not START with it). The `[^A-Za-z]` strip is an ASCII class, so it removes the emoji BYTES without a
# locale-dependent multibyte match (a byte-vs-char trap).
# Column-position-independent Status reading + the story-backend seam, shared with the story-proof + backlog
# guards (single source of truth; a divergent per-hook copy is exactly how the wide-table $3 bug recurred).
# Fail-open if the lib is absent. The In-progress count comes from the ACTIVE backend: the on-disk BACKLOG.md
# (local) or a projection materialized from the GitLab issues (gitlab) — so the dangling-branch check judges the
# same active-work count either way. Empty (no Stories/, or GitLab unreachable) => have_backlog=0, no false flag.
_bl="$(dirname "${BASH_SOURCE[0]}")/lib/backlog-lib.sh"
# [no-fail-open] a missing lib is a broken install — surface it LOUDLY (still exit 0 so Stop never wedges).
if [ -f "$_bl" ]; then . "$_bl"; else echo "[kyklos] WARNING: branch-cleanup guard INERT this Stop — backlog-lib.sh missing ($_bl), a broken plugin install; branch-closure enforcement is OFF. Reinstall kyklos." >&2; exit 0; fi
BACKLOG="$(resolve_backlog "$PROJECT_DIR")"
have_backlog=0; inprog=0; blocked=0; active=0
if [ -n "$BACKLOG" ] && [ -f "$BACKLOG" ]; then
  have_backlog=1
  inprog="$(backlog_count_status "$BACKLOG" '[Ii]n[- ]?[Pp]rogress')"
  # A Blocked / parked story legitimately OWNS its open branch: the work resumes later and
  # merging it would assert a completion that has not happened. Count it as active-owning, exactly like In-progress,
  # so a parked story does not register as DANGLING. This also dissolves the branch-cleanup <-> continue-guard
  # deadlock: a parked story no longer needs the one-shot gitflow-ok escape at every Stop (arming which reset the
  # continue-guard stuck-breaker), so an agent whose only open story is parked can reach a clean Stop without being
  # pressured to merge/close unproven work. The excess-branch check below still stands on (In-progress + Blocked),
  # so a genuinely finished-but-unmerged branch is never hidden.
  blocked="$(backlog_count_status "$BACKLOG" '[Bb]locked')"
  active=$((inprog + blocked))
fi

problems=""
if [ -n "$merged_leftovers" ]; then
  problems="MERGED-but-not-deleted: $(printf '%s' "$merged_leftovers" | tr '\n' ';' | sed 's/;/; /g; s/; $//')."
fi
if [ "$have_backlog" = 1 ] && [ "${open_count:-0}" -gt "${active:-0}" ]; then
  problems="${problems}${problems:+ }DANGLING: ${open_count} open task-branch(es) but only ${active} In-progress/Blocked story(ies) — a finished story's branch was not merged+deleted (do NOT defer to 'batch close'): $(printf '%s' "$open_branches" | tr '\n' ';' | sed 's/;/; /g; s/; $//')."
fi

[ -z "$problems" ] && exit 0

# We WOULD block. Spend the one-shot escape now (only here, so a cascade from another Stop hook can't eat it).
override_take "$OK_NAME" "$(override_hook_scope "$INPUT" "$PROJECT_DIR")" "$INPUT" && { echo "[kyklos] branch-cleanup gate: OVERRIDDEN once ($OK_NAME spent) — a Stop was allowed with an unclosed GitFlow branch." >&2; exit 0; }

# ---- Close-mode advisory: the CLOSE METHOD depends on the project's per-branch-type close-mode ------------
# (FEATURE_/HOTFIX_BRANCH_CLOSE_MODE, sourced from .claude/standards.env above). The generic "merge --no-ff
# locally" instruction is WRONG for the mr / mr-automerge modes, where GitLab performs the merge server-side.
# When the branches being blocked are feature/hotfix we tailor the instruction to the chosen mode; when the
# mode is UNSET we demand the one-time interview (no silent default). feature parent = develop; hotfix parent
# = master (+ a second MR back-merging master into develop).
_involved="$merged_leftovers
$open_branches"
_has_feature=0; _has_hotfix=0
printf '%s' "$_involved" | grep -c 'feature/' >/dev/null && _has_feature=1
printf '%s' "$_involved" | grep -c 'hotfix/' >/dev/null  && _has_hotfix=1

# A CI-self-driven gitflow SOURCE closes a feature/hotfix branch through a Merge Request that CI merges on green;
# a LOCAL merge into develop/main is WRONG - it bypasses the pipeline gate. Detect that
# posture so the advisory REJECTS local/push/unset rather than instructing a local merge.
_cg_ci_driven() {
  case "${KYKLOS_SOURCE_WORKFLOW:-}" in gitflow) ;; *) return 1 ;; esac
  [ "${KYKLOS_CI_SELF_DRIVE:-}" = true ] && return 0
  { [ "${KYKLOS_CI_MONITOR:-}" = 1 ] && [ -n "${KYKLOS_PUSH_REPO_URL:-}" ]; } && return 0
  return 1
}

_mode_hint() { # $1=TYPE-label $2=mode $3=parent-trunk $4=var-name $5=extra(mr-automerge only)
  # CI-driven gitflow source: the close MUST go through a Merge Request that CI merges on green.
  # POKA-YOKE: an UNSET close-mode DEFAULTS to mr-automerge instead of dead-ending in an interview
  # demand -- the SSDLC + GitLab-SSoT policy is "always push the feature branch + MR-automerge into develop", so
  # for a CI-self-driven source there is no other correct mode; blocking on unset only produced a deadlock
  # (KYKLOS_ALLOW_PUSH=1 + CI_SELF_DRIVE=true but no close-mode set => the branch could be closed by NO path;
  # seen in practice). An EXPLICIT local/push is still a deliberate contradiction and stays REJECTED.
  local _m="$2"
  if _cg_ci_driven; then
    case "$_m" in
      mr|mr-automerge) ;;
      "") _m="mr-automerge"
          printf '%s close-mode was UNSET on a CI-self-driven gitflow source -- defaulting to mr-automerge per the SSDLC push-close policy (always push the feature branch + MR that auto-merges into %s on green; never a local merge). Make it explicit with %s=mr-automerge in .claude/standards.env. ' "$1" "$3" "$4" ;;
      *)  printf '%s close-mode "%s" is INVALID for a CI-self-driven gitflow source -- a feature/hotfix branch MUST be closed through a Merge Request that CI merges on green, NEVER a local merge into %s. Set %s=mr-automerge in .claude/standards.env, then: git push -o merge_request.create -o merge_request.target=%s -o merge_request.merge_when_pipeline_succeeds -o merge_request.remove_source_branch origin <name> and delete the local branch. ' "$1" "$_m" "$3" "$4" "$3"; return ;;
    esac
  fi
  case "$_m" in
    "")            printf '%s close-mode is UNSET -- INTERVIEW the user now (local|push|mr|mr-automerge) and write %s to .claude/standards.env before closing this branch (no silent default). ' "$1" "$4" ;;
    local)         printf '%s mode=local: git checkout %s && git merge --no-ff <name> && git branch -d <name> (a development STORY branch is not closed this way: its close needs the time the remote received its work, which only its merge request records, so leave it for the person who pushes to push the branch with its merge request, and delete it once that merged). ' "$1" "$3" ;;
    push)          printf '%s mode=push: push the branch, then delete the local branch. ' "$1" ;;
    mr)            printf '%s mode=mr: git push -o merge_request.create -o merge_request.target=%s -o merge_request.merge_when_pipeline_succeeds origin <name> (created armed: GitLab merges it on green, never merge it by hand), then delete the local branch once it has merged. ' "$1" "$3" ;;
    mr-automerge)  printf '%s mode=mr-automerge: git push -o merge_request.create -o merge_request.target=%s -o merge_request.merge_when_pipeline_succeeds -o merge_request.remove_source_branch origin <name>%s, then delete the local branch. ' "$1" "$3" "$5" ;;
    *)             printf '%s mode=%s (unrecognised -- treat as local): git merge --no-ff <name> && git branch -d <name>. ' "$1" "$_m" ;;
  esac
}

mode_advisory=""
[ "$_has_feature" = 1 ] && mode_advisory="${mode_advisory}$(_mode_hint FEATURE "${FEATURE_BRANCH_CLOSE_MODE:-}" develop FEATURE_BRANCH_CLOSE_MODE '')"
[ "$_has_hotfix"  = 1 ] && mode_advisory="${mode_advisory}$(_mode_hint HOTFIX  "${HOTFIX_BRANCH_CLOSE_MODE:-}"  master  HOTFIX_BRANCH_CLOSE_MODE ' (then open a second MR back-merging master into develop)')"

if [ -n "$mode_advisory" ]; then
  close_hint="$mode_advisory"
else
  close_hint="Merge each finished branch into its trunk and DELETE it NOW (switch to the trunk first if it is your current branch): git checkout <trunk> && git merge --no-ff <name> && git branch -d <name>."
fi

reason="GitFlow branch CLOSURE (closing a finished branch is LOCAL + REQUIRED and is NOT 'pushing' — never skip it because you cannot/should not push, and never defer it to a 'batch close'): ${problems} ${close_hint} One-shot escape if you must keep one open: bash $OVERRIDE_MARKER_CLI set $OK_NAME $OK_SCOPE_HINT"
reason="${reason//\\/\\\\}"; reason="${reason//\"/\\\"}"; reason="$(printf '%s' "$reason" | tr '\n' ' ')"
printf '{"decision":"block","reason":"%s"}' "$reason"
exit 0
