#!/usr/bin/env bash
# kyklos-ask-first-guard.sh (Kyklos) - ASK FIRST: loosening a workflow control needs the user's confirmation.
#
# Almost every gate of this plugin has an off-switch the agent can reach: a line in .claude/standards.env, or the same
# switch given inline to a command (`NAME=0 story close`). The switches stay, because they are the escape hatch for a
# degraded situation or a bug in the enforcement, but the agent never uses them on its own: this hook answers Claude
# Code with the permission decision "ask", so Claude Code shows its own dialog and the USER decides. No marker, file or
# variable the agent can set replaces that dialog.
#
#   pre   (PreToolUse, Bash | Edit | Write | MultiEdit | NotebookEdit): first the BACKSTOP (lib/ask-first-snapshot.sh):
#         the settings file is compared with its workspace baseline; then find the changes (lib/ask-first.sh) that
#         switch a control off, weaken it or switch a grant on. None: silent. Any: answer "ask", naming each switch with
#         its old and new value, and keep a pending record of the change for the audit.
#   post  (PostToolUse and PostToolUseFailure, same tools): BACKSTOP first. The settings file is compared with the ONE
#         baseline the workspace has, read by the hooks' own parser on the lines that name a switch. A harmless change
#         becomes the baseline; a loosening becomes it only in the post step of a call the pre step asked about (the
#         user confirmed it), and only for the switches and values that question named (an unreadable change the user
#         confirmed is kept whole). Any other loosening, seen at a pre or a post step, is put back from the baseline at
#         once and the call is refused or the turn blocked with a message naming the switch, its old and new value and
#         the command; a file that cannot be put back blocks too, saying so. A loosening that a call asked about in the
#         last ten minutes names exactly is left to that call's own post step (it may still be running). Known limits,
#         to be closed by a baseline held by the host bridge: a command that deliberately rewrites this hook's state
#         folder, and a background writer that changes the file after the post step (caught at the next step); and the
#         ten minutes during which a question the user declined still names its change. Then, for a call the pre step
#         asked about: the tool ran, so the user approved. Post ONE audit note on the story being worked (the story of
#         the branch checked out where the change was made), with the switch, old and new value and the reason the agent
#         gave (the Bash description, or the comment on the changed settings line), through the bridge's
#         coordination_reply verb. A note that cannot be posted is reported to the agent and the user; the confirmation
#         already happened, so a failed audit never skips it. Every approved change is also recorded by escape_audit
#         (transcript and state log).
#
# The controls are DERIVED from the code (lib/control-inventory.sh): every switch the shared reader judges, and the
# grants named in lib/control-switch.sh. Turning a control back on, or changing a key that is no control, is silent.
#
# Two layers: the static reading asks the user BEFORE a change (the user chooses); the backstop catches what the reading
# missed AFTER it, whatever the spelling, and undoes it.
# FAIL-HARD: a change this hook cannot read for certain (an unknown program writing a settings file, an expansion, a
# value it cannot parse), or this hook failing part-way while a command or edit names a switch or a settings file,
# answers "ask" - never a silent allow. FAIL-OPEN: none (without jq, any input naming a settings file or holding an
# upper-case assignment is asked about). A baseline that cannot be written refuses the call; a file that cannot be put
# back blocks the turn.
# DEFAULT-ON. The only off-switch is KYKLOS_ASK_FIRST=off in the environment Claude Code starts the hooks with (set by
# the launcher, outside the agent's reach). It is never read from .claude/standards.env, which the agent can edit, and
# an inline `KYKLOS_ASK_FIRST=off` in a command reaches only that command, never this hook.
# Wired: PreToolUse, PostToolUse and PostToolUseFailure, matcher Bash|Edit|Write|MultiEdit|NotebookEdit.
set +e -uo pipefail

MODE="${1:-pre}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD="$(cat 2>/dev/null)" || PAYLOAD=""

