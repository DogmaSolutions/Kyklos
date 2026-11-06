#!/usr/bin/env bash
# kyklos-idle-work-nudge.sh (Kyklos) - PostToolUse(Bash), ADVISORY (never blocks). When the agent starts polling a
# LONG-running pipeline, an idle wait wastes time if independent pending work exists. This nudges the MAIN agent
# (NOT a subagent - subagents are weaker than the parent) to use the wait for one independent task, and hands it the
# raw material + a safe-switch discipline. The agent makes every judgement; the hook only mechanises "is the wait
# long enough" and pre-filters obvious dependencies.
#
# It maps to the four judgements the agent must make:
#   1. Worth switching?      MECHANISED - stays SILENT unless the TYPICAL pipeline duration of the agent's own
#                            (bridge-scoped) project exceeds a threshold (IDLE_WORK_NUDGE_MIN_MINUTES, default 8). A 1-5 min pipeline never nudges.
#   2. Dependencies?         Feeds candidate open status::todo stories, PRE-EXCLUDING the epic(s) of any in-flight
#                            status::doing story (a mechanical dependency proxy). The agent makes the final cross-dep call.
#   3. Dilution risk?        Framed as a judgement; the nudge says pick a SMALL, self-contained item.
#   4. Clean push/pop?       Checklist: write a resume-checkpoint (branch + next step + the pending pipeline id)
#                            BEFORE switching, and restore it after.
#
# Non-spammy: at most once per project per IDLE_WORK_NUDGE_COOLDOWN_MIN (default 20). Fail-open everywhere (an API
# hiccup / missing config just stays silent - it must NEVER disrupt the agent's flow). Reads go through the bridge
# (lib/ci-access.sh for pipeline durations, lib/coordination-read.sh for the candidate stories);
# KYKLOS_ISSUES_PROJECT selects the project; KYKLOS_ISSUES_API + KYKLOS_ISSUES_TOKEN_ENV (token by env-var NAME;
# [CySec] CWE-522) are only the logged fallback for a bridge without the verb. Wired: PostToolUse Bash.
# [json-answer-required] Every answer this hook reads goes through the JSON reader; without it a check would exit 127
# and fall into a fail-open path, so the hook refuses by name instead (a broken install). [CySec] CWE-636
. "$(dirname "${BASH_SOURCE[0]}")/lib/json-answer.sh" 2>/dev/null
if ! command -v json_test >/dev/null 2>&1; then
    printf '{"decision":"block","reason":"BLOCKED (%s): the JSON reader hooks/lib/json-answer.sh did not load (broken install), so this check cannot run. Reinstall or repin the kyklos plugin."}\n' "$(basename "$0")"
    exit 0
fi
set +e -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/standards-env.sh
. "$HERE/lib/standards-env.sh"; load_standards_env "${CLAUDE_PROJECT_DIR:-$(pwd)}/.claude/standards.env"   # PARSE, never source (CWE-829)

STATE_DIR="${KYKLOS_STATE_DIR:-/tmp/kyklos-state}"; mkdir -p "$STATE_DIR" 2>/dev/null || true
# shellcheck source=lib/control-switch.sh
. "$HERE/lib/control-switch.sh" 2>/dev/null || true   # kyklos_control_off: the one control-switch reader
kyklos_control_off "${IDLE_WORK_NUDGE:-}" && exit 0

INPUT="$(cat || true)"
CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
[ -n "$CMD" ] || exit 0

# (A) Cheap gate first: only act on a PIPELINE-POLL command (references a GitLab pipeline AND loops/sleeps).
printf '%s' "$CMD" | grep -cE '/pipelines/|pipelines\?' >/dev/null || exit 0
printf '%s' "$CMD" | grep -cE '(^|[^A-Za-z])sleep[[:space:]]|for[[:space:]]+.*seq|while[[:space:]]' >/dev/null || exit 0

# The project the pipeline belongs to (from `projects/<N>/pipelines`), else the agent's own project.
POLL_PROJ="$(printf '%s' "$CMD" | grep -oE 'projects/[0-9]+/pipelines' | head -1 | grep -oE '[0-9]+' | head -1 || true)"
[ -n "$POLL_PROJ" ] || POLL_PROJ="${KYKLOS_ISSUES_PROJECT:-}"
[ -n "$POLL_PROJ" ] || exit 0

