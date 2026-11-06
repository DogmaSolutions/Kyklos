#!/usr/bin/env bash
# kyklos-shared-checkout-surface.sh (Kyklos, SessionStart + Stop) -- warn about work left behind in a checkout.
#
# Why: a session that edits directly in a SHARED checkout and ends without committing leaves uncommitted edits (and
# often a local branch with no commits of its own) that nobody owns. Later sessions misread them as their own work, and
# a later pull re-applies them onto a newer trunk as merge conflicts. Guidance alone ("never leave edits in a shared
# checkout") did not prevent it; this hook makes the leftover VISIBLE.
#
# What it checks, per repo (bounded git calls, each under a timeout):
#   * unmerged paths (an unresolved merge / stash-pop conflict);
#   * tracked files with real changes -- whole-file CRLF-only noise on Windows (9p/drvfs) mounts is ignored;
#     generated story copies among them (rewritten by every story refresh) get their own line with the one-time fix;
#   * a non-trunk branch with ZERO commits of its own versus its upstream (or the trunk): a branch that holds nothing.
# Repos: the project dir, its nested source dir (KYKLOS_SOURCE_DIR, default Repo), and the first-level git repos under
# /mnt (the sibling mounts a container session can see; KYKLOS_SHARED_CHECKOUT_ROOT changes that root).
# KYKLOS_SHARED_CHECKOUTS (space-separated paths) replaces the probe. Never scans the wider filesystem; at most KYKLOS_SHARED_CHECKOUT_MAX repos (default 12).
#
# Output is a WARNING, never a block:
#   session-start -> hookSpecificOutput.additionalContext (the model sees it at the start of its session);
#   stop          -> systemMessage, at most ONCE per repo+state per session (no nagging on ordinary work in progress).
# Total scan time is capped by KYKLOS_SHARED_CHECKOUT_BUDGET seconds (default 10): every git call is bounded by it.
# Opt-out: KYKLOS_SHARED_CHECKOUT_WARN=off. Fail-open: any error -> silent.
set +e -uo pipefail

MODE="${1:-stop}"
_payload="$(cat 2>/dev/null || true)"
SESSION_ID="$(printf '%s' "$_payload" | jq -r '.session_id // empty' 2>/dev/null || true)"
command -v git >/dev/null 2>&1 || exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
_cfg="$PROJECT_DIR/.claude/standards.env"
_lib="$(dirname "${BASH_SOURCE[0]}")/lib/standards-env.sh"
if [ -f "$_cfg" ] && [ -f "$_lib" ]; then . "$_lib"; load_standards_env "$_cfg" 2>/dev/null || true; fi
# Checked AFTER the project config is loaded, so the opt-out works from the environment AND from standards.env.
# shellcheck source=lib/control-switch.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/control-switch.sh" 2>/dev/null || true   # kyklos_control_off: the one control-switch reader
kyklos_control_off "${KYKLOS_SHARED_CHECKOUT_WARN:-}" && exit 0
STATE_DIR="${KYKLOS_STATE_DIR:-/tmp/kyklos-state}"
MAX_REPOS="${KYKLOS_SHARED_CHECKOUT_MAX:-12}"
MAX_FILES=8
# Total time budget for the whole scan (seconds): a hung network mount must never stall a stop. Repos left when the
# budget runs out are skipped (and said so), never waited on.
BUDGET="${KYKLOS_SHARED_CHECKOUT_BUDGET:-10}"

# The story tool's definition of a generated story copy (regenerated from the issue tracker, never work): such files
# are reported on their own line with the one-time fix, instead of as leftover edits to commit or discard.
_mirror_lib="$(dirname "${BASH_SOURCE[0]}")/../skills/ssdlc-story/lib/story-mirror-git.sh"
# shellcheck source=../skills/ssdlc-story/lib/story-mirror-git.sh
[ -f "$_mirror_lib" ] && . "$_mirror_lib"

start="$SECONDS"
# CUT: a flag file set when a git call timed out (git runs in subshells, so a shell variable could not carry it).
CUT="$(mktemp 2>/dev/null || true)"; trap '[ -n "$CUT" ] && rm -f "$CUT"' EXIT
_cut() { [ -n "$CUT" ] && printf 1 > "$CUT" 2>/dev/null; return 124; }

