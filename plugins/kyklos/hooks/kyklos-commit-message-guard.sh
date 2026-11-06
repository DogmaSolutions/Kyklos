#!/usr/bin/env bash
# kyklos-commit-message-guard.sh — PreToolUse(Bash). Vets a `git commit` BEFORE it is made, so a mechanical
# commit-policy violation is caught at commit time instead of failing the CI `validate-commit-message` job after a
# full push + CI loop. Three rules:
#   (1) Conventional-Commits SUBJECT — ESPECIALLY a scope with a comma or space (`test(services,data): …`).
#   (2) Refs FOOTER on EVERY commit — `Refs: #<id>` citing the pertinent issue (a story branch requires its exact
#       number; any other branch requires some `Refs: #<n>`), so the link survives a squash-merge and non-GitFlow
# repos. Opt out per-repo with KYKLOS_REQUIRE_REFS=0.
#   (3) NO AI ATTRIBUTION — a Co-Authored-By/Claude-Session/"Generated with Claude" trailer or an AI `--author`
# is blocked (Tier-0) — no override; the fix is to remove the AI line.
#
# Mirrors the fleet CI templates' Conventional Commits rules EXACTLY (same regex), so the local block and the
# CI gate agree. Fleet-general: every Conventional-Commits repo benefits.
#
# FAIL-OPEN by design: no `git commit`, no `-m` message (editor-based commit — can't inspect), or an unparseable
# subject => exit 0 (allow). It only ever blocks a subject it can read AND prove non-conforming.
#
# Wired: PreToolUse, matcher Bash.
# [json-answer-required] The one-branch-one-item rule (4) reads the story tracker's answers through the JSON reader;
# without it that check would exit 127 and fall into a fail-open path, so the hook refuses by name instead (a broken
# install). [CySec] CWE-636
. "$(dirname "${BASH_SOURCE[0]}")/lib/json-answer.sh" 2>/dev/null
if ! command -v json_test >/dev/null 2>&1; then
    printf '{"decision":"block","reason":"BLOCKED (%s): the JSON reader hooks/lib/json-answer.sh did not load (broken install), so this check cannot run. Reinstall or repin the kyklos plugin."}\n' "$(basename "$0")"
    exit 0
fi
set +e -uo pipefail
_GD_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_GD_HERE/lib/git-cmd-detect.sh"   # git_cmd_invokes: command-position git-subcommand detection (shared)

INPUT="$(cat || true)"
command -v jq >/dev/null 2>&1 || { echo "[kyklos] WARNING: commit-message guard INERT — jq is missing; Conventional-Commits enforcement is OFF (CI validate-commit-message is the backstop). Install jq." >&2; exit 0; }
cmd="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
[ -n "$cmd" ] || exit 0
# Context for the Refs-footer story-branch check (below): the repo the commit targets + its branch.
HOOK_CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# Only a real `git commit` (allow intervening git options like `-C <dir>`), and only when it carries a -m message.
# git_cmd_invokes anchors the match to a COMMAND POSITION, so a `git commit -m ...` inside a quoted string or a
# piped data payload is a MENTION, not this call's commit, and is NOT blocked. See
# lib/git-cmd-detect.sh for the shared rule (one source of truth across every git-subcommand guard).
git_cmd_invokes "$cmd" commit || exit 0