# The cheap screen: only an input that names a settings file, the .claude folder or a name starting like the settings
# file, holds an upper-case NAME= or names an upper-case word with an underscore (every switch is one; `printf -v NAME`,
# `read NAME` and interpreter code name it without =) is read further.
_AF_SCREEN='standards|\.claude([^A-Za-z0-9_-]|$)|settings[A-Za-z0-9_.-]*\.json|bashrc|bash_profile|\.profile|zshrc|zshenv|envrc|/etc/environment|[A-Z][A-Z0-9_]*=|[A-Z][A-Z0-9]*_[A-Z0-9_]'

# ask_answer <reason> -> print the "ask" decision and end.
_AF_DECIDED=0
ask_answer() {
    local r="$1"
    _AF_DECIDED=1
    if command -v jq >/dev/null 2>&1; then
        jq -cn --arg r "$r" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
    else
        r="${r//\\/\\\\}"; r="${r//\"/\\\"}"; r="$(printf '%s' "$r" | tr '\n\t' '  ')"
        printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}\n' "$r"
    fi
    exit 0
}
allow_silently() { _AF_DECIDED=1; exit 0; }

# [CySec] CWE-636 (Not Failing Securely): a pre check that ends before it decides, on an input that names a switch or a
# settings file, refuses the call instead of letting the change through (and never leaves an unattended agent waiting
# on a dialog).
_af_on_exit() {
    [ "$_AF_DECIDED" = 1 ] && return 0
    [ "$MODE" = pre ] || return 0
    printf '%s' "$PAYLOAD" | grep -cE "$_AF_SCREEN" >/dev/null || return 0
    _AF_DECIDED=1
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Ask First (kyklos): REFUSED, nothing ran: this check could not finish, and the call names a workflow switch or a settings file. Rewrite the call without naming one (search with grep or jq, read with the Read tool), or write the intended change in a readable form."}}\n'
    exit 0
}
trap _af_on_exit EXIT

# [json-answer-required] The audit step reads the bridge's answer through the one JSON reader (lib/bridge-mcp.sh); without
# it a check would exit 127 and fall into a fail-open path, so a broken install is refused by name: a Bash command is
# blocked, and an Edit or Write is asked about (so the user can still let the agent repair the library in place).
# [CySec] CWE-636 (Not Failing Securely)
# shellcheck source=lib/json-answer.sh
. "$HERE/lib/json-answer.sh" 2>/dev/null
if ! declare -F json_test >/dev/null 2>&1; then
    _AF_DECIDED=1
    _af_broken="the JSON reader hooks/lib/json-answer.sh did not load (broken install), so Ask First cannot run its check. Reinstall or repin the kyklos plugin."
    if [ "$MODE" = pre ] && printf '%s' "$PAYLOAD" | grep -cE '"tool_name"[[:space:]]*:[[:space:]]*"(Edit|Write|MultiEdit)"' >/dev/null; then
        printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Ask First (kyklos): %s REFUSED without asking the user, nothing ran: rewrite the call so it does not name a workflow switch or a settings file (search with grep or jq, read with the Read tool), or reinstall the plugin if it is broken."}}\n' "$_af_broken"
    else
        printf '{"decision":"block","reason":"BLOCKED (%s): %s"}\n' "$(basename "$0")" "$_af_broken"
    fi
    exit 0
fi

# shellcheck source=lib/control-switch.sh
. "$HERE/lib/control-switch.sh" 2>/dev/null || true
# The off-switch is read from this hook's own environment only. If the reader did not load, the call fails and the
# check stays on.
# [CySec] CWE-15 (External Control of System or Configuration Setting): the switch that turns this check off is never
# read from a file or a command the agent controls.
kyklos_control_off "${KYKLOS_ASK_FIRST:-}" && allow_silently

[ -n "$PAYLOAD" ] || allow_silently
STATE_DIR="${KYKLOS_STATE_DIR:-/tmp/kyklos-state}/ask-first"

