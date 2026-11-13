#!/usr/bin/env bash
# kyklos-slnx-green-guard.sh (Kyklos) — PreToolUse Bash. Blocks a `git push` of a `feature/*|hotfix/*` branch
# when the target repo contains a *.slnx solution UNLESS a GREEN full-solution (.slnx) build was recorded for
# the pushed HEAD.
#
# WHY: a single-project `dotnet test`/`dotnet build <one.csproj>` does NOT evaluate the StyleCop SOLUTION-ruleset
# rules (SA1117 et al.) — those fire only in a FULL-solution `dotnet build <*.slnx>` (SolutionDir set). So an
# agent can pass every local single-project check and STILL fail the CI `build`, wasting a push+pipeline round
# trip. This guard makes that mistake fail EARLY (before the push) instead of late (in CI). The green build is
# recorded ONLY by the sibling `hooks/lib/record-slnx-green.sh` (a real full-solution `dotnet build`), ONE
# record per solution; this guard checks that the record of each solution the push needs names the pushed SHA.
#
# WHICH solutions: a repo with one solution needs it for every push. A repo with several needs only the ones the
# pushed commits touch — each changed path maps to its nearest enclosing .slnx, and a changed auto-imported MSBuild
# file (Directory.Build.props, global.json, ...) maps to every solution under it. A push touching no solution is
# not gated. If the pushed commits cannot be compared with the remote, every file of the pushed commit counts as
# changed, so every solution holding any of them is required (fail-hard).
#
# FAIL-OPEN on what it cannot reason about — every such path ALLOWS the push (exit 0). It NEVER blocks unless it
# positively knows: this IS a feature/hotfix push, the repo HAS a *.slnx, this container pushes
# (KYKLOS_ALLOW_PUSH=1, or KYKLOS_CI_MONITOR=1 for its own feature/hotfix branch), and a solution the push needs
# has no green record for the pushed SHA. In particular a non-.NET repo (no *.slnx) and a project session with
# neither switch set are both inert.
#
# One-shot LOGGED override (consumed on the block path only, mirroring push-ok/merge-ok/gitflow-ok):
#   bash hooks/lib/override-marker.sh set slnx-ok <repo-dir>
#
# Wired: PreToolUse, matcher Bash.
# [json-answer-required] Every answer this hook reads goes through the JSON reader; without it a check would exit 127
# and fall into a fail-open path, so the hook refuses by name instead (a broken install). [CySec] CWE-636
. "$(dirname "${BASH_SOURCE[0]}")/lib/json-answer.sh" 2>/dev/null
if ! command -v json_test >/dev/null 2>&1; then
    printf '{"decision":"block","reason":"BLOCKED (%s): the JSON reader hooks/lib/json-answer.sh did not load (broken install), so this check cannot run. Reinstall or repin the kyklos plugin."}\n' "$(basename "$0")"
    exit 0
fi
set +e -uo pipefail
_GD_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_GD_HERE/lib/git-cmd-detect.sh"   # git_cmd_invokes: command-position git-subcommand detection (shared)
. "$_GD_HERE/lib/push-refspec.sh"     # push_refspec_dest/src/is_delete/push_base: judge the PUSHED ref, not HEAD
. "$_GD_HERE/lib/slnx-solutions.sh"   # slnx_list/affected/record: the solution <-> green-record map (shared with the recorder)
RECORDER="$_GD_HERE/lib/record-slnx-green.sh"

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
_cfg="$PROJECT_DIR/.claude/standards.env"
# PARSE, never source (CWE-829): a malformed line can't execute (would break the guard + spam the TUI).
. "$(dirname "${BASH_SOURCE[0]}")/lib/standards-env.sh"; load_standards_env "$_cfg"
STATE_DIR="${KYKLOS_STATE_DIR:-/tmp/kyklos-state}"; mkdir -p "$STATE_DIR" 2>/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/override-marker.sh"   # override_take: the scoped, expiring one-shot override
OK_NAME=slnx-ok
OK_SCOPE_HINT="<repo-dir>"
INPUT="$(cat || true)"
CMD="${INPUT//\\\"/\"}"
# The ACTUAL shell command (jq-extracted) — feed THIS to the command-position detector, NOT the JSON envelope.
CMD_REAL="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"; [ -n "$CMD_REAL" ] || CMD_REAL="$CMD"
# The shell's ACTUAL working directory for the command, from the hook input (.cwd). A bare `git push`
# (no -C/cd) runs HERE, which is NOT necessarily PROJECT_DIR (CLAUDE_PROJECT_DIR may be unset/inner).
HOOK_CWD="$(printf '%s' "$INPUT" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"

# Resolve the repo a git command targets — delegates to the SHARED git_target_repo_dir (lib/git-cmd-detect.sh,
# sourced above) with op=push, so the green check judges the repo the PUSH lands in (esp. a companion's nested
# source reached via `cd Repo && git push`) from one source of truth. dedup: this was a per-guard copy.
target_repo_dir() { git_target_repo_dir "$1" "$HOOK_CWD" "$PROJECT_DIR" push; }

