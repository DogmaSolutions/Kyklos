#!/usr/bin/env bash
# mr-hands-off.sh - the shared rules for "a story merge request merges itself". Source it; it defines functions only.
#
# A story merge request is created ARMED ("merge when pipeline succeeds"), so GitLab merges it once its pipeline is
# green. Two mistakes follow from forgetting that, and this file holds the one definition each guard uses for them:
#   1. creating the merge request UNARMED (nothing then merges it, so the agent merges by hand after green);
#   2. merging by hand a merge request that GitLab has already merged, or will merge on its own.
#
#   MR_CREATE_VALUE_RE / MR_ARM_VALUE_RE the push-option VALUES that create / arm a merge request; which words of a
#                                        command are push options is decided only by the shared reader
#                                        (push_option_values, lib/push-positionals.awk), never by a pattern here
#   mr_push_creates <cmd>                rc 0 when the text carries the create push option
#   mr_push_arms <cmd>                   rc 0 when the text carries an arm push option (an unreadable expansion counts
#                                        as armed: strict for the auto-merge coverage guard)
#   mr_push_creates_armed <cmd>          rc 0 only when the creating push itself carries the arm option, written out
#                                        (an unreadable expansion counts as unarmed: strict for the hands-off guard)
#   mr_with_arm <cmd>                    the command with the arm option added right after the create option
#   mr_hand_merge_explain <state> <armed> <number> [target]
#                                        prints why a hand merge is pointless and what to do instead; rc 1 when the
#                                        merge request is open and unarmed (a merge is then a real decision)
#   mr_row_of <json>                     one merge request object -> "state<TAB>armed<TAB>number<TAB>target"
#   mr_row_for_branch <branch> [repository]
#                                        the branch's open merge request, else its latest merged one, as a row; rc 1
#                                        when none can be read
#   mr_row_for_number <number> [repository]
#                                        that merge request as a row; rc 1 when it cannot be read
#   ([repository]: the origin address of the repository the branch or request belongs to, from
#   ci_access_repository_address; the bridge reads that repository's project instead of its default one.)
#   mr_repo_has_no_ci <repo-dir> [ref]  rc 0 when the repository runs no CI for <ref> (default HEAD): its pipeline file is
#                                        the project's ci_config_path when GitLab can be asked, else .gitlab-ci.yml; a
#                                        GitLab that is asked and does not answer counts as CI
#   mr_project_has_no_ci <api> <token-setting> <project> <ref>
#                                        rc 0 when GitLab says the project runs no CI for <ref>
#   mr_project_pipeline_file <api> <token-setting> <project>
#                                        the project's in-repository pipeline file; rc 3 CI/CD off, rc 1 counts as CI
# The two lookups read through ci-access.sh (the bridge first); the caller sources it. mr_project_has_no_ci reads
# through gitlab-curl.sh; the caller sources it.
#
# No CI: in a repository without a CI pipeline an ARMED merge request never merges (no pipeline ever succeeds), so the
# "create it armed, never merge it by hand" rule would deadlock the agent. There the request is created unarmed and
# merged through the API once mergeable; the merged-result check (the branch contains the target's head, or
# the target's new commits touch none of its files; lib/merged-result.sh) still applies.
# Whenever the answer cannot be read, the project counts as having CI, so the usual refusals stand.

# shellcheck source=lib/json-answer.sh
. "$(dirname "${BASH_SOURCE[0]}")/json-answer.sh"   # json_test / json_read: an empty or cut answer is never valid
# GitLab ignores a value on these options (`merge_request.create=1` still creates), so a value never hides the option.
# shellcheck disable=SC2034  # read by the guards that source this file
MR_CREATE_VALUE_RE='^merge_request\.create(=.*)?$'
# shellcheck disable=SC2034
MR_ARM_VALUE_RE='^merge_request\.(merge_when_pipeline_succeeds|auto_merge)(=.*)?$'
# The arm as the hands-off guard accepts it to let a create through: written bare, or with a value that plainly turns
# it on. Any other value (`=x`, `= false`, a computed one) may not arm, so there the create counts as unarmed.
MR_ARM_ON_RE='^merge_request\.(merge_when_pipeline_succeeds|auto_merge)(=(true|1))?$'
# The option NAMES written anywhere in the line (an expansion the hook cannot read counts only when the line names them).
MR_CREATE_NAME_RE='merge_request\.create([^A-Za-z0-9_.]|$)'
MR_ARM_NAME_RE='merge_request\.(merge_when_pipeline_succeeds|auto_merge)'
# A word that may be a push option of git push: a short-flag bundle ending in o, or --push-option or an abbreviation.
MR_PUSH_OPT_WORD_RE='(-[A-Za-z]*o|--pu[a-z-]*)'

