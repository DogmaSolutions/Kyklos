#!/usr/bin/env bash
# kyklos-public-source-refs-guard.sh — PreToolUse(Write|Edit|MultiEdit). TWO border checks, earliest possible
# catch (before the write even lands, let alone commits/pushes):
#   1. The COMPANION border: an internal tracker/backlog identifier written into the nested PUBLIC source
#      (the repo selected by KYKLOS_SOURCE_DIR) — private process artifacts never enter a public-shipped repo.
#   2. The CROSS-REPO border: an internal marker (tracker ids + the shared audience-lint grammar) written into
#      ANY git repo that is not the session's OWN project repo — internal references live ONLY in the internal
#      repo; every other repo may be or become publicly visible. DEFAULT-ON; opt out per-session with
#      KYKLOS_BORDER_CONTROL=off; extra internal-tier repos via KYKLOS_INTERNAL_REPOS (colon-separated
#      toplevels). The own repo is recognised by identity (lib/same-repository.sh), so its worktrees and clones
#      are home too. Blocks only on PROVEN classification (a real foreign git repo + a real marker) — anything
#      ambiguous stays allowed so scratch files and new checkouts never wedge a session. The source named by
#      KYKLOS_SOURCE_DIR takes the organisation half of this border, after the companion border.
#
# The project's OWN names (KYKLOS_OWN_NAMES, a launcher setting read from the environment, never from a file) are
# exempted from the organisation half of border 2, and only for a write into the session project's own nested source.
# The internal-reference half and every other repository keep the whole check; no list exempts nothing. A refusal for
# an organisation name says so and never repeats the name.
#
# Forbidden token shapes (private-tracker-specific): STORY-<n>, Story<n> (as an identifier, e.g. Story083Tests),
# source#<n>, FOUND-<n>, companion#<n>.
#
# FAIL-OPEN, per border:
#   companion border: needs KYKLOS_SOURCE_DIR; a target not under the nested public source, or no new content =>
#                     allow. It blocks only a write it can prove targets the public source AND adds a forbidden token.
#   cross-repo border: applies whether or not KYKLOS_SOURCE_DIR is set; blocks only a write into a proven foreign
#                     git repo that adds a real marker.
#
# Wired: PreToolUse, matcher Edit|Write|MultiEdit.
set +e -uo pipefail

INPUT="$(cat || true)"
command -v jq >/dev/null 2>&1 || { echo "[kyklos] WARNING: public-source-refs guard INERT — jq is missing; internal-ref leak-prevention on public source files is NOT enforced. Install jq." >&2; exit 0; }
# An unset KYKLOS_SOURCE_DIR only disables the COMPANION border - the cross-repo border below still applies.
srcdir="${KYKLOS_SOURCE_DIR:-}"

fp="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)"
[ -n "$fp" ] || exit 0

# Is the target under the nested public source? Its git toplevel ends in /<srcdir> AND is nested in an OUTER git
# repo (the companion). PROJECT_DIR-independent. (The general resolver for the public source is
# repo_public_source_of in lib/repo-role.sh.)
dir="$(dirname "$fp")"
top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || echo "")"
[ -n "$top" ] || exit 0
_companion_target=1
{ [ -z "$srcdir" ]; } && _companion_target=0
case "$top" in */"$srcdir") : ;; *) _companion_target=0 ;; esac
[ "$_companion_target" = 1 ] && { git -C "$(dirname "$top")" rev-parse --show-toplevel >/dev/null 2>&1 || _companion_target=0; }

# The NEW content being written (Write.content, Edit.new_string, or MultiEdit.edits[].new_string).
newtext="$(printf '%s' "$INPUT" | jq -r '
    .tool_input.content
    // .tool_input.new_string
    // ([.tool_input.edits[]?.new_string] | join("\n"))
    // empty' 2>/dev/null || true)"
[ -n "$newtext" ] || exit 0

# Forbidden private-tracker token shapes.
pat='STORY-[0-9]+|Story[0-9]+|source#[0-9]+|FOUND-[0-9]+|companion#[0-9]+'

# block_with <reason> -> the hook's refusal, quoted for its JSON answer.
block_with() {
    local reason="$1"
    reason="${reason//\\/\\\\}"; reason="${reason//\"/\\\"}"; reason="$(printf '%s' "$reason" | tr '\n' ' ')"
    printf '{"decision":"block","reason":"%s"}' "$reason"
}

