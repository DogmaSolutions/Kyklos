#!/usr/bin/env bash
# has-build-execution.sh — the mechanical interview trigger for the running-tests BUILD_EXECUTION knob.
# Mirrors has-test-discipline-config.sh, but gates a SINGLE knob that has NO default: BUILD_EXECUTION.
#
# BUILD_EXECUTION declares HOW this project builds/tests:
#   bridge = every build/test runs on the real host via the KyklosBridge (a local `dotnet build`/`test` is
#            forbidden — it does not see the host SDK and fails on host-only target frameworks).
#   local  = builds/tests run locally with `dotnet` in the container.
# There is NO default: a project declares it once, in its KyklosLauncher configuration (which passes it into the
# session's environment) or by persisting bridge|local to .claude/standards.env. The shared reader
# (hooks/lib/build-execution.sh) reads the environment first, then the file, as the build-execution guard does.
#
# Decides whether the knob has already been configured: exit 0 if BUILD_EXECUTION is set to a VALID value
# (bridge|local) — skip the first-run interview, just use it; exit 1 if neither the environment nor the file sets it,
# it is blank, or the value is not one of bridge|local (run the interview, then persist the value). Makes
# "interview once, then reuse" a systematic, testable gate. bash + grep only.
#
# Usage: has-build-execution.sh [path/to/standards.env]   (default: ./.claude/standards.env)
set +e -uo pipefail
FILE="${1:-.claude/standards.env}"
. "$(dirname "${BASH_SOURCE[0]}")/../../hooks/lib/build-execution.sh"

source_of="$(build_execution_source "$FILE")"
if [ "$source_of" = none ]; then
  echo "absent: BUILD_EXECUTION is not in the environment and $FILE was not found -> run the first-run BUILD_EXECUTION interview" >&2
  exit 1
fi

where="$FILE"
[ "$source_of" = environment ] && where="the session's environment"
value="$(build_execution_raw "$FILE")"

case "$value" in
  bridge|local)
    echo "present: BUILD_EXECUTION=$value in $where -> skip interview, use it"
    exit 0 ;;
  "")
    echo "absent: BUILD_EXECUTION unset/blank in $where -> run the first-run interview (no default)" >&2
    exit 1 ;;
  *)
    echo "absent: BUILD_EXECUTION='$value' in $where is not one of bridge|local -> run the first-run interview" >&2
    exit 1 ;;
esac
