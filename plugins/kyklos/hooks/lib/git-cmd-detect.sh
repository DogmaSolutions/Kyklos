#!/usr/bin/env bash
# git-cmd-detect.sh — shared helper: does a shell command string INVOKE `git <subcommand>` at a COMMAND POSITION?
#
# WHY: several PreToolUse guards matched a git subcommand as a
# SUBSTRING (`grep -qE 'git[[:space:]]+commit'`), so a `git commit`/`git push`/`git merge` MENTION inside a quoted
# string or a piped data payload (e.g. `printf '{"cmd":"git commit -m x"}' | bash h.sh`, or
# `echo "run git push"`) tripped the guard and BLOCKED an unrelated Bash call. Centralising the detection here (one
# source of truth, reused by every guard) makes the whole class impossible: the match is anchored to a COMMAND
# POSITION — start of the command, or right after a shell separator (; && || | ( { newline) — with intervening git
# options allowed (`git -C <dir> <sub>`). A subcommand preceded by anything else (a quote, a bare space inside a
# string) is a MENTION, not an invocation, and does not match.
#
# A space alone is deliberately NOT a command boundary: a space precedes `git` inside a quoted string too
# (`echo "please git push"`), which is the very false-positive. Known runner prefixes ARE recognised (`sudo git push`,
# `env X=1 git push`, see _GCI_RUNNER below); `ssh host git ...` is deliberately not (it runs on another machine).
#
# ("Strip-Before-Match"): the match runs line-oriented `grep`, so `^` anchors to the start of EVERY line —
# including a heredoc-body line that starts with `git commit` — and a separator (`;`/`&&`/`|`) INSIDE a quoted arg
# looks real. So we FIRST strip heredoc bodies + quoted substrings via the SHARED normalization (lib/cmd-strip.sh,
# also used by dotnet-cmd-detect), then match. A mention in a heredoc/quoted string therefore never trips the gate.
# shellcheck source=cmd-strip.sh
. "$(dirname "${BASH_SOURCE[0]}")/cmd-strip.sh"

