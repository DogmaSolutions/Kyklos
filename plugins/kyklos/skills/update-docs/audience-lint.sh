#!/usr/bin/env bash
# audience-lint.sh — the poka-yoke for the ssdlc-story-proof "Documentation" dimension (skill: update-docs).
#
# Greps CONSUMER-FACING doc files for INTERNAL content that must never ship to a consumer (a public README,
# marketplace/plugin doc, or the nested public source repo). Exits 1 on any hit so an internal leak cannot
# silently ship; exits 0 when every file is clean. bash + grep only, so it runs in any ephemeral container.
#
# Usage:   audience-lint.sh <consumer-facing-file> [more files...]
# Extend:  set AUDIENCE_LINT_EXTRA_PATTERNS to a newline-separated list of extra ERE patterns (project policy).
# Org:     the built-in set is GENERIC (it names nothing of any one organisation). The organisation's own markers
#          (its domain, secret paths, CI variable names) are configuration, added to the built-in set at run time
#          from AUDIENCE_LINT_ORG_PATTERNS and/or a pattern file (see audience-lint-org-patterns.sh). When none is
#          configured the generic set still runs and ONE notice says so on stderr; it is never a silent skip.
# Swap:    set AUDIENCE_LINT_PATTERNS_FILE to use another pattern set (one ERE per line) instead of the built-in one,
#          e.g. a set tuned for test and CI files, where the doc patterns would flag ordinary code.
# Allow:   set AUDIENCE_LINT_ALLOW_FILE to a reviewed allow-list, one entry per line:
#          <path glob><TAB><ERE the hit line must match><TAB><reason>. A hit is skipped only when its file matches the
#          glob AND its line matches the ERE. An entry without a reason is refused (exit 2): every exception is argued.
# Case:    matching ignores case by default; AUDIENCE_LINT_CASE_SENSITIVE=1 makes it exact (for id formats like
#          upper-case story ids, where lower-case prose must not match).
#
# The built-in patterns are the high-signal internal markers the Documentation dimension exists to catch
# (infra endpoints, CI/runner internals, secret locations, private-repo scaffolding, agent artefacts). They are
# deliberately specific to avoid false positives on legitimate consumer prose. Tune per project via the env var.
set +e -uo pipefail

# [CySec] Prevents CWE-200 "Exposure of Sensitive Information to an Unauthorized Actor": block internal infra /
# secret-location / private-repo details from leaking into consumer-facing documentation.
AL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Patterns externalized to audience-lint-patterns.txt (one ERE per line) — the former inline multi-line
# PATTERNS=() array literal reads to kcov as phantom uncovered lines. Loaded verbatim; blank/#-comment lines skipped.
AL_PATTERNS_FILE="${AUDIENCE_LINT_PATTERNS_FILE:-$AL_DIR/audience-lint-patterns.txt}"
if [ ! -r "$AL_PATTERNS_FILE" ]; then
  echo "audience-lint: patterns file not readable: $AL_PATTERNS_FILE" >&2
  exit 2
fi
# Every pattern carries a label that names WHAT kind of marker it is; a finding prints the label and the matched line,
# never the pattern itself. [CySec] Prevents CWE-200 (exposure of sensitive information): an organisation's pattern
# list names its customers and projects, and printing it would show them to every project's agent and log.
PATTERNS=(); LABELS=()
AL_SET_LABEL="generic marker"
[ -n "${AUDIENCE_LINT_PATTERNS_FILE:-}" ] && AL_SET_LABEL="${AUDIENCE_LINT_PATTERNS_LABEL:-marker of the given pattern set}"
while IFS= read -r _al_pat; do
  case "$_al_pat" in ''|'#'*) continue ;; esac
  PATTERNS+=("$_al_pat"); LABELS+=("$AL_SET_LABEL")
done < "$AL_PATTERNS_FILE"
# The organisation-specific half joins the BUILT-IN set only: a swapped set (AUDIENCE_LINT_PATTERNS_FILE) belongs to a
# caller that supplies its own organisation half (e.g. the external-disclosure scan and the internal-refs lint).
AL_ORG_ENTRIES=""
if [ -z "${AUDIENCE_LINT_PATTERNS_FILE:-}" ]; then
  # shellcheck source=SCRIPTDIR/audience-lint-org-patterns.sh
  . "$AL_DIR/audience-lint-org-patterns.sh"
  _al_org="$(al_org_patterns)"; _al_org_rc=$?
  case "$_al_org_rc" in
    # The organisation entries are matched by the loader (plain and sealed alike), each in its own case mode.
    0) AL_ORG_ENTRIES="$_al_org" ;;
    1) al_org_patterns_notice ;;
    *) exit 2 ;;
  esac
fi
# An empty set would pass every file without checking anything: refuse it instead of passing silently.
if [ "${#PATTERNS[@]}" -eq 0 ] && [ -z "$AL_ORG_ENTRIES" ]; then
  echo "audience-lint: no patterns in $AL_PATTERNS_FILE; refusing to run a check that cannot fail" >&2
  exit 2
fi

