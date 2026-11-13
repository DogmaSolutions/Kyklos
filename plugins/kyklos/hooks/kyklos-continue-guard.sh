#!/usr/bin/env bash
# kyklos-continue-guard.sh (Kyklos)  -  Stop hook: forbid an UNMOTIVATED pause.
#
# PROBLEM (a recurring failure mode): agents self-pause with formulaic phrases ("this has been a long session", "pause
# here") while assigned work remains, no blocker exists, and nothing is needed from the user. A PROMPT that says
# "continue autonomously" is LOST after context compaction. A Stop hook is not: it is re-evaluated deterministically
# at EVERY turn boundary, reading the filesystem/GitLab  -  zero dependence on what is in context. So the fix is a
# hook + a DURABLE directive marker, never a prompt.
#
# WHAT IT DOES  -  at Stop, BLOCK the stop while open in-scope work remains, unless a VALID motivation holds:
#   * work-complete    -  no open in-scope work item (verified against GitLab; cannot be gamed).
#   * awaiting-user    -  the last assistant turn poses a question / used AskUserQuestion.
# There is DELIBERATELY no agent-usable stop marker at all (neither the old silent "stop-ok" NOR a "continue-blocked"
# reason file): ANY file the agent can touch, it will eventually abuse to self-pause - including declaring a "CI wait"
# a blocker when it has OTHER open stories to work. So the ONLY ways to stop are the two the agent CANNOT self-author:
# work-complete (no open work item, GitLab-verified) and awaiting-user (a real question in the transcript). A genuine
# "I cannot proceed" that needs a human => ASK the user (awaiting-user). A transient outage that makes open-work
# unverifiable => fail-open (below). A genuine wedge => the stuck-breaker auto-releases. A CI wait is NOT a stop:
# work another open story; and if nothing else is open, the agent must ARM ITS OWN watch (the Monitor tool or a
# backgrounded until-loop) to be notified when the pipeline lands  -  there is NO external poller that wakes it.
# A BLOCK returns {"decision":"block","reason":...}  -  Claude Code then CONTINUES the agent (does not stop); the
# agent works and stops again; the hook re-runs. The loop ends when work is complete or a motivation holds.
#
# TWO MODES:
#   * directive (DEFAULT)  -  block on any open in-scope work item: stories AND unlabelled/non-story issues
#                              (routed, parked, status::blocked and disposition-labelled issues are excluded, see
#                              _cg_classify; an explicit CONTINUE_GUARD_LABEL narrows the query instead). The agent
#                              auto-pulls the NEXT item ("keep rolling"). On by default for ALL containers. An optional
#                              `milestone=E0N` line in the $STATE_DIR/continue-directive marker narrows scope to one epic.
#   * default ("finish what you STARTED")  -  OPT-IN via CONTINUE_GUARD_DIRECTIVE=off: block only if an in-progress
#                              story you started (story + status::doing) is open. Narrow; a marker file overrides back to directive.
#
# LIVE-WORKER HOLD: while a background command or background agent is live, status::doing items are owned by it and
# the agent is blocked only once per NEW actionable item (see the hold section below).
#
# STUCK-BREAKER (mandatory safety, so the guard can never WEDGE the agent): if the open in-scope story SET is
# unchanged across K consecutive blocked stops (CONTINUE_GUARD_STUCK_TURNS, default 3), RELEASE the stop and
# surface it LOUDLY. Fail-SAFE = allow the stop, never silent. (A model that re-stops without acting hits this in
# at most K stops; a model closing stories resets the counter each time the set shrinks.)
#
# FAIL-OPEN on an unverifiable open-work query (GitLab unreachable / not configured): a guard that FORCES work must
# allow the stop when it cannot prove work remains  -  else an outage would wedge the agent forever. Logged, never silent.
#
# CONFIG (standards.env / env; all optional): CONTINUE_GUARD=on|off (default on) ; CONTINUE_GUARD_STUCK_TURNS (3) ;
# SCOPE - a cross-project agent sets CONTINUE_GUARD_PROJECTS (comma project ids) and/or CONTINUE_GUARD_GROUPS (comma
# group ids) to span its whole backlog; unset => the single CONTINUE_GUARD_PROJECT (defaults to KYKLOS_ISSUES_PROJECT)
# - back-compat. CONTINUE_GUARD_DIRECTIVE: directive (keep-rolling) is the DEFAULT for every container; set =off to
# opt out to the narrow "finish what you started" mode. Open work is the deduped union across all sources (known work blocks; a flaked source
# never hides it; fail-open only when nothing is known open AND a source errored). The open-work lists come from the
# bridge (coordination_issues via lib/coordination-read.sh); KYKLOS_ISSUES_API + KYKLOS_ISSUES_TOKEN_ENV are only
# the logged fallback for a bridge without that verb (the token referenced by env-var NAME, dereferenced in-place  -
# [CySec] CWE-522, never on argv/log/disk). Wired in hooks.json under "Stop".
# [json-answer-required] Every answer this hook reads goes through the JSON reader; without it a check would exit 127
# and fall into a fail-open path, so the hook refuses by name instead (a broken install). [CySec] CWE-636
. "$(dirname "${BASH_SOURCE[0]}")/lib/json-answer.sh" 2>/dev/null
if ! command -v json_test >/dev/null 2>&1; then
    printf '{"decision":"block","reason":"BLOCKED (%s): the JSON reader hooks/lib/json-answer.sh did not load (broken install), so this check cannot run. Reinstall or repin the kyklos plugin."}\n' "$(basename "$0")"
    exit 0
fi
set +e -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/control-switch.sh
. "$HERE/lib/control-switch.sh" 2>/dev/null || true   # kyklos_control_off: the one control-switch reader
# shellcheck source=lib/standards-env.sh
. "$HERE/lib/standards-env.sh"; load_standards_env "${CLAUDE_PROJECT_DIR:-$(pwd)}/.claude/standards.env"   # PARSE, never source (CWE-829)
# shellcheck source=lib/user-applied-label.sh
. "$HERE/lib/user-applied-label.sh"   # label_user_applied / label_present — shared label checks (also used by the proof guard)
. "$HERE/lib/coordination-read.sh"   # coordination_read: the bridge reads the issue lists (no container token)
. "$HERE/lib/gitlab-curl.sh"   # gitlab_curl / gitlab_token_present: the token never leaves the helper
. "$HERE/lib/json-answer.sh"   # json_read: an empty or cut answer is never a readable one
. "$HERE/lib/own-lane.sh"   # own_lane_verdict: the Own Lane rule, shared with the story tool
. "$HERE/lib/gitlab-paged.sh"   # gitlab_paged_walk: the one rule for reading a whole list

STATE_DIR="${KYKLOS_STATE_DIR:-/tmp/kyklos-state}"; mkdir -p "$STATE_DIR" 2>/dev/null || true
# First-class "parked / awaiting-user" story state. An issue carrying the canonical scoped `status::parked`
# (whose definition is "not forced by the continue-guard") or the legacy bare `parked` is subtracted from the
# open-scope set, so the user can defer a story WITHOUT the agent being forced to pick it up. The park is honored
# REGARDLESS of who applied the label (the usual workflow is the user telling the agent to park, and the agent
# applying it) — every exclusion is AUDITED (logged) so an agent-applied park is visible + reversible, not a silent
# escape. Set CONTINUE_GUARD_PARKED_STRICT=1 to require a non-self GitLab user as the author (it can only tighten).
# The OUTWARD/irreversible leniencies keep the strict check unchanged.
# [CySec] CWE-863 "Incorrect Authorization": the label name is FIXED, never read from a setting. A configurable name
# let the agent point it at a label every story already carries (e.g. `story`) and excuse ALL open work in one move.
readonly _cg_parked_label="parked"
DIRECTIVE="$STATE_DIR/continue-directive"
SIG_FILE="$STATE_DIR/continue-guard.sig"
CNT_FILE="$STATE_DIR/continue-guard.count"
WORK_FILE="$STATE_DIR/continue-guard.work"   # cumulative tool_use count at the last stop (progress fingerprint)

log() { printf '[kyklos] continue-guard: %s\n' "$1" >&2; }
# ALLOW resets the stuck-breaker streak (this stop is legitimate, not part of a spin).
allow() { [ -n "${1:-}" ] && log "$1"; rm -f "$CNT_FILE" "$SIG_FILE" 2>/dev/null || true; exit 0; }
emit_block() {
    local r="$1"; r="${r//\\/\\\\}"; r="${r//\"/\\\"}"; r="$(printf '%s' "$r" | tr '\n' ' ')"
    printf '{"decision":"block","reason":"%s"}' "$r"; exit 0
}