# ---- Text or call: ONE matcher for every guard that must tell a real request from text that only quotes it ----------
#   mr_only_text_commands <cmd>   rc 0 when every command the line runs can only print or record text
#   mr_segment_text_only <seg>    rc 0 when one command (a stripped segment) can only print or record text
#   mr_command_segments <cmd>     the line's commands, quoted text and heredoc bodies removed, one per output line,
#                                 with push options un-quoted first so `-o "merge_request.x"` stays visible
#   mr_heredocs_fed_to_calls <cmd> the heredoc body lines fed to a command that is not text-only (a shell, python, ...)
#   mr_segment_may_run <seg>     rc 0 unless the command is a pure printer (echo, printf, cat, grep, ...)
#   mr_push_creates / mr_push_arms <cmd>   rc 0 when a command that may run (not echo/printf/grep/...) carries the
#                                 create / arm push option, bare or quoted, directly or through a variable
# The same words inside a commit message, a note body, an echo or a heredoc written to a file are text ABOUT a merge,
# not a call to it. So a line counts as text only when EVERY command it runs is one that can only print or record text;
# any other command (an HTTP client, a runner prefix such as env/sudo/xargs/exec, a full path, an escaped name, a
# variable or a substitution as the command, a shell keyword) may send the request and is judged as a call.
# [CySec] Allow-list, not deny-list, of the commands that cannot send a request (CWE-184, incomplete list of disallowed
# inputs): an HTTP client the list does not name stays a call. git counts as text unless it is given configuration
# (-c, --config-env: an alias or a hook command may run anything) or a program to run (--exec, --upload-pack,
# --receive-pack, ext::); glab only for its mr and issue subcommands (api and alias may send anything).
MR_TEXT_ONLY_COMMANDS=' git echo printf true false : cd glab cat grep '
_MR_HO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=git-cmd-detect.sh
command -v git_cmd_invokes >/dev/null 2>&1 || . "$_MR_HO_DIR/git-cmd-detect.sh"   # also brings cmd_strip
# shellcheck source=push-refspec.sh
command -v push_option_values >/dev/null 2>&1 || . "$_MR_HO_DIR/push-refspec.sh"   # the one push-option reader

# git subcommands that record or show text and run nothing the line names (hooks aside); any other word may be an alias.
MR_GIT_TEXT_SUBCOMMANDS='add am blame branch checkout cherry-pick clone commit config describe diff fetch grep init log ls-files ls-remote merge merge-base mv notes pull push rebase reflog remote reset restore revert rev-list rev-parse rm shortlog show stash status switch tag worktree'
# _mr_git_subcommand <seg> -> the first word after `git` and its global options (-C <dir>, --git-dir=..., -P, ...).
_mr_git_subcommand() {
    local w skip=0 first=1 words
    read -ra words <<< "$1"   # split without glob expansion: `git add *.sh` must not list the folder
    for w in "${words[@]}"; do
        [ "$first" = 1 ] && { first=0; continue; }
        [ "$skip" = 1 ] && { skip=0; continue; }
        case "$w" in -C|--git-dir|--work-tree|--namespace) skip=1 ;; -*) ;; *) printf '%s' "$w"; return 0 ;; esac
    done
}

mr_segment_text_only() {
    local seg="$1" w
    seg="${seg#"${seg%%[![:space:]]*}"}"
    [ -n "$seg" ] || return 0
    w="${seg%%[[:space:]]*}"
    case "$MR_TEXT_ONLY_COMMANDS" in *" $w "*) ;; *) return 1 ;; esac
    case "$w" in
        git) printf '%s' "$seg" | grep -cE '[[:space:]](-c|--config-env|--exec|--exec-path|--upload-pack|--receive-pack)([=[:space:]]|$)|ext::|[[:space:]]alias\.' >/dev/null && return 1
             # an unknown subcommand may be an alias, which can run anything
             case " $MR_GIT_TEXT_SUBCOMMANDS " in *" $(_mr_git_subcommand "$seg") "*) ;; *) return 1 ;; esac ;;
        glab) printf '%s' "$seg" | grep -cE '^glab[[:space:]]+(mr|issue)([[:space:]]|$)' >/dev/null || return 1 ;;
    esac
    return 0
}

