#!/usr/bin/env bash
# render-managed-policy.sh - compose the managed engineering policy (Level 0 Kyklos plus a Level 1 Corporate file) into
# the managed /etc/claude-code/CLAUDE.md, exactly as a KyklosLauncher launch composes it: the composed header, the
# "Overrides in force" list, the Kyklos policy, then the Corporate extension text after its separator line.
#
# One composer: when the KyklosLauncher is installed (the `kyklos-launcher` command on PATH, or the file named by
# KYKLOS_LAUNCHER: its executable, or its DogmaSolutions.Kyklos.Launcher.dll run with dotnet), the script calls its
# composer (`kyklos-launcher compose-policy`). Without it, a Corporate file that only extends the policy is composed
# here, in the launcher's exact form (a launcher test runs this script without the launcher on the shipped files and on
# edge cases and compares the bytes with the launcher's composer, so the two cannot drift); a file that replaces or
# removes a Kyklos rule needs the launcher, which validates the blocks, and is refused here.
#
# Usage: render-managed-policy.sh --product <kyklos-policy.md> --org <corporate-policy.md> [--out <file>]
#   --product  the Kyklos policy (dist/CLAUDE.kyklos.md)
#   --org      the Corporate policy file (your organisation's own; start from dist/CLAUDE.org.sample.md)
#   --out      write the composed policy here instead of stdout
# Exit: 0 ok | 1 the Corporate file is refused or a file cannot be read | 2 usage error, a missing input, or override
#       blocks without the launcher
set -euo pipefail
export LC_ALL=C

# The launcher composer's fixed lines (Policy/PolicyComposer.cs); the launcher test compares the output byte for byte.
readonly HEADER='<!-- Managed policy composed by KyklosLauncher: Level 0 Kyklos, then Level 1 Corporate. -->'
readonly NO_OVERRIDES='**Overrides in force (Corporate policy):** none.'
readonly SEPARATOR='<!-- Level 1: Corporate policy (composed by KyklosLauncher) -->'
readonly MAXIMUM_BYTES=262144

product=""
org=""
out=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --product) [ "$#" -ge 2 ] || { echo "render-managed-policy: --product needs a file" >&2; exit 2; }; product="$2"; shift 2 ;;
        --org) [ "$#" -ge 2 ] || { echo "render-managed-policy: --org needs a file" >&2; exit 2; }; org="$2"; shift 2 ;;
        --out) [ "$#" -ge 2 ] || { echo "render-managed-policy: --out needs a file" >&2; exit 2; }; out="$2"; shift 2 ;;
        *) echo "render-managed-policy: unknown argument: $1 (usage: render-managed-policy.sh --product <kyklos-policy.md> --org <corporate-policy.md> [--out <file>])" >&2; exit 2 ;;
    esac
done

if [ -z "$product" ] || [ -z "$org" ]; then
    echo "usage: render-managed-policy.sh --product <kyklos-policy.md> --org <corporate-policy.md> [--out <file>]" >&2
    exit 2
fi
[ -f "$product" ] || { echo "render-managed-policy: product policy not found: $product" >&2; exit 2; }
[ -f "$org" ] || { echo "render-managed-policy: Corporate policy not found: $org" >&2; exit 2; }

launcher="${KYKLOS_LAUNCHER:-}"
if [ -n "$launcher" ]; then
    [ -f "$launcher" ] || { echo "render-managed-policy: KYKLOS_LAUNCHER names no file: $launcher" >&2; exit 2; }
else
    launcher="$(command -v kyklos-launcher 2>/dev/null || true)"
fi

if [ -n "$launcher" ]; then
    set -- "$product" "$org"
    if [ -n "$out" ]; then set -- "$@" "$out"; fi
    rc=0
    case "$launcher" in
        *.dll) dotnet "$launcher" compose-policy "$@" || rc=$? ;;
        *) "$launcher" compose-policy "$@" || rc=$? ;;
    esac
    exit "$rc"
fi