# block_answer <reason> -> refuse: in the pre step the call does not run (permission "deny"); in the post step the turn
# is blocked with the reason, which the user sees too.
block_answer() {
    local r="$1"
    _AF_DECIDED=1
    printf '[kyklos] %s\n' "$r" >&2
    if [ "$MODE" = pre ]; then
        jq -cn --arg r "$r" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' 2>/dev/null \
            || printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Ask First (kyklos): the check cannot run."}}\n'
    else
        jq -cn --arg r "$r" '{decision:"block",reason:$r,systemMessage:$r}' 2>/dev/null \
            || printf '{"decision":"block","reason":"Ask First (kyklos): the check cannot run."}\n'
    fi
    exit 0
}

if ! command -v jq >/dev/null 2>&1; then
    # Without jq neither the change nor the call id can be read, so the backstop cannot run either: every call asks.
    [ "$MODE" = pre ] && block_answer "Ask First (kyklos): jq is missing, so this check cannot read the change or keep the copy of the settings file it restores from. REFUSED without asking the user, nothing ran: rewrite the call so it does not name a workflow switch or a settings file (search with grep or jq, read with the Read tool), or reinstall the plugin if it is broken."
    allow_silently
fi

TOOL="$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // empty' 2>/dev/null)"
USE_ID="$(printf '%s' "$PAYLOAD" | jq -r '.tool_use_id // empty' 2>/dev/null | tr -cd 'A-Za-z0-9_-')"
CWD="$(printf '%s' "$PAYLOAD" | jq -r '.cwd // empty' 2>/dev/null)"
[ -n "$CWD" ] && [ -d "$CWD" ] || CWD="${CLAUDE_PROJECT_DIR:-$(pwd)}"
EVENT="$(printf '%s' "$PAYLOAD" | jq -r '.hook_event_name // empty' 2>/dev/null)"
[ "$MODE" = post ] && { [ -n "$EVENT" ] || EVENT=PostToolUse; }
_af_asked=0
[ -n "$USE_ID" ] && [ -f "$STATE_DIR/$USE_ID.json" ] && _af_asked=1

# ------------------------------------------------------------------------------------------------------ backstop
# The second layer (lib/ask-first-snapshot.sh): ONE baseline of the settings file per workspace, compared with the file
# at every pre and post step, whatever the call. Only a confirmed Ask First change (the post step of a call that was
# asked about) moves it past a loosening; a harmless change simply becomes the new baseline; any other loosening is
# put back and reported. It does not depend on the screen.
# [CySec] CWE-693 (Protection Mechanism Failure) / CWE-636 (Not Failing Securely): a baseline that cannot be written,
# or a file that cannot be put back, refuses the call or blocks the turn; it never passes silently.
# shellcheck source=lib/ask-first-snapshot.sh
. "$HERE/lib/ask-first-snapshot.sh" 2>/dev/null && declare -F af_baseline_ensure af_baseline_changed af_baseline_check af_baseline_accept af_baseline_restore >/dev/null \
    || { _af_broken="the backstop hooks/lib/ask-first-snapshot.sh did not load (a broken install), so a loosened workflow switch could not be put back. Reinstall or repin the kyklos plugin."
         # An edit is asked about rather than refused, so the user can still let the agent repair the library in place.
         case "$MODE:$TOOL" in pre:Edit|pre:Write|pre:MultiEdit) block_answer "Ask First (kyklos): $_af_broken REFUSED without asking the user, nothing ran: rewrite the call so it does not name a workflow switch or a settings file (search with grep or jq, read with the Read tool), or reinstall the plugin if it is broken." ;; esac
         block_answer "Ask First (kyklos): $_af_broken"; }
_af_why="$(af_baseline_ensure "$CWD")" \
    || block_answer "Ask First (kyklos): the baseline of the settings file that a loosened workflow switch is restored from cannot be written ($_af_why), so this call is refused. Free or fix the state folder ${KYKLOS_STATE_DIR:-/tmp/kyklos-state}."