# _mr_unquote_push_options <cmd> -> <cmd> with the quotes around a push option or its value removed ("-o",
# "-o<value>", "--push-option=<value>", -o "<value>", -o '<value>', -o $'<value>'), so the quote strip that follows
# keeps the option visible; a double-quoted value the shell computes ("$o", "$(...)") becomes the marker $VALUE and a
# quoted value holding a blank (a title) becomes the one word __QUOTED__, so the option keeps its value. A
# quoted option inside a commit message stays inside its message's quotes and is stripped.
_mr_unquote_push_options() {
    local o="$MR_PUSH_OPT_WORD_RE"
    printf '%s' "$1" | sed -E \
        -e 's/('"$o"'[=[:space:]]*)"[^"]*[$`][^"]*"/\1$VALUE/g' \
        -e "s/([\"'])$o\\1/\\2/g" \
        -e "s/([\"'])(${o}=?[^\"' ]*)\\1/\\2/g" \
        -e "s/(${o}[=[:space:]]*)\\\$?([\"'])([^\"' ]*)\\3/\\1\\4/g" \
        -e "s/(${o}[=[:space:]]*)([\"'])[^\"']*[[:space:]][^\"']*\\3/\\1__QUOTED__/g"
}

mr_command_segments() {
    { cmd_strip "$(_mr_unquote_push_options "$1")"; echo; } | tr ';&|(){}`' '\n\n\n\n\n\n\n\n'   # the echo ends the last line, so `read` keeps it
}

mr_heredocs_fed_to_calls() {
    local c body piped=0
    _mr_pipes_into_call "$1" && piped=1
    while IFS=$'\t' read -r c body; do
        # A body is data only when every command that reads it can only print or record text: the heredoc's own
        # command (`git commit -F -` is text, `sh -s` is not) and every command the line pipes into (`cat <<E | bash`).
        # [CySec] Allow-list of data sinks, everything else runs the body (CWE-184).
        if mr_segment_text_only "$c" && [ "$piped" = 0 ]; then continue; fi
        printf '%s\n' "$body"
    done < <(printf '%s\n' "$1" | awk -v mode=bodies -f "$_MR_HO_DIR/cmd-shell-scan.awk")
}

# _mr_pipes_into_call <cmd> -> rc 0 when the line pipes into a command that is not text-only (`... | bash`).
_mr_pipes_into_call() {
    local part
    while IFS= read -r part; do
        mr_segment_text_only "$part" || return 0
    done < <(_gtd_drop_message_text "$1" \
             | awk '{ gsub(/\|\|/, ";"); n = split($0, a, "|"); for (k = 2; k <= n; k++) { p = a[k]; sub(/^&/, "", p); sub(/(&&|;).*/, "", p); print p } }')
    return 1
}

mr_only_text_commands() {
    local seg
    [ -n "$(printf '%s\n' "$1" | awk -v mode=subst -f "$_MR_HO_DIR/cmd-shell-scan.awk")" ] && return 1
    while IFS= read -r seg; do
        mr_segment_text_only "$seg" || return 1
    done < <(mr_command_segments "$1")
    return 0
}

# mr_segment_may_run <seg> -> rc 0 unless the segment's command is a pure printer (a text-only command other than the
# two that arm: git pushes, glab merges). Used to find WHERE an arm may run, not whether a line is text.
mr_segment_may_run() {
    local seg="${1#"${1%%[![:space:]]*}"}" w
    w="${seg%%[[:space:]]*}"
    [ -n "$w" ] || return 1
    case "$w" in git|glab) return 0 ;; esac
    case "$MR_TEXT_ONLY_COMMANDS" in *" $w "*) return 1 ;; esac
    return 0
}

# _mr_repo_push_options <cmd> -> the push.pushOption values of the repository the line's push runs in (git sends them
# with every push, so an option set by an earlier command still arms or creates). The repository is MR_REPO_DIR when
# the caller knows it, else the push's own target (-C, cd, then the hook's folder HOOK_CWD or the current folder). An
# undecidable target reads nothing.
_mr_repo_push_options() {
    local repo="${MR_REPO_DIR:-}" here="${HOOK_CWD:-$PWD}"
    [ -n "$repo" ] || repo="$(git_target_repo_dir "$1" "$here" "${CLAUDE_PROJECT_DIR:-$here}" push 2>/dev/null)"
    [ -n "$repo" ] && [ "$repo" != "__UNDECIDABLE__" ] || return 0
    git -C "$repo" config --get-all push.pushOption 2>/dev/null
}