# Bridge-health override: the KyklosBridge MCP is this container's build/test hands. If it is CONFIGURED but
# UNREACHABLE, forcing "keep rolling" makes the agent grind through work it cannot actually build/verify - and
# silently paper over the outage (the exact failure this guards). So when the bridge is DOWN, direct the agent to
# FIX it or STOP + surface it, instead of "keep rolling". Default-ON; opt out with KYKLOS_BRIDGE_HEALTH_CHECK=off.
# FAIL-SAFE: any uncertainty (no .mcp.json, no http MCP server, no curl/jq, OR a real HTTP response) is treated as
# NOT-down, so the normal guard is never weakened. CONTINUE_GUARD_BRIDGE_TEST is a hermetic seam (down|up) for tests.
#
# A slow connection is not a down bridge: on a loaded machine opening the connection can take several seconds (a
# dropped connection request is sent again after 1, 3 and 7 s), while the bridge answers in milliseconds once
# connected. So the probe keeps trying for a retry window (KYKLOS_BRIDGE_PROBE_WINDOW_SECONDS, default 10) before it
# reads the bridge as down, and an answer that took a second or more reads as SLOW, reported apart from down with the
# connect and answer times. _cg_bridge_probe sets _CG_BRIDGE_STATE (up | slow | down | unjudged) and _CG_BRIDGE_DETAIL.
_CG_BRIDGE_STATE=unjudged
_CG_BRIDGE_DETAIL=""
readonly _CG_BRIDGE_SLOW_MS=1000
# The shortest attempt worth making: with less of the window left, the probe stops instead of asking curl for a
# time limit that rounds to 0.00 s (which curl reads as "no limit").
readonly _CG_BRIDGE_MIN_ATTEMPT_MS=100
# _cg_now_ms -> milliseconds of a monotonic-enough clock. CONTINUE_GUARD_TEST_CLOCK_FILE is a test seam, read once by
# the probe and only in a sealed test shell (lib/seal-rule.sh, kyklos_test_seam): each call takes the next line of that
# file as the time.
_CG_TEST_CLOCK=""
_cg_now_ms() {
    if [ -n "$_CG_TEST_CLOCK" ] && [ -s "$_CG_TEST_CLOCK" ]; then
        head -n 1 "$_CG_TEST_CLOCK"; sed -i 1d "$_CG_TEST_CLOCK"; return 0
    fi
    local t="${EPOCHREALTIME:-}"
    if [ -n "$t" ]; then t="${t/[.,]/}"; printf '%s' "$((10#$t / 1000))"; else date +%s%3N; fi
}
_cg_seconds() { printf '%d.%02d' "$(($1 / 1000))" "$((($1 % 1000) / 10))"; }
_cg_bridge_probe() {
    _CG_BRIDGE_STATE=unjudged; _CG_BRIDGE_DETAIL=""
    kyklos_control_off "${KYKLOS_BRIDGE_HEALTH_CHECK:-}" && return 0
    case "${CONTINUE_GUARD_BRIDGE_TEST:-}" in down) _CG_BRIDGE_STATE=down; _CG_BRIDGE_DETAIL="test seam"; return 0 ;; up) _CG_BRIDGE_STATE=up; return 0 ;; esac
    command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || return 0
    # The bridge's own address, found the one way every hook finds it (the KyklosBridge entry by name): the first http
    # server in .mcp.json can be another tool (a stopped test runner), which must never read as a down bridge.
    # [RiskMitigation RA-03] Only the KyklosBridge entry is probed; no entry, or a client library that cannot load,
    # means "not judged", never "down".
    command -v bridge_mcp_endpoint >/dev/null 2>&1 || . "$HERE/lib/bridge-mcp.sh" 2>/dev/null
    command -v bridge_mcp_endpoint >/dev/null 2>&1 || return 0
    local url; url="$(bridge_mcp_endpoint 2>/dev/null)" || return 0
    [ -n "$url" ] || return 0
    local base; base="$(printf '%s' "$url" | sed -E 's#^(https?://[^/]+).*#\1#')"
    [ -n "$base" ] || return 0
    local window="${KYKLOS_BRIDGE_PROBE_WINDOW_SECONDS:-10}"
    case "$window" in ''|*[!0-9]*|0) window=10 ;; esac
    local LC_ALL=C start now left attempts=0 out code connect total
    command -v kyklos_test_seam >/dev/null 2>&1 || . "$HERE/lib/seal-rule.sh" 2>/dev/null
    _CG_TEST_CLOCK="$(kyklos_test_seam continue-guard CONTINUE_GUARD_TEST_CLOCK_FILE)"
    start="$(_cg_now_ms)"
    while :; do
        now="$(_cg_now_ms)"; left=$((window * 1000 - (now - start)))
        [ "$left" -ge "$_CG_BRIDGE_MIN_ATTEMPT_MS" ] || break
        attempts=$((attempts + 1))
        # One attempt may use the whole time left: the system itself repeats a dropped connection request meanwhile.
        out="$(curl -s -o /dev/null -w '%{http_code} %{time_connect} %{time_total}' --connect-timeout "$(_cg_seconds "$left")" \
            --max-time "$(_cg_seconds "$left")" "$base/api/status" 2>/dev/null)"
        read -r code connect total <<< "$out"
        case "${code:-000}" in
            000) now="$(_cg_now_ms)"; [ $((window * 1000 - (now - start))) -gt 500 ] && sleep 0.5 ;;   # refused or no answer: try again
            *)   # any HTTP code: something is listening and answered
                now="$(_cg_now_ms)"
                _CG_BRIDGE_DETAIL="answered after $(_cg_seconds $((now - start))) s over ${attempts} attempt(s); the answering attempt: connect $(printf '%.2f' "${connect:-0}") s, answer $(printf '%.2f' "${total:-0}") s"
                if [ $((now - start)) -ge "$_CG_BRIDGE_SLOW_MS" ]; then _CG_BRIDGE_STATE=slow; else _CG_BRIDGE_STATE=up; fi
                return 0 ;;
        esac
    done
    _CG_BRIDGE_STATE=down
    _CG_BRIDGE_DETAIL="no answer within the ${window} s retry window over ${attempts} attempt(s) to $base/api/status (last attempt: connect $(printf '%.2f' "${connect:-0}") s, answer $(printf '%.2f' "${total:-0}") s)"
    return 0
}
_cg_bridge_down() {
    _cg_bridge_probe
    [ "$_CG_BRIDGE_STATE" = down ]
}
INPUT="$(cat || true)"

# Shared prohibited-prioritization detector — the SAME one the ask-user-guard uses, so a prohibited
# "which next / your preference / defer-to-user" question is caught whether asked via the AskUserQuestion tool OR
# (the loophole this closes) as plain prose at Stop. Fail-open: if the lib is unavailable the guard behaves as before.
_CG_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_CG_HERE/lib/ask-detect.sh" 2>/dev/null || true
# [Blocked needs a recorded blocker — DEFAULT-ON; opt out KYKLOS_BLOCKER_CHECK=off] A story is Blocked only through the
# bridge's story_block verb (the story tool: `story block`), which records what it waits on as a `Blocked-On:` header
# bullet. This guard only checks that bullet; the bridge alone reads the reference and lifts the block.
_cg_blocker_check_enabled() { ! kyklos_control_off "${KYKLOS_BLOCKER_CHECK:-}"; }
# _cg_blocker_recorded (an issue description on stdin) -> rc 0 when its header records a blocker: the bullet's value
# starts with a reference the bridge writes (#<n>, !<n>, <project>#<n>, <project>!<n>, or an issue / merge request web
# link), or is a user or external blocker as the bridge writes it (`user since <yyyy-MM-dd>: <link to the question>`,
# `external since <yyyy-MM-dd>: <who or what>`). A hand-edited bullet that names neither is not a recorded blocker (the
# story then counts as open work).
_cg_blocker_recorded() {
    tr -d '\r' | grep -Ec '^[[:space:]]*[-*][[:space:]]+\*\*Blocked-On:\*\*[[:space:]]*(([A-Za-z0-9._/-]*[#!][0-9]+|https?://[^[:space:]]+/-/(issues|merge_requests)/[0-9]+)([[:space:]]|$)|user since [0-9]{4}-[0-9]{2}-[0-9]{2}: https?://[^[:space:]]+/-/(issues|merge_requests)/[0-9]+#note_[0-9]+|external since [0-9]{4}-[0-9]{2}-[0-9]{2}: [^[:space:]])' >/dev/null
}

# Default ON.
kyklos_control_off "${CONTINUE_GUARD:-}" && exit 0

# (1)+(2) [REMOVED] both agent-touchable stop escapes - the silent 'stop-ok' AND the 'continue-blocked' reason file.
#     Either one let the agent self-authorize a pause (the "blocker" was abused for a CI wait during which OTHER open
#     stories were workable). ANY marker the agent can touch, it will abuse. The only stops left are the two the agent
#     CANNOT self-author: work-complete + awaiting-user (below). Outage => fail-open; genuine wedge => stuck-breaker.
#     A CI wait is not a stop: work another story; if none is open, arm your OWN watch (Monitor) - nothing else wakes you.

# (3) awaiting the user (a question was posed this turn) -> allow.
_cg_awaiting_user() {   # $1 = transcript path; return 0 iff the last assistant turn poses a question
    local t="${1:-}"; [ -n "$t" ] && [ -f "$t" ] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    local last
    last="$(tail -n 800 "$t" 2>/dev/null | jq -rc 'select((.type=="assistant") or (.message.role=="assistant") or (.role=="assistant"))' 2>/dev/null | tail -1)"
    [ -n "$last" ] || return 1
    local text; text="$(printf '%s' "$last" | jq -r '[.. | objects | .text? // empty] | join(" ")' 2>/dev/null || true)"
    # A question is a VALID (awaiting-user) stop ONLY if it is a genuine blocker/decision the user MUST
    # answer — NOT a prohibited prioritization/permission-to-CONTINUE question ("keep rolling?", "which next?",
    # "should I continue/proceed?", "or review first?", "want me to keep going?"). Those violate the
    # prioritize-autonomously directive and MUST NOT self-authorize a stop. Match the CLOSING part of the turn
    # (last 320 bytes, lower-cased) so an in-prose mention doesn't false-trip a genuine trailing question.
    local _tail; _tail="$(printf '%s' "$text" | tail -c 320)"
    # Prohibited prioritization/preference/defer question -> NOT a valid self-authorized stop. The SHARED detector
    # (lib/ask-detect.sh, also used by the ask-user-guard) owns the pattern; the inline pattern below is only a
    # fallback for a lib that was unavailable at source time, and it is NOT kept in step with the lib.
    if command -v ask_prohibited_prioritization >/dev/null 2>&1; then
        ask_prohibited_prioritization "$_tail" && return 1
    elif printf '%s' "$_tail" | tr 'A-Z' 'a-z' | grep -cE 'keep (on )?rolling|keep going|which (one|story|task|issue|enabler)?.{0,12}(next|first|should i)|should i (continue|proceed|keep|go|start|move on)|shall i (continue|proceed|keep|start|go)|want me to (keep|continue|proceed|start|go)|(continue|proceed|build|work) or (review|wait|hold|pause|stop)|(where|what|how) (do|should|would) you want|\bor (step back|stand by|hold off|wait|pause)|review .{0,20}(first|specs)|ready to (proceed|continue|move|build)' >/dev/null; then
        return 1
    fi
    printf '%s' "$last" | grep -c 'AskUserQuestion' >/dev/null && return 0                                  # asked via the tool
    printf '%s' "$text" | grep -cE '\?[[:space:]"'"'"'`*)]*$' >/dev/null && return 0                          # trailing question mark
    return 1
}
_trans="$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
if _cg_awaiting_user "$_trans"; then allow "awaiting-user (a question was posed this turn)  -  allowing this stop."; fi

