#!/usr/bin/env bash
# dotnet-cmd-detect.sh — shared: does a shell COMMAND invoke a local `dotnet <verb>` in COMMAND POSITION?
#
# The mention-vs-invocation problem, solved once for every guard that gates a .NET build/test: a `dotnet <verb>`
# inside a HEREDOC body, a QUOTED string, or an echo/grep argument (or, for a guard that mistakenly scans the whole
# hook payload, inside the tool OUTPUT) is DATA, not an invocation, and must NOT be matched. Extracted from
# kyklos-build-execution-guard so kyklos-zero-failures-gate (which was matching the raw payload and false-fired on a
# grep of test fixtures) can share the exact same precise detector. Mirrors git-cmd-detect.sh's philosophy: prefer
# NEVER false-blocking a mention over catching a rare quoted/heredoc'd real invocation (CI is the backstop).
#
# Contract — source this file, then:
#   dotnet_cmd_invokes "<command-string>" "<verb-alternation>"   # e.g. "build|test|run|msbuild|vstest" or "test|vstest"
#     rc 0 : the command invokes `dotnet <verb>` in command position.
#     rc 1 : no such invocation (a mention, a quoted/heredoc'd occurrence, or none).
#   dotnet_cmd_strip "<command-string>"    -> echoes the command with heredoc bodies + quoted substrings removed
#                                             (the shared normalization; a caller may add its own match, e.g. *.sln).

# The heredoc/quote strip is the SHARED normalization (lib/cmd-strip.sh), so the git + dotnet detectors cannot drift
# on the mention-vs-invocation rule. dotnet_cmd_strip is kept as the public name its callers already use.
# shellcheck source=cmd-strip.sh
. "$(dirname "${BASH_SOURCE[0]}")/cmd-strip.sh"

dotnet_cmd_strip() { cmd_strip "$1"; }

dotnet_cmd_invokes() {
    local cmd="$1" verbs="$2" m
    m="$(dotnet_cmd_strip "$cmd")"
    # `dotnet <verb>` — the verb immediately follows `dotnet`; terminated by space, a quote (the command may be the
    # last token before a closing JSON quote), a shell separator, or EOL. Anchored so a bare word merely CONTAINING
    # "dotnet" (a path) is not caught.
    printf '%s' "$m" | grep -ciE "(^|[^[:alnum:]_./-])dotnet[[:space:]]+(${verbs})([[:space:]\"';&|]|\$)" >/dev/null
}