# _git: every git call is bounded by 5 s AND by what is left of the total budget, so one slow repo cannot overrun it.
_git() {
    command -v timeout >/dev/null 2>&1 || { git "$@"; return; }
    local left=$((BUDGET - (SECONDS - start))) rc; [ "$left" -gt 0 ] || { _cut; return 124; }
    [ "$left" -gt 5 ] && left=5
    timeout "$left" git "$@"; rc=$?
    [ "$rc" -eq 124 ] && _cut
    return "$rc"
}

# shared_checkout_candidates -> newline list of candidate directories (not yet de-duplicated or git-checked).
shared_checkout_candidates() {
    printf '%s\n' "$PROJECT_DIR" "$PROJECT_DIR/${KYKLOS_SOURCE_DIR:-Repo}"
    if [ -n "${KYKLOS_SHARED_CHECKOUTS:-}" ]; then
        printf '%s\n' $KYKLOS_SHARED_CHECKOUTS
    else
        local d; for d in "${KYKLOS_SHARED_CHECKOUT_ROOT:-/mnt}"/*/; do [ -d "$d" ] && printf '%s\n' "${d%/}"; done
    fi
}

# trunk_ref <repo> -> the ref a branch is compared with: its upstream, else origin/HEAD, else origin/{main,master,develop}.
trunk_ref() {
    local r="$1" u
    u="$(_git -C "$r" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)" && [ -n "$u" ] && { printf '%s' "$u"; return 0; }
    remote_trunk "$r"
}

# remote_trunk <repo> -> origin/HEAD, else the first of origin/{main,master,develop} that exists; fails when none does.
remote_trunk() {
    local r="$1" u c
    u="$(_git -C "$r" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)" && [ -n "$u" ] && { printf '%s' "$u"; return 0; }
    for c in origin/main origin/master origin/develop; do
        _git -C "$r" rev-parse -q --verify "$c" >/dev/null 2>&1 && { printf '%s' "$c"; return 0; }
    done
    return 1
}

# repo_findings <repo> -> one human line per finding (empty when the checkout is clean).
repo_findings() {
    local r="$1" branch unmerged changed copies="" p n more base unique
    branch="$(_git -C "$r" symbolic-ref -q --short HEAD 2>/dev/null || echo '(detached)')"
    unmerged="$(_git -C "$r" diff --name-only --diff-filter=U 2>/dev/null | sort -u)"
    # --numstat honours --ignore-cr-at-eol (a CRLF-only file drops out); --name-only would still list it.
    changed="$(_git -C "$r" diff --ignore-cr-at-eol --numstat HEAD 2>/dev/null | awk -F'\t' '{print $3}' | sort -u)"
    if [ -n "$changed" ] && command -v story_path_is_generated_copy >/dev/null 2>&1; then
        copies="$(printf '%s\n' "$changed" | while IFS= read -r p; do
            [ -n "$p" ] && story_path_is_generated_copy "$r" "$p" && printf '%s\n' "$p"; done)"
        [ -n "$copies" ] && changed="$(printf '%s\n' "$changed" | grep -vxF -f <(printf '%s\n' "$copies") || true)"
    fi
    if [ -n "$copies" ]; then
        n="$(printf '%s\n' "$copies" | wc -l | tr -d ' ')"
        p="$(printf '%s\n' "$copies" | head -n 1)"; p="${p%%STORY-*}"; p="${p%BACKLOG.md}"
        printf 'GENERATED story copies tracked by git: %s file(s) under %s rewritten by a story refresh (not work; they come back on every refresh). Stop tracking them once, in a commit: git rm -r -q --cached -- '\''%sBACKLOG.md'\'' '\''%sSTORY-*'\'' and add /%sBACKLOG.md and /%sSTORY-*/ to .gitignore\n' \
            "$n" "${p:-./}" "$p" "$p" "$p" "$p"
    fi
    if [ -n "$unmerged" ]; then
        n="$(printf '%s\n' "$unmerged" | wc -l | tr -d ' ')"
        more=""; [ "$n" -gt "$MAX_FILES" ] && more=" (+$((n - MAX_FILES)) more)"
        printf 'UNMERGED %s file(s) on %s: %s%s\n' "$n" "$branch" "$(printf '%s\n' "$unmerged" | head -n "$MAX_FILES" | paste -sd, -)" "$more"
    elif [ -n "$changed" ]; then
        n="$(printf '%s\n' "$changed" | wc -l | tr -d ' ')"
        more=""; [ "$n" -gt "$MAX_FILES" ] && more=" (+$((n - MAX_FILES)) more)"
        printf 'UNCOMMITTED changes in %s file(s) on %s: %s%s\n' "$n" "$branch" "$(printf '%s\n' "$changed" | head -n "$MAX_FILES" | paste -sd, -)" "$more"
    fi
    case "$branch" in main|master|develop|'(detached)') return 0 ;; esac
    base="$(trunk_ref "$r")" || return 0
    # A branch in step with its own pushed copy is not empty: compare it with the trunk instead (skip if there is none).
    if [ "$base" = "origin/$branch" ]; then base="$(remote_trunk "$r")" || return 0; fi
    unique="$(_git -C "$r" rev-list --count "$base..HEAD" 2>/dev/null || echo 1)"
    [ "$unique" = "0" ] && printf 'branch %s has NO commits of its own versus %s (an empty leftover branch)\n' "$branch" "$base"
    return 0
}