# Usage:  git_cmd_invokes "<full command string>" <subcommand>   -> rc 0 if invoked at a command position, else 1.
#   e.g.  git_cmd_invokes "$cmd" commit   /   git_cmd_invokes "$cmd" push   /   git_cmd_invokes "$cmd" merge
# One shell word of a git option or its value, as it reads after cmd_strip removed the quoted text: plain characters, a
# backslash-escaped character (`a\ b` is one word), a command substitution $(...) or a process substitution <(...) /
# >(...) (one level of nested parentheses each), `...` with spaces inside it, or a bare $. A word held to "no spaces"
# lost the subcommand behind `git -c http.x=$(tok a) push`, and the guard then saw no push.
# [CySec] [RiskMitigation RA-01] CWE-184: the option grammar must cover every word shape the shell accepts before the subcommand.
_GCI_WORD='([^[:space:];&|()$`\\]|\\.|[$<>]\(([^()]|\([^()]*\))*\)|`[^`]*`|\$)+'
# The spelling of a command name the shell runs as that command: an optional escaping backslash and an optional path.
_GCI_CMD_PATH='\\?([^[:space:];&|()<>`]*/)?'
# One redirection word in front of a command (`2>&1`, `>/dev/null`, `&>log`, `<in`); after cmd_strip its quoted target
# may be empty (`>"a b"` reads `>`).
_GCI_REDIRECT='(&|[0-9]*)[<>]+[&|]?[[:space:]]*[^[:space:];&|()<>`]*'
# One word that may run the command after it: a runner (by path or not, with its options), a keyword, timeout <dur>,
# or a KEY=VAL assignment whose value opens no command substitution (`r=$(echo git push)` only prints text).
_GCI_RUNNER='(\\?([^[:space:]]*/)?(sudo|doas|command|builtin|exec|eval|nohup|nice|xargs|stdbuf|time|env)([[:space:]]+(-[ugCDnIL][[:space:]]+[^-[:space:]][^[:space:]]*|-[^[:space:]]+))*|then|do|else|elif|if|while|until|!|timeout([[:space:]]+-[^[:space:]]+)*[[:space:]]+[^[:space:]]+|[A-Za-z_][A-Za-z0-9_]*=([^[:space:]()`\\]|\\.)*|'"$_GCI_REDIRECT"')'
git_cmd_strip() { cmd_strip "$1"; }
# cmd_word_invokes "<full command string>" <name-ERE> <after-ERE> -> rc 0 when the command <name> runs at a command
# position and the text right after its name matches <after-ERE>. The ONE reading of "which command does this word
# run", shared by every guard that must find a real call of a command (git here, glab in the merge-request guard):
#   - the position: the start, or after ; & | ( ) { or a backtick (``r=`git push` `` runs the push);
#   - any number of prefix words in front of it (_GCI_RUNNER): a runner (sudo/doas/command/builtin/exec/eval/nohup/
#     nice/xargs/stdbuf/time/env, by path or not, with their options: sudo -E, sudo -u <user>, env -i, time -p),
#     timeout <dur>, KEY=VAL, a redirection (2>&1, >/dev/null, <in), or a shell keyword that starts a command
#     (then/do/else/elif/if/while/until, `!`), in any combination (`if ! git push`, `A=1 2>/dev/null git push`);
#   - the command name itself spelled with an escaping backslash or a path (`\git`, `/usr/bin/git`): the shell runs
#     the same program.
# Every word before the name MUST be one of these, so a mention such as `sudo echo "git push"` (stripped to
# `sudo echo`) or `cat ./scripts/git-push-helper.sh` never matches. `ssh host git push` is DELIBERATELY not matched:
# it runs git on a REMOTE host (outside a local guard's scope), and `ssh host "echo git push"` would false-positive.
# The text is stripped first (cmd_strip: heredoc bodies and quoted substrings dropped), so a quoted mention never
# matches either.
# [CySec] [RiskMitigation RA-01] CWE-184: a prefix word, a path or an escape in front of the command must not hide the call.
cmd_word_invokes() {
    local _c
    _c="$(cmd_strip "$1")"
    printf '%s' "$_c" | grep -ciE "(^|[;&|(){\`])[[:space:]]*(${_GCI_RUNNER}[[:space:]]+)*${_GCI_CMD_PATH}($2)$3" >/dev/null
}
git_cmd_invokes() {
    # git, then its own options (`git -C <dir> <sub>`), then the subcommand, which ends at a blank, a shell character
    # or the end (`r=$(git push)`, `{ git push; }`, `git push|cat`).
    cmd_word_invokes "$1" git "([[:space:]]+-$_GCI_WORD([[:space:]]+$_GCI_WORD)?)*[[:space:]]+$2([[:space:];&|(){}\`]|\$)"
}

