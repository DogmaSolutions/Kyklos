#!/usr/bin/env bash
# has-doc-conventions.sh — the mechanical interview trigger for the update-docs skill.
#
# Decides whether the project has already been onboarded: exit 0 if a "## Documentation conventions" section
# is present in the given CLAUDE.md (skip the first-run interview, just read it), exit 1 if absent (run the
# interview, then persist the section). Makes "interview once, then never again" a systematic, testable gate
# rather than a soft judgement. bash + grep only.
#
# Usage: has-doc-conventions.sh [path/to/CLAUDE.md]   (default: ./CLAUDE.md)
set +e -uo pipefail
FILE="${1:-CLAUDE.md}"
HEADING='^##[[:space:]]+Documentation conventions[[:space:]]*$'

if [ ! -f "$FILE" ]; then
  echo "absent: $FILE not found -> run the first-run interview" >&2
  exit 1
fi
if grep -qE "$HEADING" "$FILE"; then
  echo "present: '## Documentation conventions' in $FILE -> skip interview, read it"
  exit 0
fi
echo "absent: no '## Documentation conventions' in $FILE -> run the first-run interview" >&2
exit 1
