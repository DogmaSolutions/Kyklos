#!/usr/bin/env bash
# kyklos-agent-msg-guard.sh — PreToolUse(Bash). HARD-BLOCK a raw HTTP call that CREATES / REPLIES-TO / REOPENS /
# CLOSES a cross-agent COORDINATION issue outside the `agent-msg` tool, so every coordination issue is correctly
# labelled (kind::communication,agent-comms), assigned to its recipient, and its ball-in-court state stays consistent
# with the inbound gate.
#
# The client/target/verb detection is the SHARED lib/issue-api-detect.sh (one detector; each guard that sources it
# applies its own policy — this guard = coordination issues). This guard adds POLICY only.
# Coverage spans the realistic raw clients (see issue-api-detect.sh) across the full write surface: create /
# reply-note / reopen / close / DELETE. Out-of-band issues are listed on demand by 'agent-msg reconcile'
# (report-only; not scheduled).
#
# SCOPE / HONESTY: pure string inspection — a strong DETERRENT for the realistic clients, NOT an airtight sandbox
# (a bespoke/compiled client or a URL hidden in a shell variable can still slip). Two things make that acceptable:
# (1) `agent-msg` is the path of least resistance (this guard makes the raw path HARDER than the tool), and
# (2) every coordination issue the tool creates carries `agent-comms`, so an issue that reaches an inbox WITHOUT it
# is detectably out-of-band ('agent-msg reconcile').
#
# FRONT GATE (no escape): a raw write that CREATES an issue - any issue, whatever its labels - is refused before any
# escape is consulted. Issues are created only through `story new` (work) or `agent-msg new` (a message to another
# agent); those tools make their API calls inside their own process, so this hook never sees them.
# FAIL-OPEN: not a supported client, not the /issues API, a bare READ, or an escape present => exit 0 (allow).
# FAIL-HARD: the detector library missing, failing to load or lacking a function => every command refused, named.
# Escape, for a deliberate operation on an EXISTING issue only (a note, an admin edit, close, reopen or delete):
# AGENT_MSG_RAW_OK=1 (in the environment or set inline in the command), always audited. It never admits creating an
# issue. A raw NOTE is told apart by the issue it targets: a story gets the story tool's verbs, a coordination issue
# `agent-msg reply`; the lookup only shapes the message, never the decision.
# Wired: PreToolUse, matcher Bash.
set +e -uo pipefail

INPUT="$(cat || true)"
command -v jq >/dev/null 2>&1 || { echo "[kyklos] WARNING: agent-msg guard INERT — jq is missing; the raw-issue-write deterrent is OFF. Install jq." >&2; exit 0; }
cmd="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
[ -n "$cmd" ] || exit 0

_AMG_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The shared detector decides. A guard that cannot load it completely (missing, a syntax error, a function gone), or
# that a library ends while loading, cannot tell a raw write from any other command, so it refuses every command,
# naming the library: lib/guard-prologue.sh arms an EXIT trap that blocks unless the guard reached a decision
# (guard_done). The inline trap below covers the prologue itself being missing or ending the shell.
trap 'printf %s "{\"decision\":\"block\",\"reason\":\"BLOCKED (broken kyklos install): the agent-msg guard cannot load lib/guard-prologue.sh, so it refuses every command. Edit and Write still work, so it can be repaired in place. Repair: relaunch the container so the kyklos plugin is installed again.\"}"; exit 0' EXIT
# shellcheck source=lib/guard-prologue.sh
. "$_AMG_HERE/lib/guard-prologue.sh" 2>/dev/null && declare -F guard_arm guard_load guard_load_optional guard_done guard_refuse >/dev/null \
  && guard_arm "the agent-msg guard" || exit 0