# _mr_line_values <cmd> -> every push-option value the line sends or sets, read by the shared reader over every push of
# the line and every heredoc body fed to a shell, one per line: the values of `git config push.pushOption` and of
# git's -c push.pushOption without their markers, and `?unknown <why>` for a source or a value the reader cannot read.
_mr_line_values() {
    { _mr_line_reader_output "$1"; } | grep -vE '^@@(push|empty)$' | sed -E 's/^\?(config|cfg) //'
}
# _mr_line_reader_output <cmd> -> push_option_values_all over the line and over each heredoc body fed to a shell.
_mr_line_reader_output() {
    local line
    push_option_values_all "$1"
    mr_heredocs_fed_to_calls "$1" | while IFS= read -r line; do push_option_values_all "$line"; done
}
# mr_line_pushes <cmd> -> rc 0 when the shared reader finds a git push on the line or in a heredoc body fed to a shell.
mr_line_pushes() { _mr_line_reader_output "$1" | grep -cx '@@push' >/dev/null; }

# _mr_push_option_runs <cmd> <value-ERE> <name-ERE> -> rc 0 when a command that may run sends a push option whose
# value matches <value-ERE>, as git reads it (lib/push-positionals.awk: -o, bundled flags, abbreviations, -c
# push.pushOption, git config push.pushOption, the repository's setting), in a heredoc fed to a shell too; when a push
# carries an option the reader cannot read (a value the shell builds, a GIT_CONFIG_* variable, -c include/alias,
# --config-env), which may be this option; or when the line names the option (<name-ERE>) where the reader cannot
# place it (a command or a value held in a variable, an alias).
# [CySec] [RiskMitigation RA-01] fail closed on an option or expansion that cannot be resolved (CWE-184)
_mr_push_option_runs() {
    local seg vals names=1 pushes=0
    printf '%s' "$1" | grep -cE "$3" >/dev/null || names=0
    mr_line_pushes "$1" && pushes=1
    vals="$(_mr_line_values "$1")"
    printf '%s\n' "$vals" | grep -cE "$2" >/dev/null && return 0
    { [ "$pushes" = 1 ] || [ "$names" = 1 ]; } && printf '%s\n' "$vals" | grep -cE '^\?unknown ' >/dev/null && return 0
    mr_option_unread "$1" "$3" "$2" && return 0
    while IFS= read -r seg; do
        mr_segment_may_run "$seg" || continue
        git_cmd_invokes "$seg" push && pushes=1
        [ "$names" = 1 ] || continue
        # a push that expands a variable anywhere (`p='-o merge_request.x'; git push $p`), or a command held in a
        # variable or a substitution (`p='git push -o ...'; $p`): the hook cannot know what the expansion holds
        printf '%s' "$seg" | grep -cE '\$' >/dev/null && git_cmd_invokes "$seg" push && return 0
        printf '%s' "$seg" | grep -cE '^[[:space:]]*(\$|`)' >/dev/null && return 0
    done < <(mr_command_segments "$1")
    [ "$pushes" = 1 ] && _mr_repo_push_options "$1" | grep -cE "$2" >/dev/null && return 0
    return 1
}
# mr_option_unread <cmd> <name-ERE> <value-ERE> -> rc 0 when a line that may run (not only text-printing commands)
# and that pushes or defines an alias names the option (<name-ERE>) more often than the shared reader finds it as a
# value (<value-ERE>) on the line. The mentions are counted on the line with commit messages and heredoc bodies written
# to files dropped, plus every shell payload and substitution as its own text (a push inside a commit-message
# substitution is a push to judge, never a read that offsets another mention), quotes and backslashes removed. A
# mention inside a command that can only print text counts as read, unless the line pipes into another command. Then
# some command carries the option in a form the reader cannot see: a command word that is not git written out
# (`$GIT push`), an alias (`alias p=...`, `git -c alias.p=...`), a push held in a variable, `git $G push`.
# [CySec] [RiskMitigation RA-01] an option the reader cannot place counts as present (CWE-636, not failing securely).
mr_option_unread() {
    local drop payload pl text mentions reads
    mr_only_text_commands "$1" && return 1
    drop="$(_gtd_drop_message_text "$1")"; payload="$(_cmd_extract_shell_c "$1")"
    # A payload is counted once, as its own text below, not again inside the quotes it was written in.
    while IFS= read -r pl; do [ -n "$pl" ] && drop="${drop//"$pl"/}"; done <<< "$payload"
    text="$(printf '%s\n%s\n%s\n' "$drop" "$payload" "$(mr_heredocs_fed_to_calls "$1")" | tr -d "\"'\\\\")"
    mentions="$(printf '%s\n' "$text" | grep -oE "$2" | grep -c .)"
    [ "$mentions" -gt 0 ] || return 1
    printf '%s\n' "$text" | grep -cE '(^|[^A-Za-z0-9_.-])(push|alias)([^A-Za-z0-9_.-]|$)' >/dev/null || return 1
    reads="$(_mr_line_values "$1" | grep -cE "$3")"
    printf '%s\n' "$text" | grep -cE '(^|[^|])\|([^|]|$)' >/dev/null && { [ "$mentions" -gt "$reads" ]; return; }
    reads=$((reads + $(while IFS= read -r seg; do mr_segment_may_run "$seg" || printf '%s\n' "$seg"; done < <(mr_command_segments "$1") \
        | tr -d "\"'\\\\" | grep -oE "$2" | grep -c .)))
    [ "$mentions" -gt "$reads" ]
}
# mr_push_options_unread <cmd> -> rc 0 when a command that may run holds the word `push` after a word the shell
# expands (`$G push`, `git $G push`, `` `which git` push ``), the shared reader finds no push in it, and it passes
# a push-option word (-o..., --pu...) or names a merge_request option: a push whose options the guard cannot read.
mr_push_options_unread() {
    local seg
    while IFS= read -r seg; do
        mr_segment_may_run "$seg" || continue
        printf '%s' "$seg" | tr -d "\"'\\\\" | grep -cE '(^|[[:space:]])[^[:space:]]*[$`][^[:space:]]*[[:space:]]+([^[:space:]]+[[:space:]]+)*push([[:space:]]|$)' >/dev/null || continue
        push_reader_sees_push "$seg" && continue
        printf '%s' "$seg" | grep -cE '(^|[[:space:]])(-[A-Za-z]*o|--pu)|merge_request' >/dev/null && return 0
    done < <(mr_command_segments "$1")
    return 1
}
mr_push_creates() { _mr_push_option_runs "$1" "$MR_CREATE_VALUE_RE" "$MR_CREATE_NAME_RE"; }
mr_push_arms() { _mr_push_option_runs "$1" "$MR_ARM_VALUE_RE" "$MR_ARM_NAME_RE"; }