# Only act on `git push` at a command position (a `git push` MENTION in a string is not a push). FAIL-OPEN otherwise.
git_cmd_invokes "$CMD_REAL" push || exit 0

# FAIL-OPEN: only push-authorized containers can reach the push guard's block path at all. A non-push-authorized
# project session's push is already denied by kyklos-no-push-guard (or is the observable feature/hotfix loop);
# either way this guard must not add a second, redundant block for a container that isn't the one pushing. So we
# only engage when the container is push-authorized (KYKLOS_ALLOW_PUSH=1) OR is the CI-loop monitor
# (KYKLOS_CI_MONITOR=1, which is the exact context that DOES push its own feature/hotfix branch).
[ "${KYKLOS_ALLOW_PUSH:-0}" = "1" ] || [ "${KYKLOS_CI_MONITOR:-0}" = "1" ] || exit 0

# FAIL-OPEN: no git tooling => cannot reason. Never block.
command -v git >/dev/null 2>&1 || { echo "[kyklos] WARNING: slnx-green guard INERT — git is missing; the full-solution-green push gate is OFF. Install git." >&2; exit 0; }

_tgt="$(target_repo_dir "$CMD")"
TOP="$(git -C "$_tgt" rev-parse --show-toplevel 2>/dev/null || echo "")"
# FAIL-OPEN: unresolvable repo.
[ -n "$TOP" ] || exit 0

# FAIL-OPEN: a DELETE push (`--delete`/`-d`/`:dst`) pushes no content — there is no build to gate.
push_is_delete "$CMD_REAL" && exit 0

# Gate ONLY a push whose DESTINATION is a feature/hotfix branch — judged from the PUSHED REFSPEC, not the
# checked-out HEAD: `git push origin feature/x` issued while HEAD sits on a trunk is a feature push, and
# `git push origin main` while HEAD is on a feature branch is not. Resolve the dest from the refspec; when there is NO
# explicit refspec, git pushes the current branch => fall back to HEAD. FAIL-OPEN for trunk/release/support/other.
push_branch="$(push_refspec_dest "$CMD_REAL")"
# An empty dest (no explicit refspec, e.g. `git push`) OR a bare `HEAD` dest (`git push origin HEAD`) both mean
# "push the CURRENT branch" — resolve to the checked-out branch name so the feature/hotfix match is meaningful.
if [ -z "$push_branch" ] || [ "$push_branch" = "HEAD" ]; then
    push_branch="$(git -C "$TOP" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