# (4) mode + open in-scope work. Echo a space-separated list of open story iids, or the literal ERR (fail-open).
# directive mode = block on ANY open scope story ("keep rolling"). This is the DEFAULT: on by default for
# every container - keep working the whole backlog, don't idle. Opt OUT
# with CONTINUE_GUARD_DIRECTIVE=off (then: the narrow "finish what you STARTED" default, unless a /tmp marker forces
# directive for one session). Env on|1|true is the explicit (now redundant) form. Marker still forces it (back-compat).
if kyklos_control_off "${CONTINUE_GUARD_DIRECTIVE:-}"; then
  if [ -f "$DIRECTIVE" ]; then _mode=directive; else _mode=default; fi
else
  _mode=directive
fi
# Open in-scope stories across a configurable SET of sources (for a cross-project agent). Echoes
# the deduped list of project-qualified tokens `<project_id>#<iid>`, or the literal ERR (fail-open), or empty.
#   scope: CONTINUE_GUARD_PROJECTS (comma project ids) + CONTINUE_GUARD_GROUPS (comma group ids); if BOTH unset it
#          falls back to the single CONTINUE_GUARD_PROJECT|KYKLOS_ISSUES_PROJECT (back-compat, unchanged).
#   reduce: KNOWN work in ANY source => emit it (=> BLOCK) even if a sibling source flaked; union empty AND >=1
#           source errored => ERR (=> fail-open); union empty AND all sources clear => empty (=> work-complete).
# An issue is "parked out" of the keep-rolling set when its parked label is CURRENTLY applied. By DEFAULT
# the author does NOT matter (label_present): the common workflow is "user says park → agent applies the label", and
# refusing to honor that agent-applied park left genuinely-deferred stories resurfacing forever.
# Parking one story is bounded, visible + reversible, so honoring it is proportionate — and every exclusion is AUDITED
# (logged) so a dodging/injected agent's self-park is loud, not a silent escape. A high-assurance deployment can set
# CONTINUE_GUARD_PARKED_STRICT=1 to restore the strict USER-authored rule. Fail-CLOSED (rc 1 = stays in scope) on any
# uncertainty. The OUTWARD/irreversible leniencies (proof-override, push/merge) are UNCHANGED — they keep label_user_applied.
_cg_is_parked() {   # $1 = "project#iid"
    # dual-read: the canonical scoped `status::parked` parks an issue exactly like the (legacy /
    # fixed) bare label, during and after the unified-status migration.
    case "${CONTINUE_GUARD_PARKED_STRICT:-}" in
        on|1|true|yes|ON|TRUE|YES) label_user_applied "${1%%#*}" "${1##*#}" "$_cg_parked_label" \
                                   || label_user_applied "${1%%#*}" "${1##*#}" "status::parked" ;;
        *)                         label_present      "${1%%#*}" "${1##*#}" "$_cg_parked_label" \
                                   || label_present      "${1%%#*}" "${1##*#}" "status::parked" ;;
    esac
}

# The label-query entry that stands for "every Blocked story" (see _cg_open_stories); never a real label list.
_CG_BLOCKED_QUERY='@blocked'
# _cg_keep_blocked (query lines on stdin) -> only the lines of Blocked issues: status::blocked-on-<any kind>, or the
# legacy status::blocked, status:blocked, S:blocked; the failure marker line is kept, so a failed list is never "none".
_cg_keep_blocked() {
    grep -E '^__CG_QUERY_FAILED__$|\|(.*,)?(status::blocked(-on-[^,]+)?|status:blocked|S:blocked)(,|$)' || true
}

_cg_open_stories() {   # $1 = mode
    [ -n "${CONTINUE_GUARD_TEST_OPEN+x}" ] && { printf '%s' "$CONTINUE_GUARD_TEST_OPEN"; return 0; }   # hermetic seam (final output)
    local api="${KYKLOS_ISSUES_API:-}" tenv="${KYKLOS_ISSUES_TOKEN_ENV:-}"
    { command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; } || { printf 'ERR'; return 0; }
    # The lists come from the bridge (coordination_issues); a direct token is only the transition path for a bridge
    # without that verb, so it is no longer required up front.
    local projects="${CONTINUE_GUARD_PROJECTS:-${CONTINUE_GUARD_PROJECT:-${KYKLOS_ISSUES_PROJECT:-}}}"
    local groups="${CONTINUE_GUARD_GROUPS:-}"
    { [ -n "$projects" ] || [ -n "$groups" ] || [ -n "${CONTINUE_GUARD_SCOPE_ALL:-}" ]; } || { printf 'ERR'; return 0; }
    # Label filter: CONTINUE_GUARD_LABEL (if SET, even to empty) overrides the story default. A cross-project agent
    # whose backlog is label-scoped (e.g. a legacy for:<agent> routing label) sets it; empty => NO label filter (count EVERY open issue in
    # scope, per an "all issues in these groups/projects regardless of label" backlog). Unset keeps the story default.
    # Build the label-filter fragment(s). GitLab's labels= filter is exact-match AND, so matching the
    # in-progress story across BOTH the new scoped `status::doing` and the legacy single-colon `status:doing` (the
    # rename window) needs ONE query per scheme, unioned by the project#iid dedup below. Directive mode (the usual
    # default) filters only on `story` and is unaffected by the status rename.
    # Dual-read a multi-level routing label (e.g. for:<agent>) across BOTH schemes during the rename
    # window: the configured single-colon `for:<agent>` AND the scoped `for::<agent>`, so the guard keeps seeing the
    # backlog whether an issue is relabelled or not. Mirrors the status:: dual-read below.
    _cg_label_schemes() {   # <label> -> the label + its sibling-scheme variant (single<->double colon), one per line
        printf '%s\n' "$1"
        case "$1" in *::*) printf '%s\n' "${1/::/:}" ;; *:*) printf '%s\n' "${1/:/::}" ;; esac
    }
    # Each entry is the RAW comma label list of one query ("" = no label filter); the bridge and the direct path
    # each encode it their own way.
    local -a _label_qs=()
    if [ -n "${CONTINUE_GUARD_LABEL+x}" ]; then
        if [ -n "$CONTINUE_GUARD_LABEL" ]; then
            local _lbl
            while IFS= read -r _lbl; do _label_qs+=("$_lbl"); done < <(_cg_label_schemes "$CONTINUE_GUARD_LABEL")
        else _label_qs=(""); fi
    elif [ "$1" = default ]; then
        _label_qs=('story,status::doing' 'story,status:doing')
        # A Blocked story is checked for its recorded blocker (below), so setting a started story Blocked is not a way out.
        # Every Blocked value: the kinds (status::blocked-on-<kind>, a kind this version does not know included) and the
        # legacy bare forms. A GitLab label filter matches one exact name and cannot match a prefix, so the open stories
        # are listed once and the Blocked ones kept here (_cg_keep_blocked): no kind is missed by name.
        _cg_blocker_check_enabled && _label_qs+=("$_CG_BLOCKED_QUERY")
    else
        # directive mode with NO explicit label scope: the query is UNFILTERED — "work to do" is not
        # necessarily a story (a real blind spot: an unlabeled issue sat invisible because this filter said
        # labels=story). Each returned issue is CLASSIFIED from the labels the list response already carries
        # (_cg_partition below; zero extra API calls): stories and unlabeled/plain issues FORCE work; routed
        # coordination (kind::communication, legacy for:*/for::*), parked, status::blocked (a declared, reason-gated state) and the
        # disposition labels (wontfix/duplicate/invalid) are excluded — each exclusion audited.
        _label_qs=("")
    fi
    local ms="" ms_enc=""
    if [ "$1" = directive ]; then
        ms="$(grep -oE 'milestone=[^[:space:]]+' "$DIRECTIVE" 2>/dev/null | head -1 | cut -d= -f2 || true)"
        [ -n "$ms" ] && ms_enc="&milestone=$(printf '%s' "$ms" | jq -sRr @uri)"
    fi
    local any_err=0 acc=""
    # _cg_query <scope> <id> <raw-labels> -> prints "project_id#iid|label,label" lines; sets any_err on any failure.
    # The bridge answers first (no token in the container); only a bridge WITHOUT the verb falls back to the direct
    # token, announced on the fallback ledger. A bridge that cannot answer is "cannot check" (any_err), never "none".
    # _cg_query runs inside $( ), so a variable it sets is lost: a failure is reported as a marker LINE instead and
    # counted after the loop (a variable set here once made every failed query read as "no work").
    _cg_err() { printf '%s\n' '__CG_QUERY_FAILED__'; }
    # _cg_page_get <path> -> one page through the direct token; rc 1 unless GitLab answered 200.
    _cg_page_get() {
        local r; r="$(gitlab_curl "$_CG_TENV" -s --max-time 12 -w $'\n%{http_code}' "$_CG_API/$1" 2>/dev/null || true)"
        printf '%s' "$r" | sed '$d'; [ "$(printf '%s' "$r" | tail -n1)" = 200 ]
    }
    _cg_query() {
        local scope="$1" id="$2" lbls="$3" args out rc u resp code body
        args="$(jq -cn --arg s "$scope" --arg i "$id" --arg l "$lbls" --arg m "$ms" \
            '{scope:$s} + (if $i != "" then {id:$i} else {} end) + (if $l != "" then {labels:$l} else {} end) + (if $m != "" then {milestone:$m} else {} end)')"
        out="$(coordination_read coordination_issues "$args" 2>/dev/null)"; rc=$?
        if [ "$rc" = 0 ]; then
            printf '%s' "$out" | jq -r '.[] | "\(.project_id)#\(.iid)|\((.labels // []) | join(","))"' 2>/dev/null || _cg_err
            [ -n "${_CG_UPD_FILE:-}" ] && printf '%s' "$out" | jq -r '.[] | "\(.project_id)#\(.iid)\t\(.updated_at // "")"' >> "$_CG_UPD_FILE" 2>/dev/null
            _cg_record_assignees "$out"
            return 0
        fi
        if [ "$rc" != 4 ] || [ -z "$api" ] || [ -z "$tenv" ] || ! gitlab_token_present "$tenv"; then _cg_err; return 0; fi
        coordination_read_fallback continue-guard "the bridge has no coordination_issues verb"
        case "$scope" in
            project)  u="projects/$id/issues?state=opened" ;;
            group)    u="groups/$id/issues?state=opened" ;;
            *)        u="issues?scope=all&state=opened" ;;
        esac
        [ -n "$lbls" ] && u="$u&labels=$(printf '%s' "$lbls" | jq -sRr @uri)"
        u="$u$ms_enc"
        # Every page (the shared reader): with more than 100 open issues, the first page alone can hold only skipped
        # (parked, routed) issues while the work sits on page 2. An unreadable page or a list past the page cap is a
        # failed query, never "no work". [RiskMitigation RA-01]
        body="$(_CG_API="$api" _CG_TENV="$tenv" gitlab_paged_walk _cg_page_get "$u" 2>/dev/null)" || { _cg_err; return 0; }
        # carry the LABELS in the token (comma-joined; labels never contain '|' or whitespace in our
        # registry) so the classifier + parked/blocked subtraction read them with ZERO extra API calls (the
        # N+1 finding: the old parked check re-fetched per-issue label events every Stop).
        printf '%s' "$body" | jq -r '.[] | "\(.project_id)#\(.iid)|\((.labels // []) | join(","))"' 2>/dev/null
        [ -n "${_CG_UPD_FILE:-}" ] && printf '%s' "$body" | jq -r '.[] | "\(.project_id)#\(.iid)\t\(.updated_at // "")"' >> "$_CG_UPD_FILE" 2>/dev/null
        _cg_record_assignees "$body"
    }
    # _cg_query_entry <scope> <id> <label query> -> _cg_query, except the Blocked entry: the open stories, of which only
    # the Blocked ones are kept (a failure marker passes through).
    _cg_query_entry() {
        if [ "$3" = "$_CG_BLOCKED_QUERY" ]; then _cg_query "$1" "$2" story | _cg_keep_blocked; else _cg_query "$1" "$2" "$3"; fi
    }
    local oldIFS="$IFS" tok
    IFS=','
    local lq
    for tok in $projects; do
        tok="$(printf '%s' "$tok" | tr -d '[:space:]')"; [ -n "$tok" ] || continue
        for lq in "${_label_qs[@]}"; do
            acc="$acc$(_cg_query_entry project "$tok" "$lq")