# mr_push_verdicts <cmd> -> one line per push the shared reader finds (on the line and in heredoc bodies fed to a
# shell): "<creates> <armed> <unknown>", each 0 or 1. The options a push sends are read the way git sends them: its
# own -o options when it has any; otherwise the push.pushOption values (the repository's, then a `git config` on the
# line, then -c on the push; an empty value clears the list). `-o ''` is an own option too, so beside it no
# push.pushOption value is sent. <creates> is 1 when the options sent name the create (a value on it does not
# matter). <armed> is 1 only when the LAST arm option sent is bare or =true/=1, as GitLab reads a repeated option.
# <unknown> is 1 when an option or a positional of the push cannot be read.
mr_push_verdicts() {
    local line repo_vals line_cfg cfg_unknown block="" started=0
    repo_vals="$(_mr_repo_push_options "$1")"
    line_cfg="$(_mr_line_reader_output "$1" | sed -n 's/^?config //p')"
    cfg_unknown=0; _mr_line_reader_output "$1" | grep -cE '^\?unknown option git config' >/dev/null && cfg_unknown=1
    _mr_verdict() {
        local own cfgc eff part v last="" c=0 a=0 u=0
        # `-o ''` (marked @@empty) is an option of the push's own: git then sends no push.pushOption value.
        own="$(printf '%s\n' "$block" | grep -v '^?' | grep -v '^[[:space:]]*$')"
        cfgc="$(printf '%s\n' "$block" | sed -nE 's/^\?cfg $/@@reset/p; s/^\?cfg (.+)$/\1/p')"
        printf '%s\n' "$block" | grep -cE '^\?(unknown|positional) ' >/dev/null && u=1
        eff="$own"
        if [ -z "$own" ]; then
            eff=""; for part in "$repo_vals" "$line_cfg" "$cfgc"; do [ -n "$part" ] && eff="${eff:+$eff$'\n'}$part"; done
        fi
        while IFS= read -r v; do
            [ "$v" = "@@reset" ] && { last=""; continue; }
            printf '%s\n' "$v" | grep -cE "$MR_ARM_VALUE_RE" >/dev/null && last="$v"
        done <<< "$eff"
        printf '%s\n' "$eff" | grep -cE "$MR_CREATE_VALUE_RE" >/dev/null && c=1
        [ -n "$last" ] && printf '%s\n' "$last" | grep -ciE "$MR_ARM_ON_RE" >/dev/null && a=1
        # The line changed the configured list in a way the reader does not track (a second write, a replace, an
        # unset, an empty value): a push that relies on that list may create, and is not known to arm.
        if [ -z "$own" ] && [ "$cfg_unknown" = 1 ]; then c=1; a=0; u=1; fi
        printf '%s %s %s\n' "$c" "$a" "$u"
    }
    while IFS= read -r line; do
        if [ "$line" = "@@push" ]; then
            [ "$started" = 1 ] && _mr_verdict
            started=1; block=""
        else
            block="$(printf '%s\n%s' "$block" "$line")"
        fi
    done < <(_mr_line_reader_output "$1")
    [ "$started" = 1 ] && _mr_verdict
    return 0
}

