#!/usr/bin/env bash
# build-execution.sh — the one reader of the BUILD_EXECUTION build channel (bridge|local, no default), sourced by every
# script that judges it (the build-execution guard, the full-solution recorder, the running-tests interview gate).
#
# Where the value comes from, in this order:
#   1. the session's environment: the KyklosLauncher passes the project's BUILD_EXECUTION setting into the agent
#      session, so a project configured in the Launcher needs no file;
#   2. the BUILD_EXECUTION line of the project's .claude/standards.env (the interviewed value), when the environment
#      does not set it.
# A non-blank environment value wins over the file, even when the two disagree: the Launcher's configuration is what
# the project declared for this session. An environment value that is not bridge|local is invalid, never a reason to
# read the file instead.
#
# build_execution_source [<standards.env>] — prints environment, file or none: where the value is read from.
# build_execution_raw [<standards.env>]    — prints the value as found there (trimmed and unquoted; may be invalid or
#                                            empty).
# build_execution_mode [<standards.env>]   — prints bridge or local, or nothing when the value is unset, blank or
#                                            invalid.
# The file defaults to $CLAUDE_PROJECT_DIR/.claude/standards.env (the working folder when CLAUDE_PROJECT_DIR is unset).

build_execution_trim() {
    local v="$1"
    v="${v%%#*}"
    printf '%s' "$v" | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//'
}

build_execution_file() { printf '%s' "${1:-${CLAUDE_PROJECT_DIR:-$(pwd)}/.claude/standards.env}"; }

build_execution_source() {
    local cfg
    cfg="$(build_execution_file "${1:-}")"
    if [ -n "$(build_execution_trim "${BUILD_EXECUTION:-}")" ]; then printf 'environment'
    elif [ -f "$cfg" ]; then printf 'file'
    else printf 'none'
    fi
}

build_execution_raw() {
    local cfg v
    cfg="$(build_execution_file "${1:-}")"
    case "$(build_execution_source "$cfg")" in
        environment) build_execution_trim "${BUILD_EXECUTION:-}" ;;
        file)
            v="$(grep -E "^[[:space:]]*(export[[:space:]]+)?BUILD_EXECUTION=" "$cfg" 2>/dev/null | grep -vE "^[[:space:]]*#" | tail -1 \
                | sed -E 's/^[[:space:]]*(export[[:space:]]+)?BUILD_EXECUTION=//')"
            build_execution_trim "$v" ;;
        *) return 0 ;;
    esac
}

build_execution_mode() {
    local v
    v="$(build_execution_raw "${1:-}")"
    case "$v" in bridge|local) printf '%s' "$v" ;; *) return 0 ;; esac
}