"
        done
    done
    for tok in $groups; do
        tok="$(printf '%s' "$tok" | tr -d '[:space:]')"; [ -n "$tok" ] || continue
        for lq in "${_label_qs[@]}"; do
            acc="$acc$(_cg_query_entry group "$tok" "$lq")
"
        done
    done
    # Instance-wide label scope (CONTINUE_GUARD_SCOPE_ALL=<label>): ALSO count every matching issue across the WHOLE
    # instance (GET /issues?scope=all&labels=<label>) - for a cross-project agent whose backlog is "every <label>
    # issue in ANY project" (e.g. for:<agent>). Unioned with the per-project/group results.
    if [ -n "${CONTINUE_GUARD_SCOPE_ALL:-}" ]; then
        # dual-read the instance-wide routing label across both schemes (for:<agent> + for::<agent>).
        while IFS= read -r _lbl; do
            acc="$acc$(_cg_query instance "" "$_lbl")
"
        done < <(_cg_label_schemes "$CONTINUE_GUARD_SCOPE_ALL")
    fi
    IFS="$oldIFS"
    printf '%s' "$acc" | grep -c '^__CG_QUERY_FAILED__$' >/dev/null && any_err=1
    # Dedup on the ISSUE id (the token's part before '|'); keep the first-seen labels for it.
    local uniq; uniq="$(printf '%s\n' "$acc" | grep -E '^[0-9]+#[0-9]+(\|.*)?$' | sort -t'|' -k1,1 -u | tr '\n' ' ' | sed 's/ *$//')"
    [ -n "$uniq" ] && { printf '%s' "$uniq"; return 0; }   # known work anywhere -> block (a flaked sibling never hides it)
    [ "$any_err" = 1 ] && { printf 'ERR'; return 0; }      # no known work + a flake -> fail-open (cannot prove complete)
    printf ''                                              # all sources clear -> work-complete
}

# --- Own Lane: an agent's work is only the issues assigned to its own GitLab user or to nobody ----------------------
# The rule is hooks/lib/own-lane.sh, the same one the story tool applies to its writes. Each list query records every
# issue's assignees ("<project>#<iid><TAB><assignees json>", from the list answer itself: zero extra calls); the
# caller's own identity is read once (the bridge's coordination_whoami). An issue owned by another user is not work:
# it is listed as "owned by <user>". An issue whose ownership cannot be told (no identity, an unreadable assignee)
# stays work, the safe side for this gate. Default-on; opt-out STORY_OWN_LANE=off (the story tool's own setting).
# Hermetic seams: CONTINUE_GUARD_TEST_ASSIGNEES="<p>#<i>=<user>,<user> <p>#<i>= ..." (empty = no assignee) and
# CONTINUE_GUARD_TEST_SELF='{"id":5,"username":"me"}' (the identity answer; "none" = unreadable).
_CG_OWN_FILE="$(mktemp "${TMPDIR:-/tmp}/cg-owners.XXXXXX" 2>/dev/null || true)"
_cg_record_assignees() {   # $1 = a JSON array of issues
    [ -n "${_CG_OWN_FILE:-}" ] || return 0
    printf '%s' "$1" | jq -r '.[] | "\(.project_id)#\(.iid)\t\((.assignees // []) | map(if type == "object" then {id, username} else . end) | tojson)"' \
        >> "$_CG_OWN_FILE" 2>/dev/null || true
}
_CG_SELF=""
_cg_self_json() {   # the caller's own GitLab identity as {id, username}, or null when it cannot be read
    if [ -n "$_CG_SELF" ]; then printf '%s' "$_CG_SELF"; return 0; fi
    local out rc api="${KYKLOS_ISSUES_API:-}" tenv="${KYKLOS_ISSUES_TOKEN_ENV:-}"
    if [ -n "${CONTINUE_GUARD_TEST_SELF+x}" ]; then
        out="$CONTINUE_GUARD_TEST_SELF"; [ "$out" = none ] && out=""
    else
        out="$(coordination_read coordination_whoami '{}' 2>/dev/null)"; rc=$?
        if [ "$rc" = 4 ] && [ -n "$api" ] && [ -n "$tenv" ] && gitlab_token_present "$tenv"; then
            coordination_read_fallback continue-guard "the bridge has no coordination_whoami verb"
            out="$(gitlab_curl "$tenv" -sf --max-time 12 "$api/user" 2>/dev/null)" || out=""
        elif [ "$rc" != 0 ]; then out=""; fi
    fi
    _CG_SELF="$(printf '%s' "$out" | jq -c 'if type == "object" then {id, username} else null end' 2>/dev/null)"
    [ -n "$_CG_SELF" ] || _CG_SELF="null"
    printf '%s' "$_CG_SELF"
}
# _cg_owner_elsewhere <project#iid> -> prints the other owner(s) and returns 0 when the issue is assigned only to other
# users; rc 1 when it is the caller's own, nobody's, unknown, or not recorded.
_cg_owner_elsewhere() {
    own_lane_enabled || return 1
    [ -n "${_CG_OWN_FILE:-}" ] && [ -s "$_CG_OWN_FILE" ] || return 1
    local a v
    a="$(awk -F'\t' -v k="$1" '$1 == k { print $2; exit }' "$_CG_OWN_FILE" 2>/dev/null)"
    [ -n "$a" ] || return 1
    v="$(own_lane_verdict "$a" "$(_cg_self_json)")"
    case "$v" in other:*) own_lane_owner "$v"; return 0 ;; esac
    return 1
}

