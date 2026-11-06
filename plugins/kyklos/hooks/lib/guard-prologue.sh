#!/usr/bin/env bash
# guard-prologue.sh -- a PreToolUse guard that ends before it decides refuses the command.
#
# A guard loads its libraries into its own shell. A library that stops loading part-way is caught by require_lib, but
# one that ends the shell while it loads (`exit 0`, `exit 1`, a `trap 'exit 0' EXIT` or RETURN that fires) ends the
# GUARD itself, and a guard that exits without a decision lets the command through. The prologue arms an EXIT trap
# that prints the guard's block decision unless the guard reached a deliberate allow or block (guard_done), and
# re-arms it after every library load, so a library's own trap cannot replace it.
#
# Use, before any other library is loaded (the inline trap covers this file itself being missing or ending the shell):
#   trap '...inline block...; exit 0' EXIT
#   . "$HERE/lib/guard-prologue.sh" 2>/dev/null && guard_arm "the epic gate" || exit 0
#   guard_load "$HERE/lib/issue-api-detect.sh" var:IAD_CLIENT_RE iad_normalize_cmd ... || exit 0   # refused by the trap
#   ...
#   guard_done                       # every deliberate allow and every printed block ends this way
# A library cannot replace the trap either: while the guard runs, `trap` ignores EXIT and RETURN (see trap below).
# Scope: this protects against an accidental broken install, not a hostile library (one that redefines these
# functions, or calls `builtin trap`, can still end the guard). The prologue itself is the root: the inline trap in
# each guard covers it being missing or ending the shell, not it replacing that trap.
# [CySec] Fails closed when a security check cannot run (CWE-636 Not Failing Securely). [RiskMitigation RA-03]

_GUARD_PROLOGUE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

# shellcheck disable=SC2120  # WHAT is optional: a re-arm after a load keeps the name given first
# guard_arm WHAT -> arm (or re-arm) the EXIT trap for the guard named WHAT ("the epic gate"); clear a RETURN trap.
guard_arm() {
  _KYKLOS_GUARD_WHAT="${1:-${_KYKLOS_GUARD_WHAT:-a kyklos guard}}"
  _KYKLOS_GUARD_DECIDED="${_KYKLOS_GUARD_DECIDED:-0}"
  builtin trap - RETURN
  builtin trap _guard_on_exit EXIT
}

# trap -> while a guard runs, a library cannot replace or clear the guard's EXIT trap or set a RETURN trap: those two
# are ignored (with a note on stderr); every other trap is set as asked. The guard's own trap is set with builtin trap.
trap() {
  local _t_arg
  for _t_arg in "$@"; do
    case "$_t_arg" in
      EXIT|exit|0|SIGEXIT|RETURN|return)
        printf '[kyklos] %s: a library tried to set an %s trap; ignored so the guard still decides\n' "${_KYKLOS_GUARD_WHAT:-a kyklos guard}" "$_t_arg" >&2
        return 0 ;;
    esac
  done
  # shellcheck disable=SC2064  # the caller's own arguments are passed through unchanged
  builtin trap "$@"
}

# _guard_on_exit -> the EXIT trap: nothing when the guard decided; otherwise print the block decision and exit 0 (a
# hook's decision is read only from a 0 exit).
_guard_on_exit() {
  [ "${_KYKLOS_GUARD_DECIDED:-0}" = 1 ] && return 0
  local why="${REQUIRE_LIB_PROBLEM:-}" r
  [ -n "$why" ] || why="it ended before it decided (a library it loads ended the shell while loading)"
  r="BLOCKED (broken kyklos install): ${_KYKLOS_GUARD_WHAT:-a kyklos guard} cannot run its check: $why. Until it can, it refuses every command, because it can no longer tell a raw API write from any other command. Edit and Write still work, so a library can be repaired in place. Repair: relaunch the container so the kyklos plugin is installed again, or report the broken library to the kyklos owner."
  printf '[kyklos] %s\n' "$r" >&2
  r="${r//\\/\\\\}"; r="${r//\"/\\\"}"; r="$(printf '%s' "$r" | tr '\n\t' '  ')"
  printf '{"decision":"block","reason":"%s"}' "$r"
  _KYKLOS_GUARD_DECIDED=1
  exit 0
}

# guard_load PATH [NAME...] -> require_lib PATH NAME... (lib/require-lib.sh, loaded here first when needed), then
# re-arm the trap. Return require_lib's status; REQUIRE_LIB_PROBLEM names what failed.
guard_load() {
  local _gl_rc
  if ! declare -F require_lib >/dev/null; then
    # shellcheck source=require-lib.sh
    . "$_GUARD_PROLOGUE_DIR/require-lib.sh" 2>/dev/null
    guard_arm
    declare -F require_lib >/dev/null \
      || { REQUIRE_LIB_PROBLEM="cannot load $_GUARD_PROLOGUE_DIR/require-lib.sh"; return 1; }
  fi
  require_lib "$@" 2>/dev/null; _gl_rc=$?
  guard_arm
  return "$_gl_rc"
}

# guard_load_optional PATH [NAME...] -> guard_load for a library the guard can decide without (an audit trail, an
# override, a nicer message): a failed load returns 1 and leaves no REQUIRE_LIB_PROBLEM behind; a load that ends the
# shell is still refused by the trap.
guard_load_optional() { guard_load "$@" && return 0; REQUIRE_LIB_PROBLEM=""; return 1; }

# guard_done -> the guard decided (it allows, or it printed its block): exit 0 without the trap's block.
guard_done() { _KYKLOS_GUARD_DECIDED=1; exit 0; }

# guard_refuse -> the guard cannot decide (a library it needs did not load): print the block decision and exit 0.
guard_refuse() { _guard_on_exit; }