fi
case "$push_branch" in feature/*|hotfix/*) : ;; *) exit 0 ;; esac

# FAIL-OPEN: the repo has NO *.slnx => there is no full-solution build to gate (e.g. a non-.NET
# repo). The list excludes VCS/build output folders.
mapfile -t SOLUTIONS < <(slnx_list "$TOP")
[ "${#SOLUTIONS[@]}" -gt 0 ] || exit 0

# The SHA whose green build matters is the one being PUSHED (the refspec's SOURCE ref), not necessarily HEAD.
# `git push origin HEAD:feature/x` pushes HEAD; `git push origin feature/x` pushes feature/x's tip even
# when HEAD is elsewhere. Resolve the source ref (empty => the current branch => HEAD). FAIL-OPEN if unresolvable.
_pushed_src="$(push_refspec_src "$CMD_REAL")"; [ -n "$_pushed_src" ] || _pushed_src="HEAD"
PUSHED_SHA="$(git -C "$TOP" rev-parse "$_pushed_src" 2>/dev/null || echo "")"
[ -n "$PUSHED_SHA" ] || exit 0

# WHICH solutions this push must prove green.
#   one solution  => that solution, for every push (the long-standing behaviour, unchanged).
#   several       => only the solutions the pushed commits touch: each changed path maps to its nearest enclosing
#                    .slnx (plus every solution under a changed auto-imported MSBuild file). A push that touches no
#                    solution (docs, scripts) needs no green build. When the push base cannot be resolved, or the
#                    diff fails, every solution holding files of the pushed commit is required: never less strict
#                    than the one-solution rule.
# [RiskMitigation RA-03] a one-solution repo keeps the long-standing rule unchanged (every push needs its record).
_scope_note=""
if [ "${#SOLUTIONS[@]}" -eq 1 ]; then
    AFFECTED=("${SOLUTIONS[0]}")
else
    _remote="$(push_positionals "$CMD_REAL" | head -1)"
    [ -n "$_remote" ] || _remote="$(git -C "$TOP" config "branch.$push_branch.remote" 2>/dev/null || echo "")"
    [ -n "$_remote" ] || _remote=origin
    _sols="$(printf '%s\n' "${SOLUTIONS[@]}")"
    _changed=""; _diff_ok=0
    if _base="$(push_base "$TOP" "$_remote" "$push_branch" "$PUSHED_SHA")"; then
        # -z: NUL-separated and never C-quoted, so a non-ASCII file name keeps its real folder.
        _changed="$(git -C "$TOP" diff -z --name-only --no-renames "$_base" "$PUSHED_SHA" 2>/dev/null | tr '\0' '\n')" && _diff_ok=1
    fi
    # [RiskMitigation RA-01] no base or a failed diff never shrinks the requirement (fail-hard, see below).
    if [ "$_diff_ok" -eq 0 ]; then
        # No base to compare with (e.g. no remote-tracking ref yet): treat EVERY file of the pushed commit as changed,
        # so every solution holding any of this repo's files is required. Should even that listing fail, the solution
        # files themselves stand in as the changed paths, which requires every solution.
        _scope_note=" (the pushed commits could not be compared with '$_remote', so every solution holding files of the pushed commit is required)"
        _changed="$(git -C "$TOP" ls-tree -z -r --name-only "$PUSHED_SHA" 2>/dev/null | tr '\0' '\n')" || _changed="$_sols"
    fi
    mapfile -t AFFECTED < <(slnx_affected_by_paths "$_sols" "$_changed")
    # The push touches no solution => nothing to prove.
    [ "${#AFFECTED[@]}" -gt 0 ] || exit 0
fi

# [RiskMitigation RA-04] the block reason carries only repo paths, solution paths and SHAs; no secret is read here.
MISSING=(); _details=""
for _sol in "${AFFECTED[@]}"; do
    slnx_record_matches "$STATE_DIR" "$TOP" "$_sol" "${#SOLUTIONS[@]}" "$PUSHED_SHA" && continue
    MISSING+=("$_sol")
    _rec="$(slnx_record_sha "$STATE_DIR" "$TOP" "$_sol" "${#SOLUTIONS[@]}")"
    if [ -n "$_rec" ]; then
        _details="$_details $_sol: the recorded green build is for $_rec, not the pushed $PUSHED_SHA (new commits since the build); record it with: bash $RECORDER $TOP/$_sol (a bridge build can take longer than a foreground tool call: run it in the background, Bash run_in_background, or with the maximum tool time limit)."
    else
        _details="$_details $_sol: no recorded green full-solution build for the pushed $PUSHED_SHA; record it with: bash $RECORDER $TOP/$_sol (a bridge build can take longer than a foreground tool call: run it in the background, Bash run_in_background, or with the maximum tool time limit)."
    fi
done

# ALLOW: every solution this push needs has a green build recorded for exactly the pushed SHA.
[ "${#MISSING[@]}" -eq 0 ] && exit 0

# We WOULD block. Spend the one-shot override on the block path only, so a benign allowed push cannot silently eat it.
override_take "$OK_NAME" "$(override_scope_of "${TOP:-$PROJECT_DIR}")" "$INPUT" && { echo "[kyklos] slnx-green gate: OVERRIDDEN once ($OK_NAME spent) — a push was allowed WITHOUT a recorded full-solution green build." >&2; exit 0; }

# The refusal names the route the recorder takes for this project's build channel (BUILD_EXECUTION, read by the one
# shared reader the recorder uses), so an agent that may not build locally knows the recorder does not build locally.
# Text only: the channel never changes which push is allowed.
. "$_GD_HERE/lib/build-execution.sh" 2>/dev/null
case "$(command -v build_execution_mode >/dev/null 2>&1 && build_execution_mode "$_cfg")" in
    bridge) _route="With BUILD_EXECUTION=bridge the recorder runs that build on the host through the bridge's build verb, never in this container, so it is allowed where local builds are forbidden." ;;
    local)  _route="With BUILD_EXECUTION=local the recorder runs that build locally, in this container." ;;
    *)      _route="BUILD_EXECUTION is not set (or not bridge or local), so the recorder cannot choose where to build: set it first (bridge builds on the host through the bridge, local builds in this container), then run the recorder." ;;
esac
reason="Push BLOCKED — the pushed $push_branch @ $PUSHED_SHA needs a recorded green full-solution build for ${#MISSING[@]} solution(s)$_scope_note:$_details A single-project build/test does NOT run the StyleCop solution-ruleset rules (SA1117 etc.); only a FULL-solution 'dotnet build <solution>.slnx' does — the same build CI's 'build' job runs. The recorder runs that build and, only on GREEN, records the current HEAD for that solution; then push. $_route For a single deliberate exception: bash $OVERRIDE_MARKER_CLI set $OK_NAME $OK_SCOPE_HINT"
reason="${reason//\\/\\\\}"; reason="${reason//\"/\\\"}"; reason="$(printf '%s' "$reason" | tr '\n' ' ')"
printf '{"decision":"block","reason":"%s"}' "$reason"
exit 0