# _cg_classify <labels-csv> -> the work class of one issue, from its labels alone (pure, seam-testable):
#   skip:disposition (wontfix/duplicate/invalid — an open+dropped issue is incoherent: CLOSE it, don't work it)
#   skip:parked      (the parked label — the user-deferred state, honored as before)
# skip:blocked (status::blocked-on-<kind>, or the legacy bare status::blocked, dual-scheme — a DECLARED, reason-gated,
# phase-frozen state; an unknown future kind still counts as Blocked;
# forcing work on it was the keystone hole)
#   skip:routed      (kind::communication, or a legacy for:*/for::* — coordination; the inbound-issues guard owns
#                     its ball-in-court state)
#   story            (the story label — today's work class)
#   nonstory         (anything else, INCLUDING no labels at all — work by default: silence must never be invisible)
_cg_classify() {
    local csv=",${1:-},"
    # dual-read the scoped status:: terminal forms alongside the legacy bare names; an OPEN issue
    # carrying status::archived is the same incoherence as an open disposition (a terminal state on open work).
    case "$csv" in *,wontfix,*|*,duplicate,*|*,invalid,*|*,status::wontfix,*|*,status::duplicate,*|*,status::invalid,*|*,status::archived,*) printf 'skip:disposition'; return ;; esac
    case "$csv" in *,status::parked,*) printf 'skip:parked'; return ;; esac
    case "$csv" in *",$_cg_parked_label,"*) printf 'skip:parked'; return ;; esac
    case "$csv" in *,status::blocked,*|*,status::blocked-on-*|*,status:blocked,*|*,S:blocked,*) printf 'skip:blocked'; return ;; esac
    case "$csv" in *,kind::communication,*|*,for::*|*,for:*) printf 'skip:routed'; return ;; esac
    case "$csv" in *,story,*) printf 'story'; return ;; esac
    printf 'nonstory'
}

# _cg_blocked_checkable <labels-csv> -> rc 0 when a Blocked issue goes to the Blocked-task check: it classifies as
# skip:blocked (so parked and disposition labels keep their exclusion) and it is not a routed coordination issue
# (kind::communication, for:*/for::*; the inbound-issues guard owns those), in both modes.
_cg_blocked_checkable() {
    [ "$(_cg_classify "${1:-}")" = skip:blocked ] || return 1
    case ",${1:-}," in *,kind::communication,*|*,for::*|*,for:*) return 1 ;; esac
    return 0
}

# _cg_partition <raw token list> — split the (possibly label-enriched) open set into the FORCING work
# set and its non-story subset; audit every excluded class. Sets globals _CG_WORK / _CG_NONSTORY (bare proj#iid
# tokens). Classification applies ONLY in directive mode with no explicit label scope ($_CG_CLASSIFY=1): a
# label-scoped agent's backlog is label-defined (its every issue carries the routing label — classifying would
# empty it), and the narrow default mode keeps its story+doing contract. A bare token (no '|') is WORK unchanged —
# the hermetic seam's existing fixtures keep their meaning. An issue with an unparseable labels field classifies
# as nonstory WORK (fail-strict: never silently invisible).
_cg_partition() {
    _CG_WORK=""; _CG_NONSTORY=""; _CG_BARE=""; _CG_ACTIVE=""; _CG_UNADOPTED=""; _CG_BLOCKED=""; _CG_ELSEWHERE=""
    local tok id labels cls _sk_route="" _sk_park="" _sk_block="" _sk_disp="" _owner
    for tok in $1; do
        id="${tok%%|*}"
        # Own Lane: an issue assigned only to other users is their work, never this agent's (in every mode and class).
        if _owner="$(_cg_owner_elsewhere "$id")"; then
            _CG_ELSEWHERE="$_CG_ELSEWHERE $id (owned by $_owner);"
            continue
        fi
        # [adoption coherence] EVIDENCE-GATED + MODE-INDEPENDENT: a story cannot be worked (status::doing) without
        # being adopted — adoption stamps an ssdlc:phase:: label. If the list labels show status::doing WITHOUT any
        # ssdlc:phase:: label, this story went doing OUT OF BAND (a raw label write bypassed the 'story adopt'/'set'
        # CLI gate, which normally refuses it). Detect it from the labels the list already carries (zero extra calls),
        # independent of the work-classification short-circuit below, so it holds for EVERY label-writer.
        if [ "$tok" != "$id" ]; then
            case ",${tok#*|}," in
                *,status::doing,*|*,status:doing,*|*,S:doing,*)
                    case ",${tok#*|}," in *",ssdlc:phase::"*) : ;; *) _CG_UNADOPTED="$_CG_UNADOPTED $id" ;; esac ;;
            esac
        fi
        # The narrow default mode lists Blocked stories too: they go to the workable-task check, not straight to work.
        # Classified first, as in the directive mode: a Blocked story that is also parked, disposition-labelled or a
        # routed coordination issue keeps that exclusion and is never checked.
        if [ "$tok" != "$id" ] && [ "${_CG_BLOCKED_SPLIT:-0}" = 1 ]; then
            case ",${tok#*|}," in
                *,status::blocked,*|*,status::blocked-on-*|*,status:blocked,*|*,S:blocked,*)
                    _cg_blocked_checkable "${tok#*|}" && _CG_BLOCKED="$_CG_BLOCKED $id"
                    continue ;;
            esac
        fi
        if [ "$tok" = "$id" ] || [ "${_CG_CLASSIFY:-0}" != 1 ]; then
            # a BARE token carries no labels — it stays in the legacy per-issue parked path below
            _CG_WORK="$_CG_WORK $id"; _CG_BARE="$_CG_BARE $id"; continue
        fi
        labels="${tok#*|}"
        cls="$(_cg_classify "$labels")"
        case ",${labels}," in *,status::doing,*|*,status:doing,*|*,S:doing,*) _CG_ACTIVE="$_CG_ACTIVE $id" ;; esac
        case "$cls" in
            story)            _CG_WORK="$_CG_WORK $id" ;;
            nonstory)         _CG_WORK="$_CG_WORK $id"; _CG_NONSTORY="$_CG_NONSTORY $id" ;;
            skip:routed)      _sk_route="$_sk_route $id" ;;
            skip:parked)      _sk_park="$_sk_park $id" ;;
            skip:blocked)     _sk_block="$_sk_block $id"; _cg_blocked_checkable "$labels" && _CG_BLOCKED="$_CG_BLOCKED $id" ;;
            skip:disposition) _sk_disp="$_sk_disp $id" ;;
        esac
    done
    [ -n "$_CG_ELSEWHERE" ] && log "not counted as work, assigned to another user:${_CG_ELSEWHERE%;} — an agent works only on issues assigned to it or to nobody."
    [ -n "$_sk_route" ] && log "excluded ROUTED coordination issue(s) from the keep-rolling set:$_sk_route (kind::communication / for:* — the inbound-issues guard owns their ball-in-court state)."
    [ -n "$_sk_park" ]  && log "excluded parked story(ies) from the keep-rolling set:$_sk_park (label '$_cg_parked_label') — remove the label to put any back in scope."
    [ -n "$_sk_block" ] && log "excluded BLOCKED issue(s) from the keep-rolling set:$_sk_block (status::blocked — a declared, reason-gated state; unblock to resume forcing)."
    [ -n "$_sk_disp" ]  && log "excluded DISPOSITION-labeled issue(s):$_sk_disp (wontfix/duplicate/invalid) — an OPEN dropped issue is incoherent: CLOSE it."
    _CG_WORK="$(printf '%s' "$_CG_WORK" | sed 's/^ *//')"
    _CG_NONSTORY="$(printf '%s' "$_CG_NONSTORY" | sed 's/^ *//')"
    _CG_ACTIVE="$(printf '%s' "$_CG_ACTIVE" | sed 's/^ *//')"
    _CG_UNADOPTED="$(printf '%s' "$_CG_UNADOPTED" | sed 's/^ *//')"
    _CG_BLOCKED="$(printf '%s' "$_CG_BLOCKED" | sed 's/^ *//')"
}

# _cg_issue_description <project#iid> -> the issue description on stdout; rc != 0 when it cannot be read. The bridge
# reads it (coordination_show); a bridge without that verb falls back to the direct token, announced on the ledger.
# Hermetic seam: CONTINUE_GUARD_TEST_DESC_DIR holds one file per issue, named <project>-<iid> (no file = unreadable).
_cg_issue_description() {
    local proj="${1%%#*}" iid="${1##*#}" out rc api="${KYKLOS_ISSUES_API:-}" tenv="${KYKLOS_ISSUES_TOKEN_ENV:-}"
    if [ -n "${CONTINUE_GUARD_TEST_DESC_DIR+x}" ]; then
        printf '%s\n' "$1" >> "$CONTINUE_GUARD_TEST_DESC_DIR/_reads.log"
        [ -f "$CONTINUE_GUARD_TEST_DESC_DIR/$proj-$iid" ] || return 1
        cat "$CONTINUE_GUARD_TEST_DESC_DIR/$proj-$iid"; return 0
    fi
    out="$(coordination_read coordination_show "$(jq -cn --arg p "$proj" --arg i "$iid" '{project:$p, iid:$i}')" 2>/dev/null)"; rc=$?
    if [ "$rc" = 4 ] && [ -n "$api" ] && [ -n "$tenv" ] && gitlab_token_present "$tenv"; then
        coordination_read_fallback continue-guard "the bridge has no coordination_show verb"
        out="$(gitlab_curl "$tenv" -sf --max-time 12 "$api/projects/$proj/issues/$iid" 2>/dev/null)"; rc=$?
    fi
    [ "$rc" = 0 ] || return 1
    printf '%s' "$out" | json_read '.description // ""'
}

