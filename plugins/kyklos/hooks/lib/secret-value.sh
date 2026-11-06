#!/usr/bin/env bash
# secret-value.sh - the ONE way Kyklos hooks and skills get the value of a secret named by a *_TOKEN_ENV knob.
#
#   kyklos_secret NAME     prints the current value of NAME (no newline), or nothing when it is not available.
#
# A launcher either forwards secret values as environment variables, or keeps them on the host and serves them
# through the project's bridge (the container then holds only KYKLOS_BRIDGE_AUTH_TOKEN, and `bridge-secret NAME` reads a
# value on demand). This function hides the difference: with a bridge it asks bridge-secret (which itself falls back
# to the environment variable), otherwise it reads the environment variable. Callers keep their own fail-open or
# fail-hard behaviour for an empty result; the value never reaches stderr or a log from here.
#
# Hooks run on every tool call, so a bridge that stops answering must not stall them: the bridge is given
# KYKLOS_SECRET_TIMEOUT_SECONDS (default 3) instead of bridge-secret's interactive default.
#
# Test seam: KYKLOS_BRIDGE_SECRET_BIN overrides the bridge-secret executable.

# shellcheck source=lib/seal-rule.sh
. "$(dirname "${BASH_SOURCE[0]}")/seal-rule.sh"   # kyklos_test_sealed: a test shell never asks the live secret store

kyklos_secret() {
    local name="${1:-}" tool
    # A name is an environment-variable name; anything else could be abused through the indirection below.
    [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 0
    if [ -n "${KYKLOS_BRIDGE_AUTH_TOKEN:-}" ]; then
        tool="${KYKLOS_BRIDGE_SECRET_BIN:-$(command -v bridge-secret 2>/dev/null)}"
        # [CySec] CWE-668: a sealed test shell never asks the session's secret store for a value; only a stand-in the
        # test named itself (KYKLOS_BRIDGE_SECRET_BIN) is used, else the environment variable.
        if [ -z "${KYKLOS_BRIDGE_SECRET_BIN:-}" ] && kyklos_test_sealed; then
            tool=""
        fi
        if [ -n "$tool" ] && [ -x "$tool" ]; then
            KYKLOS_BRIDGE_SECRET_TIMEOUT_SECONDS="${KYKLOS_SECRET_TIMEOUT_SECONDS:-3}" "$tool" "$name" 2>/dev/null
            return 0
        fi
    fi
    printf '%s' "${!name:-}"
}
