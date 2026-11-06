#!/usr/bin/env bash
# kyklos-fetch-latest-surface.sh (Kyklos, SessionStart) -- fetch every remote at session start and SURFACE any
# branch that is behind, so the agent never begins coding against STALE code.
#
# PROBLEM: an agent starts editing on a branch that is behind its upstream, or off a
# `develop` that trails `main` (a prior non-GitFlow session committed straight to main). The fix was written
# against dead code and only caught by luck (a "file modified since read" Edit error). A repo can also have
# MULTIPLE remotes (origin/GitHub/...) and nothing forced a fetch across them before work began.
#
# WHAT IT DOES -- at session start, for every git repo in the workspace (the project + the nested source at
# KYKLOS_SOURCE_DIR for the companion model): `git fetch --all --prune` (bounded, best-effort), then flag
#   * the current branch behind its upstream (@{u}), and
#   * cross-branch drift: origin/develop behind origin/main|master.
# It SURFACES a warning via additionalContext (nudge, never a block) -- SessionStart can add context but not
# gate; the point is the agent sees "you are behind, pull first" before the first edit.
#
# FAIL-OPEN by construction: every git op is bounded + best-effort; a slow/large repo, a missing upstream, or an
# auth failure just yields no warning for that repo -- session start is never stalled or blocked.
# CONFIG: KYKLOS_FETCH_LATEST=on|off (default on). Wired: SessionStart.
set +e -uo pipefail

# shellcheck source=lib/control-switch.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/control-switch.sh" 2>/dev/null || true   # kyklos_control_off: the one control-switch reader
kyklos_control_off "${KYKLOS_FETCH_LATEST:-}" && exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
cat >/dev/null 2>&1   # drain the SessionStart payload (unused)

_bounded() { local t="$1"; shift; timeout "$t" "$@" 2>/dev/null; }
_isnum() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# Repos to inspect, chosen by the declared REPOSITORY MODEL (same discovery as the branch-cleanup guard): the
# project, plus the nested source at KYKLOS_SOURCE_DIR for the companion (unset => probe the default too).
_shape="${KYKLOS_REPO_SHAPE:-}"; _srcdir="${KYKLOS_SOURCE_DIR:-Repo}"
case "$_shape" in
  internal) _cand="$PROJECT_DIR" ;;
  *)        _cand="$PROJECT_DIR $PROJECT_DIR/$_srcdir" ;;   # companion / unset: probe the nested source too
esac
repos=""
for d in $_cand; do git -C "$d" rev-parse --git-dir >/dev/null 2>&1 && repos="$repos $d"; done
[ -z "$repos" ] && exit 0

warn=""
for repo in $repos; do
  _name="${repo##*/}"
  # Fetch ALL remotes. BOUNDED so a big/slow repo never stalls session start; best-effort (auth/network failures
  # are non-fatal -> just no warning for this repo).
  _bounded 25 git -C "$repo" fetch --all --prune --quiet || true

  # (1) current branch behind its upstream?
  _br="$(git -C "$repo" symbolic-ref --short -q HEAD 2>/dev/null || true)"
  if [ -n "$_br" ]; then
    _up="$(git -C "$repo" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
    if [ -n "$_up" ]; then
      _behind="$(git -C "$repo" rev-list --count "HEAD..@{u}" 2>/dev/null || echo 0)"
      _isnum "$_behind" || _behind=0
      [ "$_behind" -gt 0 ] && warn="${warn}${_name}: current branch '${_br}' is ${_behind} commit(s) BEHIND ${_up} -- pull before coding. "
    fi
  fi

  # (2) cross-branch drift: origin/develop behind origin/main|master (a non-gitflow commit went straight to trunk).
  for _hi in main master; do
    git -C "$repo" rev-parse --verify -q "refs/remotes/origin/develop" >/dev/null 2>&1 || continue
    git -C "$repo" rev-parse --verify -q "refs/remotes/origin/$_hi"    >/dev/null 2>&1 || continue
    _d="$(git -C "$repo" rev-list --count "origin/develop..origin/$_hi" 2>/dev/null || echo 0)"
    _isnum "$_d" || _d=0
    [ "$_d" -gt 0 ] && warn="${warn}${_name}: origin/develop is ${_d} commit(s) BEHIND origin/${_hi} (a non-gitflow commit went straight to ${_hi}?) -- reconcile before branching off develop. "
  done
done

if [ -n "$warn" ]; then
  _msg="[kyklos] STALE-BRANCH WARNING at session start -- ${warn}Fetched all remotes; PULL/reconcile before you start coding or open a story branch, so you never write against dead code."
  if command -v jq >/dev/null 2>&1; then
    jq -nc --arg m "$_msg" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$m}}'
  else
    _msg="${_msg//\\/\\\\}"; _msg="${_msg//\"/\\\"}"
    printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}' "$_msg"
  fi
fi
exit 0
