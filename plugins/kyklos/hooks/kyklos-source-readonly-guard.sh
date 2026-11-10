#!/usr/bin/env bash
# kyklos-source-readonly-guard.sh (Kyklos) — PreToolUse Bash. Refuses every COMMIT-CREATING git verb in a source that
# is declared READ-ONLY for the agent (KYKLOS_SOURCE_WORKFLOW=agent-readonly).
#
# Some projects set a rule: the agent NEVER writes history in the nested source clone — the human owner commits and
# pushes there; the agent only reads, builds and tests it. This guard makes that rule enforced by the Kyklos
# itself, so a consumer need not maintain a project-local hook (which cannot source the version-numbered plugin
# libraries and re-implements a weaker target resolver). It refuses commit / merge / rebase / cherry-pick / revert /
# am when the command's resolved target repo is an agent-readonly source. `git stash` (and any read-only verb) is
# NEVER refused, so the running-tests diagnosis procedure (stash -> run -> pop) keeps working.
#
# DEFAULT-ON: the moment a project declares a source as agent-readonly, this enforcement is active — there is no
# separate enable flag. The SINGLE greppable opt-out is KYKLOS_SOURCE_READONLY_GUARD=0. A single sanctioned
# exception uses the scoped, self-spent one-shot marker:
#   bash hooks/lib/override-marker.sh set source-readonly-ok <repo-dir>
#
# FAIL-SOFT: a POSITIVE agent-readonly resolution is the ONLY thing that blocks. Any library/parse error, an
# undeclared or non-readonly target, or a read-only verb all ALLOW (exit 0) — the guard must never false-block the
# vast majority of projects, and CI still guards the real branch. The sole fail-SAFE case is an UNDECIDABLE target
# (fed by a command substitution) in a project that HAS an agent-readonly source: the owner's rule is zero commits
# in the source, so an opaque target that might land there is refused with a disambiguation remedy.
#
# [CySec] Enforces an agent-write-exclusion poka-yoke on a declared read-only source (CWE-636 avoided: the guard
# fails SOFT on every uncertain case, SAFE only where a read-only source is positively at stake).
# Wired: PreToolUse, matcher Bash.
# [json-answer-required] Every answer this hook reads goes through the JSON reader; without it a check would exit 127
# and fall into a fail-open path, so the hook refuses by name instead (a broken install). [CySec] CWE-636
. "$(dirname "${BASH_SOURCE[0]}")/lib/json-answer.sh" 2>/dev/null
if ! command -v json_test >/dev/null 2>&1; then
    printf '{"decision":"block","reason":"BLOCKED (%s): the JSON reader hooks/lib/json-answer.sh did not load (broken install), so this check cannot run. Reinstall or repin the kyklos plugin."}\n' "$(basename "$0")"
    exit 0
fi
set +e -uo pipefail
_GD_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_GD_HERE/lib/git-cmd-detect.sh" 2>/dev/null || exit 0   # git_cmd_invokes + git_target_repo_dir (shared) — fail-soft
. "$_GD_HERE/lib/repo-role.sh"      2>/dev/null || exit 0   # repo_workflow + _rr_getkey: the SINGLE topology-fed resolver

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
_cfg="$PROJECT_DIR/.claude/standards.env"
# PARSE, never source (CWE-829): a malformed line can't execute. [RiskMitigation RA-03]
. "$_GD_HERE/lib/standards-env.sh" 2>/dev/null && load_standards_env "$_cfg" 2>/dev/null || true

# Single greppable opt-out (DEFAULT-ON). [RiskMitigation RA-04]
# shellcheck source=lib/control-switch.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/control-switch.sh" 2>/dev/null || true   # kyklos_control_off: the one control-switch reader
kyklos_control_off "${KYKLOS_SOURCE_READONLY_GUARD:-}" && exit 0

. "$_GD_HERE/lib/override-marker.sh" 2>/dev/null || true   # override_take / override_scope_of: the scoped one-shot

INPUT="$(cat || true)"
CMD="${INPUT//\\\"/\"}"
# The ACTUAL shell command (jq-extracted) — feed THIS to the command-position detector, NOT the JSON envelope (in the
# envelope a `git commit` sits inside a quoted string, correctly NOT a command position). Envelope-fallback only if
# jq is unavailable/empty. CMD (envelope) is kept for the target-dir parsing.
CMD_REAL="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"; [ -n "$CMD_REAL" ] || CMD_REAL="$CMD"
# The shell's ACTUAL working directory (hook input .cwd) — resolves a bare `git commit` (no -C/cd) to the repo it
# really runs in, rather than a possibly-inner/unset PROJECT_DIR.
HOOK_CWD="$(printf '%s' "$INPUT" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"

