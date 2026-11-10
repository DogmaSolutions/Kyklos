#!/usr/bin/env bash
# ai-fix-loop.sh — the DETERMINISTIC half of the AI-review fix loop. The human-in-the-loop
# reasoning (propose a fix, get approval, apply it) lives in the SKILL.md protocol; this script owns only the
# parts that MUST be mechanical and cannot be left to a model's judgement:
#   fetch  — pull the latest AI-review findings for THIS branch's open merge request, ranked by severity.
#   bound  — record the round's finding count and decide CONTINUE vs STOP (the loop must terminate).
# It NEVER edits code, never applies a fix, never pushes — so it cannot break the rule that nothing is applied
# without human approval: applying is the agent's job, gated by the SKILL protocol, not this tool's.
#
# All CI reads go through hooks/lib/ci-access.sh (its header owns the access path, its settings and its test seams).
# bash + curl + jq.
set +e -uo pipefail

PROG="ai-fix-loop"
AIFL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # for the externalized *.jq (kcov phantom-line fix)
die()  { printf '%s: %s\n' "$PROG" "$1" >&2; exit "${2:-2}"; }

# --- config: CI access comes from ci-access.sh, shared with the gate hooks, so the AI fix loop and the gates read CI
# the SAME way. AI_FIX_* carries only the loop controls (branch / round cap / state dir). ----------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../hooks/lib/ci-access.sh"   # ci_access_*: the token never leaves its helpers
MAX_ROUNDS="${AI_FIX_MAX_ROUNDS:-3}"

# Current branch (overridable for tests / detached HEAD).
_branch() { printf '%s' "${AI_FIX_BRANCH:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)}"; }

# Per-repo, EPHEMERAL loop state (round history). Under .git so it is never committed; overridable for tests.
_state_dir() {
  local d="${AI_FIX_STATE_DIR:-}"
  [ -n "$d" ] || d="$(git rev-parse --git-dir 2>/dev/null || echo .)/ai-fix-loop"
  mkdir -p "$d" 2>/dev/null || true
  printf '%s' "$d"
}

# Severity ordering (blocker > major > minor > nit) — the loop addresses the most dangerous finding first; the
# rank is applied inline in the `fetch` jq below.

# --- fetch: findings for THIS branch's open MR, ranked --------------------------------------------------------
# Source of truth = the ai-review job's findings.json artifact on the branch's latest pipeline. Every CI read goes
# through ci-access.sh (bridge-first). A read that CANNOT be satisfied (bridge down and no exception, or out of
# scope) surfaces as an error — NEVER a false "no findings" (the exact green-wash this loop exists to prevent).
# Prints a compact ranked JSON: {"branch":..,"mr_iid":..,"count":N,"by_severity":{..},"findings":[{severity,file,line,title,detail}]}.
cmd_fetch() {
  local br; br="$(_branch)"
  ci_access_configured || die "fetch: no CI access — neither the KyklosBridge nor a declared direct-token exception (KYKLOS_CI_DIRECT_TOKEN=1) is available; the AI review cannot be read" 3
  # Every read names the project of THIS repository (its origin), so a companion's nested source is read there, not in
  # the bridge's default project. No origin: the project cannot be chosen, and that is said, never guessed.
  local repo; repo="$(ci_access_repository_address .)" || repo=""
  [ -n "$repo" ] || [ "$(ci_access_mode)" != bridge ] \
    || die "fetch: this repository has no origin address, so the CI project holding branch '$br' cannot be chosen; add the origin remote" 3
  local mrs; mrs="$(ci_access_merge_requests "$br" opened "$repo")" || die "fetch: could not reach CI to find the merge request for '$br' (the KyklosBridge is down and no direct-token exception is declared, or the call was refused as out-of-scope). $(ci_access_failure_reason $?)" 3
  local mr; mr="$(printf '%s' "$mrs" | jq -r '.merge_requests[0].merge_request // empty' 2>/dev/null)"
  [ -n "$mr" ] || die "fetch: no OPEN merge request for branch '$br' — push the branch + open an MR so the AI review can run" 3

  # REQUIRE the ai-review job AND a readable findings.json. A MISSING pipeline / ai-review job / artifact means
  # the review DID NOT RUN (queued, failed to start, or the artifact expired) — which is NOT the same as "the
  # review ran and found nothing". Emitting count:0 there would let the loop declare the branch clean when the
  # reviewer never ran (the exact green-wash the loop exists to prevent). Surface it with exit 4 instead.
  local pls; pls="$(ci_access_pipelines "$br" "" 1 "$repo")" || die "fetch: could not read the pipeline for '$br' (the KyklosBridge is down and no direct-token exception is declared, or the call was refused as out-of-scope). $(ci_access_failure_reason $?)" 3
  local pipe; pipe="$(printf '%s' "$pls" | jq -r '.pipelines[0].id // empty' 2>/dev/null)"
  [ -n "$pipe" ] || die "fetch: no pipeline for branch '$br' yet — the AI review has not run (push to trigger it)" 4
  local jbs; jbs="$(ci_access_jobs "$pipe" "$repo")" || die "fetch: could not read the jobs of the pipeline for '$br' (bridge down and no direct-token exception, or out of scope). $(ci_access_failure_reason $?)" 3
  local job; job="$(printf '%s' "$jbs" | jq -r '[.jobs[] | select(.name=="ai-review")][0].id // empty' 2>/dev/null)"
  [ -n "$job" ] || die "fetch: the latest pipeline for '$br' has no 'ai-review' job — the review did not run (add one to the pipeline)" 4
  local findings; findings="$(ci_access_artifact "$job" "ai-review/findings.json" "$repo")" \
    || die "fetch: could not read the ai-review findings.json (bridge down and no direct-token exception, or out of scope). $(ci_access_failure_reason $?) — not treating that as zero findings" 4
  printf '%s' "$findings" | json_test 'has("findings") or has("status")' \
    || die "fetch: the ai-review job produced no readable findings.json (expired/failed?) — re-run the review; not treating that as zero findings" 4

  # A reviewer error (credit/rate-limit/unparseable) is NOT "clean" — surface it, do not treat as zero findings.
  local status; status="$(printf '%s' "$findings" | jq -r '.status // "ok"' 2>/dev/null || echo ok)"
  case "$status" in
    ok|"" ) : ;;
    *) die "fetch: the AI reviewer did not complete (status='$status') — re-run the ai-review job; not treating that as 'no findings'" 4 ;;
  esac

  # rank by severity, then file/line.
  local ranked
  ranked="$(printf '%s' "$findings" | jq -cf "$AIFL_DIR/aifl-rank.jq" 2>/dev/null)"
  [ -n "$ranked" ] || ranked='[]'

  jq -cn --arg br "$br" --arg mr "$mr" --argjson f "$ranked" -f "$AIFL_DIR/aifl-assemble.jq"
}