# Optional reviewed allow-list (see the header). Parsed up front so a malformed entry fails before any scan.
ALLOW_GLOBS=(); ALLOW_RES=()
if [ -n "${AUDIENCE_LINT_ALLOW_FILE:-}" ]; then
  if [ ! -r "$AUDIENCE_LINT_ALLOW_FILE" ]; then
    echo "audience-lint: allow-list not readable: $AUDIENCE_LINT_ALLOW_FILE" >&2
    exit 2
  fi
  while IFS=$'\t' read -r _al_glob _al_re _al_why; do
    case "$_al_glob" in ''|'#'*) continue ;; esac
    if [ -z "$_al_re" ] || [ -z "$_al_why" ]; then
      echo "audience-lint: allow-list entry needs <glob><TAB><regex><TAB><reason>: $_al_glob" >&2
      exit 2
    fi
    # An entry whose line pattern matches an empty line would allow EVERY hit in its paths: a blanket skip, refused.
    if printf '\n' | grep -cE -- "$_al_re" 2>/dev/null >/dev/null; then
      echo "audience-lint: allow-list entry matches any line (too broad; name the exact fixture line): $_al_glob" >&2
      exit 2
    fi
    ALLOW_GLOBS+=("$_al_glob"); ALLOW_RES+=("$_al_re")
  done < "$AUDIENCE_LINT_ALLOW_FILE"
fi

AL_CASE=(-i)
[ "${AUDIENCE_LINT_CASE_SENSITIVE:-0}" = "1" ] && AL_CASE=()

# The version values are masked before matching (one mask for the engine and the write guard).
# shellcheck source=SCRIPTDIR/audience-lint-version-mask.sh
. "$AL_DIR/audience-lint-version-mask.sh" || { echo "audience-lint: the version mask did not load" >&2; exit 2; }

# al_allowed FILE HITLINE -> 0 when an allow-list entry covers this hit.
al_allowed() {
  local i
  for i in "${!ALLOW_GLOBS[@]}"; do
    # shellcheck disable=SC2053  # the glob is intentionally unquoted: it is a pattern, not a literal
    [[ "$1" == ${ALLOW_GLOBS[$i]} ]] || continue
    printf '%s\n' "$2" | grep -cE ${AL_CASE[@]+"${AL_CASE[@]}"} -- "${ALLOW_RES[$i]}" >/dev/null && return 0
  done
  return 1
}

# Optional per-project extra patterns (newline-separated ERE).
if [ -n "${AUDIENCE_LINT_EXTRA_PATTERNS:-}" ]; then
  while IFS= read -r p; do
    [ -n "$p" ] && { PATTERNS+=("$p"); LABELS+=("project marker"); }
  done <<< "$AUDIENCE_LINT_EXTRA_PATTERNS"
fi

if [ "$#" -eq 0 ]; then
  echo "audience-lint: no files given" >&2
  echo "usage: audience-lint.sh <consumer-facing-file> [more...]" >&2
  exit 2
fi

# [CySec] Hardens CWE-377 "Insecure Temporary File": a fixed /tmp path is predictable and collision-prone
# (parallel runs clobber each other; a pre-planted symlink could redirect the write). mktemp gives a unique,
# private file cleaned up on exit.
HIT="$(mktemp "${TMPDIR:-/tmp}/audience-lint.XXXXXX")" || { echo "audience-lint: mktemp failed" >&2; exit 2; }
trap 'rm -f "$HIT"' EXIT

rc=0
for f in "$@"; do
  if [ ! -f "$f" ]; then
    echo "audience-lint: not a file: $f" >&2
    rc=2
    continue
  fi
  if [ -n "$AL_ORG_ENTRIES" ]; then
    while IFS=$'\t' read -r _al_n _al_cat _al_word; do
      [ -n "$_al_n" ] || continue
      # Line 0 is the whole file: it could not be checked, so no line exists to show and no allow-list entry applies.
      if [ "$_al_n" -eq 0 ]; then
        echo "LEAK  $f: internal marker [$_al_cat] -> $_al_word"
        rc=1
        continue
      fi
      hit="$_al_n:$(sed -n "${_al_n}p" "$f")"
      al_allowed "$f" "$hit" && continue
      echo "LEAK  $f: internal marker [$_al_cat] -> $hit"
      rc=1
    done < <(al_org_scan "$f" "$AL_ORG_ENTRIES" | sort -t$'\t' -k1,1n -u)
  fi
  for i in "${!PATTERNS[@]}"; do
    if al_mask_versions "$f" | grep -nE ${AL_CASE[@]+"${AL_CASE[@]}"} -- "${PATTERNS[$i]}" >"$HIT" 2>/dev/null; then
      while IFS= read -r hit; do
        al_allowed "$f" "$hit" && continue
        echo "LEAK  $f: internal marker [${LABELS[$i]}] -> $hit"
        rc=1
      done < "$HIT"
    fi
  done
done
if [ "$rc" -eq 0 ]; then
  echo "audience-lint: OK ($# file(s) clean of internal markers)"
fi
exit "$rc"
