#!/usr/bin/env bash
# help-link.sh (Kyklos hook lib) - the one place a refusal names its section of the public troubleshooting guide.
#
# Every guard refusal, doctor line and bridge-call message that has a section in the troubleshooting guide ends with one
# short final line "Help: <guide address>#<section anchor>", so the person and the agent go straight from the message to
# its cause, the confirming check and the fix. The guide's address is this file's one constant; the anchors are the
# guide's section headings as GitHub writes them (tests/test-help-links.sh checks that each one named by a hook exists).
#
#   kyklos_help_line ANCHOR       -> prints "Help: <guide>#ANCHOR" (no newline)
#   kyklos_help_json_suffix ANCHOR -> prints "\nHelp: <guide>#ANCHOR" with the newline written as the two characters a JSON
#                                    string needs, for a reason that is already escaped for JSON
#   kyklos_help_append TEXT ANCHOR -> prints TEXT, a newline, then the help line (for a plain-text message)

# The public troubleshooting guide (the docs folder of the public repository).
KYKLOS_HELP_GUIDE_URL="https://github.com/DogmaSolutions/Kyklos/blob/main/docs/TROUBLESHOOTING.md"

kyklos_help_line() { printf 'Help: %s#%s' "$KYKLOS_HELP_GUIDE_URL" "$1"; }

kyklos_help_json_suffix() { printf '\\nHelp: %s#%s' "$KYKLOS_HELP_GUIDE_URL" "$1"; }

kyklos_help_append() { printf '%s\n' "$1"; kyklos_help_line "$2"; }