# --- scan -------------------------------------------------------------------------------------------------------
report=""; seen=" "; count=0; skipped=0
while IFS= read -r d; do
    if [ $((SECONDS - start)) -ge "$BUDGET" ]; then skipped=$((skipped + 1)); continue; fi
    [ -n "$d" ] && [ -d "$d" ] || continue
    [ -n "$CUT" ] && : > "$CUT"
    if ! top="$(_git -C "$d" rev-parse --show-toplevel 2>/dev/null)"; then
        [ -s "${CUT:-/dev/null}" ] && skipped=$((skipped + 1))
        continue
    fi
    case "$seen" in *" $top "*) continue ;; esac
    seen="$seen$top "; count=$((count + 1)); [ "$count" -gt "$MAX_REPOS" ] && break
    f="$(repo_findings "$top")"
    # A repo whose check a timeout cut short and that showed nothing yet was NOT checked: say so, never call it clean.
    if [ -z "$f" ] && { [ -s "${CUT:-/dev/null}" ] || [ $((SECONDS - start)) -ge "$BUDGET" ]; }; then skipped=$((skipped + 1)); continue; fi
    [ -n "$f" ] || continue
    if [ "$MODE" = "stop" ]; then
        # once per repo+state per session: a repeated identical finding is not re-announced every turn.
        key="$(printf '%s|%s' "$top" "$f" | cksum | cut -d' ' -f1)"
        mark="$STATE_DIR/shared-checkout-${SESSION_ID:-nosession}-$key"
        [ -f "$mark" ] && continue
        mkdir -p "$STATE_DIR" 2>/dev/null && : > "$mark" 2>/dev/null
    fi
    report="$report
- $top: $(printf '%s' "$f" | paste -sd';' - | sed 's/;/; /g')"
done < <(shared_checkout_candidates)

[ "$skipped" -gt 0 ] && [ -n "$report" ] && report="$report
- (${skipped} more location(s) not checked: too slow, the ${BUDGET}s scan budget or a git timeout ran out)"
[ -n "$report" ] || exit 0
msg="[kyklos] WARNING: work left behind in a checkout:${report}
Leftover edits in a shared checkout belong to no story: later sessions misread them and a later pull turns them into merge conflicts. For each repo, either COMMIT them to their story branch, MOVE the work to a git worktree (git worktree add), or DISCARD them (after saving anything needed, e.g. git stash / a named branch). An empty leftover branch should be deleted. Opt-out: KYKLOS_SHARED_CHECKOUT_WARN=off."

if [ "$MODE" = "session-start" ]; then
    jq -nc --arg m "$msg" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$m}}' 2>/dev/null || true
else
    jq -nc --arg m "$msg" '{systemMessage:$m}' 2>/dev/null || true
fi
exit 0