# own_nested_source -> 0 only when the target is a checkout of the nested source of the session's own project: the
# target, or the main checkout of a linked worktree, sits exactly at the source folder of KYKLOS_SOURCE_DIR. The folder
# comes from the environment only, never from a file the agent can edit; unset, nothing is the own source.
# [CySec] Prevents CWE-200: the own-name exemption reaches no other repository, not even another repository nested in
# the same companion, so the names cannot be carried into a repository they do not belong to.
own_nested_source() {
    local cand parent
    [ -n "$srcdir" ] || return 1
    for cand in "$top" "$(_rr_main_checkout "$top" 2>/dev/null)"; do
        [ -n "$cand" ] || continue
        parent="$(git -C "$(dirname "$cand")" rev-parse --show-toplevel 2>/dev/null)" || continue
        [ "$cand" = "$parent/$srcdir" ] || continue
        { [ "$parent" = "$own" ] || same_repository "$parent" "$own"; } && return 0
    done
    return 1
}

# --- border 1: the public source carries no private tracker identifier. Not switchable.
if [ "$_companion_target" = 1 ]; then
    hit="$(printf '%s' "$newtext" | grep -oE "$pat" 2>/dev/null | sort -u | head -6 | tr '\n' ' ' | sed 's/ $//')"
    if [ -n "$hit" ]; then
        block_with "BLOCKED: '$(basename "$fp")' is in the PUBLIC source ('$srcdir') but the new content introduces internal tracker identifier(s): ${hit}. The public source must stay FREE of private process artifacts (STORY-NNN, StoryNNN, source#N, FOUND-N, companion#N) — they are AI/agent/process leakage, not shippable code. Rename/rephrase without the tracker id: e.g. a test type named after its story number -> a behaviour name like 'DbUtilsConversionCoverageTests'; cite a fix by WHAT it does, not its story number. (A genuine public GitHub issue number is none of these private shapes.)"
        exit 0
    fi
fi