# _af_deferred_names <findings> -> the switches whose loosening a call asked about in the last ten minutes names
# exactly (switch and new value): that call may still be running, and its own post step settles them. A call longer
# than a Bash call can run (ten minutes) is not waited for. _af_undeferred <findings> -> the other findings.
_af_pair_pending() {
    local name="$1" nv
    nv="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"
    [ -n "$(find "$STATE_DIR" -maxdepth 1 -name '*.json' -mmin -10 -print0 2>/dev/null \
        | xargs -0 -r jq -r --arg n "$name" --arg v "$nv" '.pairs[]? | select(.where != "inline" and .name == $n and ((.new | ascii_downcase | gsub(" "; "")) == $v)) | .name' 2>/dev/null | head -n1)" ]
}
_af_deferred_names() {
    local name nv
    while IFS=$'\t' read -r _ _ name _ nv; do
        [ -n "${name:-}" ] && _af_pair_pending "$name" "$nv" && printf '%s\n' "$name"
    done <<< "$1" | sort -u
}
_af_undeferred() {
    local line name nv
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        IFS=$'\t' read -r _ _ name _ nv <<< "$line"
        _af_pair_pending "$name" "$nv" || printf '%s\n' "$line"
    done <<< "$1"
}

if af_baseline_changed "$CWD"; then
    { . "$HERE/lib/ask-first.sh" 2>/dev/null && control_inventory_load; } \
        || { af_baseline_restore "$CWD" >/dev/null
             block_answer "Ask First (kyklos): the settings file differs from its baseline and the change detector or the control inventory did not load, so it was put back from the baseline. Reinstall or repin the kyklos plugin."; }
    if [ "$MODE" = post ] && [ "$_af_asked" = 1 ]; then
        # The user confirmed exactly the changes the question named (switch and new value), nothing else. A question
        # about a change it could not read (an "unreadable change" line) confirmed the whole result. Any other
        # loosening in the file is put back from the baseline, and the turn is blocked after the audit.
        _af_found="$(af_baseline_check "$CWD")"
        _af_rec="$(cat -- "$STATE_DIR/$USE_ID.json" 2>/dev/null)"
        if [ -z "$_af_found" ] || json_test '[.lines[]? | select(startswith("unreadable change"))] | length > 0' <<<"$_af_rec" 2>/dev/null; then
            af_baseline_accept "$CWD" >/dev/null
        else
            _af_extra="$(while IFS=$'\t' read -r _ fpath name _ nv; do
                [ -n "${name:-}" ] || continue
                v="$(printf '%s' "$nv" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"
                # Only a FILE change the question named authorises a line: same switch, same final value. A switch given
                # inline to one command (its environment) never authorises a change of the file.
                json_test 'any(.pairs[]?; .where != "inline" and .name == $n and ((.new | ascii_downcase | gsub(" "; "")) == $v))' --arg n "$name" --arg v "$v" <<<"$_af_rec" 2>/dev/null \
                    || printf '%s\t%s\t%s\n' "$fpath" "$name" "$nv"
            done <<< "$_af_found")"
            if [ -z "$_af_extra" ]; then
                af_baseline_accept "$CWD" >/dev/null
            else
                _af_names="$(printf '%s\n' "$_af_extra" | cut -f2 | sort -u | tr '\n' ' ')"
                if printf '%s\n' "$_af_extra" | cut -f2 | grep -cx '(the file itself)' >/dev/null; then
                    # A link or a folder in place of the file: the whole file goes back, the confirmed change with it.
                    _af_failed="$(af_baseline_restore "$CWD")"
                    _af_kept="the whole file was put back, the confirmed change with it, because a link or a folder was put in its place"
                else
                    # shellcheck disable=SC2086 # one word per switch to put back
                    _af_failed="$(af_baseline_accept_except "$CWD" $_af_names)"
                    _af_kept="only these switches were put back to their baseline values; the confirmed change stays"
                fi
                _af_partial="$(printf 'Ask First (kyklos): this call also loosened a workflow control the user was NOT asked about (or to another value than the question named): %s %s.%s' \
                    "$(printf '%s\n' "$_af_extra" | awk -F'\t' '{ printf "%s -> %s (%s); ", $2, $3, $1 }')" "$_af_kept" \
                    "$([ -n "$_af_failed" ] && printf ' It could NOT be put back: %s. Stop and tell the user.' "$(printf '%s' "$_af_failed" | cut -f2,3 | tr '\t\n' ' ;')")")"
                # shellcheck source=lib/escape-audit.sh
                . "$HERE/lib/escape-audit.sh" 2>/dev/null && escape_audit "ask-first-restored" "$(printf '%s' "$_af_extra" | tr '\t\n' ' ;')"
            fi
        fi
    else
        _af_found="$(af_baseline_check "$CWD")"
        if [ -z "$_af_found" ]; then
            af_baseline_accept "$CWD" >/dev/null       # a harmless change: another key, a tighter value
        elif [ -z "$(_af_undeferred "$_af_found")" ]; then
            :                                           # a confirmed call in flight names exactly this change
        else
            # Exactly the loosened switches are put back (a confirmed call still in flight keeps the ones it named); a
            # link or a folder in place of the file puts the whole file back.
            _af_found="$(_af_undeferred "$_af_found")"
            _af_names="$(printf '%s\n' "$_af_found" | cut -f3 | sort -u | tr '\n' ' ')"
            if printf '%s\n' "$_af_found" | cut -f3 | grep -cx '(the file itself)' >/dev/null; then
                _af_failed="$(af_baseline_restore "$CWD")"
            else
                # shellcheck disable=SC2086 # one word per switch to put back
                _af_failed="$(af_baseline_restore_names "$CWD" $_af_names)"
            fi
            _af_what="$(printf '%s\n' "$_af_found" | awk -F'\t' '$1 == "loosened" { printf "%s: %s -> %s (%s); ", $3, $4, $5, $2 }')"
            _af_cmd="$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // .tool_input.file_path // .tool_input.notebook_path // ""' 2>/dev/null | head -c 400)"
            _af_when="this ${TOOL:-tool} call"
            [ "$MODE" = pre ] && _af_when="a change made since the last checked call (a call whose post step did not run, a background writer, or a route outside the hooks)"
            # shellcheck source=lib/escape-audit.sh
            . "$HERE/lib/escape-audit.sh" 2>/dev/null && escape_audit "ask-first-restored" "${_af_what}call=${_af_cmd}"
            if [ -n "$_af_failed" ]; then
                block_answer "$(printf 'Ask First (kyklos): %s loosened a workflow control without the user'"'"'s confirmation, and the settings file could NOT be put back: %s. Changed: %s Command: %s. Stop and tell the user: the control stays loosened until the file is repaired by hand.' \
                    "$_af_when" "$(printf '%s' "$_af_failed" | cut -f2,3 | tr '\t\n' ' ;')" "$_af_what" "$_af_cmd")"
            fi
            _af_next="If the change is really needed, make it as a plain edit of .claude/standards.env so that Ask First asks the user."
            [ "$MODE" = pre ] && _af_next="This call was refused once so you see this; run it again. $_af_next"
            block_answer "$(printf 'Ask First (kyklos): %s loosened a workflow control without the user'"'"'s confirmation, so it was put back from its baseline (switch: baseline value -> the loosened value that was undone): %s Command: %s. %s' \
                "$_af_when" "$_af_what" "$_af_cmd" "$_af_next")"
        fi
    fi
