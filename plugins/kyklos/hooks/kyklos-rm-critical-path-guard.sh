#!/usr/bin/env bash
# kyklos-rm-critical-path-guard.sh (Kyklos) - PreToolUse Bash. Refuses AT ONCE an rm/rmdir on a critical path.
#
# Why: Claude Code's built-in "Dangerous rm operation on critical path" check asks for approval on such commands and
# nothing turns it off (bypass mode, allow rules, a hook returning allow and the sandbox all leave it on). An agent
# working unattended waits two minutes for an answer that never comes, the command is denied, and after three such
# denials every later one is denied at once. This guard refuses the same forms immediately (exit 2) and names the
# safe way to do the same thing, so the agent rewrites the command instead of stalling. It errs on the side of
# refusing: it must never let through a form the built-in check would stop on.
#
# Critical forms (the judgement lives in lib/rm-critical-path.sh): "/" or a direct child of it; the home directory;
# the working directory or any parent of it; a glob under an additional working directory; a glob or a trailing slash
# directly under a shell variable ("$DIR"/*), or a variable followed by a common top-level name ("$P/usr"); a variable
# assigned from $(pwd) or $(git rev-parse --show-toplevel); a recursive target that is only command-substitution
# output; globs ending a path at the root, a root child, home or the working directory. Nested forms are read too:
# ( rm ... ), $( rm ... ), backticks, bash -c "...", eval, and wrappers such as sudo or env.
#
# Default ON. The only off switch: KYKLOS_RM_CRITICAL_PATH_GUARD=off (environment or .claude/standards.env); every
# use is audited. Wired: PreToolUse, matcher Bash.
set +e -uo pipefail

_RG_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_RG_HERE/lib/rm-critical-path.sh"
. "$_RG_HERE/lib/standards-env.sh"
. "$_RG_HERE/lib/escape-audit.sh" 2>/dev/null || true

INPUT="$(cat || true)"
CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
[ -n "$CMD" ] || CMD="${INPUT//\\\"/\"}"
[ -n "$CMD" ] || exit 0
HOOK_CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-}"

# Additional working directories Claude Code was given through settings (permissions.additionalDirectories).
_extra=""
for _f in "${HOME:-}/.claude/settings.json" "${PROJECT_DIR:+$PROJECT_DIR/.claude/settings.json}" "${PROJECT_DIR:+$PROJECT_DIR/.claude/settings.local.json}"; do
    [ -n "$_f" ] && [ -f "$_f" ] || continue
    _extra+="$(jq -r '.permissions.additionalDirectories[]? // empty' "$_f" 2>/dev/null)"$'\n'
done

RMC_CWD="${HOOK_CWD:-$PWD}" RMC_PROJECT_DIR="$PROJECT_DIR" RMC_EXTRA_DIRS="$_extra"
export RMC_CWD RMC_PROJECT_DIR RMC_EXTRA_DIRS
rm_critical_check "$CMD" || exit 0

# [RiskMitigation RA-02] Default on; the one off switch is audited (CWE-1188, insecure default).
_switch="${KYKLOS_RM_CRITICAL_PATH_GUARD:-}"
[ -n "$_switch" ] || _switch="$(standards_env_value "${PROJECT_DIR:-${HOOK_CWD:-$PWD}}/.claude/standards.env" KYKLOS_RM_CRITICAL_PATH_GUARD)"
# shellcheck source=lib/control-switch.sh
. "$_RG_HERE/lib/control-switch.sh" 2>/dev/null || true   # kyklos_control_off: the one control-switch reader
if kyklos_control_off "$_switch"; then
    # Audited only when the guard would have refused (the reason names the target path, never the whole command).
    command -v escape_audit >/dev/null 2>&1 && escape_audit "rm-critical-path-guard-off" "reason=$RMC_REASON" 2>/dev/null
    exit 0
fi

cat >&2 <<EOF
[kyklos] rm critical-path guard: REFUSED - $RMC_REASON.
Claude Code stops every rm/rmdir on a critical path for an approval nobody gives in an unattended session (it waits two minutes, then denies; after three denials it denies all at once). Rewrite the command in a safe form:
  - a git worktree: git worktree remove --force <literal path>, then git worktree prune;
  - one literal, full path per call (rm -rf /tmp/work/build), never a glob, a trailing slash, "." or "..";
  - a variable: "\${D:?}/name" (the :? stops on an empty D), never "\$D"/* or "\$D"/;
  - a command substitution: run it first, then remove the literal paths it printed.
Only off switch: KYKLOS_RM_CRITICAL_PATH_GUARD=off (audited).
EOF
exit 2
