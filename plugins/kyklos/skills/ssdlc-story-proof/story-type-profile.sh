#!/usr/bin/env bash
# story-type-profile.sh — print the Quality-Dimension profile for a story TYPE.
#
# ADVISORY, not a hard gate: it pre-seeds the `## Proof` table and focuses attention on the dimensions that
# actually matter for this kind of change, instead of padding 8-10 rows with NOT_PERTINENT. The story-proof
# gate still requires every row to be PROVEN or (justified) NOT_PERTINENT — this just tells you which rows are
# expected to be live. A story with no `Story-Type:` falls back to the full set (the ALL= rows plus Adversarial
# Review while its gate is on).
#
# Usage: story-type-profile.sh <type>
#   types: library | service | ci (alias: ci-template) | infra | plugin | docs | test
#   unknown/empty -> the full set (no profile narrowing).
#
# Note: Documentation, Poka-Yoke, Non-Duplication and i18n are pertinent in EVERY profile. Risk Assessment is pertinent
# in every profile EXCEPT the no-risk-surface types `docs` and `test`: a pure documentation or
# test-only change has no risk DELTA, so RA lands in LIKELY_N/A and may be marked NOT_PERTINENT with the stock
# profile reason — WITHOUT a user waiver — while every OTHER type still requires the always-assess register/waiver.
# The row stays in the table (the canonical set is unchanged); only its default verdict + the waiver requirement
# differ. bash + grep only; runs in any ephemeral container.
set +e -uo pipefail

ALL="Completeness|Feature Availability|Input Validation|Robustness|Resilience|Security Posture|Defense in Depth|Observability|Thread Safety|Configurability|Test Discipline|Non-Duplication|Documentation|Poka-Yoke|Risk Assessment|i18n"

type="$(printf '%s' "${1:-}" | tr 'A-Z' 'a-z')"
case "$type" in ci-template|ci-templates) type=ci ;; doc) type=docs ;; app) type=service ;; package) type=library ;; tooling) type=plugin ;; tests|test-only) type=test ;; esac

case "$type" in
  library)
    PERT="Completeness|Feature Availability|Input Validation|Robustness|Security Posture|Observability|Thread Safety|Configurability|Test Discipline|Non-Duplication|Documentation|Poka-Yoke|Risk Assessment" ;;
  service)
    PERT="$ALL" ;;
  ci)
    PERT="Completeness|Robustness|Resilience|Security Posture|Observability|Test Discipline|Non-Duplication|Documentation|Poka-Yoke|Risk Assessment" ;;
  infra)
    PERT="Completeness|Robustness|Resilience|Security Posture|Observability|Non-Duplication|Documentation|Poka-Yoke|Risk Assessment" ;;
  plugin)
    PERT="Completeness|Robustness|Observability|Test Discipline|Non-Duplication|Documentation|Poka-Yoke|Risk Assessment" ;;
  docs)
    # a pure docs change has no risk surface -> Risk Assessment is LIKELY_N/A (no waiver required).
    PERT="Non-Duplication|Documentation|Poka-Yoke" ;;
  test)
    # a test-only change (coverage / test infra) has no runtime risk surface -> Risk Assessment +
    # Security are LIKELY_N/A. Test Discipline is the live dimension.
    PERT="Completeness|Robustness|Test Discipline|Non-Duplication|Documentation|Poka-Yoke" ;;
  ''|*)
    type="<none>"; PERT="$ALL" ;;   # unknown/empty -> full set (back-compat)
esac

# i18n is pertinent for EVERY type: it can never be NOT_PERTINENT on a development story. A change with no
# user-facing strings still proves it, with zero candidates and the scanner cited. The profile only
# pre-seeds verdicts, so without this the row of a narrow type would be pre-waived.
case "|$PERT|" in *"|i18n|"*) : ;; *) PERT="${PERT}|i18n" ;; esac

# While its gate is on, the mandatory "Adversarial Review" dimension joins ALL and is PERTINENT for EVERY type (it
# can NEVER be NOT_PERTINENT). The gate (KYKLOS_ADVREVIEW_GATE) and its default are owned by
# proof_canonical_dimensions in proof-dimensions.sh; this check mirrors it so the pre-seed and the guard's set-check
# always agree.
# shellcheck source=../../hooks/lib/control-switch.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../hooks/lib/control-switch.sh" 2>/dev/null || true   # kyklos_control_off: the one control-switch reader
if ! kyklos_control_off "${KYKLOS_ADVREVIEW_GATE:-}"; then
    case "|$ALL|"  in *"|Adversarial Review|"*) : ;; *) ALL="${ALL}|Adversarial Review" ;; esac
    case "|$PERT|" in *"|Adversarial Review|"*) : ;; *) PERT="${PERT}|Adversarial Review" ;; esac
fi

# LIKELY_N/A = ALL minus PERT (same order as ALL).
na=""
OIFS="$IFS"; IFS='|'
for d in $ALL; do
  case "|$PERT|" in *"|$d|"*) : ;; *) na="${na:+$na|}$d" ;; esac
done
IFS="$OIFS"

echo "TYPE: $type"
echo "PERTINENT: $PERT"
echo "LIKELY_N/A: ${na:-<none>}"
