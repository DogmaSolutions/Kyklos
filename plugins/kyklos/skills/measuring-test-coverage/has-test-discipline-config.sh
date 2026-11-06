#!/usr/bin/env bash
# has-test-discipline-config.sh — the mechanical interview trigger for the measuring-test-coverage skill.
# Mirrors has-risk-criteria.sh / has-doc-conventions.sh, but the config seam is `.claude/standards.env`
# (machine-read knobs) rather than a CLAUDE.md heading.
#
# Decides whether the project's Test Discipline has already been configured: exit 0 if ALL of
# COVERAGE_THRESHOLD, CRAP_THRESHOLD and MUTATION_TESTING are set to a NON-EMPTY value (skip the first-run
# interview, just use them); exit 1 if the file is missing or ANY knob is unset/blank (run the interview,
# then persist the values). MUTATION_TESTING has NO default here — a project must be ASKED once and
# explicitly persist `on|off`. When mutation testing runs at all is the mutation policy's call (see the
# measuring-test-coverage SKILL.md), not this gate's. Makes "interview once, then reuse" a systematic,
# testable gate. bash + grep only.
#
# Usage: has-test-discipline-config.sh [path/to/standards.env]   (default: ./.claude/standards.env)
set +e -uo pipefail
FILE="${1:-.claude/standards.env}"

if [ ! -f "$FILE" ]; then
  echo "absent: $FILE not found -> run the first-run Test Discipline interview" >&2
  exit 1
fi

# A knob is "set" iff a non-comment line assigns it a value that is non-empty AFTER stripping surrounding
# whitespace/quotes — so `KEY=""` and `KEY=''` count as UNSET (a `"` matched the old `[^[:space:]#]` and
# wrongly passed the interview with an empty knob). Mirrors has-build-execution.sh's normalisation.
# val KEY -> the normalised value of KEY (empty if unset). Same extraction is_set uses.
val() {
  local v
  v="$(grep -E "^[[:space:]]*(export[[:space:]]+)?$1=" "$FILE" 2>/dev/null | grep -vE "^[[:space:]]*#" | tail -1 | sed -E "s/^[[:space:]]*(export[[:space:]]+)?$1=//")"
  printf '%s' "$v" | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//'
}
is_set() { [ -n "$(val "$1")" ]; }

missing=""
for key in COVERAGE_THRESHOLD CRAP_THRESHOLD MUTATION_TESTING; do
  is_set "$key" || missing="$missing $key"
done

# MUTATION_LEVEL is required ONLY when MUTATION_TESTING=on: the Stryker level (Basic|Standard|Advanced|Complete) is
# read by the project's mutation job, so an `on` project persists it once via the interview instead of relying on
# whatever default that job applies. An `off` project needs no level — demanding it there would wrongly force the
# interview forever.
if [ "$(val MUTATION_TESTING)" = "on" ]; then
  is_set MUTATION_LEVEL || missing="$missing MUTATION_LEVEL"
fi

if [ -n "$missing" ]; then
  echo "absent: unset Test Discipline knob(s) in $FILE ->$missing -> run the first-run interview" >&2
  exit 1
fi

echo "present: COVERAGE_THRESHOLD + CRAP_THRESHOLD + MUTATION_TESTING set in $FILE -> skip interview, use them"
exit 0
