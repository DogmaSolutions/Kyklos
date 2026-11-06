#!/usr/bin/env bash
# control-switch.sh (Kyklos hook lib) - the ONE reader for the value of a control switch.
#
# A control switch turns an enforcing check (a gate, a guard, a hardening) on or off. Every control is ON by
# default: an unset, blank, unreadable or unrecognized value (a typo included) ENFORCES. Only an explicit off value
# disables it: off, 0, false or no (any case, spaces ignored). A hand-rolled per-site parser is the defect class this
# file replaces: one site compared the value to "1", so an unset value or a typo silently turned the control off.
# The plugin test test-control-switch-reader.sh fails when a per-site copy of the parser reappears.
#
# Permissions (switches whose "on" GRANTS something, such as KYKLOS_ALLOW_PUSH) are not controls: for them the
# restrictive side is "off", and they keep their own explicit-on check. A list whose entries grant exceptions (branches
# a read-only source may be written on, commits the trunk check forgives) is a grant too: any non-empty value loosens.
# KYKLOS_GRANT_SWITCHES names them, once: the
# reader test exempts exactly these from the one-reader rule, and the Ask First guard asks before one is switched on.
KYKLOS_GRANT_SWITCHES="KYKLOS_ALLOW_PUSH KYKLOS_CI_MONITOR KYKLOS_CI_SELF_DRIVE KYKLOS_CI_DIRECT_TOKEN KYKLOS_AUTOMERGE_PROBE KYKLOS_MUTATION_SUSPENDED PROOF_RAW_OK PROOF_TOOL_HOST_CHECK KYKLOS_SOURCE_READONLY_ALLOW_BRANCH KYKLOS_SOURCE_READONLY_ALLOW_VERBS KYKLOS_TRUNK_REACH_ABANDONED"
#
# [CySec] CWE-1188 (Initialization of a Resource with an Insecure Default) / CWE-636 (Not Failing Securely): an
# ambiguous switch value resolves to enforcing, never to disabled.

# kyklos_control_off <value> -> rc 0 only when <value> is an explicit off value (off|0|false|no). Use it as
# `kyklos_control_off "${SWITCH:-}" && exit 0`: when this library failed to load, the call fails and the control
# stays ON (the failure mode is enforcing, never disabled).
kyklos_control_off() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d ' ')" in
    0|off|false|no) return 0 ;;
    *) return 1 ;;
  esac
}

# kyklos_control_enabled <value> -> rc 0 when a control with this value ENFORCES (the inverse of
# kyklos_control_off).
kyklos_control_enabled() {
  ! kyklos_control_off "${1:-}"
}

# kyklos_switch_explicit_on <value> -> rc 0 only when <value> is an explicit on value (on|1|true|yes). For a
# three-state switch (explicit on, explicit off, anything else = detect automatically); never for a plain control,
# where anything but an explicit off value is on.
kyklos_switch_explicit_on() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d ' ')" in
    1|on|true|yes) return 0 ;;
    *) return 1 ;;
  esac
}
