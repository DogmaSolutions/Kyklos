#!/usr/bin/env bash
# shell options: inherited from the caller (a sourced-only library; it never runs on its own).
# audience-lint-date-mask.sh - sourced by the audience-lint engine. A public document may carry dates it publishes on
# purpose: a changelog's release heading ("## [6.1] - <date>", "## 6.1 (<date>)", "### v6.1 - <date>") and a published
# date ("Published: <date>", "Last updated: <date>", "Released: **<date>**"; a bare "Date: <date>" or front matter
# "date: <date>" only in a public document: a file under dist/public, a README or a CHANGELOG). On such a line
# the date is replaced by <date> before the generic patterns are applied, so the dev-history date pattern does not take
# it for an internal marker. Only a line that is exactly such a heading or such a field is masked: a date in prose ("on
# <date> we found") stays judged. Lines are kept one for one, so a hit still names its own line.

# An ISO date.
AL_DATE='[0-9]{4}-[0-9]{2}-[0-9]{2}'
# A release heading: one to six '#', a version (optionally in brackets, optionally with a leading v), then the date after
# a dash or in parentheses, and nothing else.
AL_DATE_MASK_HEADING='^(#{1,6}[[:space:]]+\[?v?[0-9]+(\.[0-9]+)*([-+][0-9A-Za-z.]+)?\]?[[:space:]]*(-|–|—)?[[:space:]]*\(?)'"${AL_DATE}"'(\)?[[:space:]]*)$'
# A published-date field: the field name (optionally bold, optionally a list item), a colon, the date, and nothing else.
AL_DATE_MASK_FIELD_NAMES='Published|Last updated|Updated|Released|Release date'
al_date_mask_field() {
  printf '%s' '^(([-*][[:space:]]+)?(\*\*)?('"$1"')(\*\*)?[[:space:]]*:[[:space:]]*(\*\*)?[[:space:]]*)'"${AL_DATE}"'((\*\*)?[[:space:]]*)$'
}

# al_is_public_doc FILE -> rc 0 for a public document: a file under dist/public, a README or a CHANGELOG.
al_is_public_doc() {
  case "$1" in
    dist/public/*|*/dist/public/*) return 0 ;;
  esac
  case "$(basename -- "$1")" in
    README*|readme*|CHANGELOG*|changelog*) return 0 ;;
  esac
  return 1
}

# al_mask_published_dates [FILE] - print stdin with the date of every release heading and published-date field replaced by
# <date>; FILE, the document's path, decides whether a bare Date field counts (a public document only).
al_mask_published_dates() {
  local names="$AL_DATE_MASK_FIELD_NAMES"
  [ -n "${1:-}" ] && al_is_public_doc "$1" && names="$names|Date"
  sed -E \
    -e "s/${AL_DATE_MASK_HEADING}/\\1<date>\\5/" \
    -e "s/$(al_date_mask_field "$names")/\\1<date>\\7/I"
}