# _cg_live_watch <transcript> -> prints the LIVE background worker id(s) from the transcript tail, empty when
# none/unreadable. A worker is a background shell command OR a background agent (a fork / subagent). The evidence is
# HARNESS-WRITTEN, never agent-touchable (the structured forms must be UNESCAPED JSON: a tool output that merely
# quotes a transcript line carries escaped quotes and never counts):
#   start  - a background command's structured result ("backgroundTaskId":"<id>"), an agent launch's structured
#            result ("status":"async_launched","agentId":"<id>"), or a resume ("resumedAgentId":"<id>");
#   end    - a task-notification carrying "<task-id><id></task-id>", UNLESS that notification says the agent stopped
#            with background work of its own still running (it will notify again, so it stays live).
#            A notification counts ONLY on a line the harness wrote AS a notification: one carrying the structured
#            "origin":{"kind":"task-notification"} or a "type":"queue-operation" entry. The same text quoted inside a
#            tool result or an assistant message (a pasted report, a printed fixture) is never an event.
# Events are replayed in transcript order; the last event per id wins. Bounded scan (CONTINUE_GUARD_WATCH_WINDOW
# bytes of the tail, default 4000000): a worker started before the window is not counted (fail-strict).
# LIVENESS EXPIRES: a worker is live only while its LAST event is younger than CONTINUE_GUARD_WATCH_TTL_MINUTES
# (default 30), judged by the transcript line's own harness "timestamp". A "still running" notification is often a
# leftover timer that never notifies again; without the bound such a worker stayed live for hours and the hold let the
# agent idle. An event whose line carries no readable timestamp is too old by definition (fail-strict).
# CONTINUE_GUARD_TEST_NOW (epoch seconds) pins "now" for tests.
_cg_live_watch() {
    local t="${1:-}" win="${CONTINUE_GUARD_WATCH_WINDOW:-4000000}" ttl="${CONTINUE_GUARD_WATCH_TTL_MINUTES:-30}" now cutoff
    [ -n "$t" ] && [ -f "$t" ] || return 0
    case "$win" in ''|*[!0-9]*) win=4000000 ;; esac
    case "$ttl" in ''|*[!0-9]*) ttl=30 ;; esac
    now="${CONTINUE_GUARD_TEST_NOW:-$(date -u +%s 2>/dev/null)}"
    case "$now" in ''|*[!0-9]*) return 0 ;; esac
    cutoff="$(date -u -d "@$((now - ttl * 60))" +%Y-%m-%dT%H:%M:%S 2>/dev/null)" || return 0
    [ -n "$cutoff" ] || return 0
    tail -c "$win" "$t" 2>/dev/null | awk -v cutoff="$cutoff" '
        function mark(id, v) { if (!(id in st)) order[++n] = id; st[id] = v; at[id] = ts }
        {
            ts = ""
            if (match($0, /"timestamp":"[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/)) ts = substr($0, RSTART + 13, 19)
            notice = ($0 ~ /"origin":\{"kind":"task-notification"/ || $0 ~ /"type":"queue-operation"/)
            nseg = split($0, seg, "<task-notification>")
            for (i = 1; i <= nseg; i++) {
                x = seg[i]
                if (i > 1 && notice && match(x, /<task-id>[a-z0-9]+<\/task-id>/)) {
                    id = substr(x, RSTART + 9, RLENGTH - 19)
                    if (x ~ /background work of its own still running/) mark(id, 1); else mark(id, 0)
                    continue
                }
                y = x
                while (match(y, /"backgroundTaskId":"[a-z0-9]+"/)) { mark(substr(y, RSTART + 20, RLENGTH - 21), 1); y = substr(y, RSTART + RLENGTH) }
                y = x
                while (match(y, /"status":"async_launched","agentId":"[a-z0-9]+"/)) { mark(substr(y, RSTART + 37, RLENGTH - 38), 1); y = substr(y, RSTART + RLENGTH) }
                y = x
                while (match(y, /"resumedAgentId":"[a-z0-9]+"/)) { mark(substr(y, RSTART + 18, RLENGTH - 19), 1); y = substr(y, RSTART + RLENGTH) }
            }
        }
        END { out = ""; for (k = 1; k <= n; k++) { id = order[k]; if (st[id] == 1 && at[id] != "" && at[id] >= cutoff) out = out (out == "" ? "" : " ") id }; printf "%s", out }
    ' 2>/dev/null
}
# classification is armed ONLY for directive mode with no explicit label scope (see _cg_partition).
# Each listed issue's updated_at, written by the list query (one "<project>#<iid><TAB><updated_at>" line per issue):
# the Blocked-task check caches its verdicts by it. Seam: CONTINUE_GUARD_TEST_UPDATED_AT="<p>#<i>=<stamp> ...".
_CG_UPD_FILE="$(mktemp "${TMPDIR:-/tmp}/cg-updated.XXXXXX" 2>/dev/null || true)"
trap '[ -n "${_CG_UPD_FILE:-}" ] && rm -f -- "${_CG_UPD_FILE:?}"; [ -n "${_CG_OWN_FILE:-}" ] && rm -f -- "${_CG_OWN_FILE:?}"' EXIT
if [ -n "${CONTINUE_GUARD_TEST_ASSIGNEES:-}" ] && [ -n "${_CG_OWN_FILE:-}" ]; then
    for _u in $CONTINUE_GUARD_TEST_ASSIGNEES; do
        printf '%s\t%s\n' "${_u%%=*}" "$(printf '%s' "${_u#*=}" | jq -Rc 'split(",") | map(select(length > 0))')" >> "$_CG_OWN_FILE"
    done
fi
if [ -n "${CONTINUE_GUARD_TEST_UPDATED_AT:-}" ] && [ -n "$_CG_UPD_FILE" ]; then
    for _u in $CONTINUE_GUARD_TEST_UPDATED_AT; do printf '%s	%s
' "${_u%%=*}" "${_u#*=}" >> "$_CG_UPD_FILE"; done
fi
_CG_CLASSIFY=0
{ [ "$_mode" = directive ] && [ -z "${CONTINUE_GUARD_LABEL+x}" ]; } && _CG_CLASSIFY=1
_CG_BLOCKED_SPLIT=0
{ [ "$_mode" = default ] && [ -z "${CONTINUE_GUARD_LABEL+x}" ]; } && _CG_BLOCKED_SPLIT=1
_open="$(_cg_open_stories "$_mode")"
[ "$_open" = ERR ] && allow "could not verify open work (GitLab unreachable / not configured)  -  allowing stop (fail-open); re-check when reachable."
# partition the (label-enriched) set: stories + NON-STORY issues force work; routed/parked/blocked/
# disposition classes are excluded with an audit each (labels come from the list response — zero extra calls).
# The own identity is read once here, in this shell, so the per-issue Own Lane checks below reuse it.
[ -n "${_CG_OWN_FILE:-}" ] && [ -s "$_CG_OWN_FILE" ] && own_lane_enabled && _cg_self_json >/dev/null
_cg_partition "$_open"
# [adoption coherence — DEFAULT-ON; opt out KYKLOS_ADOPTION_COHERENCE_CHECK=off] A story cannot be status::doing
# without being adopted (adoption stamps an ssdlc:phase:: label). The 'story set status=doing' CLI already refuses
# an unadopted story, but a RAW label write bypasses it — leaving the incoherent doing-but-no-phase state unnoticed.
# This is the universal, write-path-independent catch: refuse the stop and direct the agent to HEAL it. Evidence-
# gated (only fires when the list labels PROVE the incoherence), so it can never false-block a coherent backlog.
case "$(kyklos_control_off "${KYKLOS_ADOPTION_COHERENCE_CHECK:-}" && echo off)" in
    off) : ;;
    *) if [ -n "${_CG_UNADOPTED:-}" ]; then
           emit_block "BLOCKED (continue-guard): INCOHERENT story state — issue(s) [${_CG_UNADOPTED}] are status::doing but NOT adopted (no ssdlc:phase:: label). A story cannot be worked with no phase; this happens when status::doing is applied OUT OF BAND (a raw label write) instead of via 'story adopt'. HEAL each before proceeding: 'story adopt <iid> --type <t> --epic <E0N>' (sets the initial Requirements phase), OR 'story phase <iid> Requirements' if it is already typed + epic'd, OR move it out of status::doing. (opt out: KYKLOS_ADOPTION_COHERENCE_CHECK=off)"
       fi ;;
esac
_open="$_CG_WORK"
# [Blocked needs a recorded blocker — DEFAULT-ON; opt out KYKLOS_BLOCKER_CHECK=off] Blocked means the story waits on
# something recorded: the `Blocked-On:` bullet the bridge's story_block verb writes (with the reason, once). A Blocked
# story with no recorded blocker goes back into the keep-rolling set (block it with `story block`, or work it), so a
# status label alone is never a way to stop. For a story that does record one, the bridge is asked to re-check it
# (story_block with the id alone): when the reference has closed or merged the bridge lifts the block (status back,
# note posted) and the story counts as work again. The guard decides nothing about the reference itself.
# A Stop gate must never become impossible to pass, so a story this check CANNOT judge keeps the plain Blocked
# exclusion and is NAMED in an audit line, never counted as work:
#   - its description could not be read (bridge or GitLab down): after the first failed read none is read this Stop;
#   - it is past the read cap (CONTINUE_GUARD_BLOCKED_READ_MAX, default 30 reads per Stop) or the time budget
#     (CONTINUE_GUARD_BLOCKED_TIME_BUDGET, default 45 seconds of reads per Stop).
# Each verdict (work, wait, or fail for a read that failed) is cached by the WHOLE issue id + updated_at in the state
# dir, so only new or changed stories are read again, the stories past the cap are read on later Stops, and a story
# whose read failed is read LAST, so one story that never answers cannot hide the others. The cache is only read when
# it is a regular file (not a link, a pipe or a device) of at most 1 MiB; anything else is ignored, said so, and
# replaced. The re-check of a recorded blocker is never cached (the reference changes without the story changing); it
# has its own cap of the same size (so re-checks never starve the description reads) and shares the time budget. The hook's own timeout in hooks.json is a last resort: Claude Code treats a
# hook that times out as a non-blocking error, so the Stop passes.
# [RiskMitigation RA-01] [RiskMitigation RA-03] A Blocked story this pass cannot judge stays excluded and is named, reads
# are capped and time-budgeted, and parked, dropped and routed stories keep their exclusion: the Stop never wedges.
# [RiskMitigation RA-04] The verdict cache is read only as a regular, non-linked file of bounded size, matched on the
# whole issue id.
_CG_VERDICT_CACHE_MAX_BYTES=1048576
# _cg_blocker_lifted <project#iid> -> rc 0 when the bridge lifted the story's block on this re-check (its answer starts
# with "lifted"). Any other answer, or no bridge, keeps the block. Hermetic seam: CONTINUE_GUARD_TEST_LIFT_FILE lists
# one <project>#<iid> per line that the bridge would lift (every call is appended to <file>.calls).
_cg_blocker_lifted() {
    local proj="${1%%#*}" iid="${1##*#}" resp
    if [ -n "${CONTINUE_GUARD_TEST_LIFT_FILE+x}" ]; then
        printf '%s\n' "$1" >> "$CONTINUE_GUARD_TEST_LIFT_FILE.calls"
        grep -qxF -- "$1" "$CONTINUE_GUARD_TEST_LIFT_FILE" 2>/dev/null; return $?
    fi
    command -v bridge_mcp_call >/dev/null 2>&1 || return 1
    resp="$(bridge_mcp_call story_block "$(jq -cn --arg p "$proj" --arg i "$iid" '{project:$p, id:$i}')" 20 2>/dev/null)" || return 1
    bridge_mcp_is_error "$resp" && return 1
    case "$(bridge_mcp_text "$resp")" in lifted*) return 0 ;; *) return 1 ;; esac
}
if _cg_blocker_check_enabled && [ -n "${_CG_BLOCKED:-}" ]; then
    _bk_max="${CONTINUE_GUARD_BLOCKED_READ_MAX:-30}"; case "$_bk_max" in ''|*[!0-9]*) _bk_max=30 ;; esac
    _bk_budget="${CONTINUE_GUARD_BLOCKED_TIME_BUDGET:-45}"; case "$_bk_budget" in ''|*[!0-9]*) _bk_budget=45 ;; esac
    _bk_cache="$STATE_DIR/continue-guard.blocked-verdicts"; _bk_cachetext=""; _bk_newcache=""
    if [ -f "$_bk_cache" ] && [ ! -L "$_bk_cache" ] \
       && [ "$(wc -c < "$_bk_cache" 2>/dev/null || echo 0)" -le "$_CG_VERDICT_CACHE_MAX_BYTES" ]; then
        _bk_cachetext="$(cat -- "$_bk_cache" 2>/dev/null)"
    elif [ -e "$_bk_cache" ] || [ -L "$_bk_cache" ]; then
        log "WARNING: ignored the Blocked-story verdict cache $_bk_cache: not a regular file of at most $_CG_VERDICT_CACHE_MAX_BYTES bytes; every Blocked story is judged afresh and the cache is rewritten."
    fi
    _bk_reads=0; _bk_lifts=0; _bk_failed=0; _bk_start=$SECONDS; _bk_work=""; _bk_lifted=""; _bk_unreadable=""; _bk_unchecked=""; _bk_later=""
    _bk_budget_left() { [ "$_bk_reads" -lt "$_bk_max" ] && [ $((SECONDS - _bk_start)) -lt "$_bk_budget" ]; }
    # _bk_judge <id> <pass> — pass 1 judges every story whose cached verdict is not "fail" and defers the others to
    # pass 2, so a story whose read failed last time is read after all the rest.
    _bk_judge() {
        local id="$1" pass="$2" upd cached verdict="" text
        upd="$(awk -F'\t' -v id="$id" '$1 == id { print $2; exit }' "$_CG_UPD_FILE" 2>/dev/null)"
        cached=""
        [ -n "$upd" ] && cached="$(printf '%s\n' "$_bk_cachetext" | awk -F'\t' -v id="$id" -v u="$upd" '$1 == id && $2 == u { print $3; exit }')"
        if [ "$pass" = 1 ] && [ "$cached" = fail ]; then _bk_later="$_bk_later $id"; return 0; fi
        case "$cached" in work|wait) verdict="$cached" ;; esac
        if [ -z "$verdict" ]; then
            if [ "$_bk_failed" = 1 ]; then
                _bk_unreadable="$_bk_unreadable $id"
                [ "$cached" = fail ] && _bk_newcache="$_bk_newcache$id"$'\t'"$upd"$'\t'fail$'\n'
                return 0
            fi
            if ! _bk_budget_left; then _bk_unchecked="$_bk_unchecked $id"; return 0; fi
            _bk_reads=$((_bk_reads + 1))
            if ! text="$(_cg_issue_description "$id")"; then
                _bk_failed=1; _bk_unreadable="$_bk_unreadable $id"
                [ -n "$upd" ] && _bk_newcache="$_bk_newcache$id"$'\t'"$upd"$'\t'fail$'\n'
                return 0
            fi
            if printf '%s\n' "$text" | _cg_blocker_recorded; then verdict=wait; else verdict=work; fi
        fi
        [ -n "$upd" ] && _bk_newcache="$_bk_newcache$id"$'\t'"$upd"$'\t'"$verdict"$'\n'
        if [ "$verdict" = work ]; then _bk_work="$_bk_work $id"; return 0; fi
        # A recorded blocker: the bridge re-checks the reference (never cached; its own cap of the same size, so the
        # re-checks never starve the description reads, and the same time budget).
        if [ "$_bk_lifts" -lt "$_bk_max" ] && [ $((SECONDS - _bk_start)) -lt "$_bk_budget" ]; then
            _bk_lifts=$((_bk_lifts + 1))
            _cg_blocker_lifted "$id" && { _bk_lifted="$_bk_lifted $id"; _bk_work="$_bk_work $id"; }
        fi
        return 0
    }
    for _bk in $_CG_BLOCKED; do _bk_judge "$_bk" 1; done
    for _bk in $_bk_later; do _bk_judge "$_bk" 2; done
    # keep only the stories still Blocked (the cache never grows past the current Blocked set); best effort, and the
    # rename replaces whatever stood at the cache path (a link or a pipe is replaced, never followed).
    { printf '%s' "$_bk_newcache" > "$_bk_cache.$$" && mv -fT -- "$_bk_cache.$$" "$_bk_cache"; } 2>/dev/null \
        || rm -f -- "${_bk_cache:?}.$$" 2>/dev/null || true
    [ -n "$_bk_lifted" ] && log "the bridge lifted the block of:$_bk_lifted (what they waited on has closed or merged); they are open work again."
    _bk_norecord="$(for _bk in $_bk_work; do case " $_bk_lifted " in *" $_bk "*) : ;; *) printf ' %s' "$_bk" ;; esac; done)"
    [ -n "$_bk_norecord" ] && log "Blocked story(ies) with no recorded blocker count as open work:$_bk_norecord (block each with 'story block <id> --kind <issue|user|external> --on <target> --reason \"<why>\"', or work it)."
    [ -n "$_bk_unreadable" ] && log "WARNING: Blocked story(ies) NOT VERIFIED, their description could not be read (the bridge or GitLab did not answer); they stay excluded as Blocked, unchecked:$_bk_unreadable."
    [ -n "$_bk_unchecked" ] && log "WARNING: Blocked story(ies) NOT CHECKED this Stop, past the read cap of $_bk_max (CONTINUE_GUARD_BLOCKED_READ_MAX) or the time budget of ${_bk_budget}s (CONTINUE_GUARD_BLOCKED_TIME_BUDGET); they stay excluded as Blocked and are read on a later Stop:$_bk_unchecked."
    _open="$_open$_bk_work"