# --- (4) ONE BRANCH, ONE ITEM (lib/refs-rule.sh): on a story branch every Refs: trailer names that story; on any other
# branch a commit cites only the item its earlier commits cite. Judged on the -m text and on a -F/--file message file
# the guard can read, so a story's merge request carries only the story's own change (the file set its coverage token
# and its close read). Switched off together with the footer rule (2) below.
# shellcheck source=lib/refs-rule.sh
. "$_GD_HERE/lib/refs-rule.sh"
# shellcheck source=lib/control-switch.sh
. "$_GD_HERE/lib/control-switch.sh" 2>/dev/null || true
if ! kyklos_control_off "${KYKLOS_REQUIRE_REFS:-}"; then
    # [refs-footer-required] Both footer reads (this rule and rule (2) below) go through the one footer definition; without
    # it they would exit 127 and fall into a fail-open path, so the hook refuses by name instead (a broken install). The
    # opt-out above comes first: a repository that switched the footer rules off is not refused for a missing reader.
    # [CySec] CWE-636
    if ! command -v refs_footer_cited >/dev/null 2>&1 || ! command -v refs_rule_message_refusal >/dev/null 2>&1; then
        printf '{"decision":"block","reason":"BLOCKED (%s): the footer reader hooks/lib/refs-footer.sh or hooks/lib/refs-rule.sh did not load (broken install), so this check cannot run. Reinstall or repin the kyklos plugin."}\n' "$(basename "$0")"
        exit 0
    fi
    _rr_tgt="$(git_target_repo_dir "$cmd" "$HOOK_CWD" "$PROJECT_DIR")"
    _rr_filetext=""
    _rr_file="$(printf '%s' "$cmd" | grep -oE -- '(^|[[:space:]])(-F[[:space:]]*|--file[=[:space:]])[^[:space:];&|]+' | head -1 | sed -E "s/^[[:space:]]*(-F[[:space:]]*|--file[=[:space:]])//; s/^[\"']//; s/[\"']\$//")"
    if [ -n "$_rr_file" ]; then
        case "$_rr_file" in /*) ;; *) _rr_file="${HOOK_CWD:-$PROJECT_DIR}/$_rr_file" ;; esac
        [ -r "$_rr_file" ] && _rr_filetext="$(cat "$_rr_file" 2>/dev/null)"
    fi
    # the command line is read as a command, the -F file as a message (a footer starts a line there)
    _rr_why="$(refs_rule_message_refusal "$_rr_tgt" "$(git -C "$_rr_tgt" rev-parse --abbrev-ref HEAD 2>/dev/null)" "$cmd" command "$_rr_filetext")"
    if [ -n "$_rr_why" ]; then
        reason="BLOCKED: $_rr_why"
        reason="${reason//\\/\\\\}"; reason="${reason//\"/\\\"}"; reason="$(printf '%s' "$reason" | tr '\n' ' ')"
        printf '{"decision":"block","reason":"%s"}' "$reason"
        exit 0
    fi
fi

printf '%s' "$cmd" | grep -cE -- '(^|[[:space:]])-m([[:space:]=]|$)' >/dev/null || exit 0

# git's own Revert format (`Revert "<original subject>"`) carries EMBEDDED quotes that defeat naive extraction;
# exempt it at the command level, before extracting (mirrors ConventionalCommitRules.ps1's Revert exception).
printf '%s' "$cmd" | grep -cE -- '-m[[:space:]=]+["'"'"']Revert ' >/dev/null && exit 0

# Extract the FIRST -m subject = the FIRST LINE of the first -m value. Multi-line aware (a real commit carries a
# body/footer, so the value spans newlines): the old line-based `grep '"[^"]*"'` matched NOTHING on a multi-line -m
# and fail-opened, which is why a comma-scope subject on a bodied commit slipped through. awk finds the opening
# quote and prints up to the closing quote ON THAT LINE, else the rest of that line (= the subject). Double-quote
# first (the overwhelming form), then a single-line single-quote fallback.
subj="$(printf '%s' "$cmd" | awk 'match($0,/-m[ \t=]+"/){r=substr($0,RSTART+RLENGTH);q=index(r,"\"");if(q>0)print substr(r,1,q-1);else print r;exit}')"
[ -n "$subj" ] || subj="$(printf '%s' "$cmd" | grep -oE -- "-m[[:space:]=]+'[^']*'" | head -1 | sed -E "s/^-m[[:space:]=]+'//; s/'\$//")"

# A command-substitution (-m "$(...)") or ANSI-C-quoted (-m $'...') value cannot be resolved statically by
# the extractor above: it captures a shell artifact ($( / $' / a bare $), not the real subject. A legitimate
# Conventional-Commits subject NEVER begins with '$' (it starts with a type token), so a leading '$' means the
# subject is UNPARSEABLE => fail-OPEN on the SUBJECT rule (the CI validate-commit-message job checks the resolved
# message; the Refs + AI rules below still scan the whole command and are unaffected). This was a live false-block.
case "$subj" in '$'*) subj="" ;; esac

# git's own Revert format is exempt entirely (mirrors ConventionalCommitRules.ps1).
case "$subj" in 'Revert "'*) exit 0 ;; esac

# --- (1) Conventional-Commits SUBJECT rule (only when a subject was extractable; unreadable => fail-open here,
# but the Refs rule below still applies). Scope (optional) is a SINGLE token [a-zA-Z0-9_.-] — comma/space cannot match.
if [ -n "$subj" ] && ! printf '%s' "$subj" | grep -cE '^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([a-zA-Z0-9_.-]+\))?!?: .+' >/dev/null; then
    reason="BLOCKED: commit subject is not Conventional Commits: '$subj'. Required: <type>(<scope>): <subject> — type in feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert; scope OPTIONAL and a SINGLE token [a-zA-Z0-9_.-] (NO comma, NO space); append '!' for a breaking change."
    if printf '%s' "$subj" | grep -cE '\([^)]*[, ][^)]*\)' >/dev/null; then
        reason="${reason} Your scope contains a comma or space — collapse it to ONE token (e.g. 'test(services-data): ...', not 'test(services,data): ...')."
    fi
    reason="${reason} This is the SAME rule as the CI validate-commit-message job — fixing it now avoids a wasted push + CI loop."
    reason="${reason//\\/\\\\}"; reason="${reason//\"/\\\"}"; reason="$(printf '%s' "$reason" | tr '\n' ' ')"
    printf '{"decision":"block","reason":"%s"}' "$reason"
    exit 0
fi

# --- (3) NO AI ATTRIBUTION (Tier-0). A commit must NEVER cite AI authorship — not in the message/body/footer
# and not via --author. Blocks the known machine-appended traces: a `Co-Authored-By:` trailer naming an AI, a
# `Claude-Session:` link, a "Generated with … Claude" marker, or an `--author=` that names an AI. Scanned against the
# WHOLE command (newline-safe), like the Refs rule. The patterns are ANCHORED to the trailer/flag prefix, so a plain
# subject that merely mentions "Claude" (e.g. `feat(api): add Claude model support`) is NOT a match — only an actual
# attribution line is. There is deliberately NO override: the fix is to remove the AI line, never to bypass the ban.
if printf '%s' "$cmd" | grep -icE 'co-authored-by:.*(claude|anthropic)|claude-session:|generated with.*claude|--author=.*(claude|anthropic)' >/dev/null; then
    reason="BLOCKED (Tier-0, no AI attribution): this commit cites AI authorship — a Co-Authored-By/Claude-Session/'Generated with Claude' trailer or an AI --author. NEVER add an AI trace to a commit (message, body, footer, OR author); the author stays the local git identity. Remove the AI line(s) and re-commit. This is enforced mechanically now — there is no override."
    reason="${reason//\\/\\\\}"; reason="${reason//\"/\\\"}"; reason="$(printf '%s' "$reason" | tr '\n' ' ')"
    printf '{"decision":"block","reason":"%s"}' "$reason"
    exit 0
fi

# --- (2) Refs FOOTER rule: EVERY commit MUST carry a `Refs: #<N>` trailer citing the
# pertinent issue. The branch name is NOT a durable link — it is gone after a squash/FF-merge to trunk, and it never
# exists in a non-GitFlow repo — so the issue linkage must live IN the commit message. When the branch encodes a
# story (feature/story-<N>-…) the EXACT number is required; on any other branch (or a non-GitFlow repo) ANY
# `Refs: #<digits>` satisfies it and the agent supplies the pertinent id. Matched against the whole command
# (newline-safe). Only a PLAIN `#<N>` as the first item of a footer line counts here (refs_footer_lead_plain), exactly
# what the CI validate-commit-message job accepts, so a commit this rule lets through is never refused by CI; a
# project-qualified item (`group/project#N`) satisfies the attribution readers but not this rule, until the CI job reads
# the whole footer definition. Default-ON; a repo with NO issue tracker opts out with KYKLOS_REQUIRE_REFS=0 in
# .claude/standards.env. Editor commits (no -m) already exited above (fail-open — the message can't be inspected).
# shellcheck source=lib/control-switch.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/control-switch.sh" 2>/dev/null || true   # kyklos_control_off: the one control-switch reader
if ! kyklos_control_off "${KYKLOS_REQUIRE_REFS:-}"; then
    tgt="$(git_target_repo_dir "$cmd" "$HOOK_CWD" "$PROJECT_DIR")"
    branch="$(git -C "$tgt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
    storynum="$(story_num_from_branch "$branch")"
    # The footer is read by the one definition (lib/refs-footer.sh), through its CI-visible reading: the plain first item
    # of each footer line. No project path is needed, so a bridge that is down never refuses a commit.
    _rf_leads="$(refs_footer_lead_plain "$cmd" command)"
    if [ -n "$storynum" ]; then
        # Story branch: require the EXACT number (a ref to 12 must not satisfy 1; a padded ref is the same number).
        if ! printf '%s\n' "$_rf_leads" | grep -cxF -- "$(printf '%s' "$storynum" | sed -E 's/^0+([0-9])/\1/')" >/dev/null; then
            reason="BLOCKED: commit on story branch '$branch' is missing its 'Refs: #${storynum}' footer. Add a trailer line — a blank line, then 'Refs: #${storynum}' (the plain item first on its line; a project-qualified item is not accepted yet) — so the commit is tied to STORY-${storynum} (it must survive the merge to trunk and auto-link the GitLab issue). SAME rule as the CI validate-commit-message job. Example (bash ANSI-C quoting keeps the newlines):  git commit -m \$'feat(x): subject\\n\\n<body>\\n\\nRefs: #${storynum}'"
            reason="${reason//\\/\\\\}"; reason="${reason//\"/\\\"}"; reason="$(printf '%s' "$reason" | tr '\n' ' ')"
            printf '{"decision":"block","reason":"%s"}' "$reason"
            exit 0
        fi
    else
        # Any other branch (incl. a trunk in a non-GitFlow repo): require SOME `Refs: #<digits>` footer.
        if [ -z "$_rf_leads" ]; then
            reason="BLOCKED: commit is missing a 'Refs: #<id>' footer citing the pertinent issue. EVERY commit must carry it — the branch name is LOST on a squash-merge and ABSENT in non-GitFlow repos, so the issue link must live in the commit message. Add a trailer: a blank line, then 'Refs: #<id>' (the issue this commit pertains to, a plain item first on its line; a project-qualified item is not accepted yet, SAME rule as the CI validate-commit-message job). If this repo genuinely has no issue tracker, set KYKLOS_REQUIRE_REFS=0 in .claude/standards.env. Example:  git commit -m \"feat(x): subject\" -m \"Refs: #123\""
            reason="${reason//\\/\\\\}"; reason="${reason//\"/\\\"}"; reason="$(printf '%s' "$reason" | tr '\n' ' ')"
            printf '{"decision":"block","reason":"%s"}' "$reason"
            exit 0
        fi
    fi
fi
exit 0