# --- Without the launcher: an extension-only Corporate file, composed in the launcher's form. ---
bom="$(printf '\357\273\277')"
# lines <file>: the file with a leading byte-order mark dropped and every CRLF or lone CR read as LF, one line per line.
lines() { awk -v bom="$bom" 'NR == 1 && index($0, bom) == 1 { $0 = substr($0, 4) } { sub(/\r$/, ""); gsub(/\r/, "\n"); print }' "$1"; }
# trimmed: the lines read with the empty lines at the end (and, with "both", at the start) left out.
trimmed() { awk -v both="${1:-}" '{ a[NR] = $0 } END { s = 1; if (both != "") while (s <= NR && a[s] == "") s++; n = NR; while (n >= s && a[n] == "") n--; for (i = s; i <= n; i++) print a[i] }'; }

# [CySec] The Corporate file becomes the highest-precedence policy text: the launcher's limits hold here too (at most
# 256 KB, UTF-8 text, no control character). CWE-400 Uncontrolled Resource Consumption; CWE-20 Improper Input Validation.
size="$(wc -c < "$org" | tr -d ' ')"
[ "$size" -le "$MAXIMUM_BYTES" ] || { echo "render-managed-policy: the Corporate policy is $size bytes, over the 256 KB limit: $org" >&2; exit 1; }
command -v iconv >/dev/null 2>&1 || { echo "render-managed-policy: iconv is needed to check the Corporate policy is UTF-8 text (or install the KyklosLauncher)" >&2; exit 2; }
iconv -f UTF-8 -t UTF-8 "$org" >/dev/null 2>&1 || { echo "render-managed-policy: the Corporate policy is not UTF-8 text: $org" >&2; exit 1; }
if ! tr -d '\000' < "$org" | cmp -s - "$org" || grep -q "$(printf '[\001-\010\013\014\016-\037\177]')" "$org" \
    || grep -q "$(printf '\302[\200-\237]')" "$org"; then
    echo "render-managed-policy: the Corporate policy holds a control character: $org" >&2; exit 1
fi

# One reading of whitespace: this composition reads blanks as ASCII (space, tab), the launcher's composer as Unicode.
# A character the two would read differently (a no-break or other Unicode space, a line or paragraph separator, a
# zero-width or other invisible format character, a byte-order mark that does not open the file) could make the same
# file compose differently here (an indented override block left unapplied, a blank file given a separator), so it is
# refused, naming its line; the launcher composes such a file.
odd="$(printf '\302[\240\255]|\341\232\200|\341\240\216|\342\200[\200-\217]|\342\200[\250-\257]|\342\201[\237-\257]|\343\200\200|\357\273\277')"
oddline="$(awk -v bom="$bom" -v odd="$odd" 'NR == 1 && index($0, bom) == 1 { $0 = substr($0, 4) } $0 ~ odd { print NR; exit }' "$org")"
if [ -n "$oddline" ]; then
    echo "render-managed-policy: line $oddline of the Corporate policy holds a Unicode space or invisible format character that the launcher reads differently; replace it with a plain space, or install the KyklosLauncher (or name it with KYKLOS_LAUNCHER): $org" >&2
    exit 1
fi

# A replace or remove block (a "kyklos:" comment at the start of a line, outside a fenced code block) needs the launcher.
if lines "$org" | awk '{ t = $0; sub(/^[ \t]+/, "", t); f = substr(t, 1, 3); if (f == "```" || f == "~~~") { fenced = !fenced; next }
        if (!fenced && $0 ~ /^[ \t]*<!-- *kyklos:/) { found = 1 } } END { exit found ? 0 : 1 }'; then
    echo "render-managed-policy: the Corporate policy replaces or removes Kyklos rules; install the KyklosLauncher (or name it with KYKLOS_LAUNCHER), whose composer validates and applies those blocks" >&2
    exit 2
fi

extension="$(lines "$org" | trimmed both)"
compose() {
    printf '%s\n\n%s\n\n' "$HEADER" "$NO_OVERRIDES"
    lines "$product" | trimmed
    if [ -n "$(printf '%s' "$extension" | tr -d '[:space:]')" ]; then
        printf '\n%s\n\n%s\n' "$SEPARATOR" "$extension"
    fi
}

if [ -n "$out" ]; then
    compose > "$out"
else
    compose
fi