# --- border 2: a write into a FOREIGN git repo (not the session's own project repo, not an allowlisted
#     internal tier) must not introduce internal markers: the tracker shapes above, cross-project issue refs,
#     or the shared audience-lint grammar (ONE pattern source with the docs lint - the grammar cannot fork).
{
    # shellcheck source=lib/control-switch.sh
    . "$(dirname "${BASH_SOURCE[0]}")/lib/control-switch.sh" 2>/dev/null || true   # kyklos_control_off: the one control-switch reader
    kyklos_control_off "${KYKLOS_BORDER_CONTROL:-}" && exit 0
    own="$(git -C "${CLAUDE_PROJECT_DIR:-.}" rev-parse --show-toplevel 2>/dev/null || echo "")"
    [ -n "$own" ] || exit 0
    [ "$top" = "$own" ] && exit 0
    # A linked worktree or a clone of the session's own repository is the same repository, judged by identity
    # (shared git store, or remotes that all point at it), never by its folder.
    # shellcheck source=SCRIPTDIR/lib/same-repository.sh
    . "$(dirname "${BASH_SOURCE[0]}")/lib/same-repository.sh"
    same_repository "$top" "$own" && exit 0
    case ":${KYKLOS_INTERNAL_REPOS:-}:" in *":$top:"*) exit 0 ;; esac
    # The source named by KYKLOS_SOURCE_DIR already passed its tracker check above; of this border it takes only the
    # organisation half, because a public source may name a language version or an upstream project's issue.
    xpat="$pat|[A-Za-z][A-Za-z0-9-]*#[0-9]+"
    [ "$_companion_target" = 1 ] && xpat="$pat"
    hit="$(printf '%s' "$newtext" | grep -oE "$xpat" 2>/dev/null | sort -u | head -6 | tr '\n' ' ' | sed 's/ $//')"
    if [ -z "$hit" ]; then
        _pdir="$(dirname "${BASH_SOURCE[0]}")/../skills/update-docs"
        _plib="$_pdir/audience-lint-patterns.txt"
        # The generic shipped set plus the organisation-specific half from configuration (the same loader the docs lint
        # uses). Without an organisation half the generic set still runs and one notice says so; never a silent skip.
        _pgen=() _porg=""
        [ "$_companion_target" = 0 ] && [ -f "$_plib" ] && mapfile -t _pgen < "$_plib"
        if [ -f "$_pdir/audience-lint-org-patterns.sh" ]; then
            # shellcheck source=SCRIPTDIR/../skills/update-docs/audience-lint-org-patterns.sh
            . "$_pdir/audience-lint-org-patterns.sh"
            # The loader's own reason (never a pattern) goes into the block reason, so a refusal says what to fix.
            _perrf="$(mktemp "${TMPDIR:-/tmp}/border-control-err.XXXXXX" 2>/dev/null)" || _perrf=/dev/null
            _porgtext="$(al_org_patterns 2>"$_perrf")"; _prc=$?
            _perr="$( [ "$_perrf" = /dev/null ] || { head -1 "$_perrf"; rm -f "$_perrf"; } )"
            if [ "$_prc" -eq 0 ]; then
                _porg="$_porgtext"
            elif [ "$_prc" -eq 1 ]; then
                al_org_patterns_notice
            else
                # An unreadable named file or an invalid pattern is a configuration error: block, never pass.
                hit="(cannot check: ${_perr:-the organisation patterns are misconfigured}; fix AUDIENCE_LINT_ORG_PATTERNS or AUDIENCE_LINT_ORG_PATTERNS_FILE, or the tool it names)"
            fi
        fi
        # The generic patterns judge the text with its version values masked, as the docs lint does (one mask): a
        # version number such as an assembly's file version is never read as a private address.
        _pmasked="$newtext"
        if [ "${#_pgen[@]}" -gt 0 ]; then
            # shellcheck source=SCRIPTDIR/../skills/update-docs/audience-lint-version-mask.sh
            if . "$_pdir/audience-lint-version-mask.sh" 2>/dev/null; then
                _pmasked="$(printf '%s' "$newtext" | al_mask_versions)"
            else
                hit="(cannot check: the version mask of the generic patterns did not load; reinstall the plugin)"
            fi
        fi
        for _pl in ${_pgen[@]+"${_pgen[@]}"}; do
            [ -z "$hit" ] || break
            _pl="${_pl%$'\r'}"
            case "$_pl" in ''|'#'*) continue ;; esac
            if printf '%s' "$_pmasked" | grep -cE -- "$_pl" 2>/dev/null >/dev/null; then
                hit="generic marker: $(printf '%s' "$_pmasked" | grep -oE -- "$_pl" 2>/dev/null | sort -u | head -3 | tr '\n' ' ' | sed 's/ $//')"
            fi
        done
        # The organisation half is matched by the loader, plain and sealed entries alike, each in its own case mode.
        # [CySec] Prevents CWE-200: a sealed name is never repeated in the reason, and a plain entry's reason names its
        # category and the matched text, never an organisation pattern, which may name the organisation's customers.
        if [ -z "$hit" ] && [ -n "$_porg" ]; then
            # The own names count only here, and only once the target is proven the own nested source; a resolver that
            # cannot load proves nothing, so nothing is exempted.
            _pown=""
            if [ -n "${KYKLOS_OWN_NAMES:-}" ]; then
                # shellcheck source=SCRIPTDIR/lib/repo-role.sh
                . "$(dirname "${BASH_SOURCE[0]}")/lib/repo-role.sh" 2>/dev/null \
                    && own_nested_source && _pown="$(al_org_own_names)"
            fi
            _ptmp="$(mktemp "${TMPDIR:-/tmp}/border-control.XXXXXX")" && {
                printf '%s\n' "$newtext" > "$_ptmp"
                _phits="$(al_org_scan "$_ptmp" "$(printf '%s\n' "$_porg" | grep -a '^sealed')" "$_pown")"
                # A line-0 hit is "could not be checked", which names no organisation word.
                if [ -n "$_phits" ] && ! printf '%s\n' "$_phits" | grep -ac "^0"$'\t' >/dev/null; then
                    _porgname=1
                elif [ -z "$_phits" ]; then
                    _phits="$(al_org_scan "$_ptmp" "$(printf '%s\n' "$_porg" | grep -a '^re')" "$_pown")"
                fi
                rm -f "$_ptmp"
                if [ -n "$_phits" ] && [ "${_porgname:-0}" = 0 ]; then
                    hit="$(printf '%s\n' "$_phits" | head -1 | cut -f2): $(printf '%s\n' "$_phits" | cut -f3 | sort -u | head -3 | tr '\n' ' ' | sed 's/ $//')"
                fi
            } || hit="(cannot check: no temporary file for the organisation patterns)"
        fi
    fi
    if [ "${_porgname:-0}" = 1 ]; then
        block_with "BLOCKED: '$(basename "$fp")' is not in this session's own project repo, and the new content contains an organisation name from the sealed list (not repeated here). Organisation names stay out of every repo that may be or become publicly visible: reword without the name. A project's own names are allowed only in its own nested source, through the launcher setting KYKLOS_OWN_NAMES."
        exit 0
    fi
    [ -n "$hit" ] || exit 0
    block_with "BLOCKED: '$(basename "$fp")' is in a repo that is NOT this session's own project repo ('$top' vs '$own'), and the new content introduces internal marker(s): ${hit}. Internal references (story ids, issue refs, infra details) live ONLY in the internal repository - every other repo may be or become publicly visible. State the INTENT instead of the tracker/infra reference. Deliberate exception: KYKLOS_BORDER_CONTROL=off, or add the repo to KYKLOS_INTERNAL_REPOS."
    exit 0
}