fi

# ---------------------------------------------------------------------------------------------------------- post
if [ "$MODE" = post ]; then
    [ "$_af_asked" = 1 ] || allow_silently
    REC="$(cat -- "$STATE_DIR/$USE_ID.json" 2>/dev/null)"
    rm -f -- "$STATE_DIR/$USE_ID.json"
    # shellcheck source=lib/escape-audit.sh
    . "$HERE/lib/escape-audit.sh" 2>/dev/null || true
    # shellcheck source=lib/bridge-mcp.sh
    . "$HERE/lib/bridge-mcp.sh" 2>/dev/null || true
    # shellcheck source=lib/standards-env.sh
    . "$HERE/lib/standards-env.sh" 2>/dev/null || true
    lines="$(printf '%s' "$REC" | jq -r '.lines[]' 2>/dev/null)"
    reason="$(printf '%s' "$REC" | jq -r '.reason // ""' 2>/dev/null)"
    dir="$(printf '%s' "$REC" | jq -r '.dir // ""' 2>/dev/null)"
    command -v escape_audit >/dev/null 2>&1 && escape_audit "ask-first-approved" "$(printf '%s' "$lines" | tr '\n' ';') reason=${reason:-none}"
    problem=""
    branch="$(git -C "$dir" symbolic-ref --short -q HEAD 2>/dev/null)"
    story="$(printf '%s' "$branch" | sed -nE 's#^(feature|hotfix)/story-0*([0-9]+).*#\2#p')"
    top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || top="$dir"
    project=""
    command -v standards_env_value >/dev/null 2>&1 && project="$(standards_env_value "$top/.claude/standards.env" STORY_GITLAB_PROJECT)"
    [ -n "$project" ] || project="${STORY_GITLAB_PROJECT:-}"
    body="$(printf '**Ask First audit:** the user confirmed a change that loosens a workflow control (%s tool).\n\n%s\n\nReason given: %s' \
        "${TOOL:-?}" "$(printf '%s\n' "$lines" | sed 's/^/- /')" "${reason:-none given}")"
    if [ -z "$story" ]; then
        problem="the change was not made on a story branch (feature/story-<N>-... or hotfix/story-<N>-...), so there is no story to post the audit note on"
    elif [ -z "$project" ]; then
        problem="no story project is configured (STORY_GITLAB_PROJECT), so the audit note for story $story has nowhere to go"
    elif ! command -v bridge_mcp_call >/dev/null 2>&1; then
        problem="the bridge transport (lib/bridge-mcp.sh) did not load"
    else
        args="$(jq -cn --arg p "$project" --arg i "$story" --arg b "$body" '{project:$p,iid:$i,body:$b}')"
        resp="$(bridge_mcp_call coordination_reply "$args" 30)"; rc=$?
        if [ "$rc" -ne 0 ]; then
            problem="the bridge could not be reached (transport rc $rc)"
        elif bridge_mcp_is_error "$resp"; then
            problem="the bridge refused the note: $(bridge_mcp_text "$resp" | head -c 300)"
        fi
    fi
    _AF_DECIDED=1
    if [ -n "${_af_partial:-}" ]; then
        [ -n "$problem" ] && _af_partial="$_af_partial The audit note was NOT posted either: $problem."
        block_answer "$_af_partial"
    fi
    if [ -n "$problem" ]; then
        msg="Ask First: the audit note for the confirmed control change was NOT posted: $problem. The change itself ran after your confirmation. Record it by hand on the story: $(printf '%s' "$lines" | tr '\n' ';')"
        printf '[kyklos] %s\n' "$msg" >&2
        jq -cn --arg m "$msg" --arg e "$EVENT" '{systemMessage:$m,hookSpecificOutput:{hookEventName:$e,additionalContext:$m}}'
    else
        jq -cn --arg m "Ask First: the audit note for the confirmed control change was posted on story $story." --arg e "$EVENT" \
            '{hookSpecificOutput:{hookEventName:$e,additionalContext:$m}}'
    fi
    exit 0