API="${KYKLOS_ISSUES_API:-}"; TENV="${KYKLOS_ISSUES_TOKEN_ENV:-}"; MYPROJ="${KYKLOS_ISSUES_PROJECT:-}"
[ -n "$MYPROJ" ] || exit 0                                                    # not configured -> silent
{ command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; } || exit 0
# ci-access.sh carries the CI pipeline-duration read onto the bridge-first seam (the bridge Control Tower CI verbs), and
# coordination-read.sh the candidate-STORY lists (coordination_issues), so no container token is needed. Fail-open
# throughout — this hook is advisory and never blocks.
. "$HERE/lib/ci-access.sh"
. "$HERE/lib/coordination-read.sh"
. "$HERE/lib/json-answer.sh"   # json_test: an empty or cut answer is never a readable one

# (B) Cooldown: at most one nudge per project per window.
COOLDOWN="${IDLE_WORK_NUDGE_COOLDOWN_MIN:-20}"; case "$COOLDOWN" in ''|*[!0-9]*) COOLDOWN=20 ;; esac
CD_MARK="$STATE_DIR/idle-nudge-$POLL_PROJ"
if [ -f "$CD_MARK" ] && [ -z "$(find "$CD_MARK" -mmin +"$COOLDOWN" 2>/dev/null)" ]; then exit 0; fi

MIN_MIN="${IDLE_WORK_NUDGE_MIN_MINUTES:-8}"; case "$MIN_MIN" in ''|*[!0-9]*) MIN_MIN=8 ;; esac

# (C) Estimate the project's TYPICAL pipeline duration (avg of up to 3 recent successful runs, in minutes).
#     A test seam (IDLE_WORK_NUDGE_TEST_AVG_MIN) makes this hermetic. If it cannot be estimated -> stay silent
#     (never nudge on a pipeline we cannot confirm is long, to avoid annoying on a short one).
_avg_minutes() {
    [ -n "${IDLE_WORK_NUDGE_TEST_AVG_MIN+x}" ] && { printf '%s' "$IDLE_WORK_NUDGE_TEST_AVG_MIN"; return 0; }
    local ids sum=0 n=0 d
    # Bridge-first CI read: recent successful pipelines, then each one's duration, in the project of the agent's own
    # repository, named by its origin (a companion's CI runs in its nested source, so that one is asked first). The
    # bridge picks the project from that address; no origin or no answer -> no estimate -> silent (advisory, fail-open).
    local proj="${CLAUDE_PROJECT_DIR:-$(pwd)}" repo
    repo=""
    if [ "${KYKLOS_REPO_SHAPE:-}" = companion ]; then
        repo="$(ci_access_repository_address "$proj/${KYKLOS_SOURCE_DIR:-Repo}")" || repo=""
    fi
    [ -n "$repo" ] || repo="$(ci_access_repository_address "$proj")" || { printf ''; return 0; }
    ids="$(ci_access_pipelines "" success 3 "$repo" 2>/dev/null | jq -r '.pipelines[]?.id' 2>/dev/null || true)"
    [ -n "$ids" ] || { printf ''; return 0; }
    for pid in $ids; do
        d="$(ci_access_pipeline_get "$pid" "$repo" 2>/dev/null | jq -r '.duration_s // empty' 2>/dev/null || true)"
        case "$d" in ''|*[!0-9]*) : ;; *) sum=$((sum+d)); n=$((n+1)) ;; esac
    done
    [ "$n" -gt 0 ] || { printf ''; return 0; }
    printf '%s' "$(( sum / n / 60 ))"
}
AVG="$(_avg_minutes)"
case "$AVG" in ''|*[!0-9]*) exit 0 ;; esac          # no estimate -> silent
[ "$AVG" -ge "$MIN_MIN" ] || exit 0                 # short pipeline -> not worth switching (judgement 1)

