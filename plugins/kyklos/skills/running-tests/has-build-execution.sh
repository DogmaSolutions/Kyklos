#!/usr/bin/env bash
# has-build-execution.sh — the mechanical interview trigger for the running-tests BUILD_EXECUTION knob.
# Mirrors has-test-discipline-config.sh, but gates a SINGLE knob that has NO fleet default: BUILD_EXECUTION.
#
# BUILD_EXECUTION declares HOW this project builds/tests:
#   bridge = every build/test runs on the real host via the KyklosBridge (a local `dotnet build`/`test` is
#            forbidden — it does not see the host SDK and fails on host-only target frameworks).
#   local  = builds/tests run locally with `dotnet` in the container.
# There is NO default: a project must be ASKED once and explicitly persist bridge|local to .claude/standards.env.
#
# Decides whether the knob has already been configured: exit 0 if BUILD_EXECUTION is set to a VALID value
# (bridge|local) — skip the first-run interview, just use it; exit 1 if the file is missing, the knob is
# unset/blank, or the value is not one of bridge|local (run the interview, then persist the value). Makes
# "interview once, then reuse" a systematic, testable gate. bash + grep only.
#
# Usage: has-build-execution.sh [path/to/standards.env]   (default: ./.claude/standards.env)
set +e -uo pipefail
FILE="${1:-.claude/standards.env}"

if [ ! -f "$FILE" ]; then
  echo "absent: $FILE not found -> run the first-run BUILD_EXECUTION interview" >&2
  exit 1
fi

# Read the last non-comment assignment of BUILD_EXECUTION (the value the hooks' `source` would end with),
# then trim surrounding whitespace/quotes so `bridge`, `"bridge"` and `bridge  ` all normalise identically.
value="$(grep -E "^[[:space:]]*(export[[:space:]]+)?BUILD_EXECUTION=" "$FILE" | grep -vE "^[[:space:]]*#" | tail -1 | sed -E 's/^[[:space:]]*(export[[:space:]]+)?BUILD_EXECUTION=//')"
value="${value%%#*}"
value="$(printf '%s' "$value" | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//')"

case "$value" in
  bridge|local)
    echo "present: BUILD_EXECUTION=$value in $FILE -> skip interview, use it"
    exit 0 ;;
  "")
    echo "absent: BUILD_EXECUTION unset/blank in $FILE -> run the first-run interview (no default)" >&2
    exit 1 ;;
  *)
    echo "absent: BUILD_EXECUTION='$value' in $FILE is not one of bridge|local -> run the first-run interview" >&2
    exit 1 ;;
esac
