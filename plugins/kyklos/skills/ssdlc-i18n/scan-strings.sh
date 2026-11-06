#!/usr/bin/env bash
# scan-strings.sh — the reusable candidate scanner behind the i18n Proof-table dimension (ssdlc-i18n skill).
#
# Usage:
#   scan-strings.sh [--repo DIR] [--base REF] [FILE...]   list the string literals the change added or modified
#   scan-strings.sh --detect [--repo DIR]                 report the i18n technique already in use (and a recorded one)
#   scan-strings.sh --find TEXT [--repo DIR]              find an existing RESX entry whose value is exactly TEXT
#
# List mode scans FILE... whole, or by default only the lines the branch changed since its merge-base with the trunk
# (--base, else origin/HEAD, origin/main, origin/master, origin/develop, main, master, develop), plus untracked
# files. One line per literal: <file>:<line><TAB><CANDIDATE|EXCLUDED:<reason>><TAB><literal>; the tally goes to
# stderr as "i18n scan: candidates=N excluded=M files=F". Script files (sh, ps1, bat, ...) are out of scope.
# Exit: 0 ok; 2 usage error or no repository/trunk; 3 a changed source file is in a language this scanner does not
# read (build a scanner for it, then cite that tool).
set +e -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Languages whose UI/API strings this scanner cannot read yet; a changed file in one of them must not pass silently.
UNSUPPORTED_EXTENSIONS='ts tsx js jsx mjs py java kt go vb fs swift rb php razor cshtml xaml'
TRUNK_CANDIDATES='origin/HEAD origin/main origin/master origin/develop main master develop'
ALL_LINES='ALL'   # the "scan every line" marker in the internal per-file list

die() { printf 'scan-strings: %s\n' "$1" >&2; exit "${2:-2}"; }

repo="."; base=""; mode="list"; find_text=""; files=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)   [ "$#" -ge 2 ] || die "--repo needs a directory"; repo="$2"; shift 2 ;;
    --base)   [ "$#" -ge 2 ] || die "--base needs a git ref"; base="$2"; shift 2 ;;
    --detect) mode="detect"; shift ;;
    --find)   [ "$#" -ge 2 ] || die "--find needs the text to look for"; mode="find"; find_text="$2"; shift 2 ;;
    -h|--help) sed -n '2,15p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*)       die "unknown option: $1" ;;
    *)        files+=("$1"); shift ;;
  esac
done
[ -d "$repo" ] || die "not a directory: $repo"

# Source files under the repo, skipping build output and VCS folders.
# <name pattern> [find action...] -> run the action (default -print) on every matching file.
source_files() {
  local pattern="$1"; shift
  [ "$#" -gt 0 ] || set -- -print
  find "$repo" \( -name bin -o -name obj -o -name .git -o -name node_modules \) -prune -o -type f -name "$pattern" "$@"
}

# <name> -> the value of the project's recorded '- **i18n <name>:** ...' line in CLAUDE.md, or nothing.
recorded_setting() {
  grep -m1 -E "^[-*][ 	]+\*\*i18n $1:\*\*" "$repo/CLAUDE.md" 2>/dev/null | sed -E "s/^[-*][ 	]+\*\*i18n $1:\*\*[ 	]*//"
}

detect() {
  local resx localizer recorded exclusions technique
  resx="$(source_files '*.resx' | wc -l | tr -d ' ')"
  localizer="$(source_files '*.cs' -exec grep -l 'IStringLocalizer' {} + 2>/dev/null | wc -l | tr -d ' ')"
  recorded="$(recorded_setting technique)"
  exclusions="$(recorded_setting exclusions)"
  if [ "$resx" -gt 0 ] && [ "$localizer" -gt 0 ]; then technique="both"
  elif [ "$resx" -gt 0 ]; then technique="resx"
  elif [ "$localizer" -gt 0 ]; then technique="IStringLocalizer"
  else technique="none"; fi
  printf 'technique=%s\nresx-files=%s\nlocalizer-files=%s\nrecorded=%s\nexclusions=%s\n' \
    "$technique" "$resx" "$localizer" "${recorded:-none}" "${exclusions:-none}"
  source_files '*.resx' | sed 's/^/resx: /'
}