fi

# ----------------------------------------------------------------------------------------------------------- pre
# The first layer reads only a screened input.
printf '%s' "$PAYLOAD" | grep -cE "$_AF_SCREEN" >/dev/null || allow_silently
# An input this check cannot read, which names a switch or a settings file (it passed the screen), asks: invalid JSON,
# or a tool this hook does not know how to read.
# [CySec] CWE-636 (Not Failing Securely)
json_test 'type == "object"' <<<"$PAYLOAD" 2>/dev/null \
    || block_answer "Ask First (kyklos): the hook input cannot be read as JSON, and it names a workflow switch or a settings file. REFUSED without asking the user, nothing ran: rewrite the call so it does not name a workflow switch or a settings file (search with grep or jq, read with the Read tool), or reinstall the plugin if it is broken."
case "$TOOL" in
    Bash|Edit|Write|MultiEdit) ;;
    *) block_answer "Ask First (kyklos): the input of the ${TOOL:-unnamed} tool names a workflow switch or a settings file, and this check cannot read that tool. REFUSED without asking the user, nothing ran: rewrite the call so it does not name a workflow switch or a settings file (search with grep or jq, read with the Read tool), or reinstall the plugin if it is broken." ;;
esac
# An edit of a file that is no settings file changes no switch: decided before any library loads.
case "$TOOL" in
    Edit|Write|MultiEdit)
        printf '%s' "$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.file_path // empty' 2>/dev/null)" | grep -cE "$_AF_SCREEN" >/dev/null || allow_silently ;;