# git_target_repo_dir <cmd> <hook_cwd> <project_dir> [op=commit] -> the directory the git command ACTUALLY targets,
# so a guard reads the repo the operation lands in (not blindly the project dir). The precedence (work tree, git dir,
# cumulative -C, the last `cd` BEFORE the `git <op>` token, the hook cwd, <project_dir>) and the __UNDECIDABLE__
# sentinel are listed at the top of the function body. Relative dirs resolve under <project_dir>. <op> is the git subcommand the CALLING guard gates (default `commit`): a commit guard passes
# `commit`, a push guard `push`, a merge guard `merge`, so each resolves the dir ITS OWN operation runs in — e.g.
# `git commit && cd X && git push` targets the commit's cwd for a commit guard but X for a push guard. Passing the
# wrong op (or the old always-`commit` behaviour) would mis-resolve a push/merge target — a security-relevant bug for
# the no-push guard — which is exactly why this is parameterized. SHARED so the commit-message/gitflow/branch-cleanup
# (commit) and no-push/merge-green/slnx (push/merge) guards all use ONE resolver. [CySec] Enforces the
# companion/nested-Repo poka-yoke: `cd Repo && git commit` lands in the inner source repo, not the outer companion.
# Unquote one layer of surrounding single/double quotes.
_gtd_unquote() { local v="$1"; v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"; printf '%s' "$v"; }

# _gtd_first <cmd> <prefix-ERE> -> the value that follows the FIRST match of <prefix-ERE> (a `KEY=`/`--flag `/`--flag=`
# form), unquoted; empty if absent. Used for --work-tree/--git-dir and the GIT_WORK_TREE=/GIT_DIR= env prefixes.
_gtd_first() {
    local raw; raw="$(printf '%s' "$1" | grep -oE "$2"'("[^"]+"|'"'"'[^'"'"']+'"'"'|[^[:space:];&|]+)' | head -1 | sed -E "s/^$2//")"
    _gtd_unquote "$raw"
}

# _gtd_fold_dashC <cmd> -> the CUMULATIVE `-C` target: git applies EVERY `git -C <dir>` in order (a relative one
# stacks under the running dir, an absolute one resets), so `git -C a -C b` targets a/b and `git -C a -C /b` targets
# /b. The old resolver took only the FIRST -C , mis-resolving every chained-`-C` command.
# [RiskMitigation RA-01] Prints the folded value (possibly relative — the caller joins a relative one under project_dir), or empty when
# there is no -C.
# Only git's OWN options count: the ones between `git` and its subcommand. A `-C` after the subcommand belongs to the
# subcommand (`git commit -C <commit>` reuses a commit's message) and must never be read as a directory.
# One shell word: unquoted runs and quoted runs may alternate (`user.name="A B"` is one word).
_GTD_ARG='([^[:space:];&|"'"'"']|"[^"]*"|'"'"'[^'"'"']*'"'"')+'
_GTD_GIT_OPTS='(^|[^[:alnum:]_.-])git(\.exe)?([[:space:]]+(-[Cc][[:space:]]+'"$_GTD_ARG"'|--(git-dir|work-tree|namespace|exec-path|config-env)[[:space:]]+'"$_GTD_ARG"'|--[A-Za-z-]+(='"$_GTD_ARG"')?|-[A-Za-z]))+'

_gtd_fold_dashC() {
    local vals v acc=""
    local -a each=()
    vals="$(printf '%s' "$1" | grep -oE "$_GTD_GIT_OPTS" \
        | grep -oE '(^|[[:space:]])-C[[:space:]]+'"$_GTD_ARG" | sed -E 's/^[[:space:]]*-C[[:space:]]+//')"
    [ -n "$vals" ] || { printf ''; return; }
    mapfile -t each <<< "$vals"   # an array, not a `while read` heredoc loop, so every line is measurable
    for v in "${each[@]}"; do
        v="$(_gtd_unquote "$v")"; [ -n "$v" ] || continue
        case "$v" in /*) acc="$v" ;; *) [ -z "$acc" ] && acc="$v" || acc="$acc/$v" ;; esac
    done
    printf '%s' "$acc"
}

# _gtd_drop_message_text <cmd> -> <cmd> with heredoc bodies removed (an unquoted body keeps only its substitutions) and
# the QUOTED TEXT of message options (-m/--message, including short-flag clusters such as -am/-qm) replaced by a
# placeholder. Words inside a commit message ("use the -C option", "cd elsewhere") are DATA: read as arguments they
# would send every guard built on this resolver to the wrong repo. Quoted PATHS (`git -C "/a b"`, `cd "/a b"`) are
# untouched, unlike cmd_strip, which drops every quoted substring. The whole command is one record (sed -z), so a
# multi-line quoted message is matched too. A single-quoted message continues across the shell's `'\''` apostrophe idiom
# (`-m 'it'\''s here'` is ONE message), and an ANSI-C `$'...'` message (with its backslash escapes) is message text as
# well.
# Shell comments go first (cmd_drop_comments, the one comment step every push reader shares): a trailing note is neither
# a refspec, an option nor a `cd`.
# [CySec] Mitigates CWE-88 (argument injection): message text can never redirect the repo a guard judges.
# [RiskMitigation RA-01] a guard never judges a repo named only by message text.
_gtd_drop_message_text() {
    cmd_drop_comments "$1" | _cmd_strip_heredocs \
      | sed -zE 's/(^|[[:space:]])(-[A-Za-z]*m|--message)([[:space:]]+|=)?("([^"\\]|\\.)*"|'"'"'[^'"'"']*'"'"'(\\'"'"''"'"'[^'"'"']*'"'"')*|\$'"'"'([^'"'"'\\]|\\.)*'"'"')/\1\2 __MSG__/g'
}

# cmd_last_cd_dir TEXT -> the directory of the LAST `cd <dir>` in TEXT (quotes removed), or nothing. Callers cut TEXT
# to the part before the operation they judge, so a `cd` after it does not count.
cmd_last_cd_dir() {
    local d
    d="$(printf '%s' "$1" | grep -oE '(^|[^[:alnum:]_])cd[[:space:]]+("[^"]+"|'"'"'[^'"'"']+'"'"'|[^[:space:];&|]+)' | tail -1 | sed -E 's/.*cd[[:space:]]+//')"
    _gtd_unquote "$d"
}

git_target_repo_dir() {
    local cmd="$1" hook_cwd="$2" project_dir="$3" op="${4:-commit}" d="" pre=""
    # Resolve from the command WITHOUT message text / heredoc bodies (see _gtd_drop_message_text).
    cmd="$(_gtd_drop_message_text "$cmd")"
    # Resolve WHERE a git write lands, in git's own precedence, hardened so a chained-C, work-tree, git-dir or env-prefixed command resolves correctly:
    #   1. an explicit WORK TREE — --work-tree=<d> / --work-tree <d> / GIT_WORK_TREE=<d> (that IS where files land);
    #   2. an explicit GIT DIR — --git-dir=<d> / GIT_DIR=<d> (the repo is its parent when it ends in /.git);
    #   3. `git -C <d>` — CUMULATIVE (every -C in order; relative stacks, absolute resets);
    #   4. the LAST `cd <d>` BEFORE the `git <op>` token;
    #   5. the hook cwd's repo toplevel, else <project_dir>.
    # A target that is a command SUBSTITUTION is UNDECIDABLE: return the sentinel so the caller [RiskMitigation RA-02]
    # FAILS SAFE (a guard blocks/warns) instead of resolving a bogus literal path.
    d="$(_gtd_first "$cmd" '(--work-tree[= ]|GIT_WORK_TREE=)')"
    if [ -z "$d" ]; then
        local gd; gd="$(_gtd_first "$cmd" '(--git-dir[= ]|GIT_DIR=)')"
        case "$gd" in */.git|*/.git/) d="${gd%/}"; d="${d%/.git}" ;; ?*) d="$gd" ;; esac
    fi
    [ -z "$d" ] && d="$(_gtd_fold_dashC "$cmd")"
    if [ -z "$d" ]; then
        # <op> is a hardcoded subcommand literal (commit|push|merge) from the caller — no regex metacharacters, so
        # interpolating it into the strip pattern is safe. Strip from the FIRST `git <op>` so a `cd` after the
        # operation is ignored (it did not move where the operation landed).
        pre="$(printf '%s' "$cmd" | sed -E "s/git[[:space:]]+${op}.*//")"
        d="$(cmd_last_cd_dir "$pre")"
    fi
    # UNDECIDABLE target (a command substitution feeds the dir): fail safe, never resolve a bogus path. [RiskMitigation RA-02]
    case "$d" in *'$('*|*'`'*|*'${'*) printf '__UNDECIDABLE__'; return ;; esac
    if [ -z "$d" ]; then
        # No explicit -C/cd/work-tree: the bare git command runs in the shell's ACTUAL cwd (hook-input .cwd), NOT
        # necessarily <project_dir>. Resolve the repo from that cwd; fall back to <project_dir> only when cwd is not
        # inside a git repo. [RiskMitigation RA-01] so a bare trunk/feature push is never mis-resolved to a
        # non-companion <project_dir> and wrongly BLOCKED.
        local cwdtop=""
        [ -n "$hook_cwd" ] && cwdtop="$(git -C "$hook_cwd" rev-parse --show-toplevel 2>/dev/null || echo "")"
        if [ -n "$cwdtop" ]; then printf '%s' "$cwdtop"; else printf '%s' "$project_dir"; fi
        return
    fi
    case "$d" in /*) printf '%s' "$d" ;; *) printf '%s' "$project_dir/$d" ;; esac
}

# story_num_from_branch <branch> -> the story number a STORY-FIRST branch encodes, else empty.
# The SINGLE source of truth for "which story does this branch belong to", mirrored by the gitflow branch guard's
# story-first check, the commit Refs-footer guard and the CI commit-message check, so all agree on the number.
# Only the GitFlow story form counts: feature/story-<N>-<slug> or hotfix/story-<N>-<slug> (or the bare
# feature/story-<N>), any case, anchored. `story/42`, `x/story-42` and `feature/history-42-a` are no story branches.
story_num_from_branch() {
    printf '%s' "$1" | sed -nE 's#^(feature|hotfix)/story-([0-9]+)(-.*)?$#\2#Ip' | head -1
}
