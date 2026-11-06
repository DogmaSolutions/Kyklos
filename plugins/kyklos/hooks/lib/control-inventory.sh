#!/usr/bin/env bash
# control-inventory.sh (Kyklos hook lib) - the plugin's control switches, DERIVED from the code that reads them.
#
# A control switch is any variable whose value the one control-switch reader (lib/control-switch.sh,
# kyklos_control_off) judges; a grant switch is one named in KYKLOS_GRANT_SWITCHES there. The inventory is read
# from the shipped plugin files on every call (control-inventory.awk), never kept as a list of its own, so a new gate
# with an off-switch is in the inventory the moment its code reads the switch.
#
#   control_inventory_load [<plugin-root>]  -> fill CONTROL_INVENTORY_CONTROLS (space separated names),
#                                              CONTROL_INVENTORY_GRANTS and the default map; rc 1 when the scan
#                                              found nothing (a broken install: the caller must not read "no control")
#   control_inventory_kind <NAME>           -> prints control | grant | (nothing)
#   control_inventory_loosens <NAME> <value> -> rc 0 when setting NAME to <value> turns its control off or weakens it,
#                                              or switches a grant on
#
# A control's value is safe only when it is an explicit on value or the non-off default the code itself gives the
# switch (`${NAME:-block}`); every other value, an off value or one the reader does not know, counts as loosening.
# [CySec] CWE-693 (Protection Mechanism Failure): the list of protections a change could switch off is the list the
# code actually reads, so a forgotten entry cannot leave a gate unwatched.

_CI_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib/control-switch.sh
. "$_CI_LIB_DIR/control-switch.sh"

declare -gA _CONTROL_INVENTORY_DEFAULTS=()
CONTROL_INVENTORY_CONTROLS=""
CONTROL_INVENTORY_GRANTS="${KYKLOS_GRANT_SWITCHES:-}"

control_inventory_load() {
    local root="${1:-$(dirname "$(dirname "$_CI_LIB_DIR")")}" kind name val listing
    listing="$(cd "$root" 2>/dev/null && find hooks skills bin -type f \( -name '*.sh' -o -name story \) -not -path '*/tests/*' -print0 2>/dev/null \
        | xargs -0 awk -f "$_CI_LIB_DIR/control-inventory.awk" 2>/dev/null | sort -u)"
    CONTROL_INVENTORY_CONTROLS=""
    _CONTROL_INVENTORY_DEFAULTS=()
    while IFS=$'\t' read -r kind name val; do
        case "$kind" in
            control) CONTROL_INVENTORY_CONTROLS="$CONTROL_INVENTORY_CONTROLS $name" ;;
            default) _CONTROL_INVENTORY_DEFAULTS["$name"]="${_CONTROL_INVENTORY_DEFAULTS[$name]:-} $val" ;;
        esac
    done <<< "$listing"
    CONTROL_INVENTORY_CONTROLS="${CONTROL_INVENTORY_CONTROLS# }"
    CONTROL_INVENTORY_GRANTS="${KYKLOS_GRANT_SWITCHES:-}"
    [ -n "$CONTROL_INVENTORY_CONTROLS" ] && [ -n "$CONTROL_INVENTORY_GRANTS" ]
}

control_inventory_kind() {
    case " $CONTROL_INVENTORY_GRANTS " in *" $1 "*) printf 'grant'; return 0 ;; esac
    case " $CONTROL_INVENTORY_CONTROLS " in *" $1 "*) printf 'control'; return 0 ;; esac
    return 0
}

# control_inventory_names_regex -> an ERE alternation of every control and grant name.
control_inventory_names_regex() {
    printf '%s %s' "$CONTROL_INVENTORY_CONTROLS" "$CONTROL_INVENTORY_GRANTS" | tr -s ' ' '\n' | grep -v '^$' | paste -sd'|' -
}

control_inventory_loosens() {
    local name="$1" val="${2:-}" d
    case "$(control_inventory_kind "$name")" in
        grant)
            # A grant loosens when it is switched on; any value other than an explicit off value or blank counts.
            [ -z "$(printf '%s' "$val" | tr -d ' ')" ] && return 1
            kyklos_control_off "$val" && return 1
            return 0 ;;
        control)
            kyklos_switch_explicit_on "$val" && return 1
            for d in ${_CONTROL_INVENTORY_DEFAULTS[$name]:-}; do
                kyklos_control_off "$d" && continue
                [ "$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]' | tr -d ' ')" = "$(printf '%s' "$d" | tr '[:upper:]' '[:lower:]')" ] && return 1
            done
            return 0 ;;
    esac
    return 1
}