fi
# The parked STRICT mode (require a non-self label AUTHOR) still verifies via label events per issue;
# the default author-agnostic park is already honored by the classifier above at ZERO extra calls, so this
# per-issue event-fetch loop runs ONLY under the strict flag or when classification was off (label-scoped /
# default-mode / bare-token inputs). Fail-closed per-issue.
# The loop's SCOPE: everything under the strict flag; otherwise only the BARE (label-less) tokens — an enriched
# token was already classified from its labels at zero cost.
_cg_parked_scope=""
case "${CONTINUE_GUARD_PARKED_STRICT:-}" in on|1|true|yes|ON|TRUE|YES) _cg_parked_scope="$_open" ;; *) _cg_parked_scope="${_CG_BARE:-}" ;; esac
if [ -n "$_cg_parked_scope" ] && [ -n "$_open" ]; then
    _kept=""; _parked_out=""
    for _iss in $_open; do
        case " $_cg_parked_scope " in
            *" $_iss "*) if _cg_is_parked "$_iss"; then _parked_out="$_parked_out $_iss"; else _kept="$_kept $_iss"; fi ;;
            *) _kept="$_kept $_iss" ;;
        esac
    done
    if [ -n "$_parked_out" ]; then
        log "excluded parked story(ies) from the keep-rolling set:$_parked_out (label '$_cg_parked_label') — remove the label to put any back in scope."
    fi
    _open="$_kept"
fi
_open="$(printf '%s' "$_open" | tr -s ' ' | sed 's/^ *//; s/ *$//')"
[ -z "$_open" ] && allow "no open in-scope work  -  work-complete, allowing stop."

_count="$(printf '%s\n' $_open | grep -c .)"
_sig="$(printf '%s\n' $_open | sort | tr '\n' ' ' | sed 's/ *$//')"

