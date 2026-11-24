#!/usr/bin/env bash
# rulebook.sh (Kyklos hook lib) - the shell face of the one rulebook (shared/src/DogmaSolutions.Kyklos.Settings/Rules).
# Every hook that judges who may push, the self-drive default, a close mode, the API scopes, the token state or a
# topology asks these functions; none keeps its own copy. The data comes from rulebook.generated.sh, which the C# tests
# write and check; tests/test-rulebook.sh holds the shell answers to the same parity cases as the C# rulebook.
#   kyklos_push_possible            -> rc 0 when KYKLOS_ALLOW_PUSH or KYKLOS_CI_MONITOR is the rulebook's "on" value
#   kyklos_self_driving             -> rc 0 when KYKLOS_CI_SELF_DRIVE (or, unset, the rulebook default) is true
#   kyklos_ci_driven_source         -> rc 0 when the source's branches close through the pipeline
#   kyklos_rule_word_in <list> <w>  -> rc 0 when word <w> is in the space-separated <list>
#   kyklos_topology_row <topology>  -> "<shape> <workflow> <source-folder|->" on stdout; rc 1 for an unknown topology
# Missing data fails closed: a hook that sources this file without the generated file stops with a message naming it.

_kyklos_rulebook_data="$(dirname "${BASH_SOURCE[0]}")/rulebook.generated.sh"
if [ -r "$_kyklos_rulebook_data" ]; then
    # shellcheck source=/dev/null
    . "$_kyklos_rulebook_data"
else
    printf 'kyklos: the rulebook data %s is missing; reinstall the plugin.\n' "$_kyklos_rulebook_data" >&2
    return 2 2>/dev/null || exit 2
fi

kyklos_rule_word_in() { case " $1 " in *" $2 "*) return 0 ;; *) return 1 ;; esac; }

kyklos_push_possible() {
    local name
    for name in $KYKLOS_RULE_PUSH_SWITCHES; do
        [ "${!name:-}" = "$KYKLOS_RULE_SWITCH_ON" ] && return 0
    done
    return 1
}

kyklos_self_driving() { [ "${KYKLOS_CI_SELF_DRIVE:-$KYKLOS_RULE_SELF_DRIVE_DEFAULT}" = "true" ]; }

# kyklos_ci_driven_source -> rc 0 when the source's branches close through the pipeline: a gitflow source that
# explicitly drives its own CI (KYKLOS_CI_SELF_DRIVE=true), or that may push and has a push repository. The same rule
# as SessionRules.CiDrivenSource, which the launcher's Check applies.
kyklos_ci_driven_source() {
    [ "${KYKLOS_SOURCE_WORKFLOW:-}" = "gitflow" ] || return 1
    [ "${KYKLOS_CI_SELF_DRIVE:-}" = "true" ] && return 0
    kyklos_push_possible && [ -n "${KYKLOS_PUSH_REPO_URL:-}" ]
}

kyklos_topology_row() {
    local row name rest
    for row in $KYKLOS_RULE_TOPOLOGY_ROWS; do
        name="${row%%:*}"; rest="${row#*:}"
        if [ "$name" = "${1:-}" ]; then
            printf '%s %s %s\n' "${rest%%:*}" "$(printf '%s' "$rest" | cut -d: -f2)" "${rest##*:}"
            return 0
        fi
    done
    return 1
}