# (D) Candidate independent work: open status::todo stories in the AGENT's project, minus the epic(s) of any
#     in-flight status::doing story (dependency proxy) and minus anything blocked/awaiting. Test seam: IDLE_WORK_NUDGE_TEST_CANDIDATES.
_candidates() {
    [ -n "${IDLE_WORK_NUDGE_TEST_CANDIDATES+x}" ] && { printf '%s' "$IDLE_WORK_NUDGE_TEST_CANDIDATES"; return 0; }
    local doing todo busy_ms
    # Dual-read the status namespace during the rename window: union the new scoped `status::*` with the
    # legacy single-colon `status:*` (GitLab labels= is exact-match AND, so an OR across schemes = one query each,
    # merged + de-duped by issue id). Fail-safe: a non-array (curl/API error) collapses to [] so the merge never
    # throws (best-effort nudge — a fetch hiccup just yields no candidates and stays silent).
    _idle_one() {   # $1 label list -> JSON array of open issues of MYPROJ carrying all those labels ([] on any failure)
        local out rc
        out="$(coordination_read coordination_issues "$(jq -cn --arg p "$MYPROJ" --arg l "$1" '{scope:"project", id:$p, labels:$l}')" 2>/dev/null)"; rc=$?
        if [ "$rc" = 4 ] && [ -n "$API" ] && [ -n "$TENV" ] && gitlab_token_present "$TENV"; then
            coordination_read_fallback idle-work-nudge "the bridge has no coordination_issues verb"
            out="$(gitlab_curl "$TENV" -s --max-time 8 "$API/projects/$MYPROJ/issues?state=opened&labels=$1&per_page=50" 2>/dev/null || echo '[]')"
        fi
        printf '%s' "$out" | json_test 'type=="array"' && printf '%s' "$out" || printf '[]'
    }
    _idle_fetch() {   # $1 scoped-label  $2 legacy-label -> merged JSON array of open story issues carrying either
        printf '%s\n%s' "$(_idle_one "story,$1")" "$(_idle_one "story,$2")" | jq -s 'add | unique_by([.project_id, .iid])' 2>/dev/null || echo '[]'
    }
    doing="$(_idle_fetch 'status::doing' 'status:doing')"
    busy_ms="$(printf '%s' "$doing" | jq -r '[.[]?.milestone.title // empty] | unique | join("|")' 2>/dev/null || true)"
    todo="$(_idle_fetch 'status::todo' 'status:todo')"
    printf '%s' "$todo" | jq -r --arg busy "$busy_ms" '
        ($busy | split("|") | map(select(length>0))) as $b
        | [ .[]? | select( ((.milestone.title // "") as $m | ($b | index($m)) | not)
                           and ((.labels // []) | any(. == "blocked" or . == "on-hold" or . == "awaiting-user") | not) ) ]
        | .[:6] | .[] | "  #\(.iid) [\(.milestone.title // "no-epic")] \(.title)"' 2>/dev/null || true
}
CANDS="$(_candidates)"
[ -n "$CANDS" ] || exit 0                            # nothing independent to suggest -> silent

touch "$CD_MARK" 2>/dev/null || true                 # arm the cooldown only when we actually nudge

# Surface the nudge TO THE MODEL. A PostToolUse hook's stderr on exit 0 is NOT delivered to the agent; the model
# only receives `hookSpecificOutput.additionalContext` on stdout. jq builds the JSON so every character -
# quotes, backslashes, and the newlines in the multi-line message - is correctly escaped.
NUDGE="$(cat <<EOF
[kyklos] idle-work: you are polling a pipeline (project $POLL_PROJ); pipelines of your own project typically run
~$AVG min -- a LONG wait. Rather than idle,
consider doing ONE independent task while it runs (YOU do it in this same session, not a subagent). Candidate open
stories, already filtered to a DIFFERENT epic than your in-flight work (you still judge cross-deps yourself):
$CANDS
Before switching: (1) is the remaining wait really worth it? (2) does the candidate depend on your in-flight work?
if so, skip it. (3) pick a SMALL self-contained item so you do not dilute context. (4) FIRST write a
resume-checkpoint (current branch + next step + the pending pipeline id) so you can cleanly restore this task; do
the parallel item; then restore it. Nothing notifies you when the pipeline lands: arm your own watch (the Monitor
tool or a backgrounded until-loop) before switching.
EOF
)"
jq -nc --arg ctx "$NUDGE" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$ctx}}'
exit 0
