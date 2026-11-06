#!/usr/bin/env bash
# validate-scenario.sh <scenario.md> [workspace-root] — thin wrapper over validate-scenario.py so callers
# (the scenario gate, run-all.sh, a project's local check) invoke the linter uniformly. Exit 0 = valid.
set +e +u +o pipefail   # declared, never inherited from a caller that exports SHELLOPTS
exec python3 "$(dirname "$0")/validate-scenario.py" "$@"
