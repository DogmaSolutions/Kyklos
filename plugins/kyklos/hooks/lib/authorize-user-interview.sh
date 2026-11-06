#!/usr/bin/env bash
# authorize-user-interview.sh - authorize the NEXT AskUserQuestion as a legitimate, kyklos-launched interview.
#
# The SINGLE sanctioned seam for a Kyklos skill that MUST interview the developer (the repository-topology
# question, an i18n-technique choice, ...) so that question passes the ask-user-guard - instead of each skill
# hand-crafting an override, or the agent being told to defer a decision Kyklos itself demanded.
#
# It sets the `ask-user-ok` one-shot, scoped override (through override-marker.sh, the one override mechanism) for
# the target project's scope. The ask-user-guard CONSUMES it on the first question it would otherwise block, and
# nothing else: a later, unrelated deferral question is still blocked. So this allows exactly ONE kyklos-initiated
# ask and never loosens the guard's default.
#
# Usage: authorize-user-interview.sh [dir]   (dir: the project the interview is for; default: the current folder)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
DIR="${1:-$(pwd)}"
# Delegate to the ONE override mechanism; it computes the repo-scope and the expiry. Reusing it (never a second
# bespoke marker) is why an authorized interview and a guard's override can never drift.
exec bash "$HERE/override-marker.sh" set ask-user-ok "$DIR"
