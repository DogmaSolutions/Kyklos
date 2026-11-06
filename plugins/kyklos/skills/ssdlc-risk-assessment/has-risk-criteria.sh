#!/usr/bin/env bash
# has-risk-criteria.sh — the mechanical interview trigger for the ssdlc-risk-assessment skill.
# Exit 0 if a "## Risk assessment criteria" section is present in the given CLAUDE.md (skip the first-run
# interview, just read it); exit 1 if absent (run the interview, then persist the section). Makes
# "interview once, then reuse" a systematic, testable gate. bash + grep only.
#
# Usage: has-risk-criteria.sh [path/to/CLAUDE.md]   (default: ./CLAUDE.md)
set +e -uo pipefail
FILE="${1:-CLAUDE.md}"
HEADING='^##[[:space:]]+Risk assessment criteria[[:space:]]*$'

if [ ! -f "$FILE" ]; then
  echo "absent: $FILE not found -> run the first-run interview" >&2
  exit 1
fi
if grep -qE "$HEADING" "$FILE"; then
  echo "present: '## Risk assessment criteria' in $FILE -> skip interview, read it"
  exit 0
fi
echo "absent: no '## Risk assessment criteria' in $FILE -> run the first-run interview" >&2
exit 1
