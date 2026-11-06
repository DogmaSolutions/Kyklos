#!/usr/bin/env bash
# proof-authentication.sh — pure, testable helpers that raise the story-proof gate from authenticating the
# STRING "PROVEN" toward authenticating the PROOF itself. Used by kyklos-story-proof-guard.sh. Every helper is a
# best-effort HEURISTIC and MUST stay FAIL-OPEN: on any parse failure, missing tool, or uncertainty it prints
# nothing (no finding), so a legitimate close can never be wedged. It only ever reports a concretely-FALSE claim.
#
# Three helpers, all fail-open:
#   proof_missing_test_citations  — a Proof that CITES a named test artifact (a *.sh / *.ps1 file, or a test-<name>
#                                   suite) which exists NOWHERE in the repo is fabricated; name the missing one.
#   proof_ra_register_empty       — when the Proof marks Risk Assessment PROVEN, the risk register (its text, passed by the
#                                   caller) must enumerate at least one RA-## item.
#   proof_ra_untraced             — a cited RA-## with no matching [RiskMitigation RA-##] anywhere: a SOFT signal
#                                   (WARN), not a block.

# ------------------------------------------------------------------------------------------------------------------
# _proof_cited_test_tokens PROOF_TEXT -> print each distinct cited TEST-ARTIFACT token on its own line.
#
# A token is treated as a test citation ONLY when it clearly looks like a test artifact, so prose never false-fires:
#   * a script file:  <base>.sh  or  <base>.ps1   (covers *.Tests.ps1),  base = [A-Za-z0-9_.-]+
#   * a suite name:   test-<name>                  (name = [a-z][a-z0-9-]*)
# Any looser match would flag ordinary words. We scan only the rendered table rows (lines containing a `|`),
# never HTML-comment legend lines (`<!-- ... -->`), so the template legend's own wording is ignored.
_proof_cited_test_tokens() {
    printf '%s\n' "$1" \
        | grep -F '|' \
        | grep -v '<!--' \
        | grep -oE '([A-Za-z0-9_.-]+\.(sh|ps1))|(test-[a-z][a-z0-9-]*)' \
        | sort -u
}

# ------------------------------------------------------------------------------------------------------------------
# _proof_repo_has_token PROJECT_DIR TOKEN -> exit 0 iff TOKEN names something present in the repo's test surface.
#
# "Present" = the token appears as a substring of a path in the repo's TRACKED + UNTRACKED file list
# (`git ls-files --cached --others --exclude-standard`, so a test added THIS session but not yet committed still
# counts) OR of any working-tree path found by `find`. Matching the token as a literal substring of a path
# catches a file basename (foo.Tests.ps1) and a suite name embedded in a filename (test-foo -> test-foo.sh).
# Fail-open: if git is unavailable OR the file list cannot be read we report PRESENT (can't disprove -> don't
# block). The `find` fallback also covers a non-git working tree, so an empty git listing never false-blocks.
_proof_repo_has_token() {
    local proj="$1" tok="$2" listing
    if command -v git >/dev/null 2>&1; then
        listing="$(git -C "$proj" ls-files --cached --others --exclude-standard 2>/dev/null || true)"
        [ -n "$listing" ] && printf '%s\n' "$listing" | grep -Fc -- "$tok" >/dev/null && return 0
    fi
    # Working-tree fallback (covers non-git trees and anything git did not enumerate).
    find "$proj" -name "*$tok*" -not -path '*/.git/*' 2>/dev/null | grep -c . >/dev/null && return 0
    return 1
}

# ------------------------------------------------------------------------------------------------------------------
# proof_missing_test_citations PROJECT_DIR PROOF_TEXT -> print the FIRST cited test token that exists nowhere.
# Prints nothing (and returns 0) when every citation resolves, or when there is NO parseable citation at all
# (many dimensions are reasoning-signal, not a named test — absence of a citation is never a block). Fail-open.
proof_missing_test_citations() {
    local proj="$1" proof="$2" tok present=0
    local toks=""
    while IFS= read -r tok; do [ -n "$tok" ] && toks="${toks}${tok}"$'\n'; done <<EOF
$(_proof_cited_test_tokens "$proof")
EOF
    [ -n "$toks" ] || return 0
    # CROSS-REPO GUARD (fail-open): an infra/companion story keeps its folder in ONE repo while the code+tests it
    # cites live in a SIBLING repo (e.g. a workspace story citing a sibling repository's *.Tests.ps1), so NONE of the
    # cited tests resolve HERE — that is the multi-repo model, not fabrication. Only judge citations when this repo
    # DEMONSTRABLY hosts the cited tests (>=1 resolves locally); when zero resolve, skip silently (never block a
    # legitimate cross-repo close). When >=1 resolves, a cited test that is absent while its siblings are present
    # is a genuine false claim -> report the first such one.
    while IFS= read -r tok; do
        [ -n "$tok" ] || continue
        _proof_repo_has_token "$proj" "$tok" && { present=1; break; }
    done <<EOF
$toks
EOF
    [ "$present" -eq 1 ] || return 0
    while IFS= read -r tok; do
        [ -n "$tok" ] || continue
        if ! _proof_repo_has_token "$proj" "$tok"; then
            printf '%s\n' "$tok"
            return 0
        fi
    done <<EOF
$toks
EOF
    return 0
}

# ------------------------------------------------------------------------------------------------------------------
# proof_ra_register_empty REGISTER_TEXT -> exit 0 (TRUE, "empty") iff the register text is PRESENT but has NO
# `RA-##` item. Used only when the Proof marks Risk Assessment PROVEN, with the register TEXT read through the
# backend seam (backend_ra_read) so it works identically on the FS file and the GitLab note. Fail-open: a BLANK /
# absent register is NOT reported empty here (the guard's separate interview check covers a truly-missing register);
# we only flag a present-but-item-less register — preserving the exact FS semantics on both backends.
proof_ra_register_empty() {
    [ -n "$(printf '%s' "$1" | tr -d '[:space:]')" ] || return 1  # blank/absent -> not our finding (fail-open)
    printf '%s' "$1" | grep -cE 'RA-[0-9]+' >/dev/null && return 1           # has at least one RA-## -> not empty
    return 0
}

# ------------------------------------------------------------------------------------------------------------------
# proof_ra_untraced REGISTER_TEXT PROJECT_DIR -> print each RA-## enumerated in the register text that claims a code
# mitigation yet has NO matching `[RiskMitigation RA-##]` anywhere in the tracked tree. SOFT signal (the guard
# turns this into a WARN in the reason, never a hard block — some RA items are process, not code). Fail-open.
proof_ra_untraced() {
    local reg="$1" proj="$2" item line
    [ -n "$(printf '%s' "$reg" | tr -d '[:space:]')" ] || return 0
    command -v git >/dev/null 2>&1 || return 0
    # Enumerate the RA-## identifiers the register declares.
    for item in $(printf '%s' "$reg" | grep -oE 'RA-[0-9]+' | sort -u); do
        # Consider only items whose register line hints at a CODE mitigation (mentions code/mitigat/[RiskMitigation]).
        line="$(printf '%s' "$reg" | grep -E "$item")"
        printf '%s' "$line" | grep -ciE 'mitigat|in.?code|\[RiskMitigation' >/dev/null || continue
        # Is there a matching [RiskMitigation RA-##] anywhere tracked? (the greppable convention, mirrors [CySec])
        if ! git -C "$proj" grep -qE "\[RiskMitigation[[:space:]]+$item" 2>/dev/null; then
            printf '%s\n' "$item"
        fi
    done
    return 0
}