# mr_push_creates_armed <cmd> -> rc 0 only when the line holds a push and every push that creates a merge request, or
# that cannot be fully read, also sends the arm (mr_push_verdicts), directly or in a heredoc fed to a shell. A push
# whose options git does not send (`git config push.pushOption x` beside `git push -o ''`) creates nothing. An option
# the hook cannot read (a variable, a substitution, a GIT_CONFIG_* variable, an alias) or one written anywhere else on
# the line (a commit message, an echo, another push) does not count, and an unarmed creating push beside an armed one
# makes the line unarmed.
# The two guards need OPPOSITE answers for what cannot be read: for the auto-merge coverage guard an arm is what it
# refuses, so mr_push_arms reads an unresolved expansion as "armed" (strict there); for the hands-off guard "armed" is
# what lets a create through, so this reading treats it as "may be unarmed" and the create is refused with the armed
# command to run instead.
# [CySec] [RiskMitigation RA-01] each guard fails closed for its own purpose (CWE-636, not failing securely).
mr_push_creates_armed() {
    local v
    v="$(mr_push_verdicts "$1")"
    [ -n "$v" ] || return 1
    ! printf '%s\n' "$v" | grep -cE '^(1 0 .|. 0 1)$' >/dev/null
}
# mr_push_all_armed <cmd> -> rc 0 when the line holds a push and every push it holds sends the arm (mr_push_verdicts).
mr_push_all_armed() {
    local v
    v="$(mr_push_verdicts "$1")"
    [ -n "$v" ] && ! printf '%s\n' "$v" | grep -cE '^. 0 ' >/dev/null
}

# mr_with_arm <cmd> -> <cmd> with `-o merge_request.merge_when_pipeline_succeeds` placed right after the FIRST create
# option (after its closing quote when it is quoted), so the suggested command is the agent's own command, armed.
mr_with_arm() {
    # The same word boundary as MR_CREATE_NAME_RE: `merge_request.created_by` earlier in the text is not the option. A
    # value on the create (`merge_request.create=1`) stays with it, and the arm goes after the whole word.
    printf '%s' "$1" | sed -E '0,/merge_request\.create(=[^[:space:]"'"'"']*)?(["'"'"']?)([^A-Za-z0-9_.=]|$)/s/(merge_request\.create(=[^[:space:]"'"'"']*)?)(["'"'"']?)([^A-Za-z0-9_.=]|$)/\1\3 -o merge_request.merge_when_pipeline_succeeds\4/'
}

# mr_hand_merge_explain <state> <armed> <number> [target] -> the refusal text for a hand merge; rc 1 = no refusal.
mr_hand_merge_explain() {
    local state="$1" armed="$2" n="$3" target="${4:-}"
    [ -n "$target" ] || target="its target branch"
    case "$state" in
        merged)
            printf 'Hand merge REFUSED: merge request !%s is already MERGED into %s. GitLab merged it after its pipeline succeeded, so there is nothing left to merge, and merging again would fail or duplicate the work. Next: update the trunk (git fetch origin, then git pull --ff-only on %s), delete the local branch (git branch -d <branch>), and close the story citing !%s.' "$n" "$target" "$target" "$n"
            return 0 ;;
        closed)
            printf 'Hand merge REFUSED: merge request !%s is CLOSED without being merged. Do not merge its branch by hand: reopen it, or create a new one armed in the same push (git push -o merge_request.create -o merge_request.target=%s -o merge_request.merge_when_pipeline_succeeds origin <branch>).' "$n" "$target"
            return 0 ;;
        opened|open)
            if [ "$armed" = true ]; then
                printf 'Hand merge REFUSED: merge request !%s is ARMED: GitLab merges it into %s by itself as soon as its pipeline succeeds. A hand merge races GitLab and can land a result the pipeline never tested. Do nothing here: watch the pipeline. If it fails, fix, commit and push again with -o merge_request.merge_when_pipeline_succeeds (so it stays armed). Once GitLab has merged it, close the story citing !%s.' "$n" "$target" "$n"
                return 0
            fi
            return 1 ;;
    esac
    return 1
}

