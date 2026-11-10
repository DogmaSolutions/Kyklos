#!/usr/bin/env bash
# kyklos-version.sh — resolve the running kyklos plugin version, for the `kyklos:version::<v>`
# issue label. Sourced by BOTH issue-manipulating subsystems (the ssdlc-story GitLab backend and the
# ssdlc-agent-msg coordination lib) so the version source + label spelling live in ONE place (no duplication).
#
# Every Kyklos function that CREATES or MUTATES a GitLab issue calls the subsystem's
# `ensure_kyklos_version_label <iid>` (which uses this resolver), so every issue the Kyklos touches carries a
# label naming the plugin version that touched it. MORE THAN ONE `kyklos:version::<v>` is allowed and expected: a
# newer plugin adding its own label leaves the older ones in place, so an issue's labels record its version history.
#
# Guard against double-sourcing (both libs may be sourced in one process).
if [ -z "${_KYKLOS_VERSION_LIB_LOADED:-}" ]; then
_KYKLOS_VERSION_LIB_LOADED=1

# The scoped-label namespace (matches the usual `<ns>::<value>` convention, e.g. ssdlc:phase::Design). A version
# label is NOT mutually exclusive, so it is added, never mutex-swapped.
KYKLOS_VERSION_LABEL_NS='kyklos:version'

# kyklos_version -> a REAL plugin version string on stdout, or rc 1 + empty if it cannot be resolved.
# Resolution order: explicit KYKLOS_VERSION env override -> the installed plugin manifest's `.version`.
# "0.0.0" is the UNSTAMPED-SOURCE placeholder (the manifest ships 0.0.0 and is stamped to e.g. 0.2.2538 at
# publish). It is NOT a real version — treat it, and an empty/absent manifest, as UNRESOLVED (rc 1). A caller must
# NEVER stamp a `kyklos:version::0.0.0` label: that misattributes provenance to a non-existent release.
kyklos_version() {
    local v="" here="" _env_set=0
    here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)" || here=""
    if [ -n "${KYKLOS_VERSION:-}" ]; then
        v="$KYKLOS_VERSION"; _env_set=1
    else
        # This file lives at plugins/kyklos/hooks/lib/ ; the manifest is at plugins/kyklos/.claude-plugin/.
        local pj="$here/../../.claude-plugin/plugin.json"
        [ -f "$pj" ] && v="$(jq -r '.version // empty' "$pj" 2>/dev/null || true)"
    fi
    # THIRD source — the repo's newest release TAG — ONLY when the env is UNSET and the manifest is the
    # unstamped 0.0.0 placeholder (or absent). This is the case of operating the story tool from the SOURCE clone
    # (the manifest ships 0.0.0 and is stamped only at publish), where the provenance contract would otherwise
    # leave every tool-driven mutation UNLABELLED. An EXPLICIT KYKLOS_VERSION=0.0.0 is a deliberate placeholder
    # and stays refused — the fallback never rescues it. The tags (`versions/vX.Y.Z[-suffix]`) are
    # an authoritative, already-present version source; any git error degrades to the manifest/env result below.
    if [ "$_env_set" = 0 ]; then
        case "$v" in
            ""|"0.0.0"|"0.0.0-"*)
                if [ -n "$here" ] && command -v git >/dev/null 2>&1 \
                   && git -C "$here" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
                    local _tagver
                    _tagver="$(git -C "$here" tag --list 'versions/v*' 2>/dev/null \
                        | sed -nE 's#^versions/v([0-9]+\.[0-9]+\.[0-9]+).*$#\1#p' \
                        | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
                    [ -n "$_tagver" ] && v="$_tagver"
                fi
                ;;
        esac
    fi
    # reject the unstamped placeholder and any empty/whitespace result
    case "$v" in ""|"0.0.0"|"0.0.0-"*) return 1 ;; esac
    printf '%s' "$v"
}

# kyklos_version_label -> the full scoped label `kyklos:version::<v>` on stdout (rc 0), or rc 1 + a LOUD stderr
# error when the version is unavailable or the 0.0.0 placeholder. FAIL HARD, not silent: a caller propagates
# the rc-1 so the operation errors rather than stamping a meaningless `kyklos:version::0.0.0`. The remedy is to
# publish/stamp the plugin, or set KYKLOS_VERSION to the real version.
kyklos_version_label() {
    local v; v="$(kyklos_version)" || {
        echo "kyklos-version: the plugin version is unavailable or the unstamped '0.0.0' placeholder — refusing to stamp a meaningless kyklos:version label. Publish/stamp the plugin, or set KYKLOS_VERSION to the real version." >&2
        return 1
    }
    printf '%s::%s' "$KYKLOS_VERSION_LABEL_NS" "$v"
}

# kyklos_version_ge <a> <b> -> rc 0 iff SemVer <a> >= <b>, comparing major.minor.patch NUMERICALLY. Any
# -prerelease / +build metadata is stripped (our thresholds and the stamped `kyklos:version::` labels are plain
# X.Y.Z); missing components default to 0. Pure bash (no awk/subprocess) so kcov measures it directly.
kyklos_version_ge() {
    local _a="${1%%[-+]*}" _b="${2%%[-+]*}" _a1 _a2 _a3 _b1 _b2 _b3 _junk
    read -r _a1 _a2 _a3 _junk <<EOF
${_a//./ }
EOF
    read -r _b1 _b2 _b3 _junk <<EOF
${_b//./ }
EOF
    # 10# forces base-10 so a zero-padded component never parses as octal; empty/absent -> 0.
    _a1=$((10#${_a1:-0})); _a2=$((10#${_a2:-0})); _a3=$((10#${_a3:-0}))
    _b1=$((10#${_b1:-0})); _b2=$((10#${_b2:-0})); _b3=$((10#${_b3:-0}))
    if [ "$_a1" -ne "$_b1" ]; then [ "$_a1" -gt "$_b1" ]; return; fi
    if [ "$_a2" -ne "$_b2" ]; then [ "$_a2" -gt "$_b2" ]; return; fi
    [ "$_a3" -ge "$_b3" ]
}

# kyklos_version_max -> read version strings on stdin (one per line; blank/whitespace lines ignored) and print
# the SemVer-maximum on stdout (empty when none were read). Used to pick the highest `kyklos:version::<v>` among
# an issue's labels before comparing it to a threshold.
kyklos_version_max() {
    local _best="" _v
    # `|| [ -n "$_v" ]` so a FINAL line with no trailing newline (command substitution strips it) is still processed.
    while IFS= read -r _v || [ -n "$_v" ]; do
        _v="${_v#"${_v%%[![:space:]]*}"}"; _v="${_v%"${_v##*[![:space:]]}"}"   # trim surrounding whitespace
        [ -n "$_v" ] || continue
        if [ -z "$_best" ] || kyklos_version_ge "$_v" "$_best"; then _best="$_v"; fi
    done
    printf '%s' "$_best"
}

fi