esac
# shellcheck source=lib/ask-first.sh
. "$HERE/lib/ask-first.sh" 2>/dev/null && declare -F ask_first_bash_findings ask_first_edit_findings control_inventory_load >/dev/null \
    || block_answer "Ask First (kyklos): the change detector (hooks/lib/ask-first.sh) did not load (a broken install), and this input names a workflow switch or a settings file. REFUSED without asking the user, nothing ran: rewrite the call so it does not name a workflow switch or a settings file (search with grep or jq, read with the Read tool), or reinstall the plugin if it is broken."
control_inventory_load \
    || block_answer "Ask First (kyklos): the plugin's control inventory came back empty (a broken install), so this change cannot be judged. REFUSED without asking the user, nothing ran: rewrite the call so it does not name a workflow switch or a settings file (search with grep or jq, read with the Read tool), or reinstall the plugin if it is broken."

# _af_analyse <function> <args...> -> the function's findings. The analysis must end the way it was written to: it runs
# in a subshell that prints a closing line, with its error output kept. A crash anywhere in it (an unbound variable
# under set -u, a syntax error, a missing command, also inside a nested command substitution, whose failure the outer
# code would otherwise swallow) leaves a shell diagnostic or no closing line: the finding is then "unclear", and asks.
# [CySec] CWE-636 (Not Failing Securely) / CWE-755 (Improper Handling of Exceptional Conditions)
_af_analyse() {
    local out errf diag rc
    errf="$(mktemp 2>/dev/null)" || { printf 'unclear\tthe check\tno temporary file can be made, so the check cannot run\n'; return 0; }
    out="$( { "$@"; printf '__ASKFIRST_END__\n'; } 2>"$errf")"; rc=$?
    diag="$(grep -m1 -E ': line [0-9]+: |unbound variable|bad substitution|syntax error|command not found' "$errf" 2>/dev/null)"
    rm -f -- "$errf"
    if [ "$rc" -ne 0 ] || [ -n "$diag" ] || [ "${out##*__ASKFIRST_END__}" = "$out" ]; then
        printf 'unclear\tthe check\tit failed part-way (%s), so the change cannot be judged\n' "${diag:-exit $rc}"
        return 0
    fi
    printf '%s' "${out%__ASKFIRST_END__*}"
}

case "$TOOL" in
    Bash)
        CMD="$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // empty' 2>/dev/null)"
        [ -n "$CMD" ] || allow_silently
        FINDINGS="$(_af_analyse ask_first_bash_findings "$CMD" "$CWD")"
        REASON="$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.description // empty' 2>/dev/null)"
        DIR="$CWD" ;;
    Edit|Write|MultiEdit)
        FINDINGS="$(_af_analyse ask_first_edit_findings "$PAYLOAD")"
        FILE="$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
        DIR="$(dirname -- "$FILE")"; [ "$(basename -- "$DIR")" = .claude ] && DIR="$(dirname -- "$DIR")"
        [ -d "$DIR" ] || DIR="$CWD"
        REASON=""
        for n in $(printf '%s\n' "$FINDINGS" | awk -F'\t' '$1 == "change" { print $2 }'); do
            REASON="$(ask_first_edit_reason "$PAYLOAD" "$n")"; [ -n "$REASON" ] && break
        done ;;
