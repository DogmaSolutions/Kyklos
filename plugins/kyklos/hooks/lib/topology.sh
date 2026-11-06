#!/usr/bin/env bash
# topology.sh - Project Topologies: the single declared concept + derivation.
#
# A "User project" declares ONE topology; every per-repo workflow/role decision derives from it. This lib is the
# SINGLE source of that derivation. Guards SOURCE it - they must never re-implement the shape->workflow logic
# (hooks/tests/test-no-inline-repo-workflow.sh forbids that). The model: the ssdlc-repo-model skill.
#
# KYKLOS_PROJECT_TOPOLOGY in { PriComPubSou, PriSta, PriSouPubArt, PriComPriSou }. NO SILENT DEFAULT: an unknown
# value, or a declaration that conflicts with the legacy KYKLOS_REPO_SHAPE, FAILS HARD (rc 2). Undeclared is rc 3
# (the caller - the no-default gate - decides whether that blocks, per KYKLOS_REPO_MODEL_REQUIRED).
#
# PriComPriSou (Private Companion + Private Source): the same companion+nested-source SHAPE as PriComPubSou (companion
# trunk / source gitflow), but the nested source is PRIVATE and may be MANY private repos (remotes off our GitLab,
# e.g. a customer's). It exists so such a project need not mis-declare PriComPubSou (whose source is PUBLIC and must be
# AI-artifact-free). Both companion topologies derive shape=companion, so the legacy companion->PriComPubSou back-map
# is ambiguous: topology_effective treats shape=companion as compatible with EITHER companion topology (below).

# The valid topologies (a CLOSED enum - the whole point of poka-yoke here: no free-string workflow).
TOPOLOGY_VALUES="PriComPubSou PriSta PriSouPubArt PriComPriSou"

# topology_valid <t> -> 0 iff <t> is one of TOPOLOGY_VALUES.
topology_valid() { case " $TOPOLOGY_VALUES " in *" ${1:-} "*) return 0 ;; *) return 1 ;; esac; }

# topology_from_shape <shape> -> back-compat: map the legacy KYKLOS_REPO_SHAPE to a topology (stdout); rc 1 if the
# shape is unknown. NOTE: legacy `internal` maps to PriSta, but it was historically OVERLOADED to also mean the
# private source of a public artifact; such a repo RE-DECLARES PriSouPubArt explicitly (handled in topology_effective).
# Likewise `companion` maps to PriComPubSou (the only companion topology when the legacy shape was coined), but the
# newer PriComPriSou ALSO derives shape=companion; such a repo RE-DECLARES PriComPriSou explicitly (handled below).
topology_from_shape() {
    case "${1:-}" in
        internal)  printf 'PriSta' ;;
        companion) printf 'PriComPubSou' ;;
        *)         return 1 ;;
    esac
}

# topology_effective <declared_topology> <declared_shape> -> the effective topology on stdout.
#   - explicit KYKLOS_PROJECT_TOPOLOGY wins; an unknown value -> rc 2 (fail-hard).
#   - explicit topology + a legacy shape that DISAGREE -> rc 2 (fail-hard), EXCEPT the sanctioned overloads where one
#     legacy shape legitimately covers more than one topology: `internal`->PriSouPubArt, and `companion`->PriComPriSou
#     (both companion topologies derive shape=companion, so shape=companion must not conflict with either).
#   - no explicit topology -> back-compat from the shape; an unknown shape -> rc 2.
#   - neither declared -> rc 3 (undeclared).
topology_effective() {
    local t="${1:-}" shape="${2:-}"
    if [ -n "$t" ]; then
        topology_valid "$t" || { printf 'topology: unknown KYKLOS_PROJECT_TOPOLOGY %s (want: %s)\n' "'$t'" "$TOPOLOGY_VALUES" >&2; return 2; }
        if [ -n "$shape" ]; then
            local fs; fs="$(topology_from_shape "$shape" 2>/dev/null || true)"
            if [ -n "$fs" ] && [ "$fs" != "$t" ] \
                && ! { [ "$shape" = "internal" ]  && [ "$t" = "PriSouPubArt" ]; } \
                && ! { [ "$shape" = "companion" ] && [ "$t" = "PriComPriSou" ]; }; then
                printf 'topology: conflicting declaration - topology %s vs legacy shape %s (=%s)\n' "'$t'" "'$shape'" "$fs" >&2
                return 2
            fi
        fi
        printf '%s' "$t"; return 0
    fi
    if [ -n "$shape" ]; then
        topology_from_shape "$shape" || { printf 'topology: unknown KYKLOS_REPO_SHAPE %s\n' "'$shape'" >&2; return 2; }
        return 0
    fi
    return 3
}

# topology_derive <topology> -> the per-role workflow map (one "role=workflow" line), rc 2 unknown / rc 3 empty.
#   Roles: companion (trunk bookkeeping) . source (the developed source) . standalone (single private repo) .
#          artifact (the non-cloned PUBLIC facade - published by pipeline, never cloned, never hand-pushed).
# The `case` has NO `*)`->default arm that emits a workflow: an unrecognised topology is caught by topology_valid
# above and fails hard. That is the poka-yoke - a silent fall-through cannot pick a workflow.
topology_derive() {
    local t="${1:-}"
    [ -n "$t" ] || { printf 'topology_derive: no topology (undeclared)\n' >&2; return 3; }
    topology_valid "$t" || { printf 'topology_derive: unknown topology %s (want: %s)\n' "'$t'" "$TOPOLOGY_VALUES" >&2; return 2; }
    case "$t" in
        PriComPubSou) printf 'companion=trunk\nsource=gitflow\n' ;;
        PriComPriSou) printf 'companion=trunk\nsource=gitflow\n' ;;
        PriSta)       printf 'standalone=gitflow\n' ;;
        PriSouPubArt) printf 'source=gitflow\nartifact=facade\n' ;;
    esac
}
