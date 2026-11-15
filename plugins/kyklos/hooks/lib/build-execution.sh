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
# The file defaults to <workspace root>/.claude/standards.env, the root named by build_execution_root.
#
# build_execution_root [<dir>]             — prints the workspace root that owns .claude/standards.env and .mcp.json:
#                                            CLAUDE_PROJECT_DIR when set; otherwise the working folder. Either is
#                                            kept as it is, except that a folder in a companion's nested source
#                                            (repo_inner_source_of, the resolver the guards use; it reads
#                                            KYKLOS_SOURCE_DIR) resolves UP to the companion root. With
#                                            CLAUDE_PROJECT_DIR unset, <dir> (the solution's repository) is also
#                                            resolved that way when it is a nested source. An ordinary repository is
#                                            never climbed. A solution in <workspace>/Repo (no .claude/ by design) is
#                                            then judged by the companion's settings, never refused as "not set".

build_execution_trim() {
    local v="$1"
    v="${v%%#*}"
    printf '%s' "$v" | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//'
}

_BUILD_EXECUTION_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# _build_execution_companion_of <dir> -> prints the companion root and rc 0 only when <dir> lies in a companion's
# nested source (repo_inner_source_of); rc 1, nothing printed, for any other folder: an ordinary repository is never
# climbed, so a project folder that is a subfolder of a repository stays that subfolder.
_build_execution_companion_of() {
    local dir="$1" inner
    [ -d "$dir" ] || return 1
    # The companion resolver is loaded only here, so a guard that passes its own file never loads it.
    # shellcheck source=repo-role.sh
    command -v repo_inner_source_of >/dev/null 2>&1 || . "$_BUILD_EXECUTION_LIB_DIR/repo-role.sh"
    inner="$(repo_inner_source_of "$dir")" || return 1
    [ -n "$inner" ] || return 1
    repo_companion_root "$inner"
}

build_execution_root() {
    if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
        _build_execution_companion_of "$CLAUDE_PROJECT_DIR" || printf '%s' "$CLAUDE_PROJECT_DIR"
        return 0
    fi
    if [ -n "${1:-}" ] && _build_execution_companion_of "$1"; then return 0; fi
    _build_execution_companion_of "$(pwd)" || pwd
}

# build_execution_file [<file>] [<dir>] — <file> when given, else the standards.env of build_execution_root <dir>.
build_execution_file() {
    if [ -n "${1:-}" ]; then printf '%s' "$1"; return 0; fi
    printf '%s/.claude/standards.env' "$(build_execution_root "${2:-}")"
}

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