# --- bound: record this round's count + decide CONTINUE / STOP (the loop must terminate) -----------------------
# Usage: bound <count>. Appends the round to the history and prints "CONTINUE <reason>" or "STOP <reason>".
# STOP when: count==0 (clean — done) · rounds >= MAX_ROUNDS (hard cap) · count did NOT strictly decrease vs the
# previous round (ping-pong / not converging). Only a STRICT decrease earns another round.
cmd_bound() {
  local count="${1:-}"; case "$count" in ''|*[!0-9]*) die "bound: <count> must be a non-negative integer";; esac
  # A non-numeric AI_FIX_MAX_ROUNDS makes the `-ge` test error and (no set -e) fall through to CONTINUE — an
  # UNBOUNDED loop. Validate it as a positive integer.
  case "$MAX_ROUNDS" in ''|*[!0-9]*) die "bound: AI_FIX_MAX_ROUNDS must be a positive integer (got '$MAX_ROUNDS')";; esac
  [ "$MAX_ROUNDS" -ge 1 ] || die "bound: AI_FIX_MAX_ROUNDS must be >= 1 (got '$MAX_ROUNDS')"
  local sd; sd="$(_state_dir)"; local hist="$sd/rounds.tsv"
  local n=0; [ -f "$hist" ] && n="$(wc -l < "$hist" 2>/dev/null || echo 0)"
  local round=$((n + 1))
  local prev=""; [ -s "$hist" ] && prev="$(tail -n1 "$hist" | cut -f2)"
  # A corrupted history row (no tab) makes `prev` non-numeric; comparing it would error + fall through to
  # CONTINUE. A non-numeric (non-empty) prev means the round state is unreadable → STOP conservatively.
  case "$prev" in
    '') : ;;                                             # first round — no prior count, normal
    *[!0-9]*) printf 'STOP round=%s reason=corrupt-state (round history unreadable; hand off)\n' "$round"; return 0 ;;
  esac
  printf '%s\t%s\n' "$round" "$count" >> "$hist"

  if [ "$count" -eq 0 ]; then
    printf 'STOP round=%s reason=clean (no findings remain)\n' "$round"; return 0
  fi
  if [ "$round" -ge "$MAX_ROUNDS" ]; then
    printf 'STOP round=%s/%s reason=max-rounds (%s finding(s) remain — hand off to a human)\n' "$round" "$MAX_ROUNDS" "$count"; return 0
  fi
  if [ -n "$prev" ] && [ "$count" -ge "$prev" ]; then
    printf 'STOP round=%s reason=not-decreasing (was %s, now %s — the loop is not converging; hand off)\n' "$round" "$prev" "$count"; return 0
  fi
  printf 'CONTINUE round=%s reason=decreasing (was %s, now %s)\n' "$round" "${prev:-∞}" "$count"
}

# reset the loop state (start a fresh loop).
cmd_reset() { local sd; sd="$(_state_dir)"; rm -f "$sd/rounds.tsv" 2>/dev/null; printf 'reset\n'; }

case "${1:-}" in
  fetch) shift; cmd_fetch "$@" ;;
  bound) shift; cmd_bound "$@" ;;
  reset) shift; cmd_reset "$@" ;;
  -h|--help|help|'') cat >&2 <<EOF
$PROG — the deterministic half of the AI-review fix loop.
  $PROG fetch   — ranked findings for THIS branch's open MR (JSON on stdout)
  $PROG bound <count> — record the round + decide CONTINUE/STOP (the loop always terminates)
  $PROG reset   — clear the loop's round history
It NEVER edits/applies/pushes — the human-approved apply is the SKILL's job.
EOF
    [ -n "${1:-}" ] && exit 0 || exit 2 ;;
  *) die "unknown subcommand: $1" ;;
esac