# mr_row_of <json> -> "state<TAB>armed<TAB>number<TAB>target" for one merge request object in either shape (the bridge
# verb's auto_merge/merge_request, or GitLab's merge_when_pipeline_succeeds/iid). Empty when it is not one.
mr_row_of() {
    printf '%s' "$1" | jq -r 'select(type=="object" and (.state|type)=="string")
        | [.state, ((.auto_merge // .merge_when_pipeline_succeeds // false) | tostring),
           ((.merge_request // .iid) | tostring), (.target_branch // "")] | @tsv' 2>/dev/null
}

mr_row_for_branch() {
    local br="$1" repository="${2:-}" st out row
    [ -n "$br" ] || return 1
    for st in opened merged; do
        out="$(ci_access_merge_requests "$br" "$st" "$repository" 2>/dev/null)" || return 1
        row="$(mr_row_of "$(printf '%s' "$out" | jq -c '.merge_requests[0] // empty' 2>/dev/null)")"
        [ -n "$row" ] && { printf '%s\n' "$row"; return 0; }
    done
    return 1
}

mr_row_for_number() {
    local out row
    out="$(ci_access_merge_request "$1" "${2:-}" 2>/dev/null)" || return 1
    row="$(mr_row_of "$out")"
    [ -n "$row" ] || return 1
    printf '%s\n' "$row"
}

# mr_gitlab_access -> sets MR_GITLAB_API (the API base) and MR_GITLAB_TOKEN_NAME (the NAME of the setting holding a
# token; the value is never read here, gitlab_curl sends it). rc 1 when either is missing. Needs gitlab-api-base.sh and
# gitlab-curl.sh sourced; without them it answers rc 1.
mr_gitlab_access() {
    MR_GITLAB_API=""; MR_GITLAB_TOKEN_NAME=""
    command -v gitlab_api_base >/dev/null 2>&1 && command -v gitlab_pick_token >/dev/null 2>&1 || return 1
    MR_GITLAB_API="$(gitlab_api_base STORY_GITLAB_API 2>/dev/null)" || MR_GITLAB_API=""
    gitlab_pick_token MR_GITLAB_TOKEN_NAME "${KYKLOS_STORY_TOKEN_ENV:-}" "${STORY_GITLAB_TOKEN_ENV:-}" "${KYKLOS_ISSUES_TOKEN_ENV:-}" GITLAB_TOKEN KYKLOS_ISSUES_TOKEN
    [ -n "$MR_GITLAB_API" ] && [ -n "$MR_GITLAB_TOKEN_NAME" ]
}

# mr_origin_project_path <repo-dir> [api-base] -> the URL-encoded "group/sub/project" path of the repository's origin
# remote (an https, ssh or scp-style address, credentials and a trailing .git dropped); rc 1 when there is no readable
# origin. With <api-base>, the origin must live on that GitLab's host (rc 1 otherwise): a mirror on another host may
# carry the same path for an unrelated project, whose settings say nothing about this repository.
# [CySec] The path is URL-encoded before it reaches a request URL (CWE-74).
mr_origin_project_path() {
    local url path host api_host
    url="$(git -C "${1:-}" remote get-url origin 2>/dev/null)" || return 1
    case "$url" in
        *://*) path="${url#*://}"; host="${path%%/*}"; path="${path#*/}" ;;
        *@*:*) host="${url%%:*}"; path="${url#*:}" ;;
        *) return 1 ;;
    esac
    if [ -n "${2:-}" ]; then
        host="${host##*@}"; host="${host%%:*}"
        api_host="${2#*://}"; api_host="${api_host%%/*}"; api_host="${api_host##*@}"; api_host="${api_host%%:*}"
        [ -n "$host" ] && [ "$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$api_host" | tr '[:upper:]' '[:lower:]')" ] || return 1
    fi
    path="${path%.git}"; path="${path%/}"
    [ -n "$path" ] || return 1
    jq -rn --arg p "$path" '$p|@uri'
}

# mr_repo_has_no_ci <repo-dir> [ref] -> rc 0 when the repository runs no CI pipeline for <ref>. The pipeline file is
# the one GitLab is told to use (the project's ci_config_path, read from GitLab by the origin's project path), else
# .gitlab-ci.yml: a configuration held in another project (file@group/project, a URL) counts as CI, as does a project
# whose CI/CD cannot be read when the repository itself carries .gitlab-ci.yml. When GitLab cannot be asked (no token,
# no origin, an origin on another host) the answer falls back to the local .gitlab-ci.yml alone. When GitLab is asked
# and gives no readable project (a timeout, an error, not JSON) the repository counts as having CI: the project's
# ci_config_path may name a pipeline held elsewhere, which the local tree cannot show.
# [RiskMitigation RA-01] An unknown CI state never reads as "no CI", so a slow or failing GitLab never lifts the
# "merges itself" rule (CWE-636, not failing securely).
mr_repo_has_no_ci() {
    local r="${1:-}" ref="${2:-HEAD}" path=.gitlab-ci.yml proj rc
    [ -n "$r" ] || return 1
    git -C "$r" rev-parse --verify -q "$ref^{commit}" >/dev/null 2>&1 || ref=HEAD
    git -C "$r" rev-parse --verify -q "$ref^{commit}" >/dev/null 2>&1 || return 1
    if command -v gitlab_curl >/dev/null 2>&1 && mr_gitlab_access && proj="$(mr_origin_project_path "$r" "$MR_GITLAB_API")"; then
        path="$(mr_project_pipeline_file "$MR_GITLAB_API" "$MR_GITLAB_TOKEN_NAME" "$proj")"; rc=$?
        case "$rc" in 0) ;; 3) return 0 ;; *) return 1 ;; esac
    fi
    ! git -C "$r" cat-file -e "$ref:$path" 2>/dev/null
}

