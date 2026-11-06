#!/usr/bin/env bash
# render-managed-policy.sh - compose the managed engineering policy from the generic baseline plus an organisation
# layer. ONE renderer, used both by a deploying organisation and by the source-of-truth sync check, so the managed
# /etc/claude-code/CLAUDE.md is a rendered artifact, never a hand-maintained copy that can silently drift.
#
# Usage: render-managed-policy.sh --product <baseline.md> --org <org-layer.md> [--out <file>]
#   --product  the generic baseline policy (dist/CLAUDE.kyklos.md)
#   --org      the organisation layer (your private overlay; see dist/CLAUDE.org.sample.md)
#   --out      write the rendered policy here instead of stdout
# Exit: 0 ok | 2 usage error or a missing input file
set -euo pipefail

product=""
org=""
out=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --product) [ "$#" -ge 2 ] || { echo "render-managed-policy: --product needs a file" >&2; exit 2; }; product="$2"; shift 2 ;;
        --org) [ "$#" -ge 2 ] || { echo "render-managed-policy: --org needs a file" >&2; exit 2; }; org="$2"; shift 2 ;;
        --out) [ "$#" -ge 2 ] || { echo "render-managed-policy: --out needs a file" >&2; exit 2; }; out="$2"; shift 2 ;;
        *) echo "render-managed-policy: unknown argument: $1 (usage: render-managed-policy.sh --product <baseline.md> --org <org-layer.md> [--out <file>])" >&2; exit 2 ;;
    esac
done

if [ -z "$product" ] || [ -z "$org" ]; then
    echo "usage: render-managed-policy.sh --product <baseline.md> --org <org-layer.md> [--out <file>]" >&2
    exit 2
fi
[ -f "$product" ] || { echo "render-managed-policy: product policy not found: $product" >&2; exit 2; }
[ -f "$org" ] || { echo "render-managed-policy: organisation layer not found: $org" >&2; exit 2; }

render() {
    cat "$product"
    printf '\n<!-- Organisation layer (composed by render-managed-policy.sh) -->\n\n'
    cat "$org"
}

if [ -n "$out" ]; then
    render > "$out"
else
    render
fi