esac
FINDINGS="$(printf '%s\n' "$FINDINGS" | grep -v '^$' | sort -u)"
[ -n "$FINDINGS" ] || allow_silently

# A call whose only findings are unreadable is refused at once, never put to the user: an agent working unattended
# waited hours on such a dialog for a command that only read a file, and the agent can always say what it means in a
# readable form. Nothing unreadable runs, so this keeps the check closed. Only a readable loosening (a switch, its old
# and its new value) is the user's decision and is asked about.
# [CySec] CWE-636 (Not Failing Securely): an unreadable change is refused, not allowed and not left waiting.
if ! printf '%s\n' "$FINDINGS" | awk -F'\t' '$1 == "change" { found = 1 } END { exit !found }'; then
    block_answer "$(printf 'Ask First (kyklos): REFUSED without asking the user, nothing ran. This %s call names a workflow switch or a settings file in a way this check cannot read:\n%s\nIf you did not mean to change a control, rewrite the call so it does not name one beside an interpreter, a shell or a runner (xargs, find, watch, ...): search with grep or jq, read the file with the Read tool. If you do mean to change one, write the change in a readable form (an Edit of the settings file, or NAME=value before the command), so the user is asked.' \
        "$TOOL" "$(printf '%s\n' "$FINDINGS" | awk -F'\t' '$1 == "unclear" { printf "unreadable change (%s): %s\n", $2, $3 }')")"
fi

LINES="$(printf '%s\n' "$FINDINGS" | awk -F'\t' '
    $1 == "change" && $5 == "inline" { printf "%s: %s -> %s (given inline to the command)\n", $2, $3, $4; next }
    $1 == "change"  { printf "%s: %s -> %s (in %s)\n", $2, $3, $4, $5 }
    $1 == "unclear" { printf "unreadable change (%s): %s\n", $2, $3 }')"
if [ -n "$USE_ID" ]; then
    mkdir -p "$STATE_DIR" 2>/dev/null && chmod 700 "$STATE_DIR" 2>/dev/null
    # Records of changes the user declined are never consumed; drop the ones older than a day.
    find "$STATE_DIR" -maxdepth 1 -name '*.json' -mmin +1440 -delete 2>/dev/null
    PAIRS="$(printf '%s\n' "$FINDINGS" | awk -F'\t' '$1 == "change" { printf "%s\t%s\t%s\n", $2, $4, $5 }')"
    jq -cn --arg d "$DIR" --arg r "$REASON" --arg l "$LINES" --arg p "$PAIRS" '{dir:$d,reason:$r,lines:($l | split("\n") | map(select(length > 0))),
        pairs:($p | split("\n") | map(select(length > 0) | split("\t") | {name:.[0], new:(.[1] // ""), where:(.[2] // "")}))}' \
        > "$STATE_DIR/$USE_ID.json" 2>/dev/null
fi
AUDIT_NOTE="If you approve, one audit note is posted on the story being worked."
# [CySec] CWE-778 (Insufficient Logging): without a call id the approval cannot be matched to its audit step; say so
# in the question itself rather than lose the audit silently.
[ -n "$USE_ID" ] || AUDIT_NOTE="NO audit note can be posted for this change (the hook input carries no tool_use_id); record it on the story by hand."
ask_answer "$(printf 'Ask First (kyklos): this %s call loosens a workflow control. Approve only if you want the agent to work without it.\n%s\nReason the agent gave: %s\n%s' \
    "$TOOL" "$LINES" "${REASON:-none}" "$AUDIT_NOTE")"