guard_load "$_AMG_HERE/lib/issue-api-detect.sh" var:IAD_CLIENT_RE var:IAD_NORMALISER_BROKEN iad_normalize_cmd iad_refuse_broken_normaliser iad_cmd_is_issue_create iad_split_segments iad_seg_is_raw_issue_write iad_seg_hits_issue_item iad_seg_hits_notes || guard_refuse
guard_load_optional "$_AMG_HERE/lib/escape-audit.sh" || true   # escape_audit: durable trail for a consumed raw-issue escape
guard_load_optional "$_AMG_HERE/lib/gitlab-api-base.sh" || true   # gitlab_api_base: the configured GitLab API URL
guard_load_optional "$_AMG_HERE/lib/gitlab-curl.sh" || true       # gitlab_curl: the one authenticated request path
# Program names and glab flags are read the way the shell and glab read them (c""url, glab -R a/b issue ...).
cmd="$(iad_normalize_cmd "$cmd")"
[[ $cmd == "$IAD_NORMALISER_BROKEN" ]] && { iad_refuse_broken_normaliser "agent-msg"; exit 0; }

# In scope only if a supported raw client (curl/wget/glab/python) appears at all — otherwise the mechanized tools
# (`agent-msg`, `story`) and every unrelated command pass untouched (they invoke curl INSIDE a subprocess, so the
# top-level command the hook sees carries no client keyword).
printf '%s' "$cmd" | grep -Ec "$IAD_CLIENT_RE" >/dev/null || guard_done

block(){ local r="$1"; r="${r//\\/\\\\}"; r="${r//\"/\\\"}"; r="$(printf '%s' "$r" | tr '\n' ' ')"; printf '{"decision":"block","reason":"%s"}' "$r"; guard_done; }

# FRONT GATE: creating an issue is refused BEFORE any escape is read, so no marker or variable can admit it. Per shell
# statement (the client, the issues collection and the write co-occur), plus a python/node program split at its own `;`. [CySec] Enforces the
# sanctioned creation path (CWE-284): every issue an agent creates enters through a tool that applies its lifecycle
# labels, structure and assignee; an issue made by hand escapes every story and coordination gate.
if iad_cmd_is_issue_create "$cmd"; then
    block "BLOCKED (Front Gate): creating a GitLab issue through a raw API call (curl/wget/glab/python/node). Issues are created ONLY with the sanctioned tools: 'story new <slug> --type <t> --kind <development|analysis|documentation|ops> --severity <critical|high|medium|low> --epic <E0N> --title \"...\"' for work (it applies the story labels, epic, status, phase and the required sections), or 'agent-msg new --to <agent> --title \"...\" --body \"...\"' for a message to another agent. No marker or variable admits a raw creation."
fi

# The escape (a deliberate operation on an EXISTING issue; never a creation, handled above). Honor BOTH the guard's own
# env AND an INLINE assignment in the command string: the guard inspects the command BEFORE it runs, so an
# `export AGENT_MSG_RAW_OK=1` (or a `AGENT_MSG_RAW_OK=1 curl ...` prefix) in the SAME command hasn't taken effect in
# the guard's env yet — accept it from the string so the documented escape works when set inline. There is ONE
# escape; no comment in the command is honoured as one.
# A raw-issue escape is self-grantable in one silent call; record EVERY use in a durable, greppable
# trail (escape_audit) — but ONLY when this segment is actually a raw issue WRITE (so a benign command that merely
# carries the marker isn't audited as an escape). The audit fires just before the allow-exit.
_amg_escape_audit() { command -v escape_audit >/dev/null 2>&1 && printf '%s' "$cmd" | grep -Ec '/issues|glab[[:space:]]+issue' >/dev/null && escape_audit "$1" "raw-issue-write allowed by escape"; }
[ "${AGENT_MSG_RAW_OK:-}" = "1" ] && { _amg_escape_audit "AGENT_MSG_RAW_OK(env)"; guard_done; }
printf '%s' "$cmd" | grep -cE '(^|[[:space:];&|(])AGENT_MSG_RAW_OK=1([[:space:]]|;|&|\||$)' >/dev/null && { _amg_escape_audit "AGENT_MSG_RAW_OK(inline)"; guard_done; }

