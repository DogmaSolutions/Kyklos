#!/usr/bin/env bash
# require-lib.sh -- load a shell library and confirm it loaded completely.
#
# A library loaded with `[ -f lib ] && . lib` fails silently: a syntax error stops the load part-way, the functions
# after it stay undefined, and every check written as `command -v fn && check` is then skipped. For a close gate that
# means a broken library closes stories it should refuse. require_lib makes that failure visible so the caller can
# refuse instead.

# require_lib PATH [NAME...] -> load PATH into the caller's shell; return 0 when the file exists, loading it succeeded
# and every NAME is defined afterwards: a plain NAME is a function, `var:NAME` a variable that must be set and not
# empty. Otherwise print the reason on stderr, keep it in REQUIRE_LIB_PROBLEM (for a caller that must quote it in a
# refusal while staying in its own shell) and return 1. REQUIRE_LIB_PROBLEM is cleared on success.
# Top-level plain assignments in PATH stay global (bash only makes `local`/`declare` without -g local to this function).
# [RiskMitigation RA-03] a library that stops loading part-way is reported, so a close gate refuses instead of skipping its check.
require_lib() {
  local _rl_lib="$1" _rl_fn _rl_rc _rl_var
  shift
  REQUIRE_LIB_PROBLEM=""
  [ -f "$_rl_lib" ] || { _require_lib_fail "cannot load $_rl_lib: the file is missing"; return 1; }
  # shellcheck source=/dev/null
  . "$_rl_lib"; _rl_rc=$?
  [ "$_rl_rc" -eq 0 ] || { _require_lib_fail "cannot load $_rl_lib: loading it failed (exit $_rl_rc)"; return 1; }
  for _rl_fn in "$@"; do
    case "$_rl_fn" in
      var:*) _rl_var="${_rl_fn#var:}"
             [ -n "${!_rl_var:-}" ] 2>/dev/null \
               || { _require_lib_fail "cannot load $_rl_lib: $_rl_var is not set after loading"; return 1; } ;;
      *)     declare -F "$_rl_fn" >/dev/null \
               || { _require_lib_fail "cannot load $_rl_lib: $_rl_fn is not defined after loading"; return 1; } ;;
    esac
  done
  return 0
}
# shellcheck disable=SC2034  # REQUIRE_LIB_PROBLEM is read by the caller (lib/guard-prologue.sh)
_require_lib_fail() { REQUIRE_LIB_PROBLEM="$1"; printf '%s\n' "$1" >&2; }

# require_story_seam SEAM [FUNCTION...] -> load the story-backend seam (skills/ssdlc-story/lib/story-backend.sh) into
# the caller's shell. Return 0 only when require_lib succeeds for SEAM and FUNCTION... AND the seam recorded no library
# it failed to load: the seam keeps loading past such a failure and records it in STORY_LIB_LOAD_FAILED, so its own exit
# status cannot tell. Otherwise return 1 with the reason in STORY_SEAM_PROBLEM ("cannot load <what> completely"). A
# STORY_LIB_LOAD_FAILED inherited from the environment is cleared first, so only this load is judged. Every caller that
# loads the seam (the story tool and the hooks) goes through here, so none of them can miss the recorded failure.
require_story_seam() {
  local _rss_seam="$1" _rss_rc
  shift
  STORY_LIB_LOAD_FAILED=""; STORY_SEAM_PROBLEM=""
  require_lib "$_rss_seam" "$@"; _rss_rc=$?
  if [ -n "${STORY_LIB_LOAD_FAILED:-}" ]; then
    STORY_SEAM_PROBLEM="cannot load $STORY_LIB_LOAD_FAILED completely"; return 1
  fi
  [ "$_rss_rc" -eq 0 ] || { STORY_SEAM_PROBLEM="cannot load $_rss_seam completely"; return 1; }
  return 0
}