# Cheap pre-filter: if there is no git mention at all, nothing to do.
printf '%s' "$CMD_REAL" | grep -ciE '\bgit\b' >/dev/null || exit 0

# The commit-CREATING verbs this mode forbids in a read-only source. `stash` is DELIBERATELY absent (read-only
# diagnosis must keep working); `push` is DELIBERATELY absent (the no-push guard owns it).
_RO_VERBS="commit merge rebase cherry-pick revert am"

block() {
    local reason="$1" scope
    if command -v override_take >/dev/null 2>&1; then
        scope="$(override_scope_of "${2:-$PROJECT_DIR}" 2>/dev/null || printf '%s' "${2:-$PROJECT_DIR}")"
        if override_take source-readonly-ok "$scope" "$INPUT" 2>/dev/null; then
            echo "[kyklos] source-readonly gate: OVERRIDDEN once (source-readonly-ok spent for '$scope') — a commit-creating verb in the read-only source was allowed." >&2
            exit 0
        fi
    fi
    reason="${reason//\\/\\\\}"; reason="${reason//\"/\\\"}"; reason="$(printf '%s' "$reason" | tr '\n' ' ')"
    printf '{"decision":"block","reason":"%s"}' "$reason"
    exit 0
}

# _project_has_readonly_source -> 0 iff the container's OWN project declares an agent-readonly source (the project
# root itself, or its nested companion source dir). Used only to decide the fail-SAFE direction for an UNDECIDABLE
# target. [RiskMitigation RA-02]
_project_has_readonly_source() {
    local top srcdir
    top="$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "")"
    [ -n "$top" ] || return 1
    [ "$(repo_workflow "$top")" = "agent-readonly" ] && return 0
    srcdir="$(_rr_getkey "$top/.claude/standards.env" KYKLOS_SOURCE_DIR 2>/dev/null || true)"
    [ -n "$srcdir" ] && [ -d "$top/$srcdir" ] && [ "$(repo_workflow "$top/$srcdir")" = "agent-readonly" ] && return 0
    return 1
}