# _amg_note_target_kind <segment> -> story | coordination | other | unknown: what the issue a raw note targets is.
# Only a literal URL on the CONFIGURED GitLab API is looked up, so the token is never sent to a host named by the
# command; anything else (a variable URL, no token, a failed read) is "unknown". The answer only picks the message.
_amg_note_target_kind() {
    local seg="$1" api url proj iid tokname resp
    api="$(gitlab_api_base STORY_GITLAB_API 2>/dev/null)" || { echo unknown; return 0; }
    url="$(printf '%s' "$seg" | grep -oE 'https?://[^[:space:]"'"'"']+/issues/[0-9]+/notes' | head -1)"
    case "$url" in "$api"/projects/*) : ;; *) echo unknown; return 0 ;; esac
    proj="${url#"$api"/projects/}"; proj="${proj%%/issues/*}"
    iid="${url%/notes}"; iid="${iid##*/issues/}"
    # [CySec] Prevents CWE-20 / CWE-918: only a plain project id or URL-encoded path, and a numeric issue number, are
    # placed into the lookup URL, so the command cannot steer the authenticated request anywhere else.
    # [RiskMitigation RA-02] The token goes only to the configured API, through gitlab_curl (header on stdin, never traced).
    [[ "$proj" =~ ^[A-Za-z0-9%._-]+$ ]] && [[ "$iid" =~ ^[0-9]+$ ]] || { echo unknown; return 0; }
    tokname="${KYKLOS_ISSUES_TOKEN_ENV:-${STORY_GITLAB_TOKEN_ENV:-}}"
    command -v gitlab_curl >/dev/null 2>&1 && gitlab_token_present "$tokname" || { echo unknown; return 0; }
    resp="$(gitlab_curl "$tokname" -s --max-time 5 "$api/projects/$proj/issues/$iid" 2>/dev/null)" || { echo unknown; return 0; }
    printf '%s' "$resp" | jq -r '
        if (.iid // null) == null then "unknown"
        elif ((.labels // []) | index("kind::communication") or index("agent-comms")) then "coordination"
        elif ((.labels // []) | index("story")) then "story"
        else "other" end' 2>/dev/null || echo unknown
}


# Evaluate the detections PER SHELL SEGMENT, not globally (iad_split_segments): the client, the /issues target, and
# the write verb must co-occur in ONE statement. A GLOBAL check false-positives on a compound READ whose separate,
# unrelated write supplies one condition (e.g. an OpenBao-login `... -d '{...}'` beside a later `/issues?...` GET).
# Over-splitting only ever makes the guard MORE permissive (fail-open), never wrongly blocks.
while IFS= read -r seg || [ -n "$seg" ]; do
    [ -n "$seg" ] || continue
    # Transport gate: is this segment a raw WRITE to the issues API by any supported client? (shared detector)
    iad_seg_is_raw_issue_write "$seg" || continue

    # --- POLICY: map the write to the coordination operation + name the sanctioned agent-msg subcommand. --------

    # DELETE: an outright deletion — `-X/--request/--method DELETE` on a specific issue, or `glab issue delete`. The
    # MOST destructive op (it drops another agent's inbox item + its audit trail) and never a normal coordination
    # operation; the agent-msg tool has NO delete on purpose. Was the one write the guard silently permitted.
    if { printf '%s' "$seg" | grep -ciE '(-X[[:space:]=]*DELETE|--request[[:space:]=]*DELETE|--method[[:space:]=]*DELETE)' >/dev/null && iad_seg_hits_issue_item "$seg"; } \
       || printf '%s' "$seg" | grep -cE 'glab[[:space:]]+issue[[:space:]]+delete' >/dev/null; then
        block "BLOCKED: DELETING a GitLab issue via raw curl/wget/glab/python. Deleting a coordination issue destroys another agent's inbox item + its audit trail and is never a normal op — the agent-msg tool has no delete by design. Close it instead: 'agent-msg close <iid> [--comment \"why\"]'. (A deliberate admin deletion: set AGENT_MSG_RAW_OK=1.)"
    fi

    # CLOSE: `state_event=close` on a specific issue, or `glab issue close`. (Ball-in-court + labels must stay
    # consistent; a story is closed by its own tool — name both, we cannot tell them apart from a bare close URL.)
    if { printf '%s' "$seg" | grep -ciE 'state_event[[:space:]=]*close' >/dev/null && iad_seg_hits_issue_item "$seg"; } \
       || printf '%s' "$seg" | grep -cE 'glab[[:space:]]+issue[[:space:]]+close' >/dev/null; then
        block "BLOCKED: closing a GitLab issue via raw curl/wget/glab/python. Use the mechanized tool so labels + ball-in-court stay consistent: 'agent-msg close <iid> [--comment \"why\"]' for a cross-agent coordination issue, or 'story close <id>' for a story. (Deliberate bulk/admin: set AGENT_MSG_RAW_OK=1.)"
    fi

    # REOPEN: `state_event=reopen` on a specific issue, or `glab issue reopen`.
    if { printf '%s' "$seg" | grep -ciE 'state_event[[:space:]=]*reopen' >/dev/null && iad_seg_hits_issue_item "$seg"; } \
       || printf '%s' "$seg" | grep -cE 'glab[[:space:]]+issue[[:space:]]+reopen' >/dev/null; then
        block "BLOCKED: reopening a GitLab issue via raw curl/wget/glab/python. Use the mechanized tool so labels + ball-in-court stay consistent: 'agent-msg reopen <iid>' for a cross-agent coordination issue, or 'story set <id> status=<status> --reopen --reason \"<why>\"' for a story (it records the reason as the root cause). (Deliberate bulk/admin: set AGENT_MSG_RAW_OK=1.)"
    fi

    # REPLY / NOTE: a write to `/issues/<n>/notes`, or `glab issue note|comment`.
    if iad_seg_hits_notes "$seg" \
       || printf '%s' "$seg" | grep -cE 'glab[[:space:]]+issue[[:space:]]+(note|comment)' >/dev/null; then
        _story_verbs="'story reopen-root-cause <id> --reason \"<why>\"' for the reason a closed story was reopened, 'story proof <id> --set ...' for the proof, 'story ra <id> ...' for the risk register, 'story block <id> --on <reference> --reason \"...\"' for a block and its reason"
        case "$(_amg_note_target_kind "$seg")" in
            story)
                block "BLOCKED: a raw note on a STORY issue via curl/wget/glab/python. The story tool posts the notes a story needs: $_story_verbs. (Another deliberate note: set AGENT_MSG_RAW_OK=1; every use is audited.)" ;;
            coordination)
                block "BLOCKED: replying to a cross-agent coordination issue via raw curl/wget/glab/python. Use: agent-msg reply <iid> \"<body>\" — it keeps the ball-in-court state the inbound gate relies on. (Another deliberate note: set AGENT_MSG_RAW_OK=1; every use is audited.)" ;;
            *)
                block "BLOCKED: a raw note on a GitLab issue via curl/wget/glab/python. On a cross-agent coordination issue use 'agent-msg reply <iid> \"<body>\"' (it keeps the ball-in-court state); on a story use the story tool: $_story_verbs. (Another deliberate note: set AGENT_MSG_RAW_OK=1; every use is audited.)" ;;
        esac
    fi

    # CREATE a coordination issue: a WRITE carrying a kind::communication/agent-comms (or a retired for:<agent>) label
    # that is NOT an item op
    # (no /issues/<n> — so it targets the collection), or a `glab issue create` carrying one. `! item` excludes
    # close/reopen/note (all item ops), leaving only a collection create. Robust to the exact URL punctuation.
    if printf '%s' "$seg" | grep -cE '(kind::communication|for::?[a-zA-Z]|agent-comms)' \
 >/dev/null       && ! iad_seg_hits_issue_item "$seg" \
       && { printf '%s' "$seg" | grep -cE '/issues' \
 >/dev/null            || printf '%s' "$seg" | grep -cE 'glab[[:space:]]+issue[[:space:]]+(create|new)' >/dev/null; }; then
        block "BLOCKED: creating a cross-agent coordination issue via raw curl/wget/glab/python. Use: agent-msg new --to <agent> --title \"...\" [--body \"...\"] — it applies the kind::communication,agent-comms labels and the recipient assignee the inbound gate + backlog rely on (raw HTTP silently mislabels it and breaks the ball-in-court tracking)."
    fi
done < <(iad_split_segments "$cmd")

guard_done
