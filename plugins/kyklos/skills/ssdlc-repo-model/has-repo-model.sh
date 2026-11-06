#!/usr/bin/env bash
# has-repo-model.sh — the mechanical interview trigger for the ssdlc-repo-model skill.
#
# Decides whether the project has already DECLARED its repository model: exit 0 if a
# "## Repository model" section is present in the given CLAUDE.md (skip the first-run interview,
# just read it); exit 1 if absent (run the interview, then persist the section + the vars). Makes
# "declare the model once, then reuse" a systematic, testable gate rather than a soft judgement,
# mirroring has-risk-criteria.sh / has-doc-conventions.sh. bash + grep only.
#
# Any guard that needs the model may call this gate to know whether it has been declared; an UNSET
# model always means "not declared -> fall back to gitflow (back-compat)", never a block.
#
# Usage: has-repo-model.sh [path/to/CLAUDE.md]   (default: ./CLAUDE.md)
set +e -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --authorize-interview: pass this ONLY when the ssdlc-repo-model skill itself runs the gate to LAUNCH the
# first-run interview (never a guard's passive "is it declared?" call). On an interview-needed outcome it
# authorizes the next AskUserQuestion through the one-shot ask-user override, so the required interview is not
# blocked by the ask-user-guard. Without the flag the gate is side-effect-free (a guard can detect freely).
AUTHORIZE=0
while [ "$#" -gt 0 ]; do case "$1" in --authorize-interview) AUTHORIZE=1; shift ;; *) break ;; esac; done
FILE="${1:-CLAUDE.md}"
HEADING='^##[[:space:]]+Repository model[[:space:]]*$'

# _authorize_if_asked - set the one-shot, scoped ask-user override for an interview-needed outcome (only when the
# caller asked, via --authorize-interview). The helper message goes to stderr so this gate stdout stays clean.
_authorize_if_asked() {
  [ "$AUTHORIZE" = 1 ] || return 0
  bash "$HERE/../../hooks/lib/authorize-user-interview.sh" "$(dirname "$FILE")" 1>&2 || true
}

if [ ! -f "$FILE" ]; then
  echo "absent: $FILE not found -> run the first-run interview" >&2
  _authorize_if_asked
  exit 1
fi
# Strip fenced ``` code blocks before the heading match, so a '## Repository model' shown INSIDE an example
# code block (documentation of the format) is NOT mistaken for a real declaration.
if awk '/^```/{f=!f; next} !f' "$FILE" | grep -cE "$HEADING" >/dev/null; then
  echo "present: '## Repository model' in $FILE -> skip interview, read it"
  exit 0
fi
# Topology-aware: a declared KYKLOS_PROJECT_TOPOLOGY in the sibling .claude/standards.env also counts as
# declared (topology-declare.sh writes both, but a repo carrying only the env line is still declared).
_envf="$(dirname "$FILE")/.claude/standards.env"
if [ -f "$_envf" ] && grep -qE '^KYKLOS_PROJECT_TOPOLOGY=' "$_envf"; then
  echo "present: KYKLOS_PROJECT_TOPOLOGY in $_envf -> declared (topology), skip interview"
  exit 0
fi
echo "absent: no '## Repository model' in $FILE and no KYKLOS_PROJECT_TOPOLOGY -> run the first-run interview" >&2
_authorize_if_asked
exit 1