# ---- Branch-scoped exception (declared, greppable, empty by default) ----
# KYKLOS_SOURCE_READONLY_ALLOW_BRANCH=<branch or glob> + KYKLOS_SOURCE_READONLY_ALLOW_VERBS=<verb|verb...> let an
# owner-sanctioned workflow create history on ONE feature branch of the read-only source (e.g. one commit per migration
# step plus rebases). Only commit, cherry-pick and rebase can be allowed, and never on a trunk, a release or a support
# branch: a declaration that asks for more is refused loudly and the guard stays fully on. Every use is audited.
_EXC_BRANCH="${KYKLOS_SOURCE_READONLY_ALLOW_BRANCH:-}"
# One normalisation for both the validation and the use: verbs separated by |, comma or spaces -> "verb|verb".
_EXC_VERBS="$(printf '%s' "${KYKLOS_SOURCE_READONLY_ALLOW_VERBS:-}" | tr ', ' '||' | tr -s '|' | sed 's/^|//; s/|$//')"
_EXC_OK=0; _EXC_ERR=""
if [ -n "$_EXC_BRANCH" ] || [ -n "$_EXC_VERBS" ]; then
    if [ -z "$_EXC_BRANCH" ] || [ -z "$_EXC_VERBS" ]; then
        _EXC_ERR="the branch exception needs BOTH KYKLOS_SOURCE_READONLY_ALLOW_BRANCH and KYKLOS_SOURCE_READONLY_ALLOW_VERBS"
    else
        for _ev in $(printf '%s' "$_EXC_VERBS" | tr '|' ' '); do
            case "$_ev" in commit|cherry-pick|rebase) : ;;
                *) _EXC_ERR="KYKLOS_SOURCE_READONLY_ALLOW_VERBS names '$_ev': only commit, cherry-pick and rebase can be allowed (merge, revert, am and push never)"; break ;;
            esac
        done
        if [ -z "$_EXC_ERR" ]; then
            # The pattern may not reach a trunk, release or support branch (the publication paths): neither name them
            # directly (release/1.*, support/2.x) nor match one through a wildcard.
            case "$_EXC_BRANCH" in release/*|support/*|release|support)
                _EXC_ERR="KYKLOS_SOURCE_READONLY_ALLOW_BRANCH='$_EXC_BRANCH' names a release or support branch: the exception can never cover one" ;;
            esac
        fi
        if [ -z "$_EXC_ERR" ]; then
            for _tb in main master develop release/x support/x; do
                # shellcheck disable=SC2053  # the declared value IS a glob, matched on purpose
                if [[ "$_tb" == $_EXC_BRANCH ]]; then
                    _EXC_ERR="KYKLOS_SOURCE_READONLY_ALLOW_BRANCH='$_EXC_BRANCH' matches '$_tb': the exception can never cover a trunk, release or support branch"
                    break
                fi
            done
        fi
        [ -z "$_EXC_ERR" ] && _EXC_OK=1
    fi
    [ -n "$_EXC_ERR" ] && echo "[kyklos] source-readonly gate: branch exception REFUSED - $_EXC_ERR. The read-only protection stays fully on." >&2
fi
. "$_GD_HERE/lib/escape-audit.sh" 2>/dev/null || true   # escape_audit: every use of the exception leaves a trail

# _current_branch <repo> -> the branch the repo is on; during a rebase (detached HEAD) the branch being rebased.
# Prints nothing when it cannot be read, which keeps the protection on (fail-closed).
_current_branch() {
    local b f
    b="$(git -C "$1" symbolic-ref --short -q HEAD 2>/dev/null || true)"
    if [ -z "$b" ]; then
        for f in rebase-merge/head-name rebase-apply/head-name; do
            f="$(git -C "$1" rev-parse --git-path "$f" 2>/dev/null || true)"
            case "$f" in /*) : ;; *) f="$1/$f" ;; esac
            [ -f "$f" ] && { b="$(sed 's#^refs/heads/##' "$f")"; break; }
        done
    fi
    printf '%s' "$b"
}

# _exception_allows <verb> <repo> -> 0 when the declared branch exception covers this verb on the repo's current branch.
_exception_allows() {
    [ "$_EXC_OK" = 1 ] || return 1
    case "|$_EXC_VERBS|" in *"|$1|"*) : ;; *) return 1 ;; esac
    local br; br="$(_current_branch "$2")"
    [ -n "$br" ] || return 1
    # Defense in depth: whatever the pattern says, a trunk, release or support branch is never covered.
    case "$br" in main|master|develop|release/*|support/*) return 1 ;; esac
    # shellcheck disable=SC2053  # the declared value IS a glob, matched on purpose
    [[ "$br" == $_EXC_BRANCH ]] || return 1
    command -v escape_audit >/dev/null 2>&1 && escape_audit "source-readonly-allow-branch" "verb=$1 branch=$br repo=$2" 2>/dev/null || true
    echo "[kyklos] source-readonly gate: 'git $1' allowed on '$br' by the declared branch exception (audited)." >&2
    return 0
}

RO_HELP="This source is declared agent-readonly (KYKLOS_SOURCE_WORKFLOW=agent-readonly): the agent does not create history here — the owner commits and pushes. Read-only verbs and 'git stash' are fine. For a single sanctioned exception: bash \$OVERRIDE_MARKER_CLI set source-readonly-ok <repo-dir>."

for _v in $_RO_VERBS; do
    git_cmd_invokes "$CMD_REAL" "$_v" || continue
    _tgt="$(git_target_repo_dir "$CMD" "$HOOK_CWD" "$PROJECT_DIR" "$_v" 2>/dev/null || echo "")"
    if [ "$_tgt" = "__UNDECIDABLE__" ]; then
        # Fail-SAFE only where a read-only source is actually at stake: the target is opaque (a command
        # substitution), so it MIGHT land in the read-only source. [RiskMitigation RA-02]
        if _project_has_readonly_source; then
            block "Refusing '$_v': its target repo is UNDECIDABLE (fed by a command substitution), and this project declares a read-only source, so the guard cannot prove the commit does not land there and fails safe. Re-run with an explicit, literal target, e.g. git -C <repo-dir> $_v. $RO_HELP" "$PROJECT_DIR"
        fi
        continue
    fi
    [ -n "$_tgt" ] || continue
    if [ "$(repo_workflow "$_tgt" 2>/dev/null || echo "")" = "agent-readonly" ]; then
        _exception_allows "$_v" "$_tgt" && continue
        block "Refusing 'git $_v' in '$_tgt': it is an agent-readonly source. $RO_HELP${_EXC_ERR:+ (A branch exception is declared but REFUSED: $_EXC_ERR.)}" "$_tgt"
    fi
done

exit 0
