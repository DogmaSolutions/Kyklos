#!/usr/bin/env bash
# kyklos-piped-script-guard.sh (Kyklos) - PreToolUse Bash. Refuses a script fetched from the network and run in the
# same command without being saved first: `curl <address> | sh`, `wget -qO- <address> | bash`, `bash <(curl ...)`,
# `sh -c "$(curl ...)"`, `curl ... | python3 -`, `curl ... | tr -d '\r' | bash`, `curl ... 2>&1 | bash`, also behind sudo,
# su -c, env, a shell's -c or PowerShell's -Command.
#
# Why: a piped script runs whatever the address serves at that moment, unread, inside a container that can reach its
# project's tokens; a mistyped or compromised address runs code with that access. Downloading to a file first, reading
# it, then running it costs one step and makes the script reviewable. Package installs (apt, pip, npm, gem, dotnet tool,
# cargo, go) come from a package registry and are NOT refused, nor is a download saved to a file, nor a download piped
# into a program that reads it as data (`curl ... | jq .`).
#
# How: lib/piped-script.sh reads the command the way the shell does (the shared normaliser in lib/issue-api-detect.sh)
# and reports each download whose output reaches a shell or interpreter. A command word computed when the command runs
# is refused only when a download is piped into it. What it does not catch: plugin README.
#
# Default ON. The only off switch: KYKLOS_PIPED_SCRIPT_GUARD=off (environment or .claude/standards.env); every use is
# audited. Wired: PreToolUse, matcher Bash.
set +e -uo pipefail

_PS_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# [CySec] CWE-636 "Not Failing Securely": a library that does not load refuses a command naming a download tool,
# naming the broken install, instead of letting it through unread.
_PS_LOAD_PROBLEM=""
. "$_PS_HERE/lib/require-lib.sh" 2>/dev/null
if ! { declare -F require_lib >/dev/null && require_lib "$_PS_HERE/lib/piped-script.sh" piped_script_find 2>/dev/null; }; then
    _PS_LOAD_PROBLEM="${REQUIRE_LIB_PROBLEM:-cannot load $_PS_HERE/lib/require-lib.sh}"
elif ! require_lib "$_PS_HERE/lib/issue-api-detect.sh" iad_normalize_cmd var:IAD_NORMALISER_BROKEN 2>/dev/null; then
    # piped_script_find reports a command naming a download tool as unreadable when the normaliser is missing.
    unset -f iad_normalize_cmd 2>/dev/null
fi
. "$_PS_HERE/lib/standards-env.sh" 2>/dev/null || true
. "$_PS_HERE/lib/escape-audit.sh" 2>/dev/null || true

_ps_download_words='(curl|wget|iwr|irm|invoke-webrequest|invoke-restmethod|downloadstring|downloadfile|webclient)'
INPUT="$(cat || true)"
# [CySec] CWE-636 "Not Failing Securely": without jq the command cannot be read; one that names a download tool is
# refused, naming jq.
if ! command -v jq >/dev/null 2>&1; then
    if [[ "${INPUT,,}" =~ $_ps_download_words ]]; then
        printf '[kyklos] piped-script guard: REFUSED - jq (the JSON reader) is not installed, so this command, which names a download tool, cannot be checked. Restore jq in the container image.\n' >&2
        exit 2
    fi
    exit 0
fi
CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
[ -n "$CMD" ] || exit 0
HOOK_CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-${HOOK_CWD:-$PWD}}"

if [ -n "$_PS_LOAD_PROBLEM" ]; then
    [[ "${CMD,,}" =~ $_ps_download_words ]] || exit 0
    FOUND="$(printf 'broken\t%s' "$_PS_LOAD_PROBLEM")"
else
    # [CySec] Prevents CWE-494 "Download of Code Without Integrity Check": a script fetched from the network and handed
    # straight to a shell or interpreter runs unread; it must be saved to a file, read, then run.
    FOUND="$(piped_script_find "$CMD")"
fi
[ -n "$FOUND" ] || exit 0

# [RiskMitigation RA-03] Default on; the one off switch is audited (CWE-1188, insecure default).
_switch="${KYKLOS_PIPED_SCRIPT_GUARD:-}"
[ -n "$_switch" ] || _switch="$(standards_env_value "$PROJECT_DIR/.claude/standards.env" KYKLOS_PIPED_SCRIPT_GUARD 2>/dev/null)"
# shellcheck source=lib/control-switch.sh
. "$_PS_HERE/lib/control-switch.sh" 2>/dev/null || true   # kyklos_control_off: the one control-switch reader
if kyklos_control_off "$_switch"; then
    command -v escape_audit >/dev/null 2>&1 && escape_audit "piped-script-guard-off" "found=$(printf '%s' "$FOUND" | tr '\t\n' ': ' | cut -c1-300)" 2>/dev/null
    exit 0
fi

reasons=""
while IFS=$'\t' read -r kind detail; do
    [ -n "$kind" ] || continue
    case "$kind" in
        script) reasons+="  - the download from $detail is run as code in the same command, unread"$'\n' ;;
        computed) reasons+="  - a download is piped into the command $detail, whose name is computed when the command runs, so what would run the download cannot be read"$'\n' ;;
        *) reasons+="  - $detail (broken install: reinstall or repin the kyklos plugin)"$'\n' ;;
    esac
done <<< "$FOUND"

cat >&2 <<EOF
[kyklos] piped-script guard: REFUSED - this command runs a script fetched from the network without saving it first:
${reasons}A piped script runs whatever the address serves at that moment, unread. Download it to a file, read it, then run it:
  curl -fsSL -o /tmp/install.sh <address>    (or: wget -O /tmp/install.sh <address>)
  then read /tmp/install.sh, then: bash /tmp/install.sh
Package installs (apt, pip, npm, ...) are not affected.
Only off switch: KYKLOS_PIPED_SCRIPT_GUARD=off (audited).
EOF
exit 2