# mr_project_pipeline_file <api> <token-setting> <project> -> prints the in-repository pipeline file GitLab uses for
# <project> (its ci_config_path, default .gitlab-ci.yml); rc 0. rc 3: CI/CD is switched off for the project. rc 1: the
# project cannot be read (a timeout, an error, not a project) or its configuration is held elsewhere
# (file@group/project, a URL); both mean "counts as CI". The one reading of a project's CI settings, for both lookups.
mr_project_pipeline_file() {
    local api="$1" tok="$2" proj="$3" pj path
    [ -n "$api" ] && [ -n "$tok" ] && [ -n "$proj" ] || return 1
    command -v gitlab_curl >/dev/null 2>&1 || return 1
    pj="$(gitlab_curl "$tok" -s --max-time 12 "$api/projects/$proj" 2>/dev/null)" || return 1
    printf '%s' "$pj" | json_test '.id' || return 1
    [ "$(printf '%s' "$pj" | jq -r '.builds_access_level // empty' 2>/dev/null)" = disabled ] && return 3
    path="$(printf '%s' "$pj" | jq -r '.ci_config_path // empty' 2>/dev/null)"
    [ -n "$path" ] || path=.gitlab-ci.yml
    case "$path" in *@*|*://*) return 1 ;; esac
    printf '%s' "$path"
}

# [RiskMitigation RA-01] Any answer that cannot be read, and a configuration held elsewhere, counts as CI, so a misread
# never lifts the "merges itself" rule (CWE-841). [RiskMitigation RA-02] The token travels by setting name through
# gitlab_curl, never on a command line. [RiskMitigation RA-03] [CySec] The path and ref taken from GitLab or the command
# are URL-encoded before they reach a request URL (CWE-74, injection into a downstream request).
# mr_project_has_no_ci: CI/CD switched off for the project, or its CI configuration file (ci_config_path, default
# .gitlab-ci.yml) absent on <ref>. A configuration held elsewhere (file@group/project, a URL) counts as CI.
mr_project_has_no_ci() {
    local api="$1" tok="$2" proj="$3" ref="$4" path code rc
    path="$(mr_project_pipeline_file "$api" "$tok" "$proj")"; rc=$?
    case "$rc" in 0) ;; 3) return 0 ;; *) return 1 ;; esac
    [ -n "$ref" ] || return 1
    # GitLab answers 404 for the file both when it is absent and when the ref does not exist: confirm the ref first.
    code="$(gitlab_curl "$tok" -s -o /dev/null -w '%{http_code}' --max-time 12 \
        "$api/projects/$proj/repository/commits/$(jq -rn --arg r "$ref" '$r|@uri')" 2>/dev/null)"
    [ "$code" = 200 ] || return 1
    code="$(gitlab_curl "$tok" -s -o /dev/null -w '%{http_code}' --max-time 12 \
        "$api/projects/$proj/repository/files/$(jq -rn --arg p "$path" '$p|@uri')?ref=$(jq -rn --arg r "$ref" '$r|@uri')" 2>/dev/null)"
    [ "$code" = 404 ]
}