# LIVE-WORKER HOLD (default-on; CONTINUE_GUARD_WATCH_HOLD=off to disable). When the transcript shows LIVE background
# workers (a background command or a background agent, see _cg_live_watch), the harness RE-INVOKES this agent the
# moment any of them finishes, so forcing extra turns only burns tokens. Two evidence-gated relaxations:
#   (a) a status::doing story is owned by a live worker, so it is subtracted from the ACTIONABLE set; when nothing
#       actionable remains (everything open is owned, parked or blocked) the stop is allowed;
#   (b) otherwise the agent is told about the actionable set ONCE (a full block), and later stops are allowed while
#       no NEW actionable item appears (the set is a subset of the one it was last told about). Any new item blocks
#       again. Without live workers nothing changes: every open item forces work, as before.
# There is no agent-touchable hold marker: the evidence is the harness-written transcript + the GitLab labels, and a
# label-less token is never known-active (fail-strict).
LAST_TOLD_FILE="$STATE_DIR/continue-guard.told"   # the actionable set the agent was last blocked with (live-worker mode)
case "$(kyklos_control_off "${CONTINUE_GUARD_WATCH_HOLD:-}" && echo off)" in
  off) : ;;
  *)
    _live="$(_cg_live_watch "$_trans")"
    if [ -n "$_live" ] && [ -n "$_open" ]; then
        _actionable=""; _owned=""
        for _iss in $_open; do
            case " ${_CG_ACTIVE:-} " in *" $_iss "*) _owned="$_owned $_iss" ;; *) _actionable="$_actionable $_iss" ;; esac
        done
        _actionable="$(printf '%s' "$_actionable" | sed 's/^ *//')"
        [ -n "$_owned" ] && log "live worker(s) [$_live] own the status::doing item(s):$_owned - not counted as actionable."
        if [ -z "$_actionable" ]; then
            rm -f "$LAST_TOLD_FILE" 2>/dev/null || true
            allow "WATCH-ARMED HOLD: all open work [$_sig] is owned by live workers ($_live), parked or blocked - a finishing worker re-invokes the agent; allowing this stop."
        fi
        _told="$(cat "$LAST_TOLD_FILE" 2>/dev/null || true)"
        _new=""
        for _iss in $_actionable; do
            case " $_told " in *" $_iss "*) : ;; *) _new="$_new $_iss" ;; esac
        done
        if [ -n "$_told" ] && [ -z "$_new" ]; then
            log "LIVE-WORKER HOLD: no new actionable work since the last block (actionable [$_actionable]); live workers ($_live) re-invoke the agent - allowing this stop."
            exit 0
        fi
        printf '%s' "$_actionable" > "$LAST_TOLD_FILE" 2>/dev/null || true
        _open="$_actionable"
        _count="$(printf '%s\n' $_open | grep -c .)"
        _sig="$(printf '%s\n' $_open | sort | tr '\n' ' ' | sed 's/ *$//')"
    else
        rm -f "$LAST_TOLD_FILE" 2>/dev/null || true
    fi
    ;;
esac

# (5) stuck-breaker: unchanged open set across K blocked stops -> release + surface.
K="${CONTINUE_GUARD_STUCK_TURNS:-3}"; case "$K" in ''|*[!0-9]*) K=3 ;; esac; [ "$K" -lt 1 ] && K=1
_prev="$(cat "$SIG_FILE" 2>/dev/null || echo)"
_cnt="$(cat "$CNT_FILE" 2>/dev/null || echo 0)"; case "$_cnt" in ''|*[!0-9]*) _cnt=0 ;; esac
# Progress-aware: the breaker must NOT release while the agent is doing real WORK on an open story (commits
# pile up but nothing has CLOSED, so the set-signature is unchanged — the mis-fire that let a busy agent stop).
# Fingerprint = cumulative tool_use count in the transcript; if it grew since the last stop, work happened this
# turn -> reset the streak. Only a TRUE spin (set unchanged AND no new tool calls between stops) counts toward K.
_work=0; [ -n "$_trans" ] && [ -f "$_trans" ] && _work="$(grep -c '"type":"tool_use"' "$_trans" 2>/dev/null || echo 0)"
case "$_work" in ''|*[!0-9]*) _work=0 ;; esac
_prevwork="$(cat "$WORK_FILE" 2>/dev/null || echo 0)"; case "$_prevwork" in ''|*[!0-9]*) _prevwork=0 ;; esac
printf '%s' "$_work" > "$WORK_FILE" 2>/dev/null || true
if [ "$_sig" = "$_prev" ] && [ "$_work" -le "$_prevwork" ]; then _cnt=$((_cnt+1)); else _cnt=1; fi
printf '%s' "$_sig" > "$SIG_FILE" 2>/dev/null || true
printf '%s' "$_cnt" > "$CNT_FILE" 2>/dev/null || true
if [ "$_cnt" -ge "$K" ]; then
    rm -f "$CNT_FILE" "$SIG_FILE" "$WORK_FILE" 2>/dev/null || true
    log "STUCK-BREAKER  -  the open scope story set [$_sig] is unchanged AND no new tool calls happened across $K stops (a genuine spin, not active work). Allowing this stop and surfacing it. If mid-implementation, keep going next turn; if truly stuck, ASK the user."
    exit 0
fi

# Bridge-health override (before forcing "keep rolling"): we only reach here with open work + no motivation, i.e.
# about to force continuation. If the bridge is DOWN, that takes precedence over the backlog - the agent must fix
# it or stop, never grind through unverifiable work.
if _cg_bridge_down; then
    emit_block "BLOCKED (continue-guard): the KyklosBridge MCP is NOT RESPONDING - the host-side bridge is DOWN (${_CG_BRIDGE_DETAIL}), so you CANNOT reliably build or run tests through it. Do NOT 'keep rolling' through bridge-dependent work and do NOT silently work around it. EITHER (a) get the bridge restarted on the host and verify it answers /api/status, OR (b) STOP and surface the down bridge to the user (a real question about the outage is a valid awaiting-user stop). There are ${_count} open item(s) [${_sig}], but a broken CORE TOOL takes precedence over the backlog. (opt out: KYKLOS_BRIDGE_HEALTH_CHECK=off)"
fi
# A slow bridge is reported apart from a down one: the work goes on, and the note names the times measured.
_cg_slow_note=""
if [ "$_CG_BRIDGE_STATE" = slow ]; then
    _cg_slow_note=" Note: the KyklosBridge is SLOW, not down: it ${_CG_BRIDGE_DETAIL} (a loaded machine delays the connection; the bridge itself answers quickly once connected)."
    log "the KyklosBridge is slow, not down: it ${_CG_BRIDGE_DETAIL}"
fi

# (6) BLOCK the unmotivated stop.
# MESSAGE DIET: the full ~1.4k-char doctrine is emitted ONCE per work-set; while the set signature
# is UNCHANGED since the previous blocked stop (the agent already read the doctrine for exactly this set), the block
# repeats as a ONE-LINE reminder. The DECISION is identical (still a block) — only the verbosity shrinks. An allow
# or a stuck-breaker release deletes the signature file, so the next block after any reset is full again; an
# unreadable state file reads as a changed set (fail-verbose).
if [ -n "$_prev" ] && [ "$_sig" = "$_prev" ]; then
    _plural="s"; [ "$_count" = 1 ] && _plural=""
    _ns_short=""; [ -n "${_CG_NONSTORY:-}" ] && _ns_short=" (non-story to triage: ${_CG_NONSTORY})"
    emit_block "BLOCKED (continue-guard): still ${_count} open in-scope work item${_plural} [${_sig}]${_ns_short} — the set is unchanged; keep working it (full doctrine in this set's first block; stuck-breaker ${_cnt}/${K}).${_cg_slow_note}"
fi
if [ "$_mode" = directive ]; then _why="a standing continue-directive (any open scope item is fair game  -  keep rolling)"; else _why="an in-progress story you started (story + status::doing) still open"; fi
_plural="s"; [ "$_count" = 1 ] && _plural=""
# a NON-STORY open issue is WORK TO TRIAGE, not to ignore — teach the four sanctioned paths.
_ns_hint=""
if [ -n "${_CG_NONSTORY:-}" ]; then
    _ns_hint=" NON-STORY issue(s) among them [${_CG_NONSTORY}]: an open issue with no story label is STILL work — TRIAGE each: adopt it into the lifecycle ('story adopt <iid> --type <t> --epic <E0N>', with '--kind analysis|documentation' for a lightweight research/docs item), ROUTE it to its owner ('agent-msg route <iid> --to <agent>'), PARK it (the parked label), or CLOSE it with a disposition label (wontfix/duplicate/invalid). Silence is not an option: an unlabeled issue never goes invisible again."
fi
emit_block "BLOCKED (continue-guard): you are trying to STOP with ${_count} open in-scope work item${_plural} [${_sig}] and ${_why}  -  nothing is awaited from the user.${_ns_hint} Do NOT pause: pick up the next scope item and keep working (choose it with the bridge's next_work tool: it orders the open work and names the next item). If you are waiting on CI, that is NOT a stop  -  work another open item. If NOTHING else is open and you truly must wait for that pipeline, ARM A WATCH that will notify you the moment it lands (the Monitor tool, or a backgrounded 'bash' until-loop that exits on the terminal status) and keep the turn alive  -  there is NO external poller that re-invokes you on its own; nothing wakes you unless YOU arm it. The ONLY ways to stop are the two you cannot self-author: finish ALL scope work, or ASK the user a real question (awaiting-user). There is no agent-touchable stop marker  -  no 'stop-ok', no 'continue-blocked'. (stuck-breaker ${_cnt}/${K}: it auto-releases only if the open set is unchanged AND you make NO tool calls for ${K} stops — doing real work resets it, so this is not an escape.)${_cg_slow_note}"