find_resource() {
  local want f
  want="$(printf '%s' "$find_text" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')"
  # The text travels through the environment: awk -v would interpret backslash escapes in it.
  while IFS= read -r f; do
    I18N_FIND_TEXT="$want" awk -v file="$f" -f "$HERE/resx-find.awk" "$f"
  done < <(source_files '*.resx')
}

# <path> -> 0 for a C# file, 1 for a script or non-source file (skipped), 3 for a source language we cannot read.
file_kind() {
  local ext; ext="$(printf '%s' "${1##*.}" | tr '[:upper:]' '[:lower:]')"
  [ "$ext" = "cs" ] && return 0
  case " $UNSUPPORTED_EXTENSIONS " in *" $ext "*) return 3 ;; esac
  return 1
}

scan_file() {  # <path as reported> <comma-separated lines, empty = all> <path to read>
  awk -v file="$1" -v lines="$2" -f "$HERE/scan-strings-cs.awk" "$3"
}

changed_lines() {
  local ref merge_base
  git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git repository: $repo (pass FILE... to scan whole files)"
  if [ -z "$base" ]; then
    for ref in $TRUNK_CANDIDATES; do
      git -C "$repo" rev-parse --verify --quiet "$ref" >/dev/null && { base="$ref"; break; }
    done
  fi
  [ -n "$base" ] || die "no trunk found to diff against; pass --base REF or FILE..."
  merge_base="$(git -C "$repo" merge-base "$base" HEAD 2>/dev/null)" || die "no merge-base between $base and HEAD"
  # core.quotePath=false: git otherwise prints a non-ASCII path quoted and escaped, which then matches no file.
  git -C "$repo" -c core.quotePath=false diff -U0 --no-color --no-ext-diff "$merge_base" -- | awk -f "$HERE/diff-changed-lines.awk"
  git -C "$repo" -c core.quotePath=false ls-files --others --exclude-standard | sed "s/\$/\t$ALL_LINES/"
}

# An explicit FILE is read as given (absolute, or relative to the working directory, else to --repo). A FILE that
# does not exist is an error: silently skipping it would let a typo "prove" zero candidates.
explicit_files() {
  local path
  for path in "${files[@]}"; do
    if [ -f "$path" ]; then printf '%s\t%s\t%s\n' "$path" "$ALL_LINES" "$path"
    elif [ -f "$repo/$path" ]; then printf '%s\t%s\t%s\n' "$path" "$ALL_LINES" "$repo/$path"
    else die "file not found: $path"; fi
  done
}

list() {
  local out unsupported="" path lines read_path rc
  # One entry per file: <path as reported><TAB><changed lines, or ALL_LINES><TAB><path to read, absent = repo/path>.
  # (An explicit marker, never an empty field: read collapses consecutive tabs, so an empty middle field would shift.)
  out="$(
    if [ "${#files[@]}" -gt 0 ]; then explicit_files; else changed_lines; fi
  )" || exit $?
  local scanned=0 results=""
  while IFS="$(printf '\t')" read -r path lines read_path; do
    [ -n "$path" ] || continue
    [ -n "$read_path" ] || read_path="$repo/$path"
    [ "$lines" = "$ALL_LINES" ] && lines=""
    file_kind "$path"; rc=$?
    if [ "$rc" -eq 3 ]; then unsupported="$unsupported $path"; continue; fi
    [ "$rc" -eq 0 ] && [ -f "$read_path" ] || continue
    scanned=$((scanned + 1))
    results="$results$(scan_file "$path" "$lines" "$read_path")"$'\n'
  done <<<"$out"
  printf '%s' "$results" | sed '/^$/d'
  printf 'i18n scan: candidates=%s excluded=%s files=%s\n' \
    "$(printf '%s' "$results" | grep -c $'\tCANDIDATE\t')" "$(printf '%s' "$results" | grep -c $'\tEXCLUDED:')" "$scanned" >&2
  if [ -n "$unsupported" ]; then
    printf 'scan-strings: no scanner for:%s — build one for that language, keep it in the project tooling, and cite it\n' "$unsupported" >&2
    exit 3
  fi
}

case "$mode" in
  detect) detect ;;
  find)   find_resource ;;
  *)      list ;;
esac
