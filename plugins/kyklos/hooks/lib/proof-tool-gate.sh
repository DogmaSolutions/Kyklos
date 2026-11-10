#!/usr/bin/env bash
# proof-tool-gate.sh -- the FAIL-HARD complement to proof-authentication.sh's fail-open heuristics.
#
# A SMALL subset of proof dimensions is genuinely mechanizable: a real tool emits a concrete artifact that
# PROVES the dimension over the exact files it inspected. For those "tool-gated" dimensions a PROVEN verdict is
# accepted ONLY when backed by a token the tool itself emitted over those files, anchored on the story's own change to
# each (see "The change fingerprint" below) -- so the row is physically un-fillable without running the tool, and a
# later edit to the story's change invalidates the token. Every
# OTHER dimension keeps the soft heuristic authentication, by design: the reasoning-signal dimensions have no single
# tool that can prove them, so hard-gating them would only invite fabricated tokens. Poka-yoke: for the gated subset
# the mistake (claiming PROVEN without the evidence) is made IMPOSSIBLE, not merely detected after the fact.
#
# CRUCIAL fail-open safety (mirrors proof-authentication.sh): the hard finding fires ONLY when the tool is
# APPLICABLE to this story's change (e.g. code actually changed). A dimension that is NOT_PERTINENT, or a story the
# tool does not apply to, is NEVER blocked by the token gate -- so a legitimate close can never be wedged. (A
# NOT_PERTINENT that the change contradicts is challenged separately, by proof_tool_notpertinent_finding.) The token itself is
# fail-CLOSED (no token / drift / missing file -> not satisfied), but the APPLICABILITY predicate keeps the overall
# gate from ever false-blocking a story the tool was never meant to judge.
#
# Registry: proof_tool_is_gated (which dimensions are gated) and proof_tool_applies (when each applies), below.

# The shared control-switch reader (kyklos_control_off, hooks/lib/control-switch.sh): this file's gates parse their
# flags through the ONE semantics (ambiguity -> enforce). When this file runs alone (the bridge embeds it) the reader
# is absent, every `kyklos_control_off X && skip` call then fails and the gate stays on. Safe to double-source.
_PTG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=control-switch.sh
. "$_PTG_LIB_DIR/control-switch.sh" 2>/dev/null || true   # kyklos_control_off: the one control-switch reader
. "$_PTG_LIB_DIR/git-cmd-detect.sh" 2>/dev/null || true   # story_num_from_branch: the one branch-to-story parser
. "$_PTG_LIB_DIR/refs-footer.sh" 2>/dev/null || true       # refs_footer_*, REFS_FOOTER_AWK: the one definition of what a commit footer cites

# _proof_tool_footer_own REPO -> the project path the footers of REPO's commits are judged against (refs_footer_own_project:
# the repository's settings or its origin), nothing when unknown or when the footer library did not load.
_proof_tool_footer_own() { command -v refs_footer_own_project >/dev/null 2>&1 && refs_footer_own_project "${1:-.}"; return 0; }

# The awk readers below put ${REFS_FOOTER_AWK:-} (the awk functions of the footer definition) in front of their program.
# A gate that cannot read footers must not read "no footer" as "nothing to judge": when the library did not load, the
# program does not compile, its answer is empty and the story is unplaced (the close refuses), never judged on a guess.
# [CySec] CWE-636 (not failing securely)
[ -f "$_PTG_LIB_DIR/../../skills/ssdlc-story-proof/proof-dimensions.sh" ] && \
    . "$_PTG_LIB_DIR/../../skills/ssdlc-story-proof/proof-dimensions.sh"

# The container start marker -- the ONE stable "this container started here" instant. It lives in this file (not a
# sibling) because the bridge embeds and extracts this file alone as its proof CLI.
#
# A check that must tell "made in THIS container" from "left over from an earlier one" needs a reference time that
# never moves. The state folder itself is not one: a folder's modification time changes every time a file is
# created, deleted or renamed inside it (an atomic write via `mv` included), and the hooks do that all the time, so
# comparing against the folder makes something written a minute ago look older than the session. This marker is a
# plain FILE in the container-local state folder, created once (exclusive create, so two concurrent hooks cannot
# both write it) and never rewritten: its modification time is the container's start instant for as long as the
# container lives, and a new container (a fresh state folder) gets a new one.

# container_start_marker_path -> the marker file's path.
container_start_marker_path() { printf '%s/container-start' "${KYKLOS_STATE_DIR:-/tmp/kyklos-state}"; }

# container_start_marker_ensure -> create the marker if it does not exist yet; never touch an existing one. Prints
# the marker path. Returns non-zero only when the marker could not be created and does not exist. The file holds the
# creation instant in epoch seconds for a human reader; checks compare its modification time.
container_start_marker_ensure() {
    local m; m="$(container_start_marker_path)"
    if [ ! -e "$m" ]; then
        mkdir -p "$(dirname "$m")" 2>/dev/null || true
        # noclobber makes the redirect an exclusive create: a marker another process wrote first is left as it is.
        # [RiskMitigation RA-02]
        ( set -C; printf '%s\n' "$(date +%s)" > "$m" ) 2>/dev/null || true
    fi
    [ -f "$m" ] || return 1
    printf '%s' "$m"
}

# _proof_tool_slug DIM -> canonical filesystem slug (lowercase; spaces/underscores/hyphens collapse to '-').
# "Test Discipline", "Test-Discipline", "test_discipline" all map to "test-discipline" so the registry and the
# token filename never drift on cosmetic naming.
_proof_tool_slug() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr ' _' '--'; }

# _proof_tool_shared_dir -> the SHARED token store when one is in use, else nothing (exit 1). The shared store is the
# workspace-mounted `.kyklos/proof-tokens/`, the folder the HOST-side bridge writes to (its solution root), so a token
# the bridge mints is the token the container gates read. Resolution, one rule for every reader and writer:
#   1. KYKLOS_PROOF_TOKEN_DIR, when set (an operator or launcher choice);
#   2. none when KYKLOS_STATE_DIR is set explicitly (a deliberately local state dir, as the test suites use);
#   3. otherwise the first workspace mount that holds `.kyklos/proof-tokens` ($HOME/workspace, then /workspace), the
#      same order the container's startup uses when it creates that folder. A startup script's `export` never reaches
#      the agent's own process, so the gates find the folder on disk instead of relying on that variable.
# [RiskMitigation RA-03] One location rule: a writer and a reader can no longer disagree about where a token lives.
_proof_tool_shared_dir() {
    if [ -n "${KYKLOS_PROOF_TOKEN_DIR:-}" ]; then printf '%s' "$KYKLOS_PROOF_TOKEN_DIR"; return 0; fi
    [ -z "${KYKLOS_STATE_DIR:-}" ] || return 1
    local _ws
    for _ws in "${HOME:-/nonexistent}/workspace" /workspace; do
        if [ -d "$_ws/.kyklos/proof-tokens" ]; then printf '%s' "$_ws/.kyklos/proof-tokens"; return 0; fi
    done
    return 1
}

# _proof_tool_dir -> the dir holding emitted tokens: the shared store (above) when one is in use, else the per-container
# state dir (ephemeral by construction: a fresh container must re-run the tool). With a shared store the ephemerality
# rule moves to the freshness check in proof_tool_verify (a shared dir survives container restarts, so
# mtime-vs-session decides, not dir lifetime).
_proof_tool_dir() { _proof_tool_shared_dir || printf '%s' "${KYKLOS_STATE_DIR:-/tmp/kyklos-state}/proof-tool"; }

# _proof_tool_story_key ID -> the canonical story key: the first run of digits with leading zeros dropped, so
# "#42", "42", "042" and a folder name like "story-042-some-slug" all key the same token. Empty when ID carries no number.
_proof_tool_story_key() {
    local n; n="$(printf '%s' "${1:-}" | grep -oE '[0-9]+' | head -1)"
    [ -n "$n" ] || return 0
    n="$(printf '%s' "$n" | sed -E 's/^0+//')"
    printf '%s' "${n:-0}"
}

# _proof_tool_detect_story DIR -> the story the work in DIR belongs to, derived from git: the branch name
# (".../story-<N>-...") first, else the HEAD commit's story reference ("Refs: #<N>" or "STORY-<N>"). Empty when
# neither names a story. Tokens are bound to a story so two stories proven at the same time in one container can
# never overwrite or satisfy each other's tokens.
_proof_tool_detect_story() {
    local d="${1:-.}" br msg n
    command -v git >/dev/null 2>&1 || return 0
    git -C "$d" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
    br="$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    n="$(story_num_from_branch "$br" | sed -E 's/^0*([0-9])/\1/')"
    if [ -z "$n" ]; then
        msg="$(git -C "$d" log -1 --format='%B' 2>/dev/null)"
        # the first item the head commit's footer cites in the story's own project (a remark is never read for numbers)
        n="$(command -v refs_footer_story_key >/dev/null 2>&1 && refs_footer_story_key "$msg" "$(_proof_tool_footer_own "$d")")"
        [ -n "$n" ] || n="$(printf '%s' "$msg" | grep -oE 'STORY-[0-9]+' | grep -oE '[0-9]+' | head -1)"
    fi
    _proof_tool_story_key "$n"
}

# _proof_tool_token_file DIM STORY -> the token path for DIM bound to STORY ("<dim-slug>@<story>.token").
_proof_tool_token_file() { printf '%s/%s@%s.token' "$(_proof_tool_dir)" "$(_proof_tool_slug "$1")" "$2"; }
# _proof_tool_legacy_token_file DIM -> the pre-binding, story-less token path. Never accepted as proof any more
# (it cannot show which story it proves); only used to explain a refusal.
_proof_tool_legacy_token_file() { printf '%s/%s.token' "$(_proof_tool_dir)" "$(_proof_tool_slug "$1")"; }

# _proof_tool_root -> the root RELATIVE token paths resolve against. Resolution order, most-authoritative first:
#   1. KYKLOS_PROOF_TOKEN_ROOT (explicit override, always wins)
#   2. CLAUDE_PROJECT_DIR        (the declared project/companion root)
#   3. git toplevel of the CWD
#   4. the CWD
# The root MUST be CWD-INDEPENDENT: it must not change with the directory the shell happens to be in. In a
# companion/nested topology the project root (the companion) and the nested source repo are SEPARATE git repos,
# so `git rev-parse --show-toplevel` returns a DIFFERENT toplevel depending on whether the shell sits in the
# companion or in the nested source. A token records paths relative to the project root (e.g. a companion-relative
# `Repo/README.md`); if the gate later re-rooted at the nested repo's toplevel it would resolve that to
# `<nested>/Repo/README.md`, a path that does not exist, and the token would FALSE-BLOCK the close. Anchoring on
# the DECLARED project root (CLAUDE_PROJECT_DIR) before falling back to the ambient git toplevel keeps the same
# token verifying from BOTH the project root and any nested subdir. Recording RELATIVE paths is what makes a token
# PORTABLE across the host/container boundary (the host emitter sees C:\..., the container gate sees /workspace/... —
# an absolute recorded path can only ever verify on the side that wrote it); this change only fixes WHICH root those
# relative paths resolve against, leaving the portable-relative design intact.
# The root is returned in the canonical path form (_proof_tool_canon_path), so emit and verify join the same string.
_proof_tool_root() {
    if [ -n "${KYKLOS_PROOF_TOKEN_ROOT:-}" ]; then _proof_tool_canon_path "$KYKLOS_PROOF_TOKEN_ROOT"; return; fi
    if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "${CLAUDE_PROJECT_DIR}" ]; then _proof_tool_canon_path "$CLAUDE_PROJECT_DIR"; return; fi
    _proof_tool_canon_path "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
}

# _proof_tool_canon_path PATH -> PATH in the ONE form every token path takes, at mint and at verify alike: '/'
# separators (a Windows host hands the CLI C:\... roots) and no trailing '/'. A root of exactly '/' stays '/'.
_proof_tool_canon_path() {
    local p; _proof_tool_canon_path_v p "$1"
    printf '%s' "$p"
}

# _proof_tool_canon_path_v VAR PATH -> set VAR to _proof_tool_canon_path PATH, in the calling shell. Shell built-ins
# only (no subshell, no tr): a token over many files canonicalises every path, and on Git for Windows each process
# start costs tens of milliseconds. Trailing line breaks are dropped as a command substitution of the old pipeline
# dropped them, so both forms give the same text.
_proof_tool_canon_path_v() {
    local _ptg_cp="${2//\\//}"
    while [ "${_ptg_cp%$'\n'}" != "$_ptg_cp" ]; do _ptg_cp="${_ptg_cp%$'\n'}"; done
    while [ "${#_ptg_cp}" -gt 1 ] && [ "${_ptg_cp%/}" != "$_ptg_cp" ]; do _ptg_cp="${_ptg_cp%/}"; done
    printf -v "$1" '%s' "$_ptg_cp"
}

# _proof_tool_sha256 FILE -> the lowercase hex SHA-256 of FILE's bytes (empty when unreadable). The ONE hash every
# token line uses, at mint and at verify. It reads the file on stdin: `sha256sum FILE` escapes a name holding a
# backslash and prefixes the digest with '\', so a Windows path joined onto a relative entry hashed to "\<digest>"
# and an unchanged file read as changed.
_proof_tool_sha256() {
    [ -f "$1" ] || return 0
    sha256sum < "$1" 2>/dev/null | cut -d' ' -f1
}

# _proof_tool_relpath FILE ROOT -> FILE relative to ROOT when it lives under it, else FILE; both in canonical form.
_proof_tool_relpath() {
    local rel; _proof_tool_relpath_v rel "$1" "$2"
    printf '%s' "$rel"
}

# _proof_tool_relpath_v VAR FILE ROOT -> set VAR to _proof_tool_relpath FILE ROOT, in the calling shell (no subshell).
_proof_tool_relpath_v() {
    local _ptg_rp_f _ptg_rp_root
    _proof_tool_canon_path_v _ptg_rp_f "$2"; _proof_tool_canon_path_v _ptg_rp_root "$3"
    case "$_ptg_rp_f" in "$_ptg_rp_root"/*) _ptg_rp_f="${_ptg_rp_f#"$_ptg_rp_root"/}" ;; esac
    printf -v "$1" '%s' "$_ptg_rp_f"
}

# _proof_tool_rel_between FROM TO -> the relative path that leads from folder FROM to folder TO ('..' segments, then
# TO's own), both in the canonical path form; "." when they are the same folder. Prints nothing (rc 1) when there is no
# relative path: either path is not absolute, or they sit on different Windows drives. '.', '..' and '//' in either path
# are resolved first. Pure text, no file access.
_proof_tool_rel_between() {
    local from to fd td common rest up="" out
    from="$(_proof_tool_canon_path "$1")"; to="$(_proof_tool_canon_path "$2")"
    # A drive letter is compared without case (r:/ and R:/ are one drive): both take the upper-case letter.
    case "$from" in /*) fd="" ;; [A-Za-z]:/*) fd="$(printf '%s' "${from%%/*}" | tr '[:lower:]' '[:upper:]')"; from="$fd/${from#*/}" ;; *) return 1 ;; esac
    case "$to" in /*) td="" ;; [A-Za-z]:/*) td="$(printf '%s' "${to%%/*}" | tr '[:lower:]' '[:upper:]')"; to="$td/${to#*/}" ;; *) return 1 ;; esac
    [ "$fd" = "$td" ] || return 1
    # Normal forms first ('.', '..' and '//' resolved), so the walk below compares real folders.
    from="$(_proof_tool_join_rel "$from" .)"; to="$(_proof_tool_join_rel "$to" .)"
    [ "$from" = "$to" ] && { printf '.'; return 0; }
    common="$from"
    while :; do
        case "$to/" in "$common"/*|"$common"/) break ;; esac
        [ "$common" = / ] && break
        # Each step drops one segment; a path that cannot shrink further (no '/') has no relative path: never loop.
        [ "${common%/*}" != "$common" ] || return 1
        common="${common%/*}"; [ -n "$common" ] || common="/"
        up="$up../"
    done
    if [ "$common" = / ]; then rest="${to#/}"; else rest="${to#"$common"}"; rest="${rest#/}"; fi
    out="$up$rest"; out="${out%/}"
    printf '%s' "${out:-.}"
}

# _proof_tool_join_rel DIR REL -> DIR joined with the relative path REL, '.', '..' and empty ('//') segments resolved
# textually, in the canonical path form. Pure text, no file access, no pattern matching.
# [RiskMitigation RA-04] Path text from the sidecar and the token folder is joined as text, never expanded.
_proof_tool_join_rel() {
    local dir seg out="" lead="" parts=() rel=()
    dir="$(_proof_tool_canon_path "$1")"
    case "$dir" in [A-Za-z]:/*) lead="${dir%%/*}"; dir="${dir#*/}" ;; *) dir="${dir#/}" ;; esac
    # read -ra splits on '/' with no pathname expansion: a segment with * ? or [..] stays text, never a pattern.
    IFS=/ read -r -a parts <<< "$dir"
    IFS=/ read -r -a rel <<< "$2"
    for seg in ${parts[@]+"${parts[@]}"} ${rel[@]+"${rel[@]}"}; do
        case "$seg" in ''|.) : ;; ..) out="${out%/*}" ;; *) out="$out/$seg" ;; esac
    done
    printf '%s' "$lead${out:-/}"
}

# _proof_tool_base_file TOKFILE -> the sidecar "<TOKFILE>.base" that names the token's root RELATIVE TO THE TOKEN'S OWN
# FOLDER (for example "../.."). The token folder is the one path the host bridge and the container see alike (the shared
# store), so the sidecar tells either side exactly which folder the entries are relative to, wherever each mounts it.
# The gate reads the entries there and nowhere else: a file missing there is missing, never found under another root.
# A sidecar, not a line in the token, so the token's format (which other tools and older Kyklos versions read) is unchanged.
_proof_tool_base_file() { printf '%s.base' "$1"; }

# _proof_tool_token_base TOKFILE -> the base its sidecar records, or nothing (no sidecar: a token minted before it).
_proof_tool_token_base() {
    local bf; bf="$(_proof_tool_base_file "$1")"
    [ -f "$bf" ] || return 0
    head -1 "$bf" 2>/dev/null | tr -d '\r'
}

# _proof_tool_measured_file TOKFILE -> the sidecar "<TOKFILE>.measured": for each entry whose change fingerprint a run took,
# the commit that fingerprint was measured against (the bridge's trunk answer, handed in through
# KYKLOS_PROOF_MEASURED_AGAINST, else this tool's own fork point), one "<entry path><TAB><commit>" line each, then
# "mac:<MAC>" over the token's own MAC and those lines. A verifier tries an entry's measured-against commit first and then
# its own fork point, so a container whose local trunk ref is older than the one the bridge fetched still reproduces the
# patch-id. Written and renamed with the token and its .base, one rollback for all three; a sidecar whose MAC fails (under
# the host key) reads as absent, a keyless verifier reads its lines as it reads the token's content (equal patch-ids under
# either commit prove the same change). A tool older than the sidecar neither writes nor reads it.
_proof_tool_measured_file() { printf '%s.measured' "$1"; }

# _proof_tool_measured_lines TOKFILE -> the entry lines of TOKFILE's sidecar ("<path><TAB><commit>"), nothing when there
# is none or, under the host key, when its MAC does not sign them with the token's current MAC.
# [CySec] Prevents CWE-345 "Insufficient Verification of Data Authenticity": under the host key a sidecar is read only
# when it is signed together with the token it belongs to.
_proof_tool_measured_lines() {
    local mf stored lines mac tmac
    mf="$(_proof_tool_measured_file "$1")"
    [ -f "$mf" ] || return 0
    stored="$(tr -d '\r' < "$mf" 2>/dev/null)"
    lines="$(printf '%s\n' "$stored" | grep -v '^mac:' | grep -E $'^[^\t]+\t[0-9a-f]{40,64}$' 2>/dev/null)"
    if [ -n "${KYKLOS_PROOF_HMAC_KEY:-}" ]; then
        mac="$(printf '%s\n' "$stored" | sed -n 's/^mac://p' | head -1)"
        tmac="$(sed -n 's/^hmac://p' "$1" 2>/dev/null | head -1)"
        [ -n "$mac" ] && [ -n "$tmac" ] && [ "$mac" = "$(_proof_tool_hmac "$(printf '%s\n%s' "$tmac" "$lines")")" ] || return 0
    fi
    printf '%s\n' "$lines" | sed '/^$/d'
}

# A sidecar may also carry, per entry, the trunk branch and commit that entry's run measured against (handed in through
# KYKLOS_PROOF_TRUNK_REF and KYKLOS_PROOF_TRUNK_COMMIT): "trunk:<path><TAB><ref><TAB><commit>". Two tabs, so the entry
# reader above (one tab) never reads it and the "mac:" line does not cover it; a "mac2:" line signs the token's MAC and
# every entry and trunk line in file order. The bridge reads them to decide whether a token survives later trunk merges;
# a reader that knows only entry lines reads the sidecar exactly as before.
_PTG_TRUNK_LINE_RE=$'^trunk:[^\t]+\t[^\t]+\t[0-9a-f]{40,64}$'
_PTG_ENTRY_LINE_RE=$'^[^\t]+\t[0-9a-f]{40,64}$'

# _proof_tool_trunk_given -> rc 0 iff this emit was handed a usable trunk (a branch name without tabs or line breaks and a
# full commit id); an emit without one writes no trunk line.
_proof_tool_trunk_given() {
    local ref="${KYKLOS_PROOF_TRUNK_REF:-}" commit="${KYKLOS_PROOF_TRUNK_COMMIT:-}"
    [ -n "$ref" ] && [ -n "$commit" ] || return 1
    case "$ref" in *$'\t'*|*$'\n'*|*$'\r'*) return 1 ;; esac
    [[ "$commit" =~ ^[0-9a-f]{40,64}$ ]]
}

# _proof_tool_signed_sidecar_lines TEXT -> the entry and trunk lines of a sidecar's TEXT, in file order: what "mac2:" signs.
# Only the MAC lines themselves ("mac:", "mac2:") are left out, never an entry whose path merely starts with "mac".
_proof_tool_signed_sidecar_lines() {
    printf '%s\n' "$1" | grep -vE '^mac[0-9]*:' | grep -E -e "$_PTG_ENTRY_LINE_RE" -e "$_PTG_TRUNK_LINE_RE" 2>/dev/null
}

# _proof_tool_measured_trunk_lines TOKFILE -> the trunk lines of TOKFILE's sidecar, nothing when there are none or, under
# the host key, when its "mac2:" does not sign them with the token's current MAC (so a later run never carries forged or
# stale trunk lines forward).
# [CySec] Prevents CWE-345 "Insufficient Verification of Data Authenticity": trunk lines are carried only when signed with
# the token they belong to.
_proof_tool_measured_trunk_lines() {
    local mf stored signed mac2 tmac
    mf="$(_proof_tool_measured_file "$1")"
    [ -f "$mf" ] || return 0
    stored="$(tr -d '\r' < "$mf" 2>/dev/null)"
    if [ -n "${KYKLOS_PROOF_HMAC_KEY:-}" ]; then
        signed="$(_proof_tool_signed_sidecar_lines "$stored")"
        mac2="$(printf '%s\n' "$stored" | sed -n 's/^mac2://p' | head -1)"
        tmac="$(sed -n 's/^hmac://p' "$1" 2>/dev/null | head -1)"
        [ -n "$mac2" ] && [ -n "$tmac" ] && [ "$mac2" = "$(_proof_tool_hmac "$(printf '%s\n%s' "$tmac" "$signed")")" ] || return 0
    fi
    printf '%s\n' "$stored" | grep -E "$_PTG_TRUNK_LINE_RE" 2>/dev/null
    return 0
}

# The change fingerprint -- what a token records for a file the story changed.
#
# A coverage run proves the story's OWN change. Recording a file's whole content made the token fail whenever the
# branch merged its trunk and the trunk had edited another part of the same file, although the story's change was
# identical (and the merge request's pipeline re-measures the merged result anyway). So a file the branch changed
# and committed is recorded by the git patch-id of the branch's diff for that file against its merge base with the
# trunk, as "change-<patch-id>":
#   - the diff is taken with no context lines (-U0): git's patch-id hashes context lines, so with context an
#     unrelated trunk edit a line or two away from the story's hunk would still change the id;
#   - patch-id (--verbatim) drops hunk line numbers but keeps whitespace, so trunk edits that only move the story's lines keep it equal;
#   - a merge whose resolution changes the story's own added or removed lines changes the id: the token is then
#     stale, as it must be;
#   - every diff option that a git configuration could change is fixed on the command line, so the host that mints
#     and the container that verifies produce the same diff for the same commits.
# A tree-to-tree diff ignores the working tree, so the fingerprint also requires the file in the working tree to
# equal HEAD's version (line-ending differences aside, which a Windows checkout seen through a Linux mount shows).
# When no fingerprint can be taken -- no trunk to diff against, the file is not tracked, it has uncommitted edits, or
# the branch did not change it -- the file is recorded by its content hash (bare 64-hex), exactly as tokens were
# before; the verifier accepts both forms, so a token minted the earlier way keeps verifying.
_PTG_CHANGE_PREFIX="change-"

# _proof_tool_change_fingerprint FILE [COMMIT] -> print "change-<patch-id>" for FILE, or exit non-zero when no change
# fingerprint applies (see above). Used identically at mint and at verify. With COMMIT (an entry's measured-against
# commit, see _proof_tool_measured_file) the change is taken from that commit, which must be an ancestor of HEAD; without
# it, from this tool's own fork point.
_proof_tool_change_fingerprint() {
    local f="$1" at="${2:-}" dir name base pid
    [ -f "$f" ] || return 1
    command -v git >/dev/null 2>&1 || return 1
    dir="$(dirname "$f")"; name="$(basename "$f")"
    # Uncommitted edits are not in the HEAD tree the fingerprint describes: the content hash covers them instead. The
    # working-tree file is compared with HEAD's blob here, not through `git diff`: git's own view of the working tree
    # can be hidden by an index flag (assume-unchanged, skip-worktree) and runs the repository's configured helpers.
    _proof_tool_equals_head "$dir" "$name" "$f" || return 1
    if [ -n "$at" ]; then
        "${_PTG_GIT[@]}" -C "$dir" merge-base --is-ancestor "$at" HEAD >/dev/null 2>&1 || return 1
        base="$at"
    else
        base="$(_proof_tool_cached_change_base "$dir")" || return 1
    fi
    # --verbatim: whitespace is part of the code (a string literal, "i - -j" against "i--j", Python indentation), so
    # the id must not ignore it. Line numbers are still dropped, which is what lets a trunk merge move the story's lines.
    pid="$(_proof_tool_patch_id "$dir" "$base" HEAD "$name")"
    [ -n "$pid" ] || return 1
    printf '%s%s' "$_PTG_CHANGE_PREFIX" "$pid"
}

# _proof_tool_patch_id DIR BASE REV PATHSPEC -> the patch-id of the change BASE..REV makes to PATHSPEC (resolved from
# DIR), empty when it makes none. The ONE diff a change fingerprint is taken from, at mint, at verify and at close.
_proof_tool_patch_id() {
    "${_PTG_GIT[@]}" -C "$1" diff --no-color --no-ext-diff --no-textconv \
            --no-renames --no-relative --binary -U0 --inter-hunk-context=0 --diff-algorithm=myers --indent-heuristic \
            --src-prefix=a/ --dst-prefix=b/ "$2" "$3" -- "$4" 2>/dev/null \
        | git patch-id --verbatim 2>/dev/null | cut -d' ' -f1
}

# The git every fingerprint step runs. Minting runs with the signing key in its environment, inside a repository the
# agent can configure: nothing that configuration names may run. core.fsmonitor is the command git itself starts on an
# index refresh (not needed here: no step reads the index); textconv and external diff are refused on the command line
# of the diff, and the working-tree comparison reads blobs with cat-file, which applies no filter.
# [CySec] Mitigates CWE-78 "OS Command Injection" / CWE-522 via a repository-configured helper run with the key in reach.
# [RiskMitigation RA-02] No repository-configured helper runs while the signing key is in the environment.
# The hooks folder is pointed at ONE value shared with the host tools: the absolute path of an empty file they own, handed
# in KYKLOS_GIT_HOOKS_PATH by the bridge. A drive-less name (/dev/null, NUL) is not used on Windows, because Git LFS reads it
# as a folder of the working tree and writes its hooks there.
# [CySec] Mitigates CWE-73 "External Control of File Name or Path": no hook file is written into a working tree.
_proof_tool_hooks_path() {
    if [ -n "${KYKLOS_GIT_HOOKS_PATH:-}" ]; then printf '%s' "$KYKLOS_GIT_HOOKS_PATH"; return 0; fi
    case "$(uname -s 2>/dev/null)" in
        MINGW*|MSYS*|CYGWIN*)
            # The same file the host tools use: Kyklos/no-git-hooks under the local application data.
            # A folder standing there (it could hold hooks) or no such place: a fresh empty file of this run instead.
            local base="${LOCALAPPDATA:-${TEMP:-${TMP:-}}}" file=""
            if [ -n "$base" ]; then
                file="${base//\\//}/Kyklos/no-git-hooks"
                if [ ! -d "$file" ]; then mkdir -p "${file%/*}" 2>/dev/null && { [ -f "$file" ] || : >> "$file"; } 2>/dev/null; fi
                [ -f "$file" ] || file=""
            fi
            [ -n "$file" ] || file="$(mktemp "${TMPDIR:-/tmp}/kyklos-no-git-hooks.XXXXXX" 2>/dev/null)"
            printf '%s' "${file:-/dev/null}"
            ;;
        *) printf '/dev/null' ;;
    esac
}
_PTG_GIT=(git -c core.fsmonitor=false -c "core.hooksPath=$(_proof_tool_hooks_path)" -c core.pager=cat -c diff.external= )

# _proof_tool_equals_head DIR NAME FILE -> 0 iff NAME is in HEAD's tree and FILE holds the same text (a trailing
# carriage return on a line aside, which a Windows checkout seen through a Linux mount shows).
# [RiskMitigation RA-01] An edit hidden from git (index flags, filters) cannot pass as the measured change.
_proof_tool_equals_head() {
    local dir="$1" name="$2" f="$3"
    "${_PTG_GIT[@]}" -C "$dir" cat-file -e "HEAD:./$name" >/dev/null 2>&1 || return 1
    cmp -s <("${_PTG_GIT[@]}" -C "$dir" cat-file blob "HEAD:./$name" 2>/dev/null | sed 's/\r$//') <(sed 's/\r$//' "$f")
}

# _proof_tool_differs_in_mode_or_endings DIR NAME FILE -> 0 iff FILE differs from HEAD's NAME in its executable bit (when
# the repository tracks modes) or in its line endings: the edits `git diff HEAD` lists although the text comparison of
# _proof_tool_equals_head cannot see them. Reads blobs and the tree only (cat-file, ls-tree): no filter runs.
_proof_tool_differs_in_mode_or_endings() {
    local dir="$1" name="$2" f="$3" tracked_mode
    cmp -s <("${_PTG_GIT[@]}" -C "$dir" cat-file blob "HEAD:./$name" 2>/dev/null) "$f" || return 0
    [ "$("${_PTG_GIT[@]}" -C "$dir" config --bool core.fileMode 2>/dev/null)" = "false" ] && return 1
    tracked_mode="$("${_PTG_GIT[@]}" -C "$dir" ls-tree HEAD -- "$name" 2>/dev/null | cut -d' ' -f1)"
    case "$tracked_mode" in
        100755) [ -x "$f" ] || return 0 ;;
        100644) [ -x "$f" ] && return 0 ;;
    esac
    return 1
}

# _proof_tool_cached_change_base DIR -> proof_tool_change_base for DIR's repository, resolved once per repository within
# one emit or verify (the caller resets _PTG_BASE_CACHE first, so a later merge of the trunk is always seen). Resolving
# the base costs several git calls per trunk candidate; a token over many files of one repository needs it once.
declare -gA _PTG_BASE_CACHE=() 2>/dev/null || true
_proof_tool_cached_change_base() {
    local top base
    top="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" || return 1
    [ -n "$top" ] || return 1
    if [ -n "${_PTG_BASE_CACHE[$top]+set}" ]; then base="${_PTG_BASE_CACHE[$top]}"
    else base="$(proof_tool_change_base "$top" 2>/dev/null || true)"; _PTG_BASE_CACHE[$top]="$base"
    fi
    [ -n "$base" ] || return 1
    printf '%s' "$base"
}

# _proof_tool_fingerprint FILE -> the value a token records for FILE: its change fingerprint when one applies, else
# its content hash. Empty when the file is unreadable.
_proof_tool_fingerprint() {
    _proof_tool_change_fingerprint "$1" || _proof_tool_sha256 "$1"
}

# _proof_tool_hash_files FILE... -> print "path:fingerprint" per EXISTING file, sorted; skip a missing file. Empty
# output iff none of the paths exist. Sorting makes the token order-independent of the caller's argument order.
# The fingerprints are those of _proof_tool_fingerprint, taken for all files together (_proof_tool_batch_prime): a
# fixed number of git calls per repository instead of a dozen per file.
_proof_tool_hash_files() {
    local f h
    if [ "${_PTG_KEEP_CACHE:-}" != 1 ]; then
        _PTG_BASE_CACHE=(); _PTG_DIR_TOPS=()
        _proof_tool_preset_measured_against "$@"
    fi
    _proof_tool_batch_prime "$@"
    _proof_tool_batch_sha_prime "$@"
    for f in "$@"; do
        [ -f "$f" ] || continue
        _proof_tool_batch_fingerprint_v h "$f"
        [ -n "$h" ] && printf '%s:%s\n' "$f" "$h"
    done | sort
}

# _PTG_DIR_TOPS[folder] -> what `git rev-parse --show-toplevel --show-prefix` printed for a folder ("-" when it failed),
# shared by the emit's preset and the batch prime, so a folder is asked once per emit.
declare -gA _PTG_DIR_TOPS=() 2>/dev/null || true

# _proof_tool_dir_cache DIR -> fill _PTG_DIR_TOPS[DIR] (asked once per emit); rc 1 when the folder is in no work tree.
# Run it in the calling shell (never in a command substitution), so the cache is kept.
_proof_tool_dir_cache() {
    if [ -z "${_PTG_DIR_TOPS[$1]+set}" ]; then
        _PTG_DIR_TOPS[$1]="$("${_PTG_GIT[@]}" -C "$1" rev-parse --show-toplevel --show-prefix 2>/dev/null)" || _PTG_DIR_TOPS[$1]="-"
    fi
    [ "${_PTG_DIR_TOPS[$1]}" != "-" ]
}

# _proof_tool_dir_top DIR -> the folder's top and prefix lines (rc 1 when it is in no work tree), from the cache.
_proof_tool_dir_top() { _proof_tool_dir_cache "$1" || return 1; printf '%s\n' "${_PTG_DIR_TOPS[$1]}"; }

# _proof_tool_preset_measured_against FILE... -> in the calling shell, resolve each folder of FILE... once and the fork
# point of each repository once (_PTG_BASE_CACHE): the bridge's trunk answer when one is handed in
# (KYKLOS_PROOF_MEASURED_AGAINST, a full commit id) and it is an ancestor of that repository's HEAD, else this tool's own
# fork point. Every fingerprint of the mint is then taken from that one commit, which the sidecar records.
_proof_tool_preset_measured_against() {
    local at="${KYKLOS_PROOF_MEASURED_AGAINST:-}" f dir top
    case "$at" in ''|*[!0-9a-f]*) at="" ;; esac
    [ "${#at}" -ge 40 ] || at=""
    for f in "$@"; do
        dir="${f%/*}"; [ -n "$dir" ] || dir=/
        _proof_tool_dir_cache "$dir" || continue
        top="${_PTG_DIR_TOPS[$dir]%%$'\n'*}"
        [ -n "$top" ] && [ -z "${_PTG_BASE_CACHE[$top]+set}" ] || continue
        if [ -n "$at" ] && "${_PTG_GIT[@]}" -C "$top" merge-base --is-ancestor "$at" HEAD >/dev/null 2>&1; then _PTG_BASE_CACHE[$top]="$at"
        else _PTG_BASE_CACHE[$top]="$(proof_tool_change_base "$top" 2>/dev/null || true)"; fi
    done
    return 0
}

# ---- Batched fingerprints (the emit path) --------------------------------------------------------------------------
#
# Minting a token over N changed files asked git about each file one by one: the HEAD blob, the repository top, the
# fork point (merge-base and rev-list for every trunk candidate, since the per-repository cache was filled inside a
# command substitution and so lost), the diff and its patch-id; merging a previous token asked again per entry. That
# is more than a dozen git starts per file and pass, which on a Windows host with a long history ran for minutes. The
# functions below answer the same questions for all files at once: one `rev-parse` per folder, then per repository
# one fork-point resolution, one `cat-file --batch`, one diff with one `patch-id`, one `ls-tree` and one name-only
# diff. They return exactly what the per-file functions return; every file the batch cannot judge with certainty (an
# unusual name, a git error, no perl) is left undecided and judged by the per-file function, so the token is the same
# byte for byte. The per-file functions stay the ones the verifier and the close use.
#
# Results, keyed by the file path as given (set by _proof_tool_batch_prime, read through the accessors below):
#   _PTG_BATCH_CHANGE[f]   the change fingerprint ("change-<patch-id>"), or "" when none applies
#   _PTG_BATCH_STILL[f]    the return code of _proof_tool_still_changed f (0 or 1)
#   _PTG_BATCH_SHA[f]      the content hash (_proof_tool_sha256 f), set by _proof_tool_batch_sha_prime
# A path missing from an array is undecided.
declare -gA _PTG_BATCH_CHANGE=() _PTG_BATCH_STILL=() _PTG_BATCH_SHA=() 2>/dev/null || true
# The repository _proof_tool_batch_prime_repo works on: each file as given, and its path in the repository; and whether
# the caller asked for _PTG_BATCH_STILL.
_PTG_BATCH_FILES=(); _PTG_BATCH_RELS=(); _PTG_BATCH_WANT_STILL=0

# The working-tree comparison of _proof_tool_equals_head and _proof_tool_differs_in_mode_or_endings for many files in
# one process. Reads `git cat-file --batch` output on stdin (one object per file, in argument order) and prints per
# file "<equals> <identical>": <equals> 1 when the file and the blob hold the same text once one carriage return
# before each line end is dropped (what `sed 's/\r$//'` on both sides followed by cmp tells), 0 when not or when HEAD
# has no such path; <identical> 1 when the bytes are the same. "?" for anything else (not a blob, an unreadable file,
# a cut stream): the caller then asks the per-file function. Core perl only, no module, nothing read from the
# repository but the blobs.
# shellcheck disable=SC2016
_PTG_BATCH_COMPARE_PERL='
binmode STDIN; binmode STDOUT;
for my $f (@ARGV) {
    my $h = <STDIN>;
    if (!defined $h) { print "? ?\n"; next }
    chomp $h;
    if ($h =~ /^[0-9a-f]+ (\S+) (\d+)$/) {
        my ($type, $size, $blob, $got) = ($1, $2, "", 0);
        while ($got < $size) { my $r = read(STDIN, $blob, $size - $got, $got); last unless $r; $got += $r }
        my $nl; read(STDIN, $nl, 1);
        if ($got != $size || $type ne "blob") { print "? ?\n"; next }
        my $work;
        if (open(my $fh, "<:raw", $f)) { local $/; $work = <$fh>; $work = "" unless defined $work; close $fh }
        else { print "? ?\n"; next }
        my $same = ($work eq $blob) ? 1 : 0;
        s/\r(?=\n|\z)//g for ($work, $blob);
        print(($work eq $blob ? 1 : 0), " $same\n");
    } elsif ($h =~ / missing$/) { print "0 ?\n" }
    else { print "? ?\n" }
}'

# _proof_tool_batch_name_plain FILE -> rc 0 iff FILE's name can take the batched path: it names a folder (holds '/'),
# has no empty segment, no trailing '/', no line break or carriage return (git's batch input would cut it) and no
# backslash, so dirname/basename are plain text cuts.
_proof_tool_batch_name_plain() {
    case "$1" in */*) : ;; *) return 1 ;; esac
    case "$1" in *//*|*/|*$'\n'*|*$'\r'*|*\\*) return 1 ;; esac
    return 0
}

# _proof_tool_batch_rel_plain REL -> rc 0 iff the repository path REL means only itself as a pathspec (no glob
# character, no magic prefix), so a pathspec from the repository top selects what the bare name selected from its
# folder.
_proof_tool_batch_rel_plain() {
    case "$1" in ''|:*|*[\*\?\[]*|*$'\n'*|*$'\r'*) return 1 ;; esac
    return 0
}

# _proof_tool_batch_prime [--still] FILE... -> fill _PTG_BATCH_CHANGE for FILE... and, with --still, _PTG_BATCH_STILL
# (see above). Runs in the calling shell (never call it in a command substitution: the results would be lost with the
# subshell). Every git call goes through the hardened _PTG_GIT, as in the per-file functions.
# [RiskMitigation RA-02] No repository-configured helper runs while the signing key is in the environment.
_proof_tool_batch_prime() {
    _PTG_BATCH_CHANGE=(); _PTG_BATCH_STILL=(); _PTG_BATCH_WANT_STILL=0
    if [ "${1:-}" = "--still" ]; then _PTG_BATCH_WANT_STILL=1; shift; fi
    command -v git >/dev/null 2>&1 || return 0
    local f dir out top
    local -a lines=() tops=()
    local -A dir_top=() dir_prefix=() top_files=() listed=()
    for f in "$@"; do
        if [ ! -f "$f" ] || ! _proof_tool_batch_name_plain "$f"; then continue; fi
        [ -z "${listed[$f]+set}" ] || continue
        listed[$f]=1
        dir="${f%/*}"; [ -n "$dir" ] || dir=/
        if [ -z "${dir_top[$dir]+set}" ]; then
            dir_top[$dir]=""
            if out="$(_proof_tool_dir_top "$dir")"; then
                mapfile -t lines <<< "$out"
                # one line: the folder is the top (an empty prefix line was cut with the trailing line break)
                case "${#lines[@]}" in
                    1) dir_top[$dir]="${lines[0]}"; dir_prefix[$dir]="" ;;
                    2) dir_top[$dir]="${lines[0]}"; dir_prefix[$dir]="${lines[1]}" ;;
                    *) dir_top[$dir]="?" ;;
                esac
            else
                dir_top[$dir]="-"   # not in a work tree: no change fingerprint applies (the per-file check fails too)
            fi
        fi
        top="${dir_top[$dir]}"
        case "$top" in
            '?'|'') continue ;;
            -) _PTG_BATCH_CHANGE[$f]=""; _PTG_BATCH_STILL[$f]=0; continue ;;
        esac
        _proof_tool_batch_rel_plain "${dir_prefix[$dir]}${f##*/}" || continue
        [ -n "${top_files[$top]+set}" ] || tops+=("$top")
        top_files[$top]+="$f"$'\n'
    done
    for top in ${tops[@]+"${tops[@]}"}; do
        _PTG_BATCH_FILES=(); _PTG_BATCH_RELS=()
        mapfile -t _PTG_BATCH_FILES <<< "${top_files[$top]%$'\n'}"
        for f in "${_PTG_BATCH_FILES[@]}"; do
            dir="${f%/*}"; [ -n "$dir" ] || dir=/
            _PTG_BATCH_RELS+=("${dir_prefix[$dir]}${f##*/}")
        done
        _proof_tool_batch_prime_repo "$top"
    done
}

# _proof_tool_batch_prime_repo TOP -> the batch for the files of one repository, _PTG_BATCH_FILES (each file as given)
# and _PTG_BATCH_RELS (its path in the repository), in the same order.
_proof_tool_batch_prime_repo() {
    local top="$1" i f rel base head from mode fm verdict same out
    local -A eq_of=() same_of=() index_of=()
    for i in "${!_PTG_BATCH_RELS[@]}"; do index_of[${_PTG_BATCH_RELS[$i]}]="$i"; done
    if [ -z "${_PTG_BASE_CACHE[$top]+set}" ]; then
        _PTG_BASE_CACHE[$top]="$(proof_tool_change_base "$top" 2>/dev/null || true)"
    fi
    base="${_PTG_BASE_CACHE[$top]}"
    # equals HEAD / identical to HEAD, all files in one cat-file and one perl
    if command -v perl >/dev/null 2>&1; then
        local -a verdicts=()
        # Redirections, not pipes: neither reader may stop a writer early (the stream is read whole either way).
        mapfile -t verdicts < <(perl -e "$_PTG_BATCH_COMPARE_PERL" -- "${_PTG_BATCH_FILES[@]}" 2>/dev/null \
            < <("${_PTG_GIT[@]}" -C "$top" cat-file --batch <<< "$(printf 'HEAD:%s\n' "${_PTG_BATCH_RELS[@]}")" 2>/dev/null))
        if [ "${#verdicts[@]}" -eq "${#_PTG_BATCH_FILES[@]}" ]; then
            for i in "${!_PTG_BATCH_FILES[@]}"; do
                verdict="${verdicts[$i]}"
                case "$verdict" in [01?]' '[01?]) eq_of[$i]="${verdict% *}"; same_of[$i]="${verdict#* }" ;; esac
            done
        fi
    fi
    # Files differing from HEAD (an uncommitted edit, or not in HEAD) are decided here: no change fingerprint, and
    # still part of the change. Files the batch could not compare stay undecided.
    local -a cand=()
    for i in "${!_PTG_BATCH_FILES[@]}"; do
        f="${_PTG_BATCH_FILES[$i]}"
        case "${eq_of[$i]:-?}" in
            0) _PTG_BATCH_CHANGE[$f]=""; _PTG_BATCH_STILL[$f]=0 ;;
            1) cand+=("$i") ;;
        esac
    done
    [ "${#cand[@]}" -gt 0 ] || return 0
    if [ -z "$base" ]; then
        # no fork point: no change fingerprint, and the file counts as changed
        for i in "${cand[@]}"; do _PTG_BATCH_CHANGE[${_PTG_BATCH_FILES[$i]}]=""; _PTG_BATCH_STILL[${_PTG_BATCH_FILES[$i]}]=0; done
        return 0
    fi
    _proof_tool_batch_patch_ids "$top" "$base" "${cand[@]}"
    [ "$_PTG_BATCH_WANT_STILL" = 1 ] || return 0
    # _proof_tool_still_changed, past its working-tree check: mode or line endings, then the branch's diff since its
    # fork point (the last commit when HEAD is the fork point itself).
    head="$("${_PTG_GIT[@]}" -C "$top" rev-parse HEAD 2>/dev/null)"
    from="$base"
    if [ "$base" = "$head" ]; then
        # no parent: every one counts as changed, whatever its mode or line endings
        from="$("${_PTG_GIT[@]}" -C "$top" rev-parse -q --verify HEAD~1 2>/dev/null)" || {
            for i in "${cand[@]}"; do _PTG_BATCH_STILL[${_PTG_BATCH_FILES[$i]}]=0; done
            return 0; }
    fi
    fm="$("${_PTG_GIT[@]}" -C "$top" config --bool core.fileMode 2>/dev/null)"
    local -A mode_of=()
    if [ "$fm" != "false" ]; then
        local rec
        while IFS= read -r -d '' rec; do
            [ -n "${index_of[${rec#*$'\t'}]+set}" ] && mode_of[${index_of[${rec#*$'\t'}]}]="${rec%% *}"
        done < <("${_PTG_GIT[@]}" -C "$top" ls-tree -z HEAD -- "${_PTG_BATCH_RELS[@]}" 2>/dev/null)
    fi
    local -a still=()
    for i in "${cand[@]}"; do
        f="${_PTG_BATCH_FILES[$i]}"; same="${same_of[$i]}"
        case "$same" in
            0) _PTG_BATCH_STILL[$f]=0; continue ;;
            1) : ;;
            *) continue ;;
        esac
        if [ "$fm" != "false" ]; then
            [ -n "${mode_of[$i]+set}" ] || continue
            mode="${mode_of[$i]}"
            case "$mode" in
                100755) [ -x "$f" ] || { _PTG_BATCH_STILL[$f]=0; continue; } ;;
                100644) [ -x "$f" ] && { _PTG_BATCH_STILL[$f]=0; continue; } ;;
            esac
        fi
        still+=("$i")
    done
    [ "${#still[@]}" -gt 0 ] || return 0
    local -a changed_rels=() srels=()
    for i in "${still[@]}"; do srels+=("${_PTG_BATCH_RELS[$i]}"); done
    out="$("${_PTG_GIT[@]}" --literal-pathspecs -C "$top" diff --name-only -z --no-relative --no-ext-diff --no-textconv \
        --no-renames "$from" HEAD -- "${srels[@]}" 2>/dev/null | tr '\0' '\n'; exit "${PIPESTATUS[0]}")" || return 0
    local -A changed=()
    if [ -n "$out" ]; then
        mapfile -t changed_rels <<< "$out"
        for rel in "${changed_rels[@]}"; do
            # a path the window lists that is none of the files (a folder the file replaced): leave all undecided
            [ -n "${index_of[$rel]+set}" ] || return 0
            changed[$rel]=1
        done
    fi
    for i in "${still[@]}"; do
        if [ -n "${changed[${_PTG_BATCH_RELS[$i]}]+set}" ]; then _PTG_BATCH_STILL[${_PTG_BATCH_FILES[$i]}]=0
        else _PTG_BATCH_STILL[${_PTG_BATCH_FILES[$i]}]=1; fi
    done
}

# _proof_tool_batch_patch_ids TOP BASE INDEX... -> set _PTG_BATCH_CHANGE for the files at INDEX... of _PTG_BATCH_FILES
# (each equals HEAD): the patch-id of the change BASE..HEAD makes to it, as _proof_tool_patch_id takes it, from one
# diff over all of them split into one patch per file for one `git patch-id`. A file the diff does not touch gets ""
# (no change fingerprint). When the diff cannot be split with certainty (a quoted or repeated name, a path that is none
# of the files, a git error) the files stay undecided.
# sed runs with -b (binary): on Windows, GNU sed otherwise reads the file in text mode and drops the carriage return of
# every CRLF line, so the batch would hash a different diff than the one-file path (_proof_tool_patch_id) does. On POSIX
# -b changes nothing.
# The diff is kept in a temporary file and edited with sed only, never held in a shell variable or read by awk: a text
# file can hold a NUL byte past the part git inspects to call it binary, and a shell variable drops that byte, which
# would change the patch-id.
_proof_tool_batch_patch_ids() {
    local top="$1" base="$2" i rel rest n hdr line pid tag tmp script
    shift 2
    local -a idx=("$@") hdrs=() prels=() order=() hdr_lines=()
    local -A pos=() hit=()
    for i in "${idx[@]}"; do prels+=("${_PTG_BATCH_RELS[$i]}"); pos[${_PTG_BATCH_RELS[$i]}]="$i"; done
    tmp="$(mktemp 2>/dev/null)" && [ -n "$tmp" ] || return 0
    script="$tmp.sed"
    if ! "${_PTG_GIT[@]}" -C "$top" diff --no-color --no-ext-diff --no-textconv \
            --no-renames --no-relative --binary -U0 --inter-hunk-context=0 --diff-algorithm=myers --indent-heuristic \
            --src-prefix=a/ --dst-prefix=b/ "$base" HEAD -- "${prels[@]}" > "$tmp" 2>/dev/null; then
        rm -f "${tmp:?}"; return 0
    fi
    if [ -s "$tmp" ]; then
        # -a: the diff may hold binary bytes; only the header lines are read into the shell (paths, never NUL)
        mapfile -t hdrs < <(grep -a -n -e '^diff --git ' "$tmp")
        : > "$script"
        for hdr in "${hdrs[@]}"; do
            line="${hdr%%:*}"; rest="${hdr#*:diff --git }"
            case "$rest" in '"'*) rm -f "${tmp:?}" "${script:?}"; return 0 ;; esac
            n=$(( (${#rest} - 5) / 2 ))
            rel="${rest:2:$n}"
            if [ "$n" -le 0 ] || [ "$rest" != "a/$rel b/$rel" ] || [ -z "${pos[$rel]+set}" ] || [ -n "${hit[$rel]+set}" ]; then
                rm -f "${tmp:?}" "${script:?}"; return 0
            fi
            hit[$rel]=1; order+=("$rel"); hdr_lines+=("$line")
            # one patch per file: a "commit <id>" line before each file's diff, the id its position in the diff
            printf '%si\\\ncommit %0*d\n' "$line" "${#base}" "${#order[@]}" >> "$script"
        done
        while read -r pid tag; do
            case "$tag" in ''|*[!0-9]*) continue ;; esac
            n=$((10#$tag))
            if [ -z "$pid" ] || [ "$n" -lt 1 ] || [ "$n" -gt "${#order[@]}" ]; then continue; fi
            rel="${order[$((n - 1))]}"
            _PTG_BATCH_CHANGE[${_PTG_BATCH_FILES[${pos[$rel]}]}]="$_PTG_CHANGE_PREFIX$pid"
        done < <(sed -b -f "$script" "$tmp" | git patch-id --verbatim 2>/dev/null)
    fi
    rm -f "${tmp:?}" "${script:?}"
    for i in "${idx[@]}"; do
        [ -n "${_PTG_BATCH_CHANGE[${_PTG_BATCH_FILES[$i]}]+set}" ] && continue
        # untouched by the diff: no change fingerprint; touched but no patch-id came back: undecided
        [ -n "${hit[${_PTG_BATCH_RELS[$i]}]+set}" ] || _PTG_BATCH_CHANGE[${_PTG_BATCH_FILES[$i]}]=""
    done
}

# _proof_tool_batch_sha_prime FILE... -> fill _PTG_BATCH_SHA for every existing FILE with a plain name (see
# _proof_tool_batch_name_plain) that has no change fingerprint, with one sha256sum over all of them (binary mode, as
# the per-file hash reads the bytes on stdin). When the output does not give one digest per file (an unreadable
# file), nothing is set and the per-file hash is used.
_proof_tool_batch_sha_prime() {
    _PTG_BATCH_SHA=()
    local f line i=0
    local -a want=() lines=()
    local -A listed=()
    for f in "$@"; do
        if [ ! -f "$f" ] || ! _proof_tool_batch_name_plain "$f"; then continue; fi
        [ -z "${listed[$f]+set}" ] || continue
        listed[$f]=1
        [ -n "${_PTG_BATCH_CHANGE[$f]:-}" ] && continue
        want+=("$f")
    done
    [ "${#want[@]}" -gt 0 ] || return 0
    mapfile -t lines < <(sha256sum -b -- "${want[@]}" 2>/dev/null)
    [ "${#lines[@]}" -eq "${#want[@]}" ] || return 0
    local -a digests=()
    for line in "${lines[@]}"; do
        line="${line#\\}"; line="${line:0:64}"
        case "$line" in *[!0-9a-f]*) return 0 ;; esac
        [ "${#line}" -eq 64 ] || return 0
        digests+=("$line")
    done
    for f in "${want[@]}"; do _PTG_BATCH_SHA[$f]="${digests[$i]}"; i=$((i + 1)); done
}

# _proof_tool_batch_sha256_v VAR FILE -> set VAR to _proof_tool_sha256 FILE, from the batch when it holds FILE.
_proof_tool_batch_sha256_v() {
    if [ -n "${_PTG_BATCH_SHA[$2]+set}" ]; then printf -v "$1" '%s' "${_PTG_BATCH_SHA[$2]}"
    else printf -v "$1" '%s' "$(_proof_tool_sha256 "$2")"; fi
}

# _proof_tool_batch_fingerprint_v VAR FILE -> set VAR to _proof_tool_fingerprint FILE, from the batch when it decided.
_proof_tool_batch_fingerprint_v() {
    if [ -n "${_PTG_BATCH_CHANGE[$2]+set}" ]; then
        if [ -n "${_PTG_BATCH_CHANGE[$2]}" ]; then printf -v "$1" '%s' "${_PTG_BATCH_CHANGE[$2]}"
        else _proof_tool_batch_sha256_v "$1" "$2"; fi
    else
        printf -v "$1" '%s' "$(_proof_tool_fingerprint "$2")"
    fi
}

# _proof_tool_batch_still_changed FILE -> _proof_tool_still_changed FILE, from the batch when it decided.
_proof_tool_batch_still_changed() {
    [ -f "$1" ] || return 1
    if [ -n "${_PTG_BATCH_STILL[$1]+set}" ]; then return "${_PTG_BATCH_STILL[$1]}"; fi
    _proof_tool_still_changed "$1"
}

# _proof_tool_batch_entry_holds FILE HASH [COMMIT] -> _proof_tool_entry_holds FILE HASH [COMMIT], from the batch when it decided
# (a batch fingerprint that differs is tried once more against COMMIT, the entry's measured-against commit).
_proof_tool_batch_entry_holds() {
    case "$2" in
        "$_PTG_CHANGE_PREFIX"*)
            if [ -n "${_PTG_BATCH_CHANGE[$1]+set}" ]; then
                [ "${_PTG_BATCH_CHANGE[$1]}" = "$2" ] && return 0
                # The entry's own measured-against commit (its sidecar line) is tried next, as the verifier tries it.
                [ -n "${3:-}" ] && [ "$(_proof_tool_change_fingerprint "$1" "$3")" = "$2" ]; return
            fi ;;
        *)
            if [ -n "${_PTG_BATCH_SHA[$1]+set}" ]; then [ "${_PTG_BATCH_SHA[$1]}" = "$2" ]; return; fi ;;
    esac
    _proof_tool_entry_holds "$1" "$2" "${3:-}"
}

# _proof_tool_hmac TEXT -> HMAC-SHA256(TEXT) hex under KYKLOS_PROOF_HMAC_KEY, or empty if no key
# / no openssl. The key is the UNFORGEABLE binding: it is held ONLY host-side (the bridge, from the Windows
# Credential Manager) and NEVER enters the container, so a container-side self-mint cannot produce a valid MAC. The
# MAC covers the sorted content-hash lines (the token body), so it is bound to exactly those files+hashes.
_proof_tool_hmac() {
    [ -n "${KYKLOS_PROOF_HMAC_KEY:-}" ] || return 0
    command -v openssl >/dev/null 2>&1 || return 0
    printf '%s' "$1" | openssl dgst -sha256 -hmac "$KYKLOS_PROOF_HMAC_KEY" 2>/dev/null | sed -E 's/^.*= *//' | tr -d '[:space:]'
}

# ---- Coverage receipts ------------------------------------------------------------------------------------------
# A coverage run posts ONE comment on the story for each run (a summary, the changed files' coverage lines and the
# compressed report set) and the story's Test Discipline token records which upload that comment carries, one line per
# kind of coverage (dotnet: the bridge's measured run; shell: the bashcov receipt):
#   attachment:<kind> <sha256 of the uploaded archive> <note id> <changed-files line coverage, or -> <upload path>
# The close then refuses a Test Discipline row that does not link exactly that upload. The MAC covers these lines too
# (_proof_tool_signed_text), so a container that edits one, to point the token at a file it uploaded itself, breaks the
# signature. A token without attachment lines is signed exactly as before.
# A bridge that posts receipts also signs the marker line "attachment:receipt-capable" into every token it mints: the
# close requires a receipt only from such a token, so a token an older bridge minted (no marker) is still judged by the
# rules it was minted under, and removing the marker breaks the signature.
# The coverage receipt format this gate reads (the bridge writes it into the receipt body; see the bridge's
# CoverageReceiptRule.ReceiptVersion). Sent with every coverage_receipt_check call.
_PTG_RECEIPT_VERSION=1
_PTG_ATTACH_PREFIX='attachment:'
_PTG_CAPABLE_LINE='attachment:receipt-capable'
_PTG_ATTACH_PATTERN='^(dotnet|shell) [0-9a-f]{64} [1-9][0-9]{0,18} ([0-9]{1,3}(\.[0-9]{1,2})?|-) /uploads/[0-9a-f]{32}/[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'

# _proof_tool_attachments STORED -> the attachment lines of a token's text (prefix kept), sorted.
_proof_tool_attachments() { printf '%s\n' "$1" | grep -E "^$_PTG_ATTACH_PREFIX" 2>/dev/null | LC_ALL=C sort; }

# _proof_tool_signed_text BODY ATTACHMENTS -> the text the MAC covers: the content body, then the attachment lines
# when there are any (none: exactly the body, as every token minted before receipts existed).
_proof_tool_signed_text() { if [ -n "$2" ]; then printf '%s\n%s' "$1" "$2"; else printf '%s' "$1"; fi; }

# _proof_tool_stored_mac_holds STORED -> rc 0 iff the host key is present and the token text STORED carries an hmac
# line that signs its body and attachment lines. The one check the carry-over of attachments, the attach command and
# the receipt reader share.
_proof_tool_stored_mac_holds() {
    local stored="$1" body atts mac
    [ -n "${KYKLOS_PROOF_HMAC_KEY:-}" ] || return 1
    body="$(printf '%s\n' "$stored" | grep -v -e '^hmac:' -e '^root:' -e "^$_PTG_ATTACH_PREFIX" 2>/dev/null)"
    atts="$(_proof_tool_attachments "$stored")"
    mac="$(printf '%s\n' "$stored" | sed -n 's/^hmac://p' | head -1)"
    [ -n "$mac" ] && [ "$mac" = "$(_proof_tool_hmac "$(_proof_tool_signed_text "$body" "$atts")")" ]
}

# _proof_tool_attachment_valid LINE -> rc 0 iff LINE (without the prefix) is a well-formed attachment record.
_proof_tool_attachment_valid() { printf '%s\n' "$1" | grep -cE "$_PTG_ATTACH_PATTERN" >/dev/null 2>&1 && [ "$(printf '%s\n' "$1" | wc -l)" -eq 1 ]; }

# _proof_tool_receipt_only STORED -> rc 0 iff the token text STORED is exactly what the attach path writes for a story
# with no measured file: one hmac line, the receipt-capable marker and at least one well-formed shell receipt record,
# nothing else. Such a token records coverage receipts only and is NO C# coverage claim, so the C# checks judge it as a
# story without a token (the receipt check judges its receipts). Anything else that records no file (a hand-made or
# truncated token, a malformed or dotnet record, a stray line) is not one, and stays refused as unauthentic.
# [CySec] Prevents CWE-345 and CWE-636: the shape is checked line by line, and nothing passes for it. It never admits a
# C# change: a story whose change touches C# and holds only such a token is refused as having no coverage token, and
# with the host key the signature must hold too (proof_tool_verify).
_proof_tool_receipt_only() {
    local line macs=0 marker=0 recs=0
    while IFS= read -r line; do
        case "$line" in
            '') continue ;;
            hmac:*) printf '%s\n' "${line#hmac:}" | grep -cxE '[0-9a-f]{64}' >/dev/null || return 1; macs=$((macs + 1)) ;;
            "$_PTG_CAPABLE_LINE") marker=$((marker + 1)) ;;
            "${_PTG_ATTACH_PREFIX}shell "*) _proof_tool_attachment_valid "${line#"$_PTG_ATTACH_PREFIX"}" || return 1; recs=$((recs + 1)) ;;
            *) return 1 ;;
        esac
    done <<EOF
$1
EOF
    [ "$macs" -eq 1 ] && [ "$marker" -eq 1 ] && [ "$recs" -ge 1 ]
}

# _proof_tool_receipt_only_reason STORY -> the no-token reason for a story whose token holds coverage receipts only.
_proof_tool_receipt_only_reason() {
    printf 'no-token: the token for story %s records only coverage receipts (a shell receipt, no measured file), so it is no C# coverage claim; a change to C# needs a dotnet coverage run' "$1"
}

# _proof_tool_attachments_with TOKFILE [LINE] -> the attachment lines a receipt-capable bridge writes into the story's
# token: the receipt-capable marker, LINE (without the prefix; it replaces the record of its own kind) when given, and
# the records of other kinds carried over only from a token whose MAC proves them (a planted line is never signed by a
# later run). Sorted, prefix kept.
_proof_tool_attachments_with() {
    local tokfile="$1" line="${2:-}" kind="" stored=""
    [ -z "$line" ] || kind="${line%% *}"
    [ -f "$tokfile" ] && stored="$(cat "$tokfile" 2>/dev/null)"
    {
        if [ -n "$stored" ] && _proof_tool_stored_mac_holds "$stored"; then
            _proof_tool_attachments "$stored" | grep -v -x -e "$_PTG_CAPABLE_LINE" 2>/dev/null \
                | { if [ -n "$kind" ]; then grep -v "^$_PTG_ATTACH_PREFIX$kind " 2>/dev/null; else cat; fi; }
        fi
        [ -z "$line" ] || printf '%s%s\n' "$_PTG_ATTACH_PREFIX" "$line"
        printf '%s\n' "$_PTG_CAPABLE_LINE"
    } | sed '/^$/d' | LC_ALL=C sort -u
}

# proof_tool_attach --story N --attachment "<kind> <sha256> <note id> <figure> <upload path>" -> record one coverage
# receipt in story N's Test Discipline token, keeping its file records. HOST ONLY: it needs the signing key, and it
# refuses a token whose present MAC does not hold (it never signs what it cannot prove). The bridge calls it after it
# posted the receipt comment of a shell (bashcov) coverage; a dotnet run records its receipt through emit --attachment.
# [CySec] Prevents CWE-345 "Insufficient Verification of Data Authenticity": only the key holder records a receipt, and
# only over a token it can authenticate.
proof_tool_attach() {
    local story="" line="" dim="Test Discipline" tokfile stored="" body="" roots="" atts mac tmp
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --story) story="${2:-}"; shift 2 || return 1 ;;
            --attachment) line="${2:-}"; shift 2 || return 1 ;;
            *) echo "proof_tool_attach: unknown option '$1'" >&2; return 2 ;;
        esac
    done
    story="$(_proof_tool_story_key "$story")"
    [ -n "$story" ] || { echo "proof_tool_attach: pass --story <N>" >&2; return 1; }
    _proof_tool_attachment_valid "$line" || { echo "proof_tool_attach: '$line' is not '<dotnet|shell> <sha256> <note id> <figure|-> /uploads/<secret>/<file>'" >&2; return 1; }
    [ -n "${KYKLOS_PROOF_HMAC_KEY:-}" ] && command -v openssl >/dev/null 2>&1 || { echo "proof_tool_attach: no host signing key here: only the bridge records a coverage receipt" >&2; return 1; }
    tokfile="$(_proof_tool_token_file "$dim" "$story")"
    mkdir -p "$(dirname "$tokfile")" 2>/dev/null || return 1
    _proof_tool_lock "$tokfile" || { echo "proof_tool_attach: could not lock the token of story $story" >&2; return 1; }
    if [ -f "$tokfile" ]; then
        stored="$(cat "$tokfile" 2>/dev/null)"
        if ! _proof_tool_stored_mac_holds "$stored"; then
            _proof_tool_unlock "$tokfile"
            echo "proof_tool_attach: the Test Discipline token of story $story is not signed by this host's key (edited, or minted elsewhere): measure coverage again before attaching a receipt" >&2
            return 1
        fi
        body="$(printf '%s\n' "$stored" | grep -v -e '^hmac:' -e '^root:' -e "^$_PTG_ATTACH_PREFIX" 2>/dev/null)"
        roots="$(printf '%s\n' "$stored" | grep '^root:' 2>/dev/null)"
    fi
    atts="$(_proof_tool_attachments_with "$tokfile" "$line")"
    mac="$(_proof_tool_hmac "$(_proof_tool_signed_text "$body" "$atts")")"
    tmp="$tokfile.${BASHPID:-$$}.$RANDOM.tmp"
    # [CySec] Mitigates CWE-362: written then renamed, so a reader never sees a half-written token.
    if ! { { [ -z "$body" ] || printf '%s\n' "$body"; printf 'hmac:%s\n' "$mac"; [ -z "$roots" ] || printf '%s\n' "$roots"; printf '%s\n' "$atts"; } > "$tmp" && mv -f "$tmp" "$tokfile"; }; then
        rm -f "$tmp"; _proof_tool_unlock "$tokfile"
        echo "proof_tool_attach: could not write the token of story $story" >&2; return 1
    fi
    _proof_tool_unlock "$tokfile"
    printf '[kyklos] proof-tool-attach: coverage receipt recorded for story %s: %s\n' "$story" "$line" >&2
    return 0
}

# proof_tool_receipts --story N -> print "receipts: capable" (the token was minted by a receipt-capable bridge),
# "receipts: legacy" (a signed token from an older bridge) or "receipts: none" (no token), then story N's attachment
# records (without the prefix), one per line, after the keyed check that the token's MAC signs them. HOST ONLY (needs the
# key). On a refusal: rc 1 and one "<verdict>: <what>" line on stdout.
proof_tool_receipts() {
    local story="" tokfile stored
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --story) story="${2:-}"; shift 2 || return 1 ;;
            *) echo "unavailable: unknown option '$1'"; return 1 ;;
        esac
    done
    story="$(_proof_tool_story_key "$story")"
    [ -n "$story" ] || { echo "unavailable: the story is unknown (pass --story <N>)"; return 1; }
    [ -n "${KYKLOS_PROOF_HMAC_KEY:-}" ] && command -v openssl >/dev/null 2>&1 || { echo "unavailable: no host signing key here, so the receipts cannot be authenticated"; return 1; }
    tokfile="$(_proof_tool_token_file "Test Discipline" "$story")"
    [ -f "$tokfile" ] || { echo "receipts: none"; return 0; }
    stored="$(cat "$tokfile" 2>/dev/null)"
    _proof_tool_stored_mac_holds "$stored" || { echo "unauthentic: the Test Discipline token of story $story is not signed by this host's key over its records (edited, or minted elsewhere)"; return 1; }
    if printf '%s\n' "$stored" | grep -cxF "$_PTG_CAPABLE_LINE" >/dev/null; then echo "receipts: capable"; else echo "receipts: legacy"; fi
    _proof_tool_attachments "$stored" | grep -v -x -e "$_PTG_CAPABLE_LINE" | sed "s/^$_PTG_ATTACH_PREFIX//"
}

# _proof_tool_still_changed FILE -> exit 0 unless FILE is provably NOT part of the story's change any more: it no
# longer exists, or it equals HEAD and the branch's diff since its fork point (the window proof_tool_changed_files
# uses) does not touch it. When that cannot be told (no git, no trunk base) the file counts as changed, so an entry is
# never dropped on a guess. Only the hardened git runs (no index refresh, no filter, no helper): this executes while
# the signing key is in the environment.
# [RiskMitigation RA-02] No repository-configured helper runs while the signing key is in the environment.
_proof_tool_still_changed() {
    local f="$1" dir name base from
    [ -f "$f" ] || return 1
    command -v git >/dev/null 2>&1 || return 0
    dir="$(dirname "$f")"; name="$(basename "$f")"
    # An uncommitted edit, or a file HEAD does not hold, is part of the working-tree change.
    _proof_tool_equals_head "$dir" "$name" "$f" || return 0
    # The window also lists a file whose only working-tree difference is its mode or its line endings, which
    # _proof_tool_equals_head tolerates; those count as changed here too.
    _proof_tool_differs_in_mode_or_endings "$dir" "$name" "$f" && return 0
    base="$(_proof_tool_cached_change_base "$dir")" || return 0
    from="$base"
    # On the fork point itself the window is the last commit, as in proof_tool_changed_files.
    if [ "$base" = "$("${_PTG_GIT[@]}" -C "$dir" rev-parse HEAD 2>/dev/null)" ]; then
        from="$("${_PTG_GIT[@]}" -C "$dir" rev-parse -q --verify HEAD~1 2>/dev/null)" || return 0
    fi
    # --literal-pathspecs: the file name is a name, never a pattern (a name with pathspec magic or glob characters
    # would otherwise be matched against other paths, and a changed file could read as unchanged).
    "${_PTG_GIT[@]}" --literal-pathspecs -C "$dir" diff --quiet --no-ext-diff --no-textconv --no-renames "$from" HEAD -- "$name" >/dev/null 2>&1
    [ "$?" -ne 0 ]
}

# _proof_tool_entry_holds FILE HASH [COMMIT] -> rc 0 iff FILE is still what the token entry HASH measured: a change
# fingerprint ("change-<patch-id>") equals the story's own change to the file (a trunk merge that left the story's lines
# alone keeps it; an edit to them, or an uncommitted edit, does not), taken from the entry's measured-against COMMIT first
# when the sidecar names one, then from this tool's own fork point (equal patch-ids under either prove the same change);
# any other HASH equals the file's SHA-256. The ONE entry check, used by the verifier and by the merge of a new run into the
# story's token, so the two can never judge an entry apart.
_proof_tool_entry_holds() {
    local f="$1" h="$2" at="${3:-}"
    case "$h" in
        "$_PTG_CHANGE_PREFIX"*) { [ -n "$at" ] && [ "$(_proof_tool_change_fingerprint "$f" "$at")" = "$h" ]; } || [ "$(_proof_tool_change_fingerprint "$f")" = "$h" ] ;;
        *) [ "$(_proof_tool_sha256 "$f")" = "$h" ] ;;
    esac
}

# _proof_tool_merge_previous TOKFILE BODY ROOT [BASE [STORY]] -> print BODY merged with the entries of the existing token TOKFILE:
# the union by path, BODY winning for a path in both, sorted. A previous entry whose file is no longer part of the
# story's change (_proof_tool_still_changed) is dropped: nothing in the change needs it, and once its file differs
# from what was measured it would make the whole token read as stale. A kept entry whose file changed since it was
# measured stays as recorded (so the token reads as stale until a run that covers the file records it again: dropping
# it would let a story close with an edited file never re-measured, since the close needs only the recorded entries to
# hold), and each such entry this run did not record is named on stderr, so the reason is never a surprise. With
# STORY, a previous entry whose file is outside the story's current window (proof_tool_changed_files_for, the window
# this run records) is dropped and named: it is not part of the story's change, so no run of the story can ever record
# it again, and the close judges only the window; when that window cannot be known every entry is judged as before.
# Prints
# BODY unchanged when there is no previous
# token, when it was minted for another repository (its `root:` differs from ROOT, empty meaning none) or under another
# root (its .base sidecar differs from BASE; a token without one predates it and merges as before), or when the
# host key is present and the previous token's MAC does not prove its body.
_proof_tool_merge_previous() {
    local tokfile="$1" body="$2" root="$3" base="${4:-}" story="${5:-}" stored prev prev_root prev_base line f tokroot kept="" wrepo wtop wlist
    [ -f "$tokfile" ] || { printf '%s' "$body"; return 0; }
    stored="$(cat "$tokfile" 2>/dev/null)"
    prev="$(printf '%s\n' "$stored" | grep -v -e '^hmac:' -e '^root:' -e "^$_PTG_ATTACH_PREFIX" -e '^$' 2>/dev/null)"
    prev_root="$(printf '%s\n' "$stored" | sed -n 's/^root://p' | head -1)"
    prev_base="$(_proof_tool_token_base "$tokfile")"
    # Entries are relative to the root their token names: never mix a token measured under another root into this one.
    if [ -z "$prev" ] || [ "$prev_root" != "$root" ] || { [ -n "$prev_base" ] && [ "$prev_base" != "$base" ]; }; then printf '%s' "$body"; return 0; fi
    if [ -n "${KYKLOS_PROOF_HMAC_KEY:-}" ] && ! _proof_tool_stored_mac_holds "$stored"; then
        printf '%s' "$body"; return 0
    fi
    # Keep a previous entry only while its file is still part of the change, resolved the way the verifier resolves it.
    # A path this run recorded takes this run's record below, so only the others are checked for an outdated record
    # (that check hashes the file or computes the story's change to it: never done for a record about to be replaced).
    tokroot="${root:-$(_proof_tool_root)}"
    _PTG_BASE_CACHE=()
    local -A recorded=() file_of=() inwin=() repo_of=() win_known=() dir_repo=() prev_at=()
    # Each previous entry's measured-against commit (the previous token's sidecar), so an entry the bridge measured against
    # a trunk newer than the local ref is judged the way the verifier judges it, never named stale by mistake.
    local at_key at_commit at_lines
    at_lines="$(_proof_tool_measured_lines "$tokfile")"
    while IFS=$'\t' read -r at_key at_commit; do
        [ -n "$at_key" ] && prev_at[$at_key]="$at_commit"
    done <<< "$at_lines"
    local -a prev_files=() unrecorded=()
    local d r
    while IFS= read -r line; do
        [ -n "$line" ] && recorded["${line%:*}"]=1
    done <<EOF
$body
EOF
    # Resolve every previous entry's file first, then judge them all in one batch (_proof_tool_batch_prime).
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        f="${line%:*}"
        case "$f" in /*|[A-Za-z]:/*|[A-Za-z]:\\*) : ;; *) f="$tokroot/$f" ;; esac
        _proof_tool_canon_path_v f "$f"
        file_of[$line]="$f"; prev_files+=("$f")
        [ -n "${recorded[${line%:*}]:-}" ] || unrecorded+=("$f")
    done <<EOF
$prev
EOF
    # The story's current window, as absolute paths, computed only for earlier entries this run did not record (the only
    # entries it can drop), in the repository that holds each file: a companion's token records files of its nested
    # source, whose window is the nested repository's, not the companion's. Unknown (no story, no repository, or a
    # window git cannot compute) leaves the entry to the judgement below.
    if [ -n "$story" ]; then
        for f in ${unrecorded[@]+"${unrecorded[@]}"}; do
            d="${f%/*}"; while [ -n "$d" ] && [ ! -d "$d" ]; do d="${d%/*}"; done
            [ -n "$d" ] || continue
            if [ -z "${dir_repo[$d]+set}" ]; then dir_repo[$d]="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)"; fi
            r="${dir_repo[$d]}"; [ -n "$r" ] || continue
            repo_of[$f]="$r"
            [ -z "${win_known[$r]+set}" ] || continue
            win_known[$r]=0
            wlist="$(proof_tool_changed_files_for "$r" "$story" 2>/dev/null)" || continue
            wtop="$(_proof_tool_canon_path "$r")"; win_known[$r]=1
            while IFS= read -r line; do
                [ -n "$line" ] || continue
                _proof_tool_canon_path_v wrepo "$wtop/$line"; inwin[$wrepo]=1
            done <<< "$wlist"
        done
    fi
    _proof_tool_batch_prime --still ${prev_files[@]+"${prev_files[@]}"}
    _proof_tool_batch_sha_prime ${unrecorded[@]+"${unrecorded[@]}"}
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        f="${file_of[$line]}"
        r="${repo_of[$f]:-}"
        if [ -n "$r" ] && [ "${win_known[$r]:-0}" = 1 ] && [ -z "${inwin[$f]:-}" ] && [ -z "${recorded[${line%:*}]:-}" ]; then
            printf '[kyklos] proof-tool-emit: %s is outside the current window of story %s; its record of an earlier run is dropped\n' "${line%:*}" "$story" >&2
            continue
        fi
        _proof_tool_batch_still_changed "$f" || continue
        kept="$kept$line"$'\n'
        [ -n "${recorded[${line%:*}]:-}" ] && continue
        _proof_tool_batch_entry_holds "$f" "${line##*:}" "${prev_at[${line%:*}]:-}" || printf '[kyklos] proof-tool-emit: %s keeps the record of an earlier run, made before the file last changed, and this run did not record it: the token stays stale until a run whose tests cover that file records it again (for another tree, pass tree=<that tree>)\n' "${line%:*}" >&2
    done <<EOF
$prev
EOF
    prev="$kept"
    # Union by path, split on the LAST ':' (a path may hold a drive colon): this run's lines all come first, so a
    # previous entry is kept only for a path this run did not record.
    { printf '%s\n' "$body" | sed 's/^/N\t/'; printf '%s\n' "$prev" | sed 's/^/P\t/'; } | awk -F'\t' '
        $2 == "" { next }
        { match($2, /:[^:]*$/); path = substr($2, 1, RSTART - 1) }
        $1 == "N" { seen[path] = 1; print $2; next }
        !(path in seen) && !(path in kept) { kept[path] = 1; print $2 }' | sort
}

# _proof_tool_merge_measured TOKEN NEW PREVIOUS -> the sidecar lines of the merged TOKEN: this run's NEW lines, then a
# PREVIOUS line for each entry the merged token still records that this run did not measure. Used alike for the
# measured-against lines and the trunk lines ("trunk:<path>..."), each keyed by its entry path, so a kept entry keeps its
# own trunk commit.
_proof_tool_merge_measured() {
    local token="$1" new="$2" prev="$3" line key
    local -A have=() kept=()
    while IFS= read -r line; do [ -n "$line" ] && have["${line%:*}"]=1; done <<< "$token"
    printf '%s' "$new" | sed '/^$/d'
    while IFS= read -r line; do [ -n "$line" ] && key="${line#trunk:}" && kept["${key%%$'\t'*}"]=1; done <<< "$new"
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        key="${line#trunk:}"; key="${key%%$'\t'*}"
        [ -n "${have[$key]:-}" ] && [ -z "${kept[$key]:-}" ] && printf '%s\n' "$line"
    done <<< "$prev"
    return 0
}

# _proof_tool_lock TOKFILE -> take the per-story lock "<TOKFILE>.lock" (a folder: mkdir is atomic on every
# filesystem the token store lives on, and flock is missing from Git for Windows bash). Waits up to
# _PTG_LOCK_WAIT_TENTHS tenths of a second (default 300, i.e. 30 s); a lock older than two minutes was left by an emit
# killed mid-write (the locked section takes milliseconds) and is taken over. Non-zero when the lock stays held.
_proof_tool_lock() {
    local lock="$1.lock" tries="${_PTG_LOCK_WAIT_TENTHS:-300}"
    while [ "$tries" -gt 0 ]; do
        mkdir "$lock" 2>/dev/null && return 0
        if [ -n "$(find "$lock" -maxdepth 0 -mmin +2 2>/dev/null)" ]; then rmdir "$lock" 2>/dev/null; continue; fi
        sleep 0.1; tries=$((tries - 1))
    done
    return 1
}

# _proof_tool_unlock TOKFILE -> release the lock _proof_tool_lock took.
_proof_tool_unlock() { rmdir "$1.lock" 2>/dev/null || true; }

# proof_tool_emit DIM FILE... -> the TOOL calls this on a clean pass over FILE.... Records a content token = the
# hash of exactly those files. Loud non-zero if NO file could be hashed, so a tool never silently emits an empty
# (and therefore un-verifiable, trivially-satisfiable) token.
# [RiskMitigation RA-03] The token and its root sidecar are written as a pair and restored together on a failure.
proof_tool_emit() {
    local story="${KYKLOS_PROOF_STORY:-}" root_opt="" attach_opt="" capable_opt=0
    # Options in any order: --story <N> binds the story; --root <dir> is the repository the files belong to (a tree
    # the bridge measured outside its solution root). With --root every path is recorded relative to that repository
    # and a file outside it is refused, so a token can never carry a host path the container cannot resolve.
    # --attachment "<kind> <sha256> <note id> <figure> <upload path>" records the coverage receipt the run posted (see
    # "Coverage receipts" above); it replaces the record of its kind and is signed with the files. --receipt-capable (implied
    # by --attachment) signs the receipt-capable marker in, so the close requires a receipt from this token.
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --story) story="${2:-}"; shift 2 || return 1 ;;
            --root) root_opt="${2:-}"; shift 2 || return 1
                    [ -n "$root_opt" ] || { echo "proof_tool_emit: --root needs a directory" >&2; return 1; } ;;
            --receipt-capable) capable_opt=1; shift ;;
            --attachment) attach_opt="${2:-}"; capable_opt=1; shift 2 || return 1
                    _proof_tool_attachment_valid "$attach_opt" || { echo "proof_tool_emit: --attachment '$attach_opt' is not '<dotnet|shell> <sha256> <note id> <figure|-> /uploads/<secret>/<file>'" >&2; return 1; } ;;
            *) break ;;
        esac
    done
    local dim="$1"; shift
    # With --root, a relative path names a file IN that repository (as documented), never one under the caller's
    # current directory: resolve it against --root before hashing and before the containment check.
    if [ -n "$root_opt" ]; then
        local _rf _rargs=()
        for _rf in "$@"; do
            # [CySec] Path traversal (CWE-22): a `..` segment can leave the repository while still starting with its
            # path, so it would pass the containment check below as text. Refuse it outright (platform-neutral: the
            # same check holds for host X:/ paths, where a path normaliser could rewrite the drive).
            case "/$(printf '%s' "$_rf" | tr '\\' '/')/" in
                */../*) echo "proof_tool_emit($dim): '$_rf' contains '..' -> refusing a path that can leave --root '$root_opt'" >&2; return 1 ;;
            esac
            case "$_rf" in /*|[A-Za-z]:/*|[A-Za-z]:\\*) _rargs+=("$_rf") ;; *) _rargs+=("${root_opt%/}/$_rf") ;; esac
        done
        set -- "${_rargs[@]}"
    fi
    local token dir
    _PTG_BASE_CACHE=(); _PTG_DIR_TOPS=()
    _proof_tool_preset_measured_against "$@"
    token="$(_PTG_KEEP_CACHE=1 _proof_tool_hash_files "$@")"
    [ -n "$token" ] || { echo "proof_tool_emit($dim): no inspectable files -> refusing to emit an empty token" >&2; return 1; }
    # Bind the token to ONE story (explicit --story / KYKLOS_PROOF_STORY, else derived from the git state of the
    # files' repo). A token no story can own is refused rather than written story-less, because a story-less token
    # could satisfy whichever story closes next.
    story="$(_proof_tool_story_key "$story")"
    if [ -z "$story" ]; then
        local _fd; _fd="$(dirname "$1" 2>/dev/null)"; [ -d "$_fd" ] || _fd="."
        story="$(_proof_tool_detect_story "$_fd")"
    fi
    [ -n "$story" ] || { echo "proof_tool_emit($dim): cannot tell which story these files belong to -> pass --story <N> (or set KYKLOS_PROOF_STORY)" >&2; return 1; }
    dir="$(_proof_tool_dir)"; mkdir -p "$dir" 2>/dev/null || return 1
    # A SHELL-side emit is agent-callable with no tool run, so every emission leaves a DURABLE greppable trail —
    # who/what/which files — via escape_audit AND a loud stderr line (the transcript is a second record the
    # state-dir eraser cannot reach). For a SEALED dimension (proof_tool_is_sealed) a container self-mint also fails
    # the bridge seal check (proof_tool_verify_sealed); for the others the audit trail is the safeguard.
    if [ -z "${_PTG_AUDIT_SOURCED:-}" ]; then
        # shellcheck source=/dev/null
        [ -f "$_PTG_LIB_DIR/escape-audit.sh" ] && . "$_PTG_LIB_DIR/escape-audit.sh" 2>/dev/null || true
        _PTG_AUDIT_SOURCED=1
    fi
    command -v escape_audit >/dev/null 2>&1 && escape_audit "proof-tool-emit" "dim=$dim story=$story files=$*" 2>/dev/null || true
    # store paths RELATIVE to the token root so the token is portable across the host/container
    # boundary (the bridge emits with host-absolute paths; the container gate resolves against ITS root).
    local root line f h rel
    root="${root_opt:-$(_proof_tool_root)}"
    if [ -n "$root_opt" ]; then
        root="$(_proof_tool_canon_path "$root_opt")"
        local canon
        for f in "$@"; do
            _proof_tool_canon_path_v canon "$f"
            case "$canon" in
                "$root"/*) : ;;
                *) echo "proof_tool_emit($dim): '$f' is outside --root '$root_opt' -> refusing to record a path the repository cannot resolve" >&2; return 1 ;;
            esac
        done
    fi
    token="$(printf '%s\n' "$token" | while IFS= read -r line; do
        [ -n "$line" ] || continue
        f="${line%:*}"; h="${line##*:}"
        _proof_tool_relpath_v rel "$f" "$root"
        printf '%s:%s\n' "$rel" "$h"
    done)"
    # The commit each change fingerprint of this run was measured against, for the .measured sidecar: resolved once per
    # folder and once per repository, so the git calls of an emit do not grow with its number of files.
    local measured="" _mf _mrel _mdir _mtop _ml
    local -A _mchanged=()
    while IFS= read -r _ml; do
        case "$_ml" in *":$_PTG_CHANGE_PREFIX"*) _mchanged["${_ml%:*}"]=1 ;; esac
    done <<< "$token"
    for _mf in "$@"; do
        [ -f "$_mf" ] || continue
        _proof_tool_relpath_v _mrel "$_mf" "$root"
        [ -n "${_mchanged[$_mrel]:-}" ] || continue
        _mdir="${_mf%/*}"; [ -n "$_mdir" ] || _mdir=/
        _proof_tool_dir_cache "$_mdir" || continue
        _mtop="${_PTG_DIR_TOPS[$_mdir]%%$'\n'*}"
        [ -n "$_mtop" ] && [ -n "${_PTG_BASE_CACHE[$_mtop]:-}" ] || continue
        measured="$measured$_mrel"$'\t'"${_PTG_BASE_CACHE[$_mtop]}"$'\n'
    done
    # The trunk this run measured against, one trunk line per entry it recorded (none when no trunk was handed in).
    local trunk="" _tl
    if _proof_tool_trunk_given; then
        while IFS= read -r _tl; do
            [ -n "$_tl" ] && trunk="${trunk}trunk:${_tl%:*}"$'\t'"$KYKLOS_PROOF_TRUNK_REF"$'\t'"$KYKLOS_PROOF_TRUNK_COMMIT"$'\n'
        done <<< "$token"
    fi
    # Bind the token with an HMAC when a host-only key is present (the bridge emit path). The MAC
    # covers the sorted content-hash body; it rides ALONGSIDE the content (an `hmac:<mac>` line), so a keyless
    # container verify is UNCHANGED (content-only), while a keyed (host) verify additionally proves authenticity —
    # a self-mint has no key, so it cannot forge the MAC.
    local mac tokfile tmp
    tokfile="$(_proof_tool_token_file "$dim" "$story")"
    # A shared-folder token is judged against the container start marker: make sure it exists BEFORE the token is
    # written, so a token minted in this container is never older than the marker (SessionStart normally made it).
    if _proof_tool_shared_dir >/dev/null; then container_start_marker_ensure >/dev/null || true; fi
    # A story measured in more than one run (one tree per run, e.g. two solutions of one repository) must keep every
    # run's files: the new run is MERGED into the story's existing token, never written over it. A file this run
    # measured takes this run's record; every other entry still part of the story's change is kept exactly as recorded,
    # so the content check still fails it once that file changes (an entry for a file no longer changed is dropped).
    # Entries are carried over only from a token for the same repository and, when the host key is present, only from
    # one whose MAC proves it was minted under that key, so a planted token can never be signed by a later run.
    # [CySec] Mitigates CWE-362 "Concurrent Execution using Shared Resource with Improper Synchronization": the merge
    # reads the story's token and writes it back, so two runs finishing together would each drop the other's files.
    # The read-modify-write runs under one lock per story; when the lock stays held the emit refuses, loudly, rather
    # than write over a token another run is changing.
    # The root sidecar is written for a mint under the solution / project root only. A tree mint (--root) names its
    # repository in the token (root:), and its entries are relative to that repository's top, which every reader
    # resolves as its own folder of that repository; its host path relative to the token folder would not map onto the
    # container's mounts (another repository is mounted elsewhere), so it gets no sidecar and is read as before.
    local base=""
    [ -n "$root_opt" ] || base="$(_proof_tool_rel_between "$(dirname "$tokfile")" "$root")" || base=""
    local prev_measured="" prev_trunk=""
    _proof_tool_lock "$tokfile" || { echo "proof_tool_emit($dim): could not lock the token of story $story (another emit holds $tokfile.lock) -> run the coverage again (a lock left by a killed run is cleared after two minutes)" >&2; return 1; }
    prev_measured="$(_proof_tool_measured_lines "$tokfile")"
    prev_trunk="$(_proof_tool_measured_trunk_lines "$tokfile")"
    token="$(_proof_tool_merge_previous "$tokfile" "$token" "${root_opt:+$root}" "$base" "$story")"
    # A run that merges earlier runs' entries keeps their measured-against lines and replaces only its own.
    measured="$(_proof_tool_merge_measured "$token" "$measured" "$prev_measured")"
    trunk="$(_proof_tool_merge_measured "$token" "$trunk" "$prev_trunk")"
    local atts=""
    # A token a receipt-capable bridge minted is never rewritten by an emit that cannot record receipts (an older CLI, a
    # tool without --receipt-capable): that would drop its signed marker and records, and so turn it into a token the
    # close judges by the older rules.
    if [ "$capable_opt" != 1 ] && [ -f "$tokfile" ] && grep -qxF "$_PTG_CAPABLE_LINE" "$tokfile" 2>/dev/null; then
        _proof_tool_unlock "$tokfile"
        echo "proof_tool_emit($dim): the token of story $story was minted by a receipt-capable bridge; an emit without --receipt-capable must not rewrite it (measure coverage with the bridge)" >&2
        return 1
    fi
    [ "$capable_opt" != 1 ] || atts="$(_proof_tool_attachments_with "$tokfile" "$attach_opt")"
    mac="$(_proof_tool_hmac "$(_proof_tool_signed_text "$token" "$atts")")"
    # [CySec] Mitigates CWE-362: one file per story, written then renamed, so a reader never sees a half-written token.
    tmp="$tokfile.${BASHPID:-$$}.$RANDOM.tmp"   # BASHPID: unique per subshell (a subshell inherits the parent's $$)
    # A tree token also names its repository (`root:`), so the bridge's keyed check reads the files where they are on
    # the host. The MAC does not cover it: pointing it elsewhere only verifies where byte-identical files sit, and the
    # bridge accepts only a root it serves. The container's content check ignores the line.
    # Every token also names its root relative to the token's own folder (its .base sidecar), the one path both sides
    # see alike, so the gates read the entries exactly where they were measured (_proof_tool_base_file). Not covered by
    # the MAC: the bridge's keyed check reads the files under its own root, whatever the sidecar says.
    # The token and its root sidecar change together or not at all: both are written to temporary files, the current
    # pair is copied aside, then both are renamed; any failure puts the old pair back, so an old token never sits next
    # to a new root (the gate would read a good token in the wrong folder) and a new token never next to an old one.
    # No relative path (another drive) -> no sidecar, and the gates use the project root.
    local bf btmp="" tokbak="" bfbak="" ok=1 mf mtmp="" mfbak="" mmac="" mmac2=""; bf="$(_proof_tool_base_file "$tokfile")"; mf="$(_proof_tool_measured_file "$tokfile")"
    { printf '%s\n' "$token"; if [ -n "$mac" ]; then printf 'hmac:%s\n' "$mac"; fi
      if [ -n "$root_opt" ]; then printf 'root:%s\n' "$root"; fi
      if [ -n "$atts" ]; then printf '%s\n' "$atts"; fi; } > "$tmp" || ok=0
    if [ "$ok" = 1 ] && [ -n "$base" ]; then btmp="$bf.${BASHPID:-$$}.$RANDOM.tmp"; printf '%s\n' "$base" > "$btmp" || ok=0; fi
    if [ "$ok" = 1 ] && { [ -n "$measured" ] || [ -n "$trunk" ]; }; then
        mtmp="$mf.${BASHPID:-$$}.$RANDOM.tmp"
        [ -z "$mac" ] || mmac="$(_proof_tool_hmac "$(printf '%s\n%s' "$mac" "$measured")")"
        # mac2 signs the token's MAC and every entry and trunk line, in the order they are written.
        [ -z "$mac" ] || [ -z "$trunk" ] || mmac2="$(_proof_tool_hmac "$(printf '%s\n%s' "$mac" "$(printf '%s\n%s\n' "$measured" "$trunk" | sed '/^$/d')")")"
        { [ -z "$measured" ] || printf '%s\n' "$measured"; if [ -n "$mmac" ]; then printf 'mac:%s\n' "$mmac"; fi
          [ -z "$trunk" ] || printf '%s\n' "$trunk"; if [ -n "$mmac2" ]; then printf 'mac2:%s\n' "$mmac2"; fi; } > "$mtmp" || ok=0
    fi
    if [ "$ok" = 1 ] && [ -f "$tokfile" ]; then tokbak="$tokfile.${BASHPID:-$$}.$RANDOM.bak"; cp -p "$tokfile" "$tokbak" || ok=0; fi
    if [ "$ok" = 1 ] && [ -f "$bf" ]; then bfbak="$bf.${BASHPID:-$$}.$RANDOM.bak"; cp -p "$bf" "$bfbak" || ok=0; fi
    if [ "$ok" = 1 ] && [ -f "$mf" ]; then mfbak="$mf.${BASHPID:-$$}.$RANDOM.bak"; cp -p "$mf" "$mfbak" || ok=0; fi
    if [ "$ok" = 1 ]; then
        mv -f "$tmp" "$tokfile" || ok=0
        if [ "$ok" = 1 ]; then
            if [ -n "$btmp" ]; then mv -f "$btmp" "$bf" || ok=0; else rm -f "$bf" && [ ! -e "$bf" ] || ok=0; fi
        fi
        if [ "$ok" = 1 ]; then
            if [ -n "$mtmp" ]; then mv -f "$mtmp" "$mf" || ok=0; else rm -f "$mf" && [ ! -e "$mf" ] || ok=0; fi
        fi
    fi
    if [ "$ok" != 1 ]; then
        # Put the old pair back (an absent file stays absent), then refuse loudly.
        if [ -n "$tokbak" ]; then mv -f "$tokbak" "$tokfile"; else [ -f "$tmp" ] || rm -f "$tokfile"; fi
        if [ -n "$bfbak" ]; then mv -f "$bfbak" "$bf"; else rm -f "$bf"; fi
        if [ -n "$mfbak" ]; then mv -f "$mfbak" "$mf"; else rm -f "$mf"; fi
        rm -f "$tmp" ${btmp:+"$btmp"} ${mtmp:+"$mtmp"}
        _proof_tool_unlock "$tokfile"
        echo "proof_tool_emit($dim): could not write the token of story $story and its root together -> the previous token is kept; run the tool again" >&2
        return 1
    fi
    rm -f ${tokbak:+"$tokbak"} ${bfbak:+"$bfbak"} ${mfbak:+"$mfbak"}
    _proof_tool_unlock "$tokfile"
    # Echo the commits the change fingerprints were measured against (a tool older than the sidecar prints none).
    [ -z "$measured" ] || printf 'measured-against: %s\n' "$(printf '%s\n' "$measured" | cut -f2 | sed '/^$/d' | sort -u | tr '\n' ' ' | sed 's/ $//')"
    # Said only now, once the token is written: a refusal above never follows a success line.
    printf '[kyklos] proof-tool-emit: token minted for "%s" (story %s) over: %s [audit]\n' "$dim" "$story" "$*" >&2
    return 0
}

# proof_tool_verify DIM [ROOT] [STORY] -> exit 0 iff a token exists AND every recorded file still hashes identically
# (nothing edited since the tool ran) AND at least one file was recorded. Fail-CLOSED: absent token, any content
# drift, or a since-deleted recorded file all yield non-zero. This is the whole point -- a stale claim cannot pass.
# On a failure PROOF_TOOL_VERIFY_REASON says why, as "<verdict>: <what>" with verdict no-token, stale or unauthentic
# (the CLI prints it, so the bridge can say which field or file differs).
proof_tool_verify() {
    local dim="$1" root="${2:-}" story="${3:-}" tokfile stored line f h
    PROOF_TOOL_VERIFY_REASON=""
    if [ -n "$root" ]; then root="$(_proof_tool_canon_path "$root")"; else root="$(_proof_tool_root)"; fi
    story="$(_proof_tool_story_key "${story:-${KYKLOS_PROOF_STORY:-}}")"
    [ -n "$story" ] || story="$(_proof_tool_detect_story "$root")"
    # Only the token bound to THIS story counts: fail closed when the story is unknown, and never fall back to a
    # story-less legacy token (it cannot show which story it proves). [RiskMitigation RA-02]
    [ -n "$story" ] || { PROOF_TOOL_VERIFY_REASON="no-token: the story could not be determined (pass --story <N>)"; return 1; }
    tokfile="$(_proof_tool_token_file "$dim" "$story")"
    [ -f "$tokfile" ] || { PROOF_TOOL_VERIFY_REASON="no-token: no token for story $story"; return 1; }
    # FRESHNESS in shared mode: a shared token dir (workspace-mounted) survives container restarts, so
    # dir lifetime no longer enforces "a fresh container must re-run the tool" — the token must be NEWER than this
    # container's start marker (container_start_marker_ensure: a file created once and never rewritten). The state
    # folder itself is NOT a usable reference: its modification time moves whenever any file inside it is created,
    # removed or renamed, so a token minted a minute ago would read as older than the session. A missing marker is
    # created now, so the rule never fails open: a token from before this point is still refused. Container-local
    # mode is unchanged (the dir IS the session). The
    # bridge's host check skips it (PROOF_TOOL_HOST_CHECK, set only by the CLI's `verify --host-check`): the host has
    # no container session, and its state folder is shared by every bridge on the machine, so any other project's
    # activity would make a token minted a minute ago look old. Every gate calls this function directly, so it keeps
    # the rule, and the container gate applies it before it asks the host (proof_tool_verify_sealed).
    if _proof_tool_shared_dir >/dev/null && [ "${PROOF_TOOL_HOST_CHECK:-0}" != 1 ]; then
        # [RiskMitigation RA-01] fail closed: no marker can be made -> refuse; an earlier token -> refuse.
        local _start
        _start="$(container_start_marker_ensure)" || { PROOF_TOOL_VERIFY_REASON="stale: the container start marker could not be created in ${KYKLOS_STATE_DIR:-/tmp/kyklos-state} (measure coverage again)"; return 1; }
        if [ "$tokfile" -ot "$_start" ]; then
            PROOF_TOOL_VERIFY_REASON="stale: the token is older than this session (measure coverage again)"; return 1
        fi
    fi
    stored="$(cat "$tokfile" 2>/dev/null)"
    [ -n "$stored" ] || { PROOF_TOOL_VERIFY_REASON="unauthentic: the token file is empty"; return 1; }
    # Split the token into its CONTENT body (the sorted path:sha lines) and the optional trailing
    # `hmac:<mac>` authenticity line. The content check below is UNCHANGED (a keyless container verify behaves
    # exactly as before); the MAC is checked only in keyed (host) mode.
    local body
    body="$(printf '%s\n' "$stored" | grep -v -e '^hmac:' -e '^root:' -e "^$_PTG_ATTACH_PREFIX" 2>/dev/null)"
    _PTG_BASE_CACHE=()   # resolve each repository's merge base afresh for this verify
    # The commit each entry was measured against (its .measured sidecar, when its MAC holds): tried first, then the
    # fork point, so a container whose trunk ref is older than the one the bridge fetched still verifies.
    local -A measured_at=()
    local _ml
    while IFS= read -r _ml; do [ -n "$_ml" ] && measured_at["${_ml%%$'\t'*}"]="${_ml#*$'\t'}"; done <<< "$(_proof_tool_measured_lines "$tokfile")"
    # Recompute the hash of exactly the recorded paths (RELATIVE entries resolve against the root — the
    # cross-boundary portability seam; absolute legacy entries verify as before) byte-for-byte, through the same
    # path form and hash function the mint used.
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        f="${line%:*}"; h="${line##*:}"
        case "$f" in /*|[A-Za-z]:/*|[A-Za-z]:\\*) : ;; *) f="$root/$f" ;; esac
        f="$(_proof_tool_canon_path "$f")"
        [ -f "$f" ] || { PROOF_TOOL_VERIFY_REASON="stale: ${line%:*} no longer exists"; return 1; }
        _proof_tool_entry_holds "$f" "$h" "${measured_at[${line%:*}]:-}" || {
            case "$h" in
                "$_PTG_CHANGE_PREFIX"*) PROOF_TOOL_VERIFY_REASON="stale: the story's own change to ${line%:*} differs from the one measured (or the file has uncommitted edits)" ;;
                *) PROOF_TOOL_VERIFY_REASON="stale: ${line%:*} changed since the token was minted" ;;
            esac
            return 1; }
    done <<EOF
$body
EOF
    # A token that records no file proves nothing (emit refuses to write one; a hand-made or truncated file is refused).
    # A token holding coverage receipts only is no file claim: it never verifies, and says so (with the key, its
    # signature must hold first, so an edited one is still called unauthentic).
    if ! printf '%s\n' "$body" | grep -c . >/dev/null; then
        if ! _proof_tool_receipt_only "$stored"; then PROOF_TOOL_VERIFY_REASON="unauthentic: the token records no file"
        elif [ -n "${KYKLOS_PROOF_HMAC_KEY:-}" ] && ! _proof_tool_stored_mac_holds "$stored"; then
            PROOF_TOOL_VERIFY_REASON="unauthentic: the hmac field does not match the recorded files and hashes (the token was edited, or minted under another key)"
        else PROOF_TOOL_VERIFY_REASON="$(_proof_tool_receipt_only_reason "$story")"; fi
        return 1
    fi
    # AUTHENTICITY (keyed / host mode only): when a host-only HMAC key is configured, the token MUST carry a MAC
    # that matches the content body — a self-mint (no key) cannot forge it, and a keyless token is refused. A keyless
    # (container) verify checks content only here; for a sealed dimension proof_tool_verify_sealed then asks the
    # bridge to authenticate it.
    _proof_tool_signature_holds "$stored"
}

# _proof_tool_signature_holds STORED -> rc 0 when no host key is configured (a keyless container check judges content
# only), or when the token text STORED carries an hmac line that signs its body and attachment lines under the key. On
# failure PROOF_TOOL_VERIFY_REASON says which part is wrong. The one signature rule of the checkout check
# (proof_tool_verify) and the result check (proof_tool_verify_at_result).
# [CySec] CWE-345: with the host key, a token without a matching MAC (a container self-mint, an edited record) is refused.
_proof_tool_signature_holds() {
    [ -n "${KYKLOS_PROOF_HMAC_KEY:-}" ] || return 0
    [ -n "$(printf '%s\n' "$1" | sed -n 's/^hmac://p' | head -1)" ] \
        || { PROOF_TOOL_VERIFY_REASON="unauthentic: the token has no hmac field (not minted under the host key)"; return 1; }
    _proof_tool_stored_mac_holds "$1" \
        || { PROOF_TOOL_VERIFY_REASON="unauthentic: the hmac field does not match the recorded files and hashes (the token was edited, or minted under another key)"; return 1; }
}

# proof_tool_verify_at_result DIM ROOT STORY -> rc 0 iff the Test Discipline token of STORY is authentic and holds at the
# story's OWN result in the repository at ROOT (default: the token root), the rule the container's close applies
# (proof_tool_close_finding): each place the story landed on a trunk (its merge against the first parent, its own
# commits, or its branch ahead of the trunk before the merge), plus the late-change check after a held place. The
# bridge's close calls it through `verify --at-result`, because it runs on whatever the checkout is, usually the trunk
# after the merge, where the checkout's own change window is empty and every change record would read stale. Checks
# made before the merge (the container gate, the auto-merge arm guard) keep the checkout check (proof_tool_verify). Any
# other dimension records no change window and is judged by the checkout check. On failure PROOF_TOOL_VERIFY_REASON is
# one "<verdict>: <why>" line.
# [CySec] CWE-345 / CWE-367: the token is judged against the story's own landed change, never against whatever commit
# the shared checkout sits on; the signature is checked first and any doubt git raises refuses (fail-closed).
# [RiskMitigation RA-03] a merge whose resolution or a later unattributed commit changed the measured lines refuses.
proof_tool_verify_at_result() {
    local dim="$1" root="${2:-}" story="${3:-}" tokfile stored body finding
    PROOF_TOOL_VERIFY_REASON=""
    [ "$(_proof_tool_slug "$dim")" = test-discipline ] || { proof_tool_verify "$dim" "$root" "$story"; return; }
    if [ -n "$root" ]; then root="$(_proof_tool_canon_path "$root")"; else root="$(_proof_tool_root)"; fi
    story="$(_proof_tool_story_key "${story:-${KYKLOS_PROOF_STORY:-}}")"
    [ -n "$story" ] || { PROOF_TOOL_VERIFY_REASON="no-token: the story could not be determined (pass --story <N>)"; return 1; }
    tokfile="$(_proof_tool_token_file "$dim" "$story")"
    [ -f "$tokfile" ] || { PROOF_TOOL_VERIFY_REASON="no-token: no token for story $story"; return 1; }
    stored="$(cat "$tokfile" 2>/dev/null)"
    [ -n "$stored" ] || { PROOF_TOOL_VERIFY_REASON="unauthentic: the token file is empty"; return 1; }
    body="$(printf '%s\n' "$stored" | grep -v -e '^hmac:' -e '^root:' -e "^$_PTG_ATTACH_PREFIX" 2>/dev/null)"
    # a token recording no file (receipts only, or a truncated one) gets the checkout check's own answer: it never holds
    printf '%s\n' "$body" | grep -c . >/dev/null || { proof_tool_verify "$dim" "$root" "$story"; return 1; }
    _proof_tool_signature_holds "$stored" || return 1
    git -C "$root" rev-parse --show-toplevel >/dev/null 2>&1 \
        || { PROOF_TOOL_VERIFY_REASON="stale: $root is not a git work tree, so the story's own result cannot be found"; return 1; }
    if finding="$(proof_tool_close_finding "$dim" PROVEN "$root" "$story" development "")"; then
        PROOF_TOOL_VERIFY_REASON="stale: $(printf '%s' "$finding" | tr '\r\n' '  ' | sed 's/[[:space:]]*$//')"
        return 1
    fi
    return 0
}

# proof_tool_recorded_files DIM ROOT STORY -> print, one per line, the paths (relative to ROOT, '/'-separated) that
# the token for DIM bound to STORY records. Prints nothing when there is no such token. It does NOT verify the
# token -- callers pair it with proof_tool_verify, which proves the recorded files are unchanged.
proof_tool_recorded_files() {
    local dim="$1" root="${2:-}" story tokfile line f
    [ -n "$root" ] || root="$(_proof_tool_root)"
    story="$(_proof_tool_story_key "${3:-${KYKLOS_PROOF_STORY:-}}")"
    [ -n "$story" ] || story="$(_proof_tool_detect_story "$root")"
    [ -n "$story" ] || return 0
    tokfile="$(_proof_tool_token_file "$dim" "$story")"
    [ -f "$tokfile" ] || return 0
    root="$(_proof_tool_canon_path "$root")"
    while IFS= read -r line; do
        case "$line" in ''|hmac:*|root:*|attachment:*) continue ;; esac
        f="$(_proof_tool_canon_path "${line%:*}")"
        case "$f" in "$root"/*) f="${f#"$root"/}" ;; esac
        printf '%s\n' "$f"
    done < "$tokfile"
}

# proof_tool_is_gated DIM -> exit 0 iff DIM is in the gated subset. A dimension NOT listed keeps the fail-open
# heuristic authentication (proof-authentication.sh) and is never hard-gated here.
proof_tool_is_gated() {
    case "$(_proof_tool_slug "$1")" in
        test-discipline) return 0 ;;
        non-duplication) return 0 ;;   # PROVEN needs a fresh ssdlc-deduplicate pass token over the changed source
        documentation)   return 0 ;;   # PROVEN needs a fresh update-docs pass token over the changed source
        *) return 1 ;;
    esac
}

# proof_tool_applies DIM PROJECT_DIR -> exit 0 iff the gated tool is APPLICABLE to this story's change. Fail-open:
# on any uncertainty it returns non-zero (NOT applicable), so the gate never hard-blocks on a case it cannot judge.
proof_tool_applies() {
    case "$(_proof_tool_slug "$1")" in
        test-discipline) _proof_tool_code_changed "$2" ;;
        non-duplication) _proof_tool_source_changed "$2" ;;   # dedup applies whenever the change adds source (any language)
        documentation)   _proof_tool_source_changed "$2" ;;   # a source change is the trigger for a doc review; docs-only/no-source -> fail-open
        *) return 1 ;;
    esac
}

# proof_tool_change_base PROJECT_DIR -> print the commit this branch forked from its trunk (the merge-base), or exit
# non-zero when none can be resolved. Candidates, in order of authority:
#   1. KYKLOS_CHANGE_BASE_REF (an explicit ref; if set it is the ONLY candidate, so a typo fails instead of guessing);
#   2. the merge request's target branch in CI (CI_MERGE_REQUEST_TARGET_BRANCH_NAME, as origin/<name> or <name>);
#   3. the usual trunks origin/develop, origin/main, origin/master, each preceded by its local branch when that one
#      is strictly ahead of it (_proof_tool_trunk_candidates).
# Among the candidates that exist, the NEAREST merge-base wins (fewest commits between it and HEAD): a GitFlow feature
# branch forked from develop is judged against develop, a hotfix against main. A merge of the trunk INTO the branch
# moves the merge-base forward, so trunk changes merged in are never charged to the branch. A shallow clone whose
# history does not reach the fork point resolves to nothing (non-zero) rather than a wrong base.
proof_tool_change_base() {
    local pair; pair="$(proof_tool_change_base_ref "$1")" || return 1
    printf '%s\n' "${pair#* }"
}

# proof_tool_change_base_ref <repo> -> "<trunk-ref> <merge-base>": the trunk this branch forked from (the candidate
# with the closest merge base) and that merge base; rc 1 when none resolves. One selection rule for every caller.
# _proof_tool_trunk_candidates [REPO] -> the trunk refs a branch may have forked from, one per line, in order of
# authority. In REPO, a local trunk branch (develop, main, master) comes before its remote copy when it holds
# everything the remote copy holds and more (strictly ahead; equal copies keep the remote one): a project that
# merges into its trunk locally and pushes later has its stories' merges only there. A local trunk that is behind,
# has diverged, or has no remote copy is never used.
# [RiskMitigation RA-03] a local trunk is trusted only when it contains the remote one, so it can add places, never
# hide the ones the remote holds.
_proof_tool_trunk_candidates() {
    local repo="${1:-}"
    if [ -n "${KYKLOS_CHANGE_BASE_REF:-}" ]; then
        printf '%s\n' "$KYKLOS_CHANGE_BASE_REF"
    elif [ -n "${CI_MERGE_REQUEST_TARGET_BRANCH_NAME:-}" ]; then
        printf '%s\n' "origin/$CI_MERGE_REQUEST_TARGET_BRANCH_NAME" "$CI_MERGE_REQUEST_TARGET_BRANCH_NAME"
    elif [ -z "$repo" ]; then
        printf '%s\n' origin/develop origin/main origin/master
    else
        # One read of the six trunk refs per listing; the ancestry checks are reused while those refs are unchanged
        # (the token step lists the candidates several times, and its git calls must not grow with each listing).
        local n refs loc rem out="" trunk_refs=(refs/heads/develop refs/heads/main refs/heads/master refs/remotes/origin/develop refs/remotes/origin/main refs/remotes/origin/master)
        refs="$(git -C "$repo" for-each-ref --format='%(refname) %(objectname)' "${trunk_refs[@]}" 2>/dev/null)"
        if [ "${_PTG_TRUNK_CACHE_KEY:-}" != "$repo|$refs" ]; then
            for n in develop main master; do
                loc="$(printf '%s\n' "$refs" | awk -v r="refs/heads/$n" '$1 == r { print $2 }')"
                rem="$(printf '%s\n' "$refs" | awk -v r="refs/remotes/origin/$n" '$1 == r { print $2 }')"
                if [ -n "$loc" ] && [ -n "$rem" ] && [ "$loc" != "$rem" ] \
                    && git -C "$repo" merge-base --is-ancestor "$rem" "$loc" 2>/dev/null; then
                    out="$out$n"$'\n'
                fi
                out="${out}origin/$n"$'\n'
            done
            _PTG_TRUNK_CACHE_KEY="$repo|$refs"; _PTG_TRUNK_CACHE="$out"
        fi
        printf '%s' "$_PTG_TRUNK_CACHE"
    fi
}

# proof_tool_change_base_ref <repo> [<commit>] -> as above, for <commit> (default HEAD) instead of the checkout.
proof_tool_change_base_ref() {
    local proj="$1" rev="${2:-HEAD}" ref mb n best="" bestn="" bestref="" cands=()
    command -v git >/dev/null 2>&1 || return 1
    git -C "$proj" rev-parse --verify -q "$rev^{commit}" >/dev/null 2>&1 || return 1
    mapfile -t cands < <(_proof_tool_trunk_candidates "$proj")
    for ref in "${cands[@]}"; do
        git -C "$proj" rev-parse --verify -q "${ref}^{commit}" >/dev/null 2>&1 || continue
        mb="$(git -C "$proj" merge-base "$ref" "$rev" 2>/dev/null)" || continue
        [ -n "$mb" ] || continue
        n="$(git -C "$proj" rev-list --count "${mb}..$rev" 2>/dev/null)" || continue
        if [ -z "$bestn" ] || [ "$n" -lt "$bestn" ]; then best="$mb"; bestn="$n"; bestref="$ref"; fi
    done
    [ -n "$best" ] || return 1
    printf '%s %s\n' "$bestref" "$best"
}

# proof_tool_changed_files PROJECT_DIR -> print the files this change touches (sorted, unique, repo-relative) -- the
# ONE change window shared by the tool-gate predicates, the bridge's coverage emitter (which calls this through the
# CLI's `changed-files` command) and the auto-merge coverage guard:
#   - the working tree vs HEAD, plus
#   - the WHOLE branch since it forked from its trunk (proof_tool_change_base..HEAD), so C# changed in an earlier
#     commit is still judged when the last commit is docs-only; or, when HEAD is the fork point itself (working on the
#     trunk, or right after a merge) or no trunk base resolves, the last commit (HEAD~1..HEAD) as before.
# Non-zero when there is no git / not a work tree ("cannot tell"). Diffs are captured FIRST: `git diff HEAD~1 HEAD`
# fails on a single-commit history, and under `set -o pipefail` that failure must never poison the caller.
proof_tool_changed_files() {
    local proj="$1" base="" name
    command -v git >/dev/null 2>&1 || return 1
    git -C "$proj" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
    base="$(proof_tool_change_base "$proj" 2>/dev/null || true)"
    # NUL-separated (-z), hence never quoted: a name with a quote, a backslash or a non-ASCII character is printed as it is
    # on disk, so a caller's file test finds it (see _proof_tool_raw_names for a name holding a line break).
    {
        git -C "$proj" diff -z --name-only HEAD 2>/dev/null
        if [ -n "$base" ] && [ "$base" != "$(git -C "$proj" rev-parse HEAD 2>/dev/null)" ]; then
            git -C "$proj" diff -z --name-only "$base" HEAD 2>/dev/null
        else
            git -C "$proj" diff -z --name-only HEAD~1 HEAD 2>/dev/null
        fi
        true  # a single-commit history makes HEAD~1 fail; under pipefail that must not poison the listing
    } | _proof_tool_raw_names | sort -u
}

# _proof_tool_raw_names: read git's NUL-separated (-z) file names on stdin and print each as it is on disk, one per line.
# Only a name holding a line break cannot be one line; it is printed in git's quoted form (leading and trailing double
# quote), which no file test can open: a caller requires such a file instead of skipping it (the auto-merge guard), and
# every C# test here recognises it (_proof_tool_cs_names). The ONE reader of git file names here: the change window and
# the merged-story window must print the same name for the same file.
_proof_tool_raw_names() {
    local name
    while IFS= read -r -d '' name; do
        [ -n "$name" ] || continue
        case "$name" in *$'\n'*) name="\"${name//$'\n'/\\n}\"" ;; esac
        printf '%s\n' "$name"
    done
}

# _proof_tool_cs_names: read file names on stdin (one per line, as _proof_tool_raw_names prints them) and print the C#
# ones, including a C# name in git's quoted form (a line break in the name), so such a change is judged, never skipped.
# [CySec] Mitigates CWE-636 "Not Failing Securely": an unusual file name can never hide a changed C# file from a C# test.
# [RiskMitigation RA-03]
_proof_tool_cs_names() { grep -iE '\.cs"?$'; }

# _proof_tool_code_changed PROJECT_DIR -> exit 0 iff the change window (proof_tool_changed_files) touches a *.cs
# file. Fail-open: no git / not a work tree -> non-zero (treated as "cannot tell -> do not block"). The changed list
# is captured into a variable FIRST (not piped straight to grep), so the result never depends on the caller's
# pipefail setting.
_proof_tool_code_changed() {
    local changed
    changed="$(proof_tool_changed_files "$1")" || return 1
    printf '%s\n' "$changed" | _proof_tool_cs_names | grep -c . >/dev/null
}

# _proof_tool_source_changed PROJECT_DIR -> exit 0 iff the change window (proof_tool_changed_files) touches a
# SOURCE file in any of the supported languages (dedup applies to constants/logic in C#, PowerShell, shell, Python,
# TS/JS, Go, Java, Ruby — not just *.cs). Same fail-open contract as _proof_tool_code_changed: no git / not a work
# tree / no source touched -> non-zero ("cannot tell -> do not block"), so a docs-only story is never gated here.
_proof_tool_source_changed() {
    local changed
    changed="$(proof_tool_changed_source_files "$1")" || return 1
    [ -n "$changed" ]
}

# proof_tool_changed_source_files PROJECT_DIR -> print the SOURCE files (any supported language) among
# proof_tool_changed_files, one per line; empty output when the change touches no source. Non-zero only when the
# change window cannot be known (no git / not a work tree). The one definition of "a source file" for every caller.
proof_tool_changed_source_files() {
    local changed
    changed="$(proof_tool_changed_files "$1")" || return 1
    printf '%s\n' "$changed" | grep -iE '\.(cs|ps1|psm1|sh|py|ts|tsx|js|jsx|go|java|rb)$' || true
}

# _proof_tool_diff_attributable SRC_ROOT STORY_ID -> exit 0 iff the LIVE source diff of SRC_ROOT can honestly be
# attributed to story STORY_ID -- i.e. there are UNCOMMITTED source changes in the working tree (an active close in
# progress), OR the HEAD commit that produced the HEAD~1..HEAD diff REFERENCES this story (`#<id>` / `STORY-<id>`,
# e.g. the `Refs: #<id>` trailer). Otherwise the diff is some OTHER story's last commit (or the story's
# real deliverable lives in a DIFFERENT repo than SRC_ROOT), and re-grading it against that diff is meaningless.
#
# WHY: the diff-dependent tool-gate (proof_tool_gate_finding) and its mirror
# (proof_tool_notpertinent_finding) decide applicability from the LIVE HEAD~1..HEAD + working-tree diff. That is
# correct for the story whose change IS that diff, but the Stop hook re-grades EVERY story closed within the
# KYKLOS_SESSION_WINDOW_SECONDS window (kyklos-story-proof-guard.sh) on every Stop -- against whatever the last commit happens to be. When the last commit belongs to a
# DIFFERENT story (its `Refs: #<other>` trailer), or the graded story's deliverable is cross-repo, the gate demands a
# coverage %/dedup token for source the story never touched: an UNSATISFIABLE gate on an already-clean close.
#
# Fail-OPEN (exit 1 -> caller SKIPS the diff-dependent gate) on any uncertainty (no git, no id). This matches the
# tool-gate's existing fail-open contract (a story that touched no source is never gated); a genuinely-active close
# is unaffected -- its own working-tree edits, or its own `Refs: #<id>` commit, keep it attributable so the gate runs.
_proof_tool_diff_attributable() {
    local src="$1" id="$2" num msg
    # CONSERVATIVE: default to attributable (run the gate). Only SKIP on POSITIVE evidence the live diff belongs to
    # a DIFFERENT story -- so this can only ever REMOVE a false block, never introduce one or weaken the gate on a
    # story whose code IS the current diff. Any uncertainty (no id, no git, non-repo, a commit with no story ref)
    # keeps the legacy behaviour: run the gate (its own fail-open handles a no-source repo).
    [ -n "$id" ] || return 0
    num="$(printf '%s' "$id" | grep -oE '[0-9]+' | head -1)"; [ -n "$num" ] || return 0
    command -v git >/dev/null 2>&1 || return 0
    git -C "$src" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
    # (0) the source tree is on ANOTHER story's branch (feature/story-<M>-..., hotfix/story-<M>-...): its commits and its
    #     uncommitted changes are that story's work, so they are never graded against this one -> NOT attributable.
    #     Checked before (a): a story closed a moment ago must not be graded against the next story's first edits.
    local br bnum
    br="$(git -C "$src" symbolic-ref --short -q HEAD 2>/dev/null)"
    bnum="$(printf '%s' "$br" | sed -nE 's#^(feature|hotfix)/story-0*([0-9]+)(-.*)?$#\2#p')"
    if [ -n "$bnum" ] && [ "$bnum" != "$((10#$num))" ]; then return 1; fi
    # (a) uncommitted SOURCE changes in the working tree -> an active close in progress -> attributable.
    git -C "$src" status --porcelain 2>/dev/null | grep -ciE '\.(cs|ps1|psm1|sh|py|ts|tsx|js|jsx|go|java|rb)$' >/dev/null && return 0
    # (b) the HEAD commit references THIS story (#<id> / STORY-<id>) -> attributable.
    msg="$(git -C "$src" log -1 --format='%B' 2>/dev/null)"
    # The `#<id>` reference is the commit's footer (refs_footer_*: a number in a remark is never read as a reference).
    # A cited item whose number is the story's attributes the commit to it whatever project path it is written with: this
    # reader does not know whether that path is the story's own (a moved or redirected project is written another way), and
    # an unknown path is not positive evidence of another story.
    local word="STORY" cited item
    cited="$(refs_footer_cited "$msg" "")"
    while IFS= read -r item; do
        [ -n "$item" ] && [ "${item##*#}" = "$(printf '%s' "$num" | sed -E 's/^0+([0-9])/\1/')" ] && return 0
    done <<< "$cited"
    printf '%s' "$msg" | grep -ciE "${word}-0*${num}([^0-9]|\$)" >/dev/null && return 0
    # (c) the HEAD commit references a DIFFERENT story (some footer item / <word>-N that is NOT this one) -> the diff is
    #     that story's (or a cross-repo deliverable left PROJECT_DIR on another story's commit) -> NOT attributable.
    if [ -n "$cited" ] || printf '%s' "$msg" | grep -ciE "${word}-[0-9]+" >/dev/null; then return 1; fi
    # (d) no story reference at all -> ambiguous -> default attributable (run the gate).
    return 0
}

# proof_tool_is_sealed DIM -> rc 0 iff DIM's token is minted by the bridge under the host key, so a gate must have the
# bridge confirm its signature (not only its content). Test Discipline is minted by the bridge's get_coverage; the
# other gated dimensions are still minted inside the container and keep the content check until they move too.
proof_tool_is_sealed() { [ "$(_proof_tool_slug "$1")" = test-discipline ]; }

# proof_tool_bridge_seal DIM STORY -> rc 0 iff the bridge's keyed check (verify_proof_token) answers "authentic" for
# the story's token. On failure it sets PROOF_TOOL_SEAL_REASON. FAIL-HARD: an unreachable bridge, a refused call or
# any other answer is "not sealed"; there is no fallback to the content-only check.
# [CySec] Prevents CWE-345 "Insufficient Verification of Data Authenticity": a token the container produced without
# the host key never satisfies a gate, because only the bridge holding the key can confirm its signature.
# [RiskMitigation RA-04] A gate hook must finish inside its time limit: a cancelled pre-tool hook does not block.
# One wait budget for every keyed check one process makes: a hook can check several tokens in a row (a companion and
# its nested source, every closed story), and Claude Code cancels the hook at its hooks.json timeout (3700 s) without
# blocking, so the SUM of the waits must stay under it, not each one. The deadline is fixed when this library loads (at
# the hook's top level, before any subshell) and tagged with the process id, so a value inherited from another process
# is never used.
# The longest any wait or the whole budget may be; it must stay below the gate hooks' hooks.json timeout.
PROOF_TOOL_WAIT_CEILING_SECONDS=3600
# KYKLOS_PROOF_VERIFY_BUDGET_SECONDS may only lower it (1 to the ceiling; anything else is the default), which only
# refuses sooner.
PROOF_TOOL_SEAL_BUDGET_SECONDS=$PROOF_TOOL_WAIT_CEILING_SECONDS
case "${KYKLOS_PROOF_VERIFY_BUDGET_SECONDS:-}" in
    ''|*[!0-9]*|?????*) ;;
    *) [ "$KYKLOS_PROOF_VERIFY_BUDGET_SECONDS" -ge 1 ] && [ "$KYKLOS_PROOF_VERIFY_BUDGET_SECONDS" -le "$PROOF_TOOL_WAIT_CEILING_SECONDS" ] \
           && PROOF_TOOL_SEAL_BUDGET_SECONDS="$KYKLOS_PROOF_VERIFY_BUDGET_SECONDS" ;;
esac
case "${_PTG_SEAL_DEADLINE:-}" in
    "$$":*) ;;
    *) _PTG_SEAL_DEADLINE="$$:$(( $(date +%s) + PROOF_TOOL_SEAL_BUDGET_SECONDS ))" ;;
esac

proof_tool_bridge_seal() {
    local dim="$1" story="$2" purpose="${3:-arm}" reply text rc left
    PROOF_TOOL_SEAL_REASON=""
    if ! command -v bridge_mcp_call >/dev/null 2>&1; then
        # shellcheck source=/dev/null
        [ -f "$_PTG_LIB_DIR/bridge-mcp.sh" ] && . "$_PTG_LIB_DIR/bridge-mcp.sh"
    fi
    command -v bridge_mcp_call >/dev/null 2>&1 || { PROOF_TOOL_SEAL_REASON="the bridge client (hooks/lib/bridge-mcp.sh) is missing, so the token's signature cannot be checked"; return 1; }
    # The keyed check re-hashes every file the token records, so a large change takes minutes, not seconds: the wait
    # is a setting (KYKLOS_PROOF_VERIFY_TIMEOUT_SECONDS, 1-3600, default 600). A value outside that range is refused
    # loudly rather than silently replaced.
    local wait="${KYKLOS_PROOF_VERIFY_TIMEOUT_SECONDS:-600}"
    # The hooks that reach this check carry an explicit "timeout": 3700 in hooks.json: Claude Code cancels a hook at
    # its timeout (600 s by default) and a cancelled PreToolUse hook does NOT block, so a wait that outlived the hook
    # would let the gated action through. Keep 3600 (the maximum here) below that hook timeout.
    case "$wait" in
        ''|*[!0-9]*|?????*) PROOF_TOOL_SEAL_REASON="KYKLOS_PROOF_VERIFY_TIMEOUT_SECONDS='$wait' is not a whole number of seconds (1-$PROOF_TOOL_WAIT_CEILING_SECONDS)"; return 1 ;;
    esac
    if [ "$wait" -lt 1 ] || [ "$wait" -gt "$PROOF_TOOL_WAIT_CEILING_SECONDS" ]; then
        PROOF_TOOL_SEAL_REASON="KYKLOS_PROOF_VERIFY_TIMEOUT_SECONDS=$wait is outside 1-$PROOF_TOOL_WAIT_CEILING_SECONDS"; return 1
    fi
    # [CySec] Prevents CWE-636 "Not Failing Securely": the waits of one hook run share one budget below the hook's
    # timeout, so a slow bridge refuses the check instead of getting the hook cancelled (a cancelled hook lets the action
    # through).
    left=$(( ${_PTG_SEAL_DEADLINE#*:} - $(date +%s) ))
    if [ "$left" -lt 1 ]; then
        PROOF_TOOL_SEAL_REASON="this check had no time left: the signature checks of one run share a ${PROOF_TOOL_SEAL_BUDGET_SECONDS}s budget (below the hook's own time limit) and earlier checks used it; retry when the bridge answers faster"
        return 1
    fi
    [ "$wait" -le "$left" ] || wait="$left"
    # The purpose tells the bridge what a trunk it cannot fetch means: an arm refuses, a Stop keeps the patch-id verdict
    # with a note. A bridge without the reuse rule ignores it.
    reply="$(bridge_mcp_call verify_proof_token "$(jq -cn --arg d "$dim" --arg s "$story" --arg p "$purpose" '{dimension:$d, story:$s, purpose:$p}')" "$wait")"; rc=$?
    if [ "$rc" -ne 0 ]; then
        PROOF_TOOL_SEAL_REASON="the bridge could not be reached, or did not answer within ${wait}s, to check the token's signature (bridge client rc $rc); a large change takes longer to check: raise KYKLOS_PROOF_VERIFY_TIMEOUT_SECONDS, or start the bridge (or relaunch), then retry"
        return 1
    fi
    if bridge_mcp_is_error "$reply"; then
        PROOF_TOOL_SEAL_REASON="the bridge refused the signature check: $(bridge_mcp_text "$reply" | tr '\n' ' ' | cut -c1-300)"
        return 1
    fi
    text="$(bridge_mcp_text "$reply" | tr -d '\r' | head -1)"
    [ "$text" = authentic ] && return 0
    PROOF_TOOL_SEAL_REASON="the bridge's signature check answered '${text:-nothing}' for story ${story}: the token is not one the bridge minted under the host key over these files; measure coverage again with the bridge get_coverage"
    return 1
}

# proof_tool_verify_sealed DIM ROOT STORY [PURPOSE] -> rc 0 iff the content check passes AND, for a sealed dimension, the
# bridge confirms the signature for PURPOSE (arm, the default and strict reading, or stop). PROOF_TOOL_SEAL_REASON says
# which part failed.
proof_tool_verify_sealed() {
    local dim="$1" root="${2:-}" story="${3:-}" purpose="${4:-arm}" key
    PROOF_TOOL_SEAL_REASON=""
    proof_tool_verify "$dim" "$root" "$story" || { PROOF_TOOL_SEAL_REASON="no valid content token (${PROOF_TOOL_VERIFY_REASON:-missing, or a recorded file changed since it was minted})"; return 1; }
    proof_tool_is_sealed "$dim" || return 0
    key="$(_proof_tool_story_key "${story:-${KYKLOS_PROOF_STORY:-}}")"; [ -n "$key" ] || key="$(_proof_tool_detect_story "${root:-$(_proof_tool_root)}")"
    proof_tool_bridge_seal "$dim" "$key" "$purpose"
}

# proof_tool_token_root DIM STORY FALLBACK -> the ONE root the story's DIM token's relative entries are read under, by
# every check that reads them (the Stop gate, the auto-merge arm guard): the folder its .base sidecar names, relative to
# the token's own folder (the root the mint measured, whoever minted it: a container tool under the project root, the
# bridge under its solution root, the nested source of a companion, a subfolder of a repository). A token without a
# sidecar (minted before it existed, or across drives) is read under FALLBACK, the caller's root before tokens named
# theirs: such a token can only be refused where it was measured elsewhere (re-measure to fix), never pass on files
# the mint did not measure. The root is never chosen by which files exist. STORY must be the story key the caller
# also passes to the verifier (derive it once), so both read the same token.
# Layout limit: the base is joined onto THIS side's token folder, so it is exact when both sides lay out the token
# folder and the root alike (the token folder inside the root, or both under the same parents). That is why a tree
# mint (another repository, often mounted elsewhere in the container than on the host) writes no sidecar.
# [RiskMitigation RA-01] [RiskMitigation RA-02] The root is the one the mint recorded, never chosen by which files
# exist; the bridge keyed seal stays the check under its own root.
proof_tool_token_root() {
    local dim="$1" story="$2" fallback="$3" tokfile base=""
    story="$(_proof_tool_story_key "$story")"
    if [ -n "$story" ]; then
        tokfile="$(_proof_tool_token_file "$dim" "$story")"
        [ -f "$tokfile" ] && base="$(_proof_tool_token_base "$tokfile")"
    fi
    if [ -n "$base" ]; then _proof_tool_join_rel "$(dirname "$tokfile")" "$base"; else _proof_tool_canon_path "$fallback"; fi
}

# proof_tool_gate_finding DIM VERDICT PROJECT_DIR -> print a BLOCK reason and return 0 ("finding present") iff DIM
# is gated AND VERDICT is PROVEN AND the tool applies to this change AND no valid content token backs it. Otherwise
# print nothing and return 1 (no finding). This is the fail-HARD path -- contrast proof-authentication.sh, whose
# helpers only ever report a concretely-false claim and stay fail-open.
proof_tool_gate_finding() {
    local dim="$1" verdict="$2" proj="$3" story="${4:-}" key
    proof_tool_is_gated "$dim" || return 1
    [ "$verdict" = "PROVEN" ] || return 1
    proof_tool_applies "$dim" "$proj" || return 1     # not applicable -> never block (fail-open safety)
    # a fresh, matching token FOR THIS STORY satisfies the gate; a sealed dimension also needs the bridge's signature check
    # The content is read under the one root the token names (proof_tool_token_root); the bridge's signature check runs
    # once, after it: its wait may take the whole hook timeout (see proof_tool_bridge_seal), and a cancelled hook does
    # not block.
    # The story is derived ONCE (from the project root, as before) and the same key goes to every read below.
    key="$(_proof_tool_story_key "${story:-${KYKLOS_PROOF_STORY:-}}")"; [ -n "$key" ] || key="$(_proof_tool_detect_story "$(_proof_tool_root)")"
    local troot; troot="$(proof_tool_token_root "$dim" "$key" "$(_proof_tool_root)")"
    if [ -n "$key" ] && [ -n "$troot" ] && proof_tool_verify "$dim" "$troot" "$key"; then
        proof_tool_verify_sealed "$dim" "$troot" "$key" stop && return 1
        printf 'Tool-gated dimension "%s": the token for this story has the right content, but %s.\n' "$dim" "$PROOF_TOOL_SEAL_REASON"
        return 0
    fi
    if [ -n "$key" ] && [ ! -f "$(_proof_tool_token_file "$dim" "$key")" ] && [ -f "$(_proof_tool_legacy_token_file "$dim")" ]; then
        printf 'Tool-gated dimension "%s": the only %s token present is not bound to a story (minted by an older tool/bridge), so it cannot prove story %s. Re-run the tool with the current Kyklos (or pass --story %s to its emit), then re-set the proof.\n' "$dim" "$dim" "$key" "$key"
        return 0
    fi
    printf 'Tool-gated dimension "%s": PROVEN requires a fresh %s tool run over the changed files for story %s (no valid content token bound to it at the current state). Run the tool, then re-set the proof.\n' "$dim" "$dim" "${key:-<unknown>}"
    return 0
}

# ---- The token judged at the story's OWN commits (the close) -----------------------------------------------------
# A close happens from whatever commit the checkout sits on, often the trunk after other stories merged. Judging the
# story's token there compares it with another story's state: the content check fails for a reason that is not this
# story's, or the change window holds no C# of this story and the check is skipped, so a stale token passed. The close
# therefore judges the token at the story's own result, found from git alone, in this order (the first step that finds
# the story wins; a merge wins over an unmerged branch, because a close cites merged work and a branch made after the
# merge must not stand in for what landed):
#   1. a story merged with a merge commit whose subject names it (`Merge branch '.../story-<N>-...'`): EVERY such merge
#      (a story merged more than once, e.g. its first branch and then a follow-up), each against its first parent (the
#      merge result: the story's change as it landed on the trunk, after any conflict resolution), together with every
#      other place its own commits landed on that trunk (step 3). The story's change is their union: each result that
#      changes C# is judged, so a token over the latest merge alone cannot stand in for an earlier one;
#   2. a story branch ((feature|hotfix)/story-<N>-..., local or origin) merged by fast forward: its tip, with no change
#      base (only content records can be judged);
#   3. the story's OWN commits on the trunk: a commit is the story's own when a footer line cites the story (the one
#      definition, refs-footer.sh: a list such as `Refs: #<N>, #<M>` cites both, a remark after the list is never read
#      for numbers, another project's item is not the story's), and it is no merge named for another story. Every place they landed is a result,
#      and every one is judged: each merge commit on the trunk's own line that brought own commits in, when every
#      commit of that merge carries `Refs: #<N>` and the merge is not named for another story (a branch named without
#      the story number, hotfix/<slug>), against its first parent; and each run of consecutive trunk commits
#      (first-parent line) carrying `Refs: #<N>` that holds at least one own commit (a squash merge, or commits placed
#      on the trunk directly), the run's newest commit against the parent of the run. Every result that changes C#
#      must hold, so a later docs-only commit or merge carrying the same trailer cannot stand in for an earlier one
#      that changed C#. Tried only after 1 and 2 found nothing, so another story's merge whose commits mention this
#      one cannot stand in for this story's own result;
#   4. an unmerged story branch ((feature|hotfix)/story-<N>-..., or hotfix/<slug> whose own commits carry
#      `Refs: #<N>`; local or origin): its tip, against the merge base with its trunk (exactly what the coverage run
#      measured).
# Before all of these: when the checkout itself is the story's own branch ahead of its trunk and that branch changes C#
# (proof_tool_story_branch_ahead), its head against its fork point is the result, the same window the coverage emitter
# records there, so a follow-up branch of an already merged story is judged on its own change.
# Finding places is never the whole check. A place whose change window holds no C# never counts as success, and when
# a story with a coverage token has no placed window with C# that was judged and held (git places it nowhere, or only
# by a docs-only commit or merge, while its C# landed in a squash naming no story or several, a merge mixing other
# work, an octopus merge), the token is judged at a trunk head (proof_tool_verify_at_trunk_head): every file it records
# must be there what was measured (a content record byte for byte; a change record as the last change the trunk's own
# line made to that file). A token measured on the merged result therefore always holds; a stale landing never does.
# What the token records must hold there: a change record ("change-<patch-id>") equals the patch-id of the story's
# change to that file; a content record equals the file at the story's result or at the trunk's current head (a
# coverage run repeated on the merged result records file contents, since the story's change is then part of the
# trunk). Nothing else is required, so an honest close stays possible after the merge: re-measure on the merged result.

# _proof_tool_refs_grep KEY [REPO] -> the `git log -E --grep` pattern of a footer line citing item KEY (refs_footer_grep,
# the one definition: a list of items, a remark never read for numbers, an item of another project is not this story's;
# REPO's own project path decides which `group/project#N` is the story's own). When the footer library did not load the
# pattern matches nothing (never everything).
_proof_tool_refs_grep() {
    if command -v refs_footer_grep >/dev/null 2>&1; then refs_footer_grep "$1" "$(_proof_tool_footer_own "${2:-.}")"
    else printf '%s' '$^.'; fi
}

# _proof_tool_own_mark KEY [OWN] -> read `git log --format='%x01%H %P%n%s%n%B'` records on stdin and print
# "<own> <H> <P...>" per commit, <own> 1 when the commit is the story's OWN: a footer line cites item KEY (refs_footer_*:
# alone, or in a list with other items: such a commit is judged as the story's, never ignored; OWN is the story's
# project path), and its subject is not a merge named for another story (`Merge branch '.../story-<M>-...'`, M not KEY).
# [CySec] CWE-345: a commit that cites another item only in a remark, or another project's item, never places the story.
_proof_tool_own_mark() {
    awk -v RS='\001' -v key="$1" -v ownproject="${2:-}" "${REFS_FOOTER_AWK:-}"'
        NF == 0 { next }
        {
            n = split($0, L, "\n"); own = 0; other = 0
            # Only the anchored story-branch form names a story: Merge branch '\''(feature|hotfix)/story-<M>[-slug]'\''.
            s = tolower(L[2])
            if (match(s, /^merge branch '\''(feature|hotfix)\/story-[0-9]+(-[^'\'']*)?'\''/)) {
                t = substr(s, RSTART, RLENGTH); sub(/^merge branch '\''(feature|hotfix)\/story-/, "", t); sub(/[^0-9].*$/, "", t)
                if (t + 0 != key + 0) other = 1
            }
            for (i = 3; i <= n; i++) if (refs_footer_cites_line(L[i], ownproject, key, 0)) own = 1
            print ((own && !other) ? 1 : 0), L[1]
        }'
}

# _proof_tool_named_for_other KEY SUBJECT -> rc 0 when SUBJECT is a merge named for a story other than KEY: the first
# word of it that is a story branch in the one anchored form (story_num_from_branch: feature/story-<M>[-slug] or
# hotfix/story-<M>[-slug]), M not KEY, in GitLab's form (`Merge branch 'feature/story-<M>-...'`) or a hand-written one
# (`Merge feature/story-<M>-... into develop`, `Merge request 42: feature/story-<M>-...`). A word that only contains
# `story-<M>` (docs/story-8, story-71) names no story.
_proof_tool_named_for_other() {
    local w n="" words
    read -r -a words <<< "$(printf '%s' "$2" | tr "'\"\`:,()\n" '         ')"
    for w in "${words[@]}"; do
        n="$(story_num_from_branch "$w" | sed -E 's/^0*([0-9])/\1/')"
        [ -n "$n" ] && break
    done
    [ -n "$n" ] && [ "$n" != "$1" ]
}

# _proof_tool_refs_merges REPO KEY REF -> one "<merge> <its first parent> <REF>" line per merge on REF's own line that
# brought in at least one of the story's OWN commits (_proof_tool_own_mark), when every commit of that merge's own
# (non-merge) carries `Refs: #<KEY>` and the merge is not named for another story; newest first. Prints nothing when
# none (the story's own commits all sit on REF's own line, or every such merge mixes other work).
# [CySec] CWE-345: a merge carrying commits of other work, or named for another story, never places the story, so
# another story's merge cannot stand in for this story's result.
_proof_tool_refs_merges() {
    local repo="$1" key="$2" ref="$3" head own proj m c p1 subj seen=" "
    head="$(git -C "$repo" rev-parse --verify -q "${ref}^{commit}" 2>/dev/null)" || return 0
    proj="$(_proof_tool_footer_own "$repo")"
    own="$(git -C "$repo" log -E --grep="$(_proof_tool_refs_grep "$key" "$repo")" --format='%x01%H %P%n%s%n%B' "$ref" 2>/dev/null \
        | _proof_tool_own_mark "$key" "$proj" | awk '$1 == 1 { print $2 }')"
    [ -n "$own" ] || return 0
    # One walk of the history: REF's own line from its oldest commit to its head; each commit of that line claims the
    # commits that become reachable through its other parents (the commits its merge brought in). Prints "<own commit>
    # <merge>" for each own commit off that line, newest own commit first.
    while read -r c m; do
        case "$seen" in *" $m "*) continue ;; esac
        seen="$seen$m "
        { read -r p1 _; IFS= read -r subj; } < <(git -C "$repo" log -1 --format='%P%n%s' "$m" 2>/dev/null)
        # a merge named for another story is never this story's
        _proof_tool_named_for_other "$key" "$subj" && continue
        # every commit the merge brought in (merges aside) carries the story's Refs trailer
        git -C "$repo" log --no-merges --format='%x01%B' "$p1..$m" 2>/dev/null | awk -v RS='\001' -v key="$key" -v ownproject="$proj" "${REFS_FOOTER_AWK:-}"'
            NF == 0 { next }
            { n++; k = split($0, L, "\n"); for (i = 1; i <= k; i++) if (refs_footer_cites_line(L[i], ownproject, key, 0)) { mine++; break } }
            END { exit !(n > 0 && n == mine) }' || continue
        printf '%s %s %s\n' "$m" "$p1" "$ref"
    done < <({ printf '%s\n' "$own"; echo; git -C "$repo" log --format='%H %P' "$ref" 2>/dev/null; } | awk -v head="$head" '
        NF == 0 && !s { s = 1; next }
        !s { want[$1] = ++nw; order[nw] = $1; next }
        { np[$1] = NF - 1; for (i = 2; i <= NF; i++) par[$1, i - 1] = $i }
        END {
            k = 0; x = head
            while (x != "" && !(x in onfp)) { fp[++k] = x; onfp[x] = 1; x = ((x, 1) in par) ? par[x, 1] : "" }
            for (j = k; j >= 1; j--) {
                X = fp[j]; reached[X] = 1; top = 0
                for (i = 2; i <= np[X]; i++) st[++top] = par[X, i]
                while (top > 0) {
                    y = st[top--]; if (y in reached) continue
                    reached[y] = 1; if (y in want) by[y] = X
                    for (i = 1; i <= np[y]; i++) st[++top] = par[y, i]
                }
            }
            for (i = 1; i <= nw; i++) if (order[i] in by) print order[i], by[order[i]]
        }')
}

# _proof_tool_refs_squash REPO KEY REF -> one "<newest> <base or -> <REF>" line per run of consecutive commits on REF's
# own line that carry `Refs: #<KEY>` (a squash merge, or commits placed on the trunk directly) and that holds at least
# one of the story's OWN commits (_proof_tool_own_mark), newest run first: the run's newest commit against the parent
# of its oldest. A run made only of commits that also name other stories places nothing. rc 1 when REF's own line
# holds no such run.
_proof_tool_refs_squash() {
    local repo="$1" key="$2" ref="$3" own c p rest top="" curp="" curmerge="" curown=0 any=1 proj
    proj="$(_proof_tool_footer_own "$repo")"
    while read -r own c p rest; do
        # c continues the run when it is the first parent of the run's oldest commit, and that commit is no merge
        if [ -n "$top" ] && [ "$curp" = "$c" ] && [ -z "$curmerge" ]; then curp="$p"; curmerge="$rest"; [ "$own" = 1 ] && curown=1; continue; fi
        [ -n "$top" ] && [ "$curown" = 1 ] && { _proof_tool_run_line "$repo" "$top" "${curp:--}" "$ref"; any=0; }
        top="$c"; curp="$p"; curmerge="$rest"; curown="$own"
    done < <(git -C "$repo" log --first-parent -E --grep="$(_proof_tool_refs_grep "$key" "$repo")" --format='%x01%H %P%n%s%n%B' "$ref" 2>/dev/null \
        | _proof_tool_own_mark "$key" "$proj")
    [ -n "$top" ] && [ "$curown" = 1 ] && { _proof_tool_run_line "$repo" "$top" "${curp:--}" "$ref"; any=0; }
    return "$any"
}

# _proof_tool_bare_cs_below REPO COMMIT -> print the first commit, walking COMMIT's own line down from COMMIT itself,
# that carries no footer at all (a footer line that cites an item: refs_footer_has_line) and changes C#; rc 1 when there
# is none. The walk covers only consecutive commits that carry no footer, are no merge and are not the repository's first
# commit (a merge or a commit that cites any item ends the stretch: it is attributed). Such a commit sits right below the story's own commits,
# so git cannot tell whether it is part of the story's change: the close refuses rather than leave it unjudged.
# [CySec] CWE-345: a story's C# change cannot be hidden in a commit without the story's trailer next to its own.
_proof_tool_bare_cs_below() {
    local repo="$1" c np refs proj
    [ "$2" != "-" ] || return 1
    proj="$(_proof_tool_footer_own "$repo")"
    while read -r c np refs; do
        [ "$np" = 1 ] && [ "$refs" = 0 ] || return 1
        _proof_tool_window_files "$repo" "$c^" "$c" 2>/dev/null | _proof_tool_cs_names | grep -c . >/dev/null \
            && { printf '%s\n' "$c"; return 0; }
    done < <(git -C "$repo" log --first-parent --format='%x01%H %P%n%B' "$2" 2>/dev/null | awk -v RS='\001' -v ownproject="$proj" "${REFS_FOOTER_AWK:-}"'
        NF == 0 { next }
        { k = split($0, L, "\n"); nh = split(L[1], h, " "); r = 0
          for (i = 2; i <= k; i++) if (refs_footer_has_line(L[i], ownproject, 0)) r = 1
          print h[1], (nh - 1), r }')
    return 1
}

# _proof_tool_run_line REPO RESULT BASE REF -> the place line of a run of the story's own commits: "<RESULT> <BASE>
# <REF>", or "<RESULT> !<commit> <REF>" when a commit without any `Refs:` trailer right below the run changes C#
# (_proof_tool_bare_cs_below): the close refuses such a place by name.
_proof_tool_run_line() {
    local bare
    if bare="$(_proof_tool_bare_cs_below "$1" "$3")"; then printf '%s !%s %s\n' "$2" "$bare" "$4"
    else printf '%s %s %s\n' "$2" "$3" "$4"; fi
}

# _proof_tool_ff_window REPO KEY TIP REF -> the place of a story branch merged by fast forward: its tip against the
# parent of the story's oldest own commit (one whose `Refs:` names the story, lists included) on the stretch the fast
# forward put on REF's own line (the consecutive commits below TIP that are no merge, the first commit excluded). Every
# commit in between is judged as the story's, also one carrying no trailer or another story's; one without any
# trailer right below that window that changes C# makes the place unattributable (_proof_tool_run_line). rc 1 when
# no own commit is on the stretch.
_proof_tool_ff_window() {
    local repo="$1" key="$2" tip="$3" ref="$4" c np own oldest="" proj
    proj="$(_proof_tool_footer_own "$repo")"
    while read -r c np own; do
        [ "$np" = 1 ] || break
        [ "$own" = 1 ] && oldest="$c"
    done < <(git -C "$repo" log --first-parent --format='%x01%H %P%n%B' "$tip" 2>/dev/null | awk -v RS='\001' -v key="$key" -v ownproject="$proj" "${REFS_FOOTER_AWK:-}"'
        NF == 0 { next }
        { k = split($0, L, "\n"); nh = split(L[1], h, " "); o = 0
          for (i = 2; i <= k; i++) if (refs_footer_cites_line(L[i], ownproject, key, 0)) o = 1
          print h[1], (nh - 1), o }')
    [ -n "$oldest" ] || return 1
    _proof_tool_run_line "$repo" "$tip" "$(git -C "$repo" rev-parse "$oldest^" 2>/dev/null || echo -)" "$ref"
}

# _proof_tool_fp_trunk REPO TIP REF... -> print the first trunk REF whose own (first-parent) line holds TIP: a branch
# fast-forwarded into that trunk. rc 1 when none does.
_proof_tool_fp_trunk() {
    local repo="$1" tip="$2" ref; shift 2
    for ref in "$@"; do
        git -C "$repo" rev-parse --verify -q "${ref}^{commit}" >/dev/null 2>&1 || continue
        git -C "$repo" merge-base --is-ancestor "$tip" "$ref" 2>/dev/null || continue
        git -C "$repo" rev-list --first-parent "$ref" 2>/dev/null | grep -cxF "$tip" >/dev/null && { printf '%s\n' "$ref"; return 0; }
    done
    return 1
}

# _proof_tool_carrier_subject SUBJECT -> rc 0 when SUBJECT is the merge of a line that carries other branches' work: a
# release, support or hotfix branch, or a trunk (`Merge branch 'release/1.2' into 'develop'`, `Merge main into
# develop`, `Merge remote-tracking branch 'origin/develop'`).
_proof_tool_carrier_subject() {
    printf '%s\n' "$1" | grep -cE "^Merge (remote-tracking )?(branch )?'?(origin/)?((release|support|hotfix)/[^' ]*|develop|main|master)'?( |$)" >/dev/null
}

# _proof_tool_via_merge REPO KEY TIP REF... -> the place of a story branch whose tip TIP reached a trunk through a
# merge commit, whatever its subject: "<merge> <its first parent> <REF>" for the merge that brought TIP in, so every
# commit of the branch is judged, one without a `Refs:` trailer included. On the first trunk REF... that contains TIP,
# the search starts at the oldest commit of REF's own line that contains TIP. A merge whose other parent is TIP itself
# places it. A merge that carries another line (a release, support or hotfix branch, or a trunk: by its subject, or
# because its other parent sits on another trunk's own line) never places the story: the search goes on down that
# carried line, to the merge there that brought TIP in. A merge named for another story, or joining more than two
# parents, brought the branch in with other work: the branch is then placed by its own commits below TIP
# (_proof_tool_ff_window, or TIP with no base). Prints nothing when no trunk contains TIP.
# [CySec] CWE-345: a merged story branch is never judged on fewer commits than the merge brought in, nor charged the
# work a back-merge, a release merge or another story's merge carries.
_proof_tool_via_merge() {
    local repo="$1" key="$2" tip="$3" ref line m subj res par o other carried next depth; shift 3
    for ref in "$@"; do
        git -C "$repo" rev-parse --verify -q "${ref}^{commit}" >/dev/null 2>&1 || continue
        git -C "$repo" merge-base --is-ancestor "$tip" "$ref" 2>/dev/null || continue
        line="$ref"
        for depth in 1 2 3 4 5 6 7 8; do
            # the oldest commit of LINE's own line that descends from TIP
            m="$(grep -xF -f <(git -C "$repo" rev-list --ancestry-path "$tip..$line" 2>/dev/null) \
                <(git -C "$repo" rev-list --first-parent "$tip..$line" 2>/dev/null) | tail -1)"
            [ -n "$m" ] || break
            # the merge's parents, first parent first
            read -r _ par < <(git -C "$repo" rev-list --parents -1 "$m" 2>/dev/null)
            subj="$(git -C "$repo" log -1 --format=%s "$m" 2>/dev/null)"
            if _proof_tool_named_for_other "$key" "$subj" || [ "$(printf '%s\n' $par | grep -c .)" -gt 2 ]; then
                res="$(_proof_tool_ff_window "$repo" "$key" "$tip" "$ref")"; [ -n "$res" ] || res="$tip - $ref"
                printf '%s\n' "$res"
                return 0
            fi
            case " ${par#* } " in *" $tip "*) printf '%s %s %s\n' "$m" "${par%% *}" "$ref"; return 0 ;; esac
            carried=""
            _proof_tool_carrier_subject "$subj" && carried=1
            for o in "$@"; do
                [ -z "$carried" ] || break
                [ "$o" = "$ref" ] && continue
                for other in ${par#* }; do _proof_tool_fp_trunk "$repo" "$other" "$o" >/dev/null && carried=1; done
            done
            if [ -z "$carried" ]; then printf '%s %s %s\n' "$m" "${par%% *}" "$ref"; return 0; fi
            # go down the carried line that holds TIP
            next=""
            for other in ${par#* }; do git -C "$repo" merge-base --is-ancestor "$tip" "$other" 2>/dev/null && { next="$other"; break; }; done
            [ -n "$next" ] || break
            line="$next"
        done
        return 0
    done
}

# _proof_tool_merged_places REPO KEY REF -> every place on REF where the story's own commits landed, without repeats:
# each merge they came in by (_proof_tool_refs_merges, against the merge's first parent), then each run of the story's
# trunk commits (_proof_tool_refs_squash). EVERY one is judged at the close, so a later docs-only placement can never
# replace an earlier one that changed C#.
_proof_tool_merged_places() {
    { _proof_tool_refs_merges "$1" "$2" "$3"; _proof_tool_refs_squash "$1" "$2" "$3"; } | awk '!seen[$1 " " $2]++'
}

# proof_tool_story_result REPO STORY -> "<result-commit> <base-commit or -> <trunk-ref>" lines for STORY in REPO, one
# per place its change landed on a trunk; rc 1 when none is found. EVERY place is listed, on every path, so the close
# (which judges these places) and the token step (whose window is their files: proof_tool_story_merged_window, plus the
# same own commits through proof_tool_story_own_files) always see one change:
#   - each merge named for the story in GitLab's form, and every other place its own commits landed by
#     (_proof_tool_merged_places), on the first trunk holding any;
#   - each branch of the story (`.../story-<N>-...`, or a hotfix whose commits carry `Refs: #<N>`) on a trunk: a
#     fast-forward by its own commits (_proof_tool_ff_window), one reached through a merge by that merge
#     (_proof_tool_via_merge);
#   - when any of those exists, each own commit of the story (_proof_tool_own_commits) none of them holds, by itself
#     (a story only own commits place stays unplaced: the close reads its change from the deliverables it cites).
# Only when none of these exists, an unmerged branch head of the story against its fork point (its open change).
# [CySec] CWE-345: a later placement (a fast-forwarded docs follow-up) never hides an earlier one that changed C#.
# [RiskMitigation RA-01] the token window and the close window are the union of the same places.
proof_tool_story_result() {
    local repo="$1" key pat name sha pair tref fpref open="" places="" mline cands=() ref res c r b t held
    key="$(_proof_tool_story_key "$2")"; [ -n "$key" ] || return 1
    command -v git >/dev/null 2>&1 || return 1
    git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
    mapfile -t cands < <(_proof_tool_trunk_candidates "$repo")
    for ref in "${cands[@]}"; do
        git -C "$repo" rev-parse --verify -q "${ref}^{commit}" >/dev/null 2>&1 || continue
        mline="$(git -C "$repo" log --first-parent --merges --format='%H %s' "$ref" 2>/dev/null \
            | grep -E "^[0-9a-f]+ Merge branch '([^']*/)?story-0*${key}(-[^']*)?'" | cut -d' ' -f1)"
        res="$(while read -r sha; do [ -n "$sha" ] && printf '%s %s %s\n' "$sha" "$(git -C "$repo" rev-parse "$sha^1")" "$ref"; done <<< "$mline"
            _proof_tool_merged_places "$repo" "$key" "$ref")"
        [ -n "$res" ] && { places="$res"; break; }
    done
    pat="^(feature|hotfix)/story-0*${key}(-|\$)"
    while read -r name sha; do
        pair=""
        if ! printf '%s' "${name#origin/}" | grep -ciE "$pat" >/dev/null; then
            # a hotfix named by a slug belongs to the story when its own commits carry the story's Refs trailer
            case "${name#origin/}" in hotfix/*) ;; *) continue ;; esac
            pair="$(proof_tool_change_base_ref "$repo" "$sha" 2>/dev/null)" || continue
            [ -n "$(git -C "$repo" log -1 -E --grep="$(_proof_tool_refs_grep "$key" "$repo")" --format=%H "${pair#* }..$sha" 2>/dev/null)" ] || continue
        fi
        [ -n "$pair" ] || pair="$(proof_tool_change_base_ref "$repo" "$sha" 2>/dev/null)" || continue
        tref="${pair%% *}"
        if ! git -C "$repo" merge-base --is-ancestor "$sha" "$tref" 2>/dev/null; then
            [ -n "$open" ] || open="$sha ${pair#* } $tref"
        elif fpref="$(_proof_tool_fp_trunk "$repo" "$sha" "$tref" "${cands[@]}")"; then
            # A fast-forward: the tip sits on a trunk's own line (on main for a hotfix fast-forwarded there and later
            # merged back into develop, whichever trunk the base was taken from). It leaves no merge commit to diff, so
            # its change is everything from the parent of its oldest own commit there up to its tip; a branch none of
            # whose commits names `#<N>` keeps the tip with no base ("-"), which the close refuses without a token.
            res="$(_proof_tool_ff_window "$repo" "$key" "$sha" "$fpref")"
            places="$places"$'\n'"${res:-$sha - $fpref}"
        else
            # the trunk reached the tip through a merge commit: that merge places the branch, also when its subject
            # does not name the story and some of the branch's commits carry no `Refs:` trailer
            places="$places"$'\n'"$(_proof_tool_via_merge "$repo" "$key" "$sha" "$tref" "${cands[@]}")"
        fi
    done < <(git -C "$repo" for-each-ref --sort=-committerdate --format='%(refname:short) %(objectname)' refs/heads refs/remotes/origin 2>/dev/null)
    places="$(printf '%s\n' "$places" | awk 'NF && !seen[$1 " " $2]++')"
    # next to those places, every own commit none of them holds is a place of its own (a story no merge or branch
    # places stays unplaced: the close then reads its change from the deliverables it cites)
    [ -n "$places" ] && held=" $(while read -r r b t; do
        case "$b" in "") ;; -|!*) printf '%s ' "$r" ;; *) git -C "$repo" rev-list "$b..$r" 2>/dev/null | tr '\n' ' ' ;; esac
    done <<< "$places")"
    while read -r c ref; do
        [ -n "$c" ] || continue
        case "$held" in *" $c "*) continue ;; esac
        b="$(git -C "$repo" rev-parse --verify -q "$c^" 2>/dev/null)" || b=-
        places="$places"$'\n'"$c $b $ref"
    done < <([ -n "$places" ] && _proof_tool_own_commits "$repo" "$key")
    places="$(printf '%s\n' "$places" | sed '/^$/d')"
    [ -n "$places" ] && { printf '%s\n' "$places"; return 0; }
    [ -n "$open" ] && { printf '%s\n' "$open"; return 0; }
    return 1
}

# proof_tool_story_latest_place REPO STORY -> "<result> <base or -> <trunk-ref>": the LATEST place story STORY landed
# on its trunk, the one every other place proof_tool_story_result finds is an ancestor of (the story's last merge, or
# its last run of trunk commits carrying `Refs: #<N>`). rc 1 when the story is not merged (no place on a trunk) or the
# places do not line up on one history (git cannot tell which is latest). The ONE answer to "which commit is the
# story's result now", shared by the coverage emitter (proof_tool_changed_files_for: a measured tree must contain it)
# and the close (proof_tool_close_finding: a stale record is explained against it), so the two never pick different
# merges of a story merged more than once. [RiskMitigation RA-01]
proof_tool_story_latest_place() {
    local repo="$1" res r b t line latest="" lr
    res="$(proof_tool_story_result "$repo" "$2")" || return 1
    while read -r r b t; do
        [ -n "$r" ] || continue
        case "$b" in -|!*) continue ;; esac
        git -C "$repo" merge-base --is-ancestor "$r" "$t" 2>/dev/null || return 1   # an unmerged branch head: no place
        if [ -z "$latest" ]; then latest="$r $b $t"; continue; fi
        lr="${latest%% *}"
        if git -C "$repo" merge-base --is-ancestor "$lr" "$r" 2>/dev/null; then latest="$r $b $t"
        elif ! git -C "$repo" merge-base --is-ancestor "$r" "$lr" 2>/dev/null; then return 1; fi
    done <<< "$res"
    [ -n "$latest" ] || return 1
    printf '%s\n' "$latest"
}

# _proof_tool_token_rel TOP ROOT F -> the repository-relative path of token entry F (see proof_tool_verify_at): F is
# resolved against ROOT unless absolute; a path outside TOP is read as relative to TOP.
_proof_tool_token_rel() {
    local top="$1" root="$2" f="$3" rel
    case "$f" in /*|[A-Za-z]:/*|[A-Za-z]:\\*) rel="$(_proof_tool_canon_path "$f")" ;; *) rel="$(_proof_tool_canon_path "$root/$f")" ;; esac
    case "$rel" in "$top"/*) rel="${rel#"$top"/}" ;; *) rel="$(_proof_tool_canon_path "$f")"; rel="${rel#/}" ;; esac
    printf '%s' "$rel"
}

# _proof_tool_blob_matches TOP REV PATH HASH -> rc 0 iff the file PATH at REV hashes to HASH (as stored, or with CRLF
# line ends, as a Windows checkout hashes it); rc 1 on a mismatch, rc 2 when git cannot read the file (a missing or
# corrupt object), so the caller refuses on doubt.
_proof_tool_blob_matches() {
    local top="$1" at="$2" rel="$3" h="$4" tmp rc=1
    tmp="$(mktemp 2>/dev/null)" || return 2
    if ! "${_PTG_GIT[@]}" -C "$top" cat-file blob "$at:$rel" > "$tmp" 2>/dev/null; then rm -f "$tmp"; return 2; fi
    if [ "$(sha256sum < "$tmp" | cut -d' ' -f1)" = "$h" ] \
        || [ "$(sed 's/\r*$/\r/' "$tmp" | sha256sum | cut -d' ' -f1)" = "$h" ]; then rc=0; fi
    rm -f "$tmp"
    return "$rc"
}

# proof_tool_verify_at_trunk_head DIM STORY REPO -> rc 0 iff STORY's DIM token holds at the head of a trunk: every
# file it records exists at that head and is what was measured there. A content record equals the file at the head
# byte for byte (or with CRLF line ends). A change record equals the change the trunk's own line last made to that
# file (the newest first-parent commit touching it, against its first parent): since nothing on that line changed the
# file after it, the head carries exactly the measured change. On failure PROOF_TOOL_VERIFY_REASON says why (the
# reason at the first trunk). Any git doubt (an unreadable object, a failing log or diff, a root commit) fails.
# [CySec] CWE-345 / CWE-367: the fallback for a story whose placed commits hold no judged C#: the token must describe
# what the trunk carries now, so no unplaced (or hidden) stale landing can close with it.
# [RiskMitigation RA-02] A merged story's coverage claim is judged on what actually landed on the trunk.
proof_tool_verify_at_trunk_head() {
    local dim="$1" story="$2" repo="$3" tokfile top root ref h line f hv rel c p1 rest want why="" n held cands=()
    PROOF_TOOL_VERIFY_REASON=""
    story="$(_proof_tool_story_key "$story")"
    tokfile="$(_proof_tool_token_file "$dim" "$story")"
    [ -f "$tokfile" ] || { PROOF_TOOL_VERIFY_REASON="no-token: no token for story $story"; return 1; }
    top="$(_proof_tool_canon_path "$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)")"
    root="$(sed -n 's/^root://p' "$tokfile" | head -1)"
    if [ -n "$root" ] && [ -d "$root" ]; then root="$(_proof_tool_canon_path "$root")"; else root="$(_proof_tool_root)"; fi
    mapfile -t cands < <(_proof_tool_trunk_candidates "$repo")
    for ref in "${cands[@]}"; do
        h="$(git -C "$repo" rev-parse --verify -q "${ref}^{commit}" 2>/dev/null)" || continue
        n=0; held=1
        while IFS= read -r line; do
            case "$line" in ''|hmac:*|root:*|attachment:*) continue ;; esac
            f="${line%:*}"; hv="${line##*:}"; n=$((n + 1))
            rel="$(_proof_tool_token_rel "$top" "$root" "$f")"
            if ! git -C "$top" cat-file -e "$h:$rel" 2>/dev/null; then
                held=0; why="${f} does not exist at the head of ${ref}"; break
            fi
            case "$hv" in
                "$_PTG_CHANGE_PREFIX"*)
                    if ! rest="$("${_PTG_GIT[@]}" -C "$top" log --first-parent -1 --format='%H %P' "$h" -- "$rel" 2>/dev/null)"; then
                        held=0; why="git cannot read the history of ${f} on ${ref}"; break
                    fi
                    read -r c p1 _ <<< "$rest"
                    if [ -z "${p1:-}" ]; then held=0; why="the change to ${f} on ${ref} cannot be isolated (no parent commit)"; break; fi
                    want="$_PTG_CHANGE_PREFIX$(_proof_tool_patch_id "$top" "$p1" "$c" "$rel")"
                    if [ "$want" != "$hv" ]; then
                        held=0; why="the last change ${ref} made to ${f} (at ${c:0:8}) differs from the one measured"; break
                    fi ;;
                *)
                    _proof_tool_blob_matches "$top" "$h" "$rel" "$hv"
                    case $? in
                        0) ;;
                        1) held=0; why="${f} at the head of ${ref} differs from the file measured"; break ;;
                        *) held=0; why="git cannot read ${f} at the head of ${ref}"; break ;;
                    esac ;;
            esac
        done < "$tokfile"
        if [ "$n" -le 0 ]; then
            if _proof_tool_receipt_only "$(cat "$tokfile" 2>/dev/null)"; then PROOF_TOOL_VERIFY_REASON="$(_proof_tool_receipt_only_reason "$story")"
            else PROOF_TOOL_VERIFY_REASON="no-token: the token for story $story records no file"; fi
            return 1
        fi
        [ "$held" = 1 ] && return 0
        [ -n "$PROOF_TOOL_VERIFY_REASON" ] || PROOF_TOOL_VERIFY_REASON="stale: $why"
    done
    [ -n "$PROOF_TOOL_VERIFY_REASON" ] || PROOF_TOOL_VERIFY_REASON="stale: no trunk found"
    return 1
}

# _proof_tool_token_has_content TOKFILE -> rc 0 when the token holds at least one content record (not a change record).
_proof_tool_token_has_content() {
    local line
    while IFS= read -r line; do
        case "$line" in ''|hmac:*|root:*|attachment:*) continue ;; esac
        case "${line##*:}" in "$_PTG_CHANGE_PREFIX"*) ;; *) return 0 ;; esac
    done < "$1"
    return 1
}

# proof_tool_story_merged_window REPO STORY -> print the files of STORY's own change as it landed on a trunk (the diff
# of its latest named merge commit against that commit's first parent, or of each merge and each run its own trunk
# commits landed by, as proof_tool_story_result finds them), one per line, sorted; rc 1 when the story is not merged with a merge
# commit or trunk commits (an unmerged branch, a fast-forward merge, or no story found). The ONE definition of a merged
# story's change window: the close judges a token against it, and the coverage emitter (the CLI's
# `changed-files --story`) records exactly these files, so a re-measure after the merge can satisfy the close. An
# unmerged branch keeps the working-tree-and-branch window (proof_tool_changed_files) for both.
proof_tool_story_merged_window() {
    local repo="$1" res r b t w files="" n=0
    res="$(proof_tool_story_result "$repo" "$2")" || return 1
    while read -r r b t; do
        [ -n "$r" ] || continue
        case "$b" in -|!*) return 1 ;; esac
        # merged: the result commit is on the trunk; an unmerged branch head is not
        git -C "$repo" merge-base --is-ancestor "$r" "$t" 2>/dev/null || return 1
        w="$(_proof_tool_window_files "$repo" "$b" "$r")" || return 1
        files="$files$w"$'\n'; n=$((n + 1))
    done <<< "$res"
    [ "$n" -gt 0 ] || return 1
    printf '%s' "$files" | sed '/^$/d' | sort -u
}

# proof_tool_story_own_files REPO STORY -> the files of STORY's OWN commits on a trunk (_proof_tool_own_mark: each
# has a footer citing the story, no merge, not a merge named for another story), one per line, sorted: the
# window of a story no merge places with its C# (its commits came in through merges that also carry other work, or
# under merge subjects that do not name it). Prints nothing (rc 0) when no trunk holds an own commit. Says on stderr
# that this window was used and names every file a later commit that is not the story's own also changed (that file
# is judged as measured, like every other). rc 1 (reason on stderr) when the measured tree (HEAD) does not contain
# every own commit, or git cannot compute a commit's change: a token must never be minted on a tree without the
# story's code.
# [CySec] Mitigates CWE-345 "Insufficient Verification of Data Authenticity": only commits whose footer cites this story
# place it, so another story's commit that merely mentions it in a remark never stands in for its change.
# [RiskMitigation RA-03]
proof_tool_story_own_files() {
    local repo="$1" key ref own c p head files="" w oldest shared n=0 f
    key="$(_proof_tool_story_key "$2")"; [ -n "$key" ] || return 0
    head="$(git -C "$repo" rev-parse --verify -q 'HEAD^{commit}' 2>/dev/null)" || return 0
    own="$(_proof_tool_own_commits "$repo" "$key")"; [ -n "$own" ] || return 0
    ref="$(printf '%s\n' "$own" | head -1 | cut -d' ' -f2)"; own="$(printf '%s\n' "$own" | cut -d' ' -f1)"
    while read -r c; do
        [ -n "$c" ] || continue
        if ! git -C "$repo" merge-base --is-ancestor "$c" "$head" 2>/dev/null; then
            printf 'story %s: the measured tree (HEAD %s) does not contain its own commit %s on %s, whose files belong to the story'"'"'s change; measure coverage on a tree that contains it (the trunk head).\n' \
                "$key" "${head:0:8}" "${c:0:8}" "$ref" >&2
            return 1
        fi
        p="$(git -C "$repo" rev-parse --verify -q "$c^" 2>/dev/null)" || p="$(git -C "$repo" hash-object -t tree /dev/null)"
        w="$(_proof_tool_window_files "$repo" "$p" "$c")" || { printf 'story %s: git cannot compute the change of %s\n' "$key" "${c:0:8}" >&2; return 1; }
        files="$files$w"$'\n'; n=$((n + 1)); oldest="$c"
    done <<< "$own"
    files="$(printf '%s' "$files" | sed '/^$/d' | sort -u)"
    printf 'story %s: the window holds the files of its %s own commits on %s (each citing Refs: #%s)\n' "$key" "$n" "$ref" "$key" >&2
    # a file a later commit that is not the story's own also changed is named (it stays in the window)
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        shared="$(git -C "$repo" log --no-merges --format=%H "$oldest..$ref" -- "$f" 2>/dev/null | grep -vxF -f <(printf '%s\n' "$own") | head -1)"
        [ -z "$shared" ] || printf 'story %s: %s is also changed by %s, a commit that is not the story'"'"'s own; it is judged as measured\n' "$key" "$f" "${shared:0:8}" >&2
    done <<< "$files"
    printf '%s\n' "$files"
    return 0
}

# _proof_tool_own_commits REPO KEY -> "<commit> <trunk-ref>" per OWN commit of story KEY (no merge, a footer line citing
# the story, alone or in a list: _proof_tool_own_mark), newest first, on the first trunk candidate holding any. The ONE
# list both windows take the story's own commits from: the token's (proof_tool_story_own_files) and the close's
# (proof_tool_story_result).
_proof_tool_own_commits() {
    local repo="$1" key="$2" ref own cands=() proj
    proj="$(_proof_tool_footer_own "$repo")"
    mapfile -t cands < <(_proof_tool_trunk_candidates "$repo")
    for ref in "${cands[@]}"; do
        git -C "$repo" rev-parse --verify -q "${ref}^{commit}" >/dev/null 2>&1 || continue
        own="$(git -C "$repo" log --no-merges -E --grep="$(_proof_tool_refs_grep "$key" "$repo")" --format='%x01%H %P%n%s%n%B' "$ref" 2>/dev/null \
            | _proof_tool_own_mark "$key" "$proj" | awk -v r="$ref" '$1 == 1 { print $2, r }')"
        [ -n "$own" ] && { printf '%s\n' "$own"; return 0; }
    done
    return 0
}

# _proof_tool_window_files REPO BASE RESULT -> the files BASE..RESULT changes, one per line, sorted (no rename pairing,
# so a moved file shows as both paths), each name as it is on disk (_proof_tool_raw_names), so a C# file with a
# non-ASCII name is still seen as C# and matches the name its token records. Shared by the close and the merged-window
# emit. rc 1 when git cannot compute the diff (a missing or corrupt object): the caller then refuses, never reads it as
# empty.
# [CySec] Mitigates CWE-176 "Improper Handling of Unicode Encoding": git's quoted form of a non-ASCII name would hide a
# changed C# file from the close's judgement. [RiskMitigation RA-03]
_proof_tool_window_files() {
    local out
    out="$("${_PTG_GIT[@]}" -C "$1" diff -z --name-only --no-renames "$2" "$3" 2>/dev/null | _proof_tool_raw_names; exit "${PIPESTATUS[0]}")" || return 1
    printf '%s\n' "$out" | sed '/^$/d' | sort -u
}

# proof_tool_story_branch_ahead REPO STORY -> "<HEAD> <merge-base> <trunk-ref>" when the checkout of REPO is STORY's
# own work that its trunk does not hold yet: HEAD has commits the trunk lacks (it is not contained in the trunk), the
# branch is STORY's (named .../story-<N>-..., or, when it names no story, one of its commits beyond the trunk carries
# `Refs: #<N>`), and the branch's change window (proof_tool_changed_files: the working tree plus the branch since its
# fork point) holds C#. rc 1 otherwise: HEAD on (or contained in) the trunk, no trunk ref to compare with
# (undecidable), another story's branch, or a branch that changes no C#.
# The ONE decision of which window a story is judged on, shared by the coverage emitter (proof_tool_changed_files_for)
# and the close (proof_tool_close_finding), so the two cannot disagree: a follow-up branch of an already merged story
# is measured and judged over its own change, exactly as an unmerged branch is; the merged change is used only when
# the checkout sits on what the trunk already holds (re-measuring the merged result).
# [CySec] CWE-345: a branch that changes no C# never stands in for the story's merged result (a docs-only decoy branch
# named for the story cannot hide a stale merged change); the merged result is then judged as before.
proof_tool_story_branch_ahead() {
    local repo="$1" key head pair mb br named
    key="$(_proof_tool_story_key "$2")"; [ -n "$key" ] || return 1
    command -v git >/dev/null 2>&1 || return 1
    head="$(git -C "$repo" rev-parse --verify -q 'HEAD^{commit}' 2>/dev/null)" || return 1
    pair="$(proof_tool_change_base_ref "$repo" "$head" 2>/dev/null)" || return 1
    mb="${pair#* }"
    [ -n "$mb" ] && [ "$mb" != "$head" ] || return 1
    br="$(git -C "$repo" symbolic-ref -q --short HEAD 2>/dev/null || true)"
    named="$(story_num_from_branch "$br" | sed -E 's/^0*([0-9])/\1/')"
    if [ -n "$named" ]; then
        [ "$named" = "$key" ] || return 1
    else
        [ -n "$(git -C "$repo" log -1 -E --grep="$(_proof_tool_refs_grep "$key" "$repo")" --format=%H "$mb..$head" 2>/dev/null)" ] || return 1
    fi
    proof_tool_changed_files "$repo" | _proof_tool_cs_names | grep -c . >/dev/null || return 1
    printf '%s %s %s\n' "$head" "$mb" "${pair%% *}"
}

# _proof_tool_holds_latest_place REPO STORY -> rc 0 when the checkout (HEAD) contains STORY's latest place
# (proof_tool_story_latest_place), or no latest place is known; rc 1, naming that merge on stderr, when it does not.
_proof_tool_holds_latest_place() {
    local latest head
    latest="$(proof_tool_story_latest_place "$1" "$2")" || return 0
    head="$(git -C "$1" rev-parse --verify -q 'HEAD^{commit}' 2>/dev/null)"
    if [ -z "$head" ] || ! git -C "$1" merge-base --is-ancestor "${latest%% *}" "$head" 2>/dev/null; then
        printf 'story %s was last merged at %s, which the measured tree (HEAD %s) does not contain; the close judges the story there, so measure coverage on a tree that contains that merge (the trunk head, or a work tree on that commit).\n' \
            "$(_proof_tool_story_key "$2")" "$(git -C "$1" rev-parse --short "${latest%% *}" 2>/dev/null)" "${head:0:8}" >&2
        return 1
    fi
}

# _PTG_MR_FILES: the list file the bridge passes with --mr-files (changed-files, verify): the files of the story's own
# merge requests as GitLab lists them, one repository-relative path per line (empty: the story has none yet).
_PTG_MR_FILES="${_PTG_MR_FILES:-}"

# _proof_tool_mr_files -> the paths of the --mr-files list, sorted, without blank lines or carriage returns; rc 1 (reason
# on stderr) when the list cannot be read.
# [CySec] Prevents CWE-636 "Not Failing Securely": an unreadable list refuses, it never reads as "no merge request".
_proof_tool_mr_files() {
    [ -f "$_PTG_MR_FILES" ] && [ -r "$_PTG_MR_FILES" ] \
        || { echo "the list of the story's merge-request files ($_PTG_MR_FILES) cannot be read" >&2; return 1; }
    tr -d '\r' < "$_PTG_MR_FILES" | sed '/^$/d' | sort -u
}

# proof_tool_changed_files_for PROJECT_DIR [STORY] -> the change window a coverage token records: for a story not ahead
# on its own branch whose merge requests the bridge passed (--mr-files, _proof_tool_mr_files), their files; else the ordinary window
# (proof_tool_changed_files) when the checkout is STORY's own branch ahead of its trunk (proof_tool_story_branch_ahead),
# else STORY's merged change (proof_tool_story_merged_window) when STORY is given and merged with a merge commit, else
# the ordinary window. Non-zero only when the ordinary window cannot be known.
#
# A merged story is measured on a tree that CONTAINS its latest place (proof_tool_story_latest_place): the close judges
# every place, and a file the story changed again in a later merge is judged there, so a run on a tree from before that
# merge (a checkout or work tree still at the first merge) records what the close can never accept. Such a run is
# refused here, naming the latest merge, instead of minting a token that is stale at birth. A tree that holds the
# latest place (the trunk head after it, or a work tree on that merge) is measured as before.
# [RiskMitigation RA-01] the token and the close judge a story's result at the same, latest merge.
proof_tool_changed_files_for() {
    local proj="$1" story="${2:-}" repo window own checked="" mr
    if [ -n "$(_proof_tool_story_key "$story")" ] && repo="$(git -C "$proj" rev-parse --show-toplevel 2>/dev/null)" \
        && ! proof_tool_story_branch_ahead "$repo" "$story" >/dev/null; then
        # The bridge read the story's own merge requests from GitLab (--mr-files): their change is the story's change,
        # the very set the close reads, whatever trailer each of their commits carries. No merge request yet keeps the
        # git window below; an unreadable list refuses (never a smaller set).
        if [ -n "${_PTG_MR_FILES:-}" ]; then
            mr="$(_proof_tool_mr_files)" || return 1
            if [ -n "$mr" ]; then
                _proof_tool_holds_latest_place "$repo" "$story" || return 1
                printf '%s\n' "$mr"
                return 0
            fi
        fi
        window="$(proof_tool_story_merged_window "$repo" "$story" 2>/dev/null)" || window=""
        # No merge window holds the story's C# (its C# arrived only through merges that also carry other work, or
        # under merge subjects that do not name it): the story's own commits on a trunk place it instead.
        if ! printf '%s\n' "$window" | _proof_tool_cs_names | grep -c . >/dev/null; then
            own="$(proof_tool_story_own_files "$repo" "$story")" || return 1
            if printf '%s\n' "$own" | _proof_tool_cs_names | grep -c . >/dev/null; then
                printf '%s\n%s\n' "$window" "$own" | sed '/^$/d' | sort -u
                return 0
            fi
        else
            # Some of the story's own commits may have reached the trunk outside a merge of its own (through a merge
            # shared with other work, or directly): their files belong to the story's change as well, so the window is
            # the union. A tree without one of them is refused with the reason, never measured on the merges alone.
            local errf
            # the tree must hold the story's latest merge first: that refusal names the merge the close judges
            _proof_tool_holds_latest_place "$repo" "$story" || return 1
            checked=1
            errf="$(mktemp 2>/dev/null)" || { echo "story $(_proof_tool_story_key "$story"): no temporary file for the window check" >&2; return 1; }
            if ! own="$(proof_tool_story_own_files "$repo" "$story" 2>"$errf")"; then
                cat "$errf" >&2; rm -f "$errf"; return 1
            fi
            # the notes (which own commits, and which of their files later work also changed) go with the answer when
            # an own commit is a place of its own (no merge or branch of the story holds it)
            if proof_tool_story_result "$repo" "$story" 2>/dev/null | grep -cF -f <(_proof_tool_own_commits "$repo" "$(_proof_tool_story_key "$story")" | awk '{ print $1 " " }') >/dev/null; then
                cat "$errf" >&2
            fi
            rm -f "$errf"
            window="$(printf '%s\n%s\n' "$window" "$own" | sed '/^$/d' | sort -u)"
        fi
        [ -n "$window" ] || { proof_tool_changed_files "$proj"; return; }
        [ -n "$checked" ] || _proof_tool_holds_latest_place "$repo" "$story" || return 1
        printf '%s\n' "$window"
        return 0
    fi
    proof_tool_changed_files "$proj"
}

# proof_tool_story_changed_lines PROJECT_DIR STORY FILE... -> for each FILE (repository-relative), one line
# "<FILE><TAB><ranges>": the story lines of FILE (the lines the story's own commits added or changed, judged by the bridge's
# one story-line producer from its trunk answer), written "3,7-9" ("-" when none). A thin call to the bridge's story_lines
# verb: this tool reads no history of its own. rc 1 (reason on stderr) when the story is not named, the bridge refuses
# (its reason code first), or the bridge cannot be reached: "bridge unreachable: changed lines unknown"
# (BRIDGE-UNREACHABLE), never an empty answer.
# [CySec] Mitigates CWE-345 "Insufficient Verification of Data Authenticity" and CWE-636 "Not Failing Securely": the lines
# a receipt judges come from the bridge's own reading of the repository, and an unreachable bridge refuses.
# [RiskMitigation RA-03]
proof_tool_story_changed_lines() {
    local proj="$1" story="${2:-}" key args reply rc text wait
    shift 2 2>/dev/null || true
    key="$(_proof_tool_story_key "$story")"
    [ -n "$key" ] || { echo "changed-lines: name the story (--story <N>)" >&2; return 1; }
    if ! command -v bridge_mcp_call >/dev/null 2>&1; then
        # shellcheck source=/dev/null
        [ -f "$_PTG_LIB_DIR/bridge-mcp.sh" ] && . "$_PTG_LIB_DIR/bridge-mcp.sh"
    fi
    command -v bridge_mcp_call >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 \
        || { echo "changed-lines: BRIDGE-UNREACHABLE: bridge unreachable: changed lines unknown (the bridge client is missing)" >&2; return 1; }
    args="$(jq -cn --arg s "$key" --arg t "$proj" '{story:$s, tree:$t, files:$ARGS.positional}' --args "$@")" || return 1
    wait="${KYKLOS_PROOF_VERIFY_TIMEOUT_SECONDS:-600}"
    case "$wait" in ''|*[!0-9]*|?????*) wait=600 ;; esac
    reply="$(bridge_mcp_call story_lines "$args" "$wait")"; rc=$?
    text="$(bridge_mcp_text "$reply" 2>/dev/null | tr -d '\r')"
    if [ "$rc" -ne 0 ] || bridge_mcp_is_error "$reply" || [ -z "$text" ]; then
        echo "changed-lines: BRIDGE-UNREACHABLE: bridge unreachable: changed lines unknown (bridge client rc $rc)" >&2; return 1
    fi
    case "$text" in
        "unknown tool: story_lines"*) echo "changed-lines: BRIDGE-UNREACHABLE: bridge unreachable: changed lines unknown (the bridge has no story_lines verb: update the bridge)" >&2; return 1 ;;
        "lines:"*) printf '%s\n' "$text" | sed '1d' | sed '/^$/d'; return 0 ;;
    esac
    echo "changed-lines: $(printf '%s' "$text" | head -1)" >&2
    return 1
}

# proof_tool_story_change_base PROJECT_DIR STORY -> the commit STORY's change starts from on its trunk: its fork point
# while the checkout is its own branch ahead of the trunk (proof_tool_story_branch_ahead), else the base of the EARLIEST
# place git finds for it (proof_tool_story_result: a merge's first parent, the parent of a run of its own commits, or an
# unmerged branch's fork point). The same window the token and the changed lines read, so the trunk base a coverage
# receipt compares a touched file against is the one the story's change was measured from. rc 1 (reason on stderr) when
# the story is not named, the folder is not a git work tree, or git places the story nowhere with a base (a fast
# forward with no own commit): the caller then refuses, never guesses a base.
# [RiskMitigation RA-03] the no-drop rule compares against the story's own starting point, never an assumed one.
# With RANGES=1 (`change-base --ranges`) it prints, after that base, one more line per place: "<base> <result>", the
# place's own range (its merge against the first parent, or a run of its own trunk commits), earliest first; a branch
# ahead of its trunk prints "<fork point> -" (the working tree). A reader that judges what the story changed (the rename
# pairing of the coverage receipt) then reads only those ranges, never the trunk between them, which holds other
# stories' changes. When one place has no range git can isolate, no place is listed (the reader keeps the whole range).
proof_tool_story_change_base() {
    local proj="$1" story="${2:-}" ranges="${3:-}" repo key ahead res r b t best="" bestn="" n places="" unisolated=""
    key="$(_proof_tool_story_key "$story")"
    [ -n "$key" ] || { echo "change-base: name the story (--story <N>)" >&2; return 1; }
    repo="$(git -C "$proj" rev-parse --show-toplevel 2>/dev/null)" || { echo "change-base: '$proj' is not a git work tree" >&2; return 1; }
    if ahead="$(proof_tool_story_branch_ahead "$repo" "$key")"; then
        read -r _ b _ <<< "$ahead"; printf '%s\n' "$b"; [ "$ranges" != 1 ] || printf '%s -\n' "$b"; return 0
    fi
    res="$(proof_tool_story_result "$repo" "$key")" || { echo "change-base: git places story $key nowhere in $repo (no branch, merge or own commit of it)" >&2; return 1; }
    local early="" earlyn="" c cn
    while read -r r b t; do
        [ -n "$r" ] || continue
        case "$b" in -|!*)
            unisolated="${r:0:8}"
            # the earliest commit such a place may have changed starts at its own parent (the bare commit's, for "!"),
            # so a whole range printed for it never starts after that change
            c="$b"; [ "$c" = "-" ] && c="$r"; c="${c#!}"
            if cn="$(git -C "$repo" rev-list --count "$c^" 2>/dev/null)" && { [ -z "$earlyn" ] || [ "$cn" -lt "$earlyn" ]; }; then
                early="$(git -C "$repo" rev-parse --verify -q "$c^" 2>/dev/null)" && earlyn="$cn"
            fi
            continue ;;
        esac
        n="$(git -C "$repo" rev-list --count "$b" 2>/dev/null)" || { unisolated="${r:0:8}"; continue; }
        places="$places$n $b $r"$'\n'
        if [ -z "$bestn" ] || [ "$n" -lt "$bestn" ]; then best="$b"; bestn="$n"; fi
    done <<< "$res"
    [ -n "$best" ] || { echo "change-base: story $key landed without a base git can isolate (a fast forward with no own commit carrying Refs: #$key)" >&2; return 1; }
    # [CySec] Prevents CWE-636 "Not Failing Securely": with --ranges, an unisolated place earlier than every isolated one
    # moves the printed base before it, so the whole range a reader falls back to holds that place's change too.
    if [ "$ranges" = 1 ] && [ -n "$early" ] && [ "$earlyn" -lt "$bestn" ]; then best="$early"; fi
    printf '%s\n' "$best"
    [ "$ranges" = 1 ] || return 0
    # A place git cannot isolate (a fast forward with no own commit, or a commit next to the story's own that names no
    # story) has no range of its own: no place is listed then, so a reader falls back to the whole range from the base,
    # never to the other places alone.
    if [ -n "$unisolated" ]; then
        echo "change-base: story $key has a place git cannot isolate (at $unisolated), so its places are not listed" >&2
        return 0
    fi
    printf '%s' "$places" | sed '/^$/d' | sort -n -s -k1,1 | awk '!seen[$2 " " $3]++ { print $2 " " $3 }'
}

# _proof_tool_measured_at_other TOP REL HASH RESULT -> when the content record HASH of REL equals the file at another
# of the story's places (_PTG_VERIFY_PLACES, set by the close), the plain-words reason: the record was measured on a
# tree from that earlier merge, not at RESULT. Empty otherwise. Explains, never decides. [RiskMitigation RA-01]
_proof_tool_measured_at_other() {
    local top="$1" rel="$2" h="$3" res="$4" r b t
    [ -n "${_PTG_VERIFY_PLACES:-}" ] || return 0
    while read -r r b t; do
        [ -n "$r" ] && [ "$r" != "$res" ] || continue
        if _proof_tool_blob_matches "$top" "$r" "$rel" "$h"; then
            printf '; the record is the file as at %s, an earlier place of the story: it was measured on a tree from before the latest merge %s, or kept from an earlier run that the latest run did not replace (a run must cover this file on a tree that contains %s)' "${r:0:8}" "${res:0:8}" "${res:0:8}"
            return 0
        fi
    done <<< "$_PTG_VERIFY_PLACES"
}

# proof_tool_verify_at DIM STORY REPO RESULT BASE TRUNK -> rc 0 iff DIM's token for STORY holds at the story's own
# result (see above). On failure PROOF_TOOL_VERIFY_REASON says why ("no-token: ..." or "stale: ..."). The token's
# paths resolve against its root: line when that folder exists here, else against the token root (_proof_tool_root);
# a path outside REPO is read as relative to REPO's top (the bridge's solution root is the repository).
proof_tool_verify_at() {
    local dim="$1" story="$2" repo="$3" res="$4" base="$5" trunk="$6" tokfile top root line f h rel blob want later=0
    PROOF_TOOL_VERIFY_REASON=""
    story="$(_proof_tool_story_key "$story")"
    tokfile="$(_proof_tool_token_file "$dim" "$story")"
    [ -f "$tokfile" ] || { PROOF_TOOL_VERIFY_REASON="no-token: no token for story $story"; return 1; }
    top="$(_proof_tool_canon_path "$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)")"
    root="$(sed -n 's/^root://p' "$tokfile" | head -1)"
    if [ -n "$root" ] && [ -d "$root" ]; then root="$(_proof_tool_canon_path "$root")"; else root="$(_proof_tool_root)"; fi
    local n=0
    while IFS= read -r line; do
        case "$line" in ''|hmac:*|root:*|attachment:*) continue ;; esac
        f="${line%:*}"; h="${line##*:}"; n=$((n + 1))
        rel="$(_proof_tool_token_rel "$top" "$root" "$f")"
        # A story with several results: a record outside the story's whole change proves nothing of it (refused), and a
        # record of another result's file is judged at that result, not here.
        if [ -n "${_PTG_VERIFY_UNION:-}" ]; then
            printf '%s\n' "$_PTG_VERIFY_UNION" | grep -cxF -- "$rel" >/dev/null \
                || { PROOF_TOOL_VERIFY_REASON="stale: ${f} is not part of the story's change (none of its merges changes it)"; return 1; }
            printf '%s\n' "${_PTG_VERIFY_ONLY:-}" | grep -cxF -- "$rel" >/dev/null || { n=$((n - 1)); continue; }
            # a later place of the story changed this file again: it is judged there, at the story's latest version
            if printf '%s\n' "${_PTG_VERIFY_LATER:-}" | grep -cxF -- "$rel" >/dev/null; then n=$((n - 1)); later=$((later + 1)); continue; fi
        fi
        if ! git -C "$top" cat-file -e "$res:$rel" 2>/dev/null; then
            PROOF_TOOL_VERIFY_REASON="stale: ${f} does not exist at the story's result ${res:0:8}"; return 1
        fi
        case "$h" in
            "$_PTG_CHANGE_PREFIX"*)
                [ "$base" != "-" ] || { PROOF_TOOL_VERIFY_REASON="stale: the story was merged without a merge commit, so its own change to ${f} cannot be isolated; measure coverage on the merged result"; return 1; }
                want="$_PTG_CHANGE_PREFIX$(_proof_tool_patch_id "$top" "$base" "$res" "$rel")"
                [ "$want" = "$h" ] || { PROOF_TOOL_VERIFY_REASON="stale: the story's own change to ${f} at ${res:0:8} differs from the one measured"; return 1; } ;;
            *)
                local ok=0 at
                for at in "$res" "$trunk"; do
                    [ -n "$at" ] || continue
                    blob="$("${_PTG_GIT[@]}" -C "$top" cat-file blob "$at:$rel" 2>/dev/null | sha256sum | cut -d' ' -f1)"
                    [ "$blob" = "$h" ] && { ok=1; break; }
                    # a Windows checkout hashes the file with CRLF line ends while git stores LF
                    blob="$("${_PTG_GIT[@]}" -C "$top" cat-file blob "$at:$rel" 2>/dev/null | sed 's/\r*$/\r/' | sha256sum | cut -d' ' -f1)"
                    [ "$blob" = "$h" ] && { ok=1; break; }
                done
                [ "$ok" = 1 ] || { PROOF_TOOL_VERIFY_REASON="stale: ${f} at the story's result ${res:0:8} (and at the head of ${trunk}) differs from the file measured$(_proof_tool_measured_at_other "$top" "$rel" "$h" "$res")"; return 1; } ;;
        esac
    done < "$tokfile"
    # every record of this place's files is judged at a later place of the story: nothing is left to judge here
    if [ "$n" -le 0 ] && [ "$later" -gt 0 ]; then return 0; fi
    if [ "$n" -le 0 ]; then
        if _proof_tool_receipt_only "$(cat "$tokfile" 2>/dev/null)"; then PROOF_TOOL_VERIFY_REASON="$(_proof_tool_receipt_only_reason "$story")"
        elif [ -n "${_PTG_VERIFY_UNION:-}" ]; then PROOF_TOOL_VERIFY_REASON="no-token: the token for story $story records no file this result changes (it was measured over another of the story's merges)"
        else PROOF_TOOL_VERIFY_REASON="no-token: the token for story $story records no file"; fi
        return 1
    fi
    return 0
}

# _proof_tool_late_change REPO KEY TOKFILE HELD -> print "<commit> <file>" for the first commit, on a trunk's own line
# after a place of story KEY that held (HELD: "<result> <trunk-ref>" lines), that changes a file TOKFILE records and is
# not one of the story's own places. Only two kinds of commit are let through, each a place judged as such: the story's
# own commit (a footer line cites this story, _proof_tool_own_mark) and a real two-parent merge named
# for this story. Any other commit that edits a measured file refuses, whatever its message says and whoever's merge it
# is (another story's merge included: neither its subject nor its token proves what its second parent or an amended
# merge did to the file); the story is then measured again on the trunk head. rc 1 when there is none. When git cannot
# read that history it prints "<result> -" (doubt), which the caller refuses.
# [CySec] CWE-345 / CWE-367: a held place does not vouch for what a later commit did to the measured file, and a
# commit message is not evidence of who measured it.
_proof_tool_late_change() {
    local repo="$1" key="$2" tokfile="$3" held="$4" top root line rel r t c cc own subj log p2 p3 proj rels=()
    proj="$(_proof_tool_footer_own "$repo")"
    top="$(_proof_tool_canon_path "$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)")"
    root="$(sed -n 's/^root://p' "$tokfile" | head -1)"
    if [ -n "$root" ] && [ -d "$root" ]; then root="$(_proof_tool_canon_path "$root")"; else root="$(_proof_tool_root)"; fi
    while IFS= read -r line; do
        case "$line" in ''|hmac:*|root:*|attachment:*) continue ;; esac
        rel="$(_proof_tool_token_rel "$top" "$root" "${line%:*}")"
        [ -n "$rel" ] && rels+=("$rel")
    done < "$tokfile"
    [ "${#rels[@]}" -gt 0 ] || return 1
    while read -r r t; do
        [ -n "$r" ] || continue
        if ! log="$("${_PTG_GIT[@]}" -C "$top" log --first-parent --format='%x01%H %P%n%s%n%B' "$r..$t" -- "${rels[@]}" 2>/dev/null)"; then
            printf '%s -\n' "$r"; return 0
        fi
        # the story's own commits (a footer cites it) and its real merges were judged as places;
        # every other commit that edits a measured file is a late change
        c=""
        while read -r own cc _ p2 p3; do
            [ "$own" = 1 ] && continue
            IFS= read -r subj < <(git -C "$top" log -1 --format=%s "$cc" 2>/dev/null)
            if [ -n "${p2:-}" ] && [ -z "${p3:-}" ] && git -C "$top" cat-file -e "$p2^{commit}" 2>/dev/null \
                && printf '%s' "${subj:-}" | grep -cE "^Merge branch '([^']*/)?story-0*${key}(-[^']*)?'" >/dev/null; then
                continue
            fi
            c="$cc"; break
        done < <(printf '%s\n' "$log" | _proof_tool_own_mark "$key" "$proj")
        [ -n "$c" ] || continue
        printf '%s %s\n' "$c" "$("${_PTG_GIT[@]}" -C "$top" diff --name-only "$c^1" "$c" -- "${rels[@]}" 2>/dev/null | head -1)"
        return 0
    done <<< "$held"
    return 1
}

# _proof_tool_bare_refusal COMMIT KEY REF RESULT HOW -> print the refusal for a commit without any Refs trailer that
# changes C# right next to story KEY's own commits (_proof_tool_bare_cs_below).
_proof_tool_bare_refusal() {
    printf 'Test Discipline is PROVEN, but commit %s, which carries no Refs trailer, changes C# right next to the commits of story %s on %s (up to %s), so git cannot tell whether it is part of the story'"'"'s change. Give it the story'"'"'s Refs: #%s trailer (or the trailer of the story it belongs to), or merge the story with a merge commit, or measure coverage on the trunk head over that commit'"'"'s C# too, and close again. %s\n' "${1:0:8}" "$2" "$3" "${4:0:8}" "$2" "$5"
}

# _proof_tool_cited_finding REPO KEY CITED HOW -> print a refusal and rc 0 when a deliverable in CITED (branch names or
# commit ids, separated by spaces or commas; merge requests written !N are skipped, git cannot read them) changes C#,
# or when CITED names a branch or commit and none of them can be found in REPO; else rc 1. A cited commit on a trunk is
# read against its first parent, a cited branch against its fork point from the trunk.
_proof_tool_cited_finding() {
    local repo="$1" key="$2" how="$4" item sha pair base asked=0 found=0
    for item in $(printf '%s' "$3" | tr ',' ' '); do
        case "$item" in !*|'') continue ;; esac
        asked=1
        sha="$(git -C "$repo" rev-parse --verify -q "${item}^{commit}" 2>/dev/null)" \
            || sha="$(git -C "$repo" rev-parse --verify -q "origin/${item}^{commit}" 2>/dev/null)" || continue
        found=1
        pair="$(proof_tool_change_base_ref "$repo" "$sha" 2>/dev/null)" || pair=""
        if [ -n "$pair" ] && ! git -C "$repo" merge-base --is-ancestor "$sha" "${pair%% *}" 2>/dev/null; then base="${pair#* }"
        else base="$(git -C "$repo" rev-parse --verify -q "${sha}^" 2>/dev/null)" || continue; fi
        if _proof_tool_window_files "$repo" "$base" "$sha" 2>/dev/null | _proof_tool_cs_names | grep -c . >/dev/null; then
            printf 'Test Discipline is PROVEN, but git places no commit of story %s here, the cited %s changes C#, and the story has no coverage token. %s\n' "$key" "$item" "$how"
            return 0
        fi
    done
    if [ "$asked" = 1 ] && [ "$found" = 0 ]; then
        printf 'Test Discipline is PROVEN, but git places no commit of story %s here and none of the cited deliverables (%s) can be found in %s, so whether the story changed C# is unknown, and it has no coverage token. Fetch them (git fetch origin), or cite the commit ids that landed (a squash merge whose message carries no Refs: #%s is otherwise invisible), and close again. %s\n' "$key" "$3" "$repo" "$key" "$how"
        return 0
    fi
    return 1
}

# _proof_tool_mr_window REPO TRUNK CITED KEY TIP -> the files the commits of the merge requests CITED names (!N) changed, each
# commit against its parent, read through the bridge (mr_commits, the project of REPO's origin): the own change of a
# story merged by fast forward whose commits carry no Refs: #<N>. rc 1 when CITED names no merge request; rc 2, the
# reason on stdout, when a list cannot be read, is cut short, or names a commit git does not hold on TRUNK, and when the
# merge request is not the story's: it must be merged, hold the landed TIP among its commits, and either come from a
# branch named for story KEY or have every commit carry Refs: #KEY (a cited merge request of other work isolates nothing).
# [CySec] Prevents CWE-636 "Not Failing Securely": an unreadable or partial commit list never isolates a change.
_proof_tool_mr_window() {
    local repo="$1" trunk="$2" key="${4:-}" tip="${5:-}" item n url args reply sha full files="" asked=0 f mr branch state holds=0 owned cited_mrs=""
    for item in $(printf '%s' "$3" | tr ',' ' '); do
        case "$item" in '!'*) n="${item#!}" ;; *) continue ;; esac
        case "$n" in ''|*[!0-9]*) continue ;; esac
        asked=1
        url="$(git -C "$repo" remote get-url origin 2>/dev/null)" || { echo "git names no origin for $repo, so the bridge cannot tell whose merge request !$n to read"; return 2; }
        args="$(jq -cn --arg m "$n" --arg r "$url" '{merge_request:$m, repository:$r, limit:"500"}' 2>/dev/null)" || { echo "jq is missing, so the commits of merge request !$n cannot be asked for"; return 2; }
        reply="$(_PTG_CALL_WHOLE=1 proof_receipt_call mr_commits "$args")" || { echo "the commits of merge request !$n could not be read: $reply"; return 2; }
        if ! command -v json_test >/dev/null 2>&1; then
            # shellcheck source=/dev/null
            [ -f "$_PTG_LIB_DIR/json-answer.sh" ] && . "$_PTG_LIB_DIR/json-answer.sh"
        fi
        command -v json_test >/dev/null 2>&1 || { echo "the JSON reader (hooks/lib/json-answer.sh) is missing, so the commits of merge request !$n cannot be read"; return 2; }
        if ! printf '%s' "$reply" | json_test '.commits | type == "array"'; then
            echo "the bridge's answer for the commits of merge request !$n is not a commit list: $(printf '%s' "$reply" | tr '\n' ' ' | cut -c1-200)"; return 2
        fi
        if ! printf '%s' "$reply" | json_test '.truncated == null and (.commits | length) == .total'; then
            echo "the commit list of merge request !$n is cut short, so its change cannot be isolated whole"; return 2
        fi
        mr="$(_PTG_CALL_WHOLE=1 proof_receipt_call mr_get "$args")" || { echo "merge request !$n could not be read: $mr"; return 2; }
        branch="$(printf '%s' "$mr" | json_read '.source_branch')" || { echo "the bridge's answer for merge request !$n names no source branch"; return 2; }
        state="$(printf '%s' "$mr" | json_read '.state')" || state=""
        [ "$state" = merged ] || { echo "merge request !$n is not merged (state: ${state:-unknown}), so it is not what landed"; return 2; }
        owned=1; cited_mrs="$cited_mrs !$n"
        [ "$(story_num_from_branch "${branch#origin/}" | sed -E 's/^0*([0-9])/\1/')" = "$key" ] || owned=0
        while IFS= read -r sha; do
            [ -n "$sha" ] || continue
            full="$(git -C "$repo" rev-parse --verify -q "${sha}^{commit}" 2>/dev/null)" \
                || { echo "commit $sha of merge request !$n is not in $repo (fetch it: git fetch origin)"; return 2; }
            git -C "$repo" merge-base --is-ancestor "$full" "$trunk" 2>/dev/null \
                || { echo "commit $sha of merge request !$n is not on $trunk, so it is not what landed there"; return 2; }
            [ "$full" = "$tip" ] && holds=1
            f="$(_proof_tool_window_files "$repo" "$full^" "$full" 2>/dev/null)" || { echo "git cannot compute the change of commit $sha of merge request !$n"; return 2; }
            files="$files$f"$'\n'
        done < <(printf '%s' "$reply" | jq -r '.commits[].sha' 2>/dev/null)
        if [ "$owned" = 0 ]; then
            # not a branch of the story: every commit must name it
            while IFS= read -r sha; do
                [ -n "$sha" ] || continue
                refs_footer_cites "$(git -C "$repo" log -1 --format=%B "$sha" 2>/dev/null)" "$(_proof_tool_footer_own "$repo")" "$key" \
                    || { echo "merge request !$n comes from $branch, which does not name story $key, and its commit $sha does not carry Refs: #$key, so it is not the story's"; return 2; }
            done < <(printf '%s' "$reply" | jq -r '.commits[].sha' 2>/dev/null)
        fi
    done
    [ "$asked" = 1 ] || return 1
    # [CySec] Prevents CWE-636 "Not Failing Securely": the landed commit must be known and held by the cited merge
    # requests together (a story may land through several), never assumed.
    [ -n "$tip" ] || { echo "the commit that landed for story $key cannot be resolved, so the cited merge requests cannot be shown to hold it"; return 2; }
    [ "$holds" = 1 ] || { echo "none of the cited merge requests ($cited_mrs ) holds the commit ${tip:0:8} that landed for story $key"; return 2; }
    printf '%s' "$files" | sed '/^$/d' | sort -u
}

# proof_tool_close_finding DIM VERDICT PROJECT_DIR STORY [KIND [CITED]] -> print a refusal and rc 0 iff DIM is Test Discipline,
# VERDICT is PROVEN, the story is not of the ops kind, and the close cannot be shown honest; otherwise print nothing,
# rc 1. The invariant: a story WITH a coverage token closes only when the token holds at a place that contains the C#
# it records. Every place git finds for the story (proof_tool_story_result) whose change window holds C# is judged and
# must hold (one that does not refuses, as does a C# window with no token at all). A place with no C# is never a
# success: when no placed window with C# was judged and held, the token is judged at a trunk head
# (proof_tool_verify_at_trunk_head), so a stale landing git cannot place (a squash naming no story or several, a merge
# of mixed work) still refuses. A held place is not enough either when, after it, a commit attributed to no story
# (_proof_tool_late_change) changed a recorded file on the trunk: the token is then judged at a trunk head too, so an
# unplaced stale landing still refuses after a held first merge. Any doubt refuses: a shallow clone, a failing git
# diff, an unreadable object, a commit without any Refs trailer that changes C# right next to the story's own
# commits, a fast-forwarded branch none of whose commits names the story (unless the close cites its merge request,
# whose own commits, read through the bridge, then isolate it: _proof_tool_mr_window). A story with no token that git places, and whose placed windows hold no C#, closes. A
# development story with no token that git places nowhere is judged on the deliverables the close cites (CITED,
# _proof_tool_cited_finding); the one gap left is a close that cites only merge requests (!N), which git cannot read.
# [CySec] CWE-345 / CWE-367: the evidence a close accepts is checked against the story's own commits, its cited
# deliverables or the trunk head, never against whatever commit a shared checkout happens to sit on.
# [RiskMitigation RA-02] A merged story's coverage claim is judged on what actually landed on the trunk.
proof_tool_close_finding() {
    local dim="$1" verdict="$2" proj="$3" story="$4" kind="${5:-}" cited="${6:-}" repo key res="" r b t tokfile how files held=0 placed=1 bare="" ctok=0 heldat="" late=""
    [ "$(_proof_tool_slug "$dim")" = test-discipline ] || return 1
    [ "$verdict" = PROVEN ] || return 1
    [ "$(printf '%s' "$kind" | tr '[:upper:]' '[:lower:]')" != ops ] || return 1
    key="$(_proof_tool_story_key "$story")"; [ -n "$key" ] || return 1
    repo="$(git -C "$proj" rev-parse --show-toplevel 2>/dev/null)" || return 1
    tokfile="$(_proof_tool_token_file "$dim" "$key")"
    # ctok: the story has a C# coverage token. A token holding coverage receipts only (a shell-only story's attached
    # bashcov receipt) is none: the C# checks below judge such a story exactly as one with no token, and its receipts are
    # judged by the coverage receipt check (proof_receipt_close_finding).
    # [CySec] Prevents CWE-345 and CWE-636: only the exact receipt-only shape counts as "no C# token"; any other token,
    # a hand-made or truncated one included, is judged as a C# claim and refused unless it holds.
    if [ -f "$tokfile" ] && ! _proof_tool_receipt_only "$(cat "$tokfile" 2>/dev/null)"; then ctok=1; fi
    how="Measure coverage again on the story's own commits: before the merge, on its branch head; after the merge, on the merged result (a work tree on the merge commit or the trunk head), with the bridge get_coverage or run_tests (story=$key, tree=<that work tree>). The only other way is the owner's override."
    if [ "$ctok" = 1 ] && [ "$(git -C "$repo" rev-parse --is-shallow-repository 2>/dev/null)" != false ]; then
        printf 'Test Discipline is PROVEN with a coverage token, but %s is a shallow clone (or git cannot tell), so the places story %s landed cannot all be found. Fetch the full history (git fetch --unshallow origin) and close again.\n' "$repo" "$key"
        return 0
    fi
    # The checkout is the story's own branch ahead of its trunk (a follow-up of a merged story, or a branch not merged
    # yet): judged at its head, against its fork point, the window the coverage emitter records there. Otherwise every
    # place git finds for the story.
    res="$(proof_tool_story_branch_ahead "$repo" "$key")" || res="$(proof_tool_story_result "$repo" "$key")" || placed=0
    # With several places the story's change is their union: each place is judged on the records of its own files, a
    # place changing C# needs at least one, and a record outside the union refuses. A window git cannot compute refuses.
    # A file the story changed at several places is judged at the LATEST of them (the newest one on the trunk), the story's
    # last version of it, which is what a re-measure on the trunk records; an earlier place skips it (_PTG_VERIFY_LATER).
    local _PTG_VERIFY_UNION="" _PTG_VERIFY_ONLY="" _PTG_VERIFY_LATER="" _PTG_VERIFY_PLACES="$res" _pn _pr
    local -A _place_files=() _place_order=()
    if [ "$(printf '%s\n' "$res" | sed '/^$/d' | wc -l)" -gt 1 ]; then
        while read -r r b t; do
            [ -n "$r" ] || continue
            case "$b" in -|!*) continue ;; esac
            if ! files="$(_proof_tool_window_files "$repo" "$b" "$r")"; then
                printf 'Test Discipline is PROVEN, but git cannot compute the change of story %s at %s against %s (a missing or corrupt object), so its coverage token cannot be judged. Repair or re-fetch the repository and close again.\n' "$key" "${r:0:8}" "${b:0:8}"
                return 0
            fi
            _PTG_VERIFY_UNION="$_PTG_VERIFY_UNION$files"$'\n'
            _place_files[$r]="$files"
            _place_order[$r]="$(git -C "$repo" rev-list --count "$r" 2>/dev/null || echo 0)"
        done <<< "$res"
        [ -n "$(printf '%s' "$_PTG_VERIFY_UNION" | sed '/^$/d')" ] || _PTG_VERIFY_UNION=""
        # the story's own merge requests (--mr-files) are its change too: a record of a file only they change (a commit
        # in them carrying another trailer) is part of the story, judged by its receipt, not refused as foreign
        if [ -n "$_PTG_VERIFY_UNION" ] && [ -n "${_PTG_MR_FILES:-}" ]; then
            local _mrf
            _mrf="$(_proof_tool_mr_files 2>/dev/null)" || {
                printf 'Test Discipline is PROVEN, but the list of the merge-request files of story %s (%s) cannot be read, so its coverage token cannot be judged against the change the close reads. Close again.\n' "$key" "$_PTG_MR_FILES"
                return 0
            }
            _PTG_VERIFY_UNION="$_PTG_VERIFY_UNION$_mrf"$'\n'
        fi
    fi
    # Every placed window that changes C# is judged; one that does not hold refuses.
    while read -r r b t; do
        [ -n "$r" ] || continue
        _PTG_VERIFY_ONLY=""
        case "$b" in !*)
            # a commit without any Refs trailer right next to the story's own commits changes C#: git cannot tell
            # whether it belongs to the story. Without a token that refuses; with one, the token must hold at a trunk
            # head and record that commit's C# (judged after this loop), never this place alone.
            [ "$ctok" = 1 ] || { _proof_tool_bare_refusal "${b#!}" "$key" "$t" "$r" "$how"; return 0; }
            [ -n "$bare" ] || bare="${b#!} $r $t"
            continue ;;
        esac
        if [ "$b" != "-" ]; then
            if ! files="$(_proof_tool_window_files "$repo" "$b" "$r")"; then
                printf 'Test Discipline is PROVEN, but git cannot compute the change of story %s at %s against %s (a missing or corrupt object), so its coverage token cannot be judged. Repair or re-fetch the repository and close again.\n' "$key" "${r:0:8}" "${b:0:8}"
                return 0
            fi
            printf '%s\n' "$files" | _proof_tool_cs_names | grep -c . >/dev/null || continue
            [ -z "$_PTG_VERIFY_UNION" ] || _PTG_VERIFY_ONLY="$files"
            _PTG_VERIFY_LATER=""
            for _pr in "${!_place_order[@]}"; do
                _pn="${_place_order[$_pr]}"
                [ "$_pn" -gt "${_place_order[$r]:-0}" ] && _PTG_VERIFY_LATER="$_PTG_VERIFY_LATER${_place_files[$_pr]}"$'\n'
            done
        else
            # merged by fast forward with no commit of its own carrying `Refs: #<N>`: git cannot isolate its change,
            # so only a token's claim can be judged; without a token the close cannot tell whether it changed C#.
            # [CySec] CWE-636: an unknown change window refuses, it never counts as "no C#".
            if [ "$ctok" = 0 ]; then
                # The cited merge request's own commits isolate it instead (their files, each commit against its
                # parent): no C# there is a place without C#; C# there needs a token; an unreadable list refuses.
                local mrfiles mrrc=0
                mrfiles="$(_proof_tool_mr_window "$repo" "$t" "$cited" "$key" "$(git -C "$repo" rev-parse --verify -q "$r^{commit}" 2>/dev/null)")" || mrrc=$?
                if [ "$mrrc" = 0 ]; then
                    printf '%s\n' "$mrfiles" | _proof_tool_cs_names | grep -c . >/dev/null || continue
                    printf 'Test Discipline is PROVEN, but story %s was merged by fast forward (at %s), the commits of the merge request it cites (%s) change C#, and the story has no coverage token. %s\n' "$key" "${r:0:8}" "$cited" "$how"
                    return 0
                fi
                if [ "$mrrc" = 2 ]; then
                    printf 'Test Discipline is PROVEN, but story %s was merged by fast forward (at %s), none of its commits carries Refs: #%s, and the change of the merge request it cites cannot be read (%s), so whether it changed C# is unknown and the story has no coverage token. %s\n' "$key" "${r:0:8}" "$key" "$mrfiles" "$how"
                    return 0
                fi
                printf 'Test Discipline is PROVEN, but story %s was merged by fast forward (at %s) and none of its commits carries Refs: #%s, so git cannot isolate its change to tell whether it changed C#, the close cites no merge request (!N) whose commits would isolate it, and the story has no coverage token. %s\n' "$key" "${r:0:8}" "$key" "$how"
                return 0
            fi
        fi
        if ! proof_tool_verify_at "$dim" "$key" "$repo" "$r" "$b" "$t"; then
            case "$PROOF_TOOL_VERIFY_REASON" in
                no-token:*) printf 'Test Discipline is PROVEN, but story %s changes C# (at %s) and has no coverage token (%s). %s\n' "$key" "${r:0:8}" "$PROOF_TOOL_VERIFY_REASON" "$how" ;;
                *) printf 'Test Discipline is PROVEN, but the coverage token of story %s does not hold at the story'"'"'s own result %s (%s). %s\n' "$key" "${r:0:8}" "$PROOF_TOOL_VERIFY_REASON" "$how" ;;
            esac
            return 0
        fi
        held=1; heldat="$heldat$r $t"$'\n'
    done <<< "$res"
    if [ -n "$bare" ]; then
        # the unattributed commit's C# must be what the token measured on the trunk as it is now
        local bc br bt f missing=""
        read -r bc br bt <<< "$bare"
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            proof_tool_recorded_files "$dim" "$repo" "$key" | grep -cxF -- "$f" >/dev/null || missing="$missing $f"
        done < <(_proof_tool_window_files "$repo" "$bc^" "$bc" | _proof_tool_cs_names)
        if [ -z "$missing" ] && proof_tool_verify_at_trunk_head "$dim" "$key" "$repo"; then return 1; fi
        _proof_tool_bare_refusal "$bc" "$key" "$bt" "$br" "$how"
        return 0
    fi
    if [ "$held" = 1 ]; then
        # A held place vouches for the recorded files as they were there. A later commit on the trunk that changes one
        # of them and is attributed to no story may be the story's own late change landed without its trailer: the
        # token must then also hold at a trunk head. Only a C# token records files; a receipt-only token has nothing
        # this check could judge (it is judged by the coverage receipt check).
        [ "$ctok" = 1 ] || return 1
        late="$(_proof_tool_late_change "$repo" "$key" "$tokfile" "$heldat")" || return 1
        proof_tool_verify_at_trunk_head "$dim" "$key" "$repo" && return 1
        if [ "${late#* }" = "-" ]; then
            printf 'Test Discipline is PROVEN, but git cannot read the history of the trunk after the place %s of story %s, so whether a later commit changed the files its coverage token records is unknown, and the token does not hold at the head of a trunk (%s). Repair or re-fetch the repository and close again. %s\n' "${late%% *}" "$key" "$PROOF_TOOL_VERIFY_REASON" "$how"
        else
            printf 'Test Discipline is PROVEN, but commit %s changes %s, a file the coverage token of story %s records, after the place where the token held, and it is not one of the story'"'"'s own places (a commit whose footer cites this story, or a real merge named for it): neither a commit message nor another story'"'"'s merge proves what it did to the measured lines, so the token does not hold at the head of a trunk (%s). Measure coverage again on the trunk head (story=%s, tree=<a work tree on the trunk head>) and close again. %s\n' "${late%% *}" "${late#* }" "$key" "$PROOF_TOOL_VERIFY_REASON" "$key" "$how"
        fi
        return 0
    fi
    if [ "$ctok" = 0 ]; then
        # No C# token (none at all, or one holding coverage receipts only). When git places the story somewhere, every placed window was judged above (none changed C#). When
        # git places it nowhere (a squash whose message names no story, branch deleted), its change is read from the
        # deliverables the close cites: one that changes C# refuses; a cited branch or commit git cannot find refuses,
        # because whether it changed C# is unknown. A development story whose cited commits change only shell code
        # (no .NET token expected) still closes, and so does a close that cites only merge requests (!N), which git
        # cannot read here.
        # [CySec] CWE-636: an unplaced story with an unreadable cited change refuses instead of passing as "no C#".
        [ "$placed" = 0 ] && [ "$(printf '%s' "$kind" | tr '[:upper:]' '[:lower:]')" = development ] || return 1
        _proof_tool_cited_finding "$repo" "$key" "$cited" "$how" && return 0
        return 1
    fi
    # No placed window with C# was judged and held: the token must hold at a trunk head.
    proof_tool_verify_at_trunk_head "$dim" "$key" "$repo" && return 1
    if [ "$placed" = 0 ]; then
        printf 'Test Discipline is PROVEN with a coverage token, but git places no branch of story %s here (a branch named story-%s-..., or hotfix/<slug> whose commits carry Refs: #%s), no merge of it and no trunk commit of its own (one whose Refs: footer cites #%s) in %s, and the token does not hold at the head of a trunk (%s; the token is judged at a trunk head only). If the branch or its merge exists only on the remote, fetch it (git fetch origin) and close again. Otherwise: %s\n' "$key" "$key" "$key" "$key" "$repo" "$PROOF_TOOL_VERIFY_REASON" "$how"
    else
        printf 'Test Discipline is PROVEN with a coverage token, but no place git finds for story %s in %s changes the C# the token records, and the token does not hold at the head of a trunk (%s; the token is judged at a trunk head only). %s\n' "$key" "$repo" "$PROOF_TOOL_VERIFY_REASON" "$how"
    fi
    return 0
}

# ---- The coverage receipt at the close -----------------------------------------------------------------------------
# proof_receipt_call VERB ARGS-JSON -> the bridge verb's first answer line on stdout, rc 0; rc 1 with the reason on
# stdout when the bridge cannot be reached, refuses, or has no such verb (an older bridge). One wait budget with the
# signature check (PROOF_TOOL_SEAL_BUDGET_SECONDS), so a close hook never outlives its own time limit.
proof_receipt_call() {
    local verb="$1" args="$2" reply text rc wait left
    if ! command -v bridge_mcp_call >/dev/null 2>&1; then
        # shellcheck source=/dev/null
        [ -f "$_PTG_LIB_DIR/bridge-mcp.sh" ] && . "$_PTG_LIB_DIR/bridge-mcp.sh"
    fi
    command -v bridge_mcp_call >/dev/null 2>&1 || { echo "the bridge client (hooks/lib/bridge-mcp.sh) is missing"; return 1; }
    wait="${KYKLOS_PROOF_VERIFY_TIMEOUT_SECONDS:-600}"
    case "$wait" in ''|*[!0-9]*|?????*) wait=600 ;; esac
    left=$(( ${_PTG_SEAL_DEADLINE#*:} - $(date +%s) ))
    [ "$left" -ge 1 ] || { echo "no time was left in this check's ${PROOF_TOOL_SEAL_BUDGET_SECONDS}s budget"; return 1; }
    [ "$wait" -le "$left" ] || wait="$left"
    reply="$(bridge_mcp_call "$verb" "$args" "$wait")"; rc=$?
    [ "$rc" -eq 0 ] || { echo "the bridge could not be reached, or did not answer within ${wait}s (bridge client rc $rc)"; return 1; }
    text="$(bridge_mcp_text "$reply" | tr -d '\r')"
    # Only the bridge's own answer for a verb it does not have ("unknown tool: <verb>", at the start) means an older
    # bridge; the words anywhere else in a reply (a refusal quoting them) never do.
    case "$text" in "unknown tool: $verb"*) echo "this bridge has no $verb verb: update the bridge (an older bridge cannot post or check coverage receipts)"; return 1 ;; esac
    if bridge_mcp_is_error "$reply"; then
        # A JSON-RPC error (an unreadable or over-size request) carries its reason in error.message, not in a tool
        # result: name it, so a refusal is never printed without its reason.
        [ -n "$text" ] || text="$(printf '%s' "$reply" | jq -r '.error.message // empty' 2>/dev/null)"
        [ -n "$text" ] || text="the bridge gave no reason (raw answer: $(printf '%s' "$reply" | tr '\n' ' ' | cut -c1-200))"
        echo "the bridge refused $verb: $(printf '%s' "$text" | tr '\n' ' ' | cut -c1-300)"; return 1
    fi
    if [ "${_PTG_CALL_WHOLE:-}" = 1 ]; then printf '%s\n' "$text"; else printf '%s\n' "$text" | head -1; fi
}

# proof_tool_limit_accepted VERDICT STORY KIND PROJECT ROW CITED -> rc 0 when the story's PROVEN Test Discipline ROW cites a
# tool-limit note the bridge posted for it and the owner accepted (the bridge judges it in coverage_receipt_check, reading
# the owner's tick back through GitLab), else rc 1. The close then takes that note as the Test Discipline evidence in place
# of a coverage token; the receipt check still runs and answers "bound" for it. Any doubt (no bridge, no answer) is rc 1.
proof_tool_limit_accepted() {
    local verdict="$1" story="$2" kind="$3" project="$4" row="$5" cited="$6" key args answer
    [ "$verdict" = PROVEN ] || return 1
    case "$row" in *note_*) ;; *) return 1 ;; esac
    key="$(_proof_tool_story_key "$story")"; [ -n "$key" ] && [ -n "$project" ] || return 1
    args="$(jq -cn --arg s "$key" --arg p "$project" --arg k "${kind:-development}" --arg r "$row" --arg c "$cited" --arg v "$_PTG_RECEIPT_VERSION" \
        '{story:$s, project:$p, kind:$k, row:$r, cited:$c, version:$v}' 2>/dev/null)" || return 1
    answer="$(proof_receipt_call coverage_receipt_check "$args")" || return 1
    case "$answer" in "bound: tool-limit note "*) return 0 ;; esac
    return 1
}

# proof_receipt_close_finding VERDICT STORY KIND PROJECT ROW CITED -> print a refusal and rc 0 when the story's PROVEN Test
# Discipline row does not hold against its coverage receipts; else nothing, rc 1. The judgement is the bridge's
# (coverage_receipt_check runs the same rule as the bridge's own story_close: the receipts the cited change needs, the
# signed records, each linked upload re-fetched and re-hashed, the floor on the bound receipt's own figure), so the
# two closes cannot judge a row apart. Exempt by kind only: documentation, analysis and ops stories. DEFAULT-ON; the
# greppable opt-out is PROOF_COVERAGE_RECEIPT=off (audited). FAIL-HARD: an unreachable or older bridge refuses.
# [CySec] Prevents CWE-345 "Insufficient Verification of Data Authenticity": a coverage claim passes only by linking the
# receipt the signed token names.
proof_receipt_close_finding() {
    local verdict="$1" story="$2" kind="$3" project="$4" row="$5" cited="$6" key args answer
    [ "$verdict" = PROVEN ] || return 1
    case "$(printf '%s' "$kind" | tr '[:upper:]' '[:lower:]')" in documentation|analysis|ops) return 1 ;; esac
    if kyklos_control_off "${PROOF_COVERAGE_RECEIPT:-}"; then
        if [ -z "${_PTG_AUDIT_SOURCED:-}" ]; then
            # shellcheck source=/dev/null
            [ -f "$_PTG_LIB_DIR/escape-audit.sh" ] && . "$_PTG_LIB_DIR/escape-audit.sh" 2>/dev/null || true
            _PTG_AUDIT_SOURCED=1
        fi
        command -v escape_audit >/dev/null 2>&1 && escape_audit "coverage-receipt-off" "story=$story PROOF_COVERAGE_RECEIPT=${PROOF_COVERAGE_RECEIPT:-}" 2>/dev/null || true
        echo "[kyklos] coverage receipt check skipped: PROOF_COVERAGE_RECEIPT=${PROOF_COVERAGE_RECEIPT:-} [audit]" >&2
        return 1
    fi
    key="$(_proof_tool_story_key "$story")"
    [ -n "$key" ] || { printf 'Test Discipline is PROVEN, but the story number is unknown, so its coverage receipt cannot be checked.\n'; return 0; }
    [ -n "$project" ] || { printf 'Test Discipline is PROVEN, but STORY_GITLAB_PROJECT is unset, so the coverage receipt on story %s cannot be checked.\n' "$key"; return 0; }
    # The bridge judges; the gate says which receipt format it reads, so a receipt newer than this plugin is refused by
    # name (RECEIPT-VERSION: update the plugin), never read by older rules.
    args="$(jq -cn --arg s "$key" --arg p "$project" --arg k "${kind:-development}" --arg r "$row" --arg c "$cited" --arg v "$_PTG_RECEIPT_VERSION" \
        '{story:$s, project:$p, kind:$k, row:$r, cited:$c, version:$v}')"
    if ! answer="$(proof_receipt_call coverage_receipt_check "$args")"; then
        # The transition: an older bridge has no receipt check, and the tokens it minted carry no receipt. Such a token
        # (no receipt-capable marker) is judged by the rules it was minted under, with a warning; a token whose marker
        # says a receipt-capable bridge minted it refuses, because that bridge must know the check.
        case "$answer" in
            "this bridge has no coverage_receipt_check verb"*)
                # The marker is read from the token file, which the container could edit, so it is trusted only after the
                # bridge's own keyed check (verify_proof_token, which every bridge has) proves the token: an older bridge
                # signs the files alone, so a token a receipt-capable bridge signed (its marker and records under the
                # MAC) fails that check whether or not its marker line was removed, and refuses below. A story with no
                # token at all has nothing a receipt could bind; its coverage token gate judges it as before.
                local tokfile; tokfile="$(_proof_tool_token_file "Test Discipline" "$key")"
                if [ ! -f "$tokfile" ] || { ! grep -qxF "$_PTG_CAPABLE_LINE" "$tokfile" 2>/dev/null && proof_tool_bridge_seal "Test Discipline" "$key" stop; }; then
                    printf '[kyklos] WARNING: story %s closes without a coverage receipt: its Test Discipline token was minted by a bridge older than coverage receipts, and that bridge cannot check them (%s). Relaunch to get a receipt-capable bridge.\n' "$key" "$answer" >&2
                    return 1
                fi
                [ -n "${PROOF_TOOL_SEAL_REASON:-}" ] && answer="$answer; the token is not one this bridge signed ($PROOF_TOOL_SEAL_REASON)" ;;
        esac
        printf 'Test Discipline is PROVEN, but the coverage receipt of story %s could not be checked: %s. Start (or update) the bridge and close again.\n' "$key" "$answer"
        return 0
    fi
    case "$answer" in
        "bound: "*|"exempt: "*) return 1 ;;
        "legacy: "*) printf '[kyklos] WARNING: story %s closes without a coverage receipt: %s\n' "$key" "${answer#legacy: }" >&2; return 1 ;;
    esac
    printf 'Test Discipline is PROVEN, but its coverage receipt does not hold: %s\n' "${answer#refused: }"
    return 0
}

# proof_tool_notpertinent_finding DIM VERDICT PROJECT_DIR -> print a BLOCK reason and return 0 iff DIM is
# marked NOT_PERTINENT but the story's CHANGE shows it IS applicable — closing the "unverified self-exemption" hole
# (a dimension waved off as NOT_PERTINENT skips its metric entirely). It uses the shared change window but a
# DELIBERATELY different predicate from the PROVEN gate for Test Discipline: _proof_tool_source_changed, which is
# MULTI-STACK (C#/PowerShell/shell/Python/TS/JS/Go/Java/Ruby), so a bash/PowerShell change is judged too — whereas
# proof_tool_applies keeps Test Discipline on the *.cs-only _proof_tool_code_changed (bound to the .NET coverage
# token). Fail-OPEN by construction: no source touched (a docs-only change) -> no finding, the exemption stands.
# DEFAULT-ON; opt out with PROOF_NOTPERTINENT_VERIFY=off. Covers Test Discipline and Non-Duplication; Documentation
# not yet (its source-touched heuristic over-refuses an internal refactor, so it needs a narrower signal).
proof_tool_notpertinent_finding() {
    local dim="$1" verdict="$2" proj="$3" why
    # DEFAULT-ON (user-authorized) via the shared deterministic parser. If the helper is
    # unavailable (broken partial install) the gate FAILS SAFE to enforcing — never silently open. The fail-OPEN
    # applicability below (no source touched -> no finding) still means it can only ever refuse a NOT_PERTINENT
    # the diff actually contradicts, never wedge a clean close.
    kyklos_control_off "${PROOF_NOTPERTINENT_VERIFY:-}" && return 1
    [ "$verdict" = "NOT_PERTINENT" ] || return 1
    # Test Discipline + Non-Duplication both key off _proof_tool_source_changed (a source change means there IS a
    # testable / dedupable surface); for Test Discipline this is broader than its PROVEN gate's *.cs-only predicate. Documentation is deliberately NOT here yet: "source
    # changed" over-refuses a legitimate internal refactor that needs no doc, so it needs a narrower signal (follow-up).
    case "$(_proof_tool_slug "$dim")" in
        test-discipline) _proof_tool_source_changed "$proj" || return 1; why="a testable surface" ;;
        non-duplication) _proof_tool_source_changed "$proj" || return 1; why="new source that could duplicate existing logic/constants" ;;
        *) return 1 ;;
    esac
    printf 'Dimension "%s" is marked NOT_PERTINENT, but this story changed source it governs (%s) — PROVE it rather than wave it off; if it is genuinely exempt, narrow the change or justify that in the evidence.\n' "$dim" "$why"
    return 0
}

# ------------------------------------------------------------------------------------------------------------------
# Adversarial-Review token — proves a REAL ssdlc-adversarial-review run over a story's findings report,
# so the mandatory "Adversarial Review" Proof row cannot be hand-filled. The token is BOUND to (story id + the exact
# report artifact content) and HMAC-signed under the host-only key, which only the bridge holds (a container cannot
# forge it). The bridge mints it (advreview_mint) and checks it at close (advreview_check). Unlike a hand-typed string, a valid
# token requires a concrete report file whose content still hashes identically. Distinct from the coverage
# proof-tool token above: this proves a REVIEW ran, not that files were covered.
#
# _advreview_body STORY REPORTFILE -> the canonical bound string "advreview:<story>:<sha256(report)>" (or empty if
# the report is unreadable). The token is a signature/hash OVER this body, so producer + verifier never drift.
_advreview_body() {
    local story="$1" report="$2" h
    [ -n "$story" ] && [ -f "$report" ] || return 1
    h="$(_proof_tool_sha256 "$report")"; [ -n "$h" ] || return 1
    printf 'advreview:%s:%s' "$story" "$h"
}

# _advreview_token BODY -> the token for a bound body: HMAC-SHA256 under the host-only signing key. There is NO keyless
# fallback: a plain hash of the body could be computed by anyone holding the report, so it would prove nothing. Without
# the key (always the case inside the container) this returns non-zero and prints nothing, so a review token can only
# be minted and checked by the bridge, which holds the key. ONE function so emit + verify compute it identically.
# [CySec] Enforces CWE-345 "Insufficient Verification of Data Authenticity": the review token is a keyed MAC only.
_advreview_token() {
    local mac; mac="$(_proof_tool_hmac "$1")"
    [ -n "$mac" ] || return 1
    printf '%s' "$mac"
}

# proof_advreview_emit STORY REPORTFILE -> mint + STORE the token for STORY bound to REPORTFILE, and PRINT it (for
# embedding in the GitLab comment body AND the Proof "Token" metric). Loud non-zero if the report is unreadable, so
# a review can never mint an empty/unbindable token. Stores the bound body so verify can recompute without the file.
proof_advreview_emit() {
    local story="$1" report="$2" body tok dir
    body="$(_advreview_body "$story" "$report")" || { echo "proof_advreview_emit($story): report not readable -> refusing to mint" >&2; return 1; }
    tok="$(_advreview_token "$body")" && [ -n "$tok" ] \
        || { echo "proof_advreview_emit($story): no host signing key here - a review token is minted only by the bridge (run advreview, which asks it)" >&2; return 1; }
    dir="$(_proof_tool_dir)"; mkdir -p "$dir" 2>/dev/null || return 1
    printf '%s\n' "$body" > "$dir/advreview-$story.body"
    printf '%s\n' "$tok"  > "$dir/advreview-$story.token"
    printf '%s\n' "$tok"
}

# proof_advreview_verify STORY PRESENTED -> exit 0 iff PRESENTED matches the token recomputed from the STORED bound
# body for STORY. Fail-CLOSED: no stored body, or a mismatch (a hand-typed / stale / wrong-key token), yields
# non-zero. The gate calls this at close; a pass means a real emit happened for exactly this story's report.
proof_advreview_verify() {
    local story="$1" presented="$2" dir body want
    [ -n "$story" ] && [ -n "$presented" ] || return 1
    dir="$(_proof_tool_dir)"
    [ -f "$dir/advreview-$story.body" ] || return 1
    body="$(cat "$dir/advreview-$story.body" 2>/dev/null)"; [ -n "$body" ] || return 1
    want="$(_advreview_token "$body")" && [ -n "$want" ] || return 1   # no key here: only the bridge can verify
    [ "$presented" = "$want" ]
}

# ------------------------------------------------------------------------------------------------------------------
# CLI surface — when this file is EXECUTED (not sourced), dispatch a subcommand. This is the SINGLE source of truth
# for the token format: a producer (the bridge's coverage path, a CI coverage step, a skill) shells out to
#   proof-tool-gate.sh emit [--story <N>] [--root <dir>] [--receipt-capable] [--attachment "<record>"] <dimension> <file>...  # record the story-bound content token over the files
#                                                       (with --root a relative <file> is read in that repository; a path with '..' is refused;
#                                                        --attachment records the coverage receipt the run posted)
#   proof-tool-gate.sh attach --story <N> --attachment "<record>"  # HOST ONLY: record a shell coverage receipt in the story's token
#   proof-tool-gate.sh receipt --story <N>              # HOST ONLY: "receipts: capable|legacy|none", then the records, once the MAC proves them
#   proof-tool-gate.sh verify <dimension> [--story <N>] [--root <dir>] [--host-check] [--at-result] # exit 0 iff a fresh matching token
#                                                       for the story exists (--host-check: the bridge's keyed check, no container session;
#                                                        --at-result: the close's check, judged at the story's own merge, not the checkout)
# proof-tool-gate.sh advreview-emit <story> <report-file> # mint+print the adversarial-review token
# proof-tool-gate.sh advreview-verify <story> <token> # exit 0 iff the token verifies
# proof-tool-gate.sh changed-lines <dir> --story <N> <file>... # per file, the line ranges the story's change made
# proof-tool-gate.sh change-base <dir> --story <N> [--ranges]   # the commit the story's change starts from (the trunk base the
#                                                     # coverage receipt's no-drop rule compares touched files against)
# proof-tool-gate.sh changed-files <dir> [--story <N>] # print the change window (the bridge emitter uses THIS, so the
#                                                     # files it records are exactly the files the guards judge; with
#                                                     # --story, a story merged by a merge commit gives its merged change,
#                                                     # unless the checkout is the story's own branch ahead of its trunk)
# rather than re-implementing the hash, so the emit format can never drift from the guard's verifier. Sourcing this
# file (the guard does) defines the functions WITHOUT running the CLI, so the two uses never interfere.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set +e +u +o pipefail   # run as a command: declare the options, never inherit them from an exported SHELLOPTS
    _ptg_cmd="${1:-}"; shift 2>/dev/null || true
    case "$_ptg_cmd" in
        emit)             proof_tool_emit "$@" ;;
        verify)           # verify <dimension> [--story <N>] [--root <dir>] (options in any order). --root is the repository
                          # the token's relative paths belong to (a tree beside the solution root); default: the token root.
                          _v_dim="${1:-}"; shift 2>/dev/null || true; _v_story=""; _v_root=""; _v_at_result=0
                          while [ "$#" -gt 0 ]; do
                              case "$1" in
                                  --story) _v_story="${2:-}"; shift 2 2>/dev/null || shift ;;
                                  --root)  _v_root="${2:-}"; shift 2 2>/dev/null || shift ;;
                                  --host-check) PROOF_TOOL_HOST_CHECK=1; shift ;;
                                  --at-result) _v_at_result=1; shift ;;
                                  --mr-files) _PTG_MR_FILES="${2:-}"; shift 2 2>/dev/null || shift ;;
                                  *) echo "proof-tool-gate.sh verify: unknown option '$1'" >&2; exit 2 ;;
                              esac
                          done
                          # On a refusal, say why on stdout (one "<verdict>: <what>" line): the bridge returns it as its answer.
                          # --at-result (the bridge's close): judged at the story's own result, not at the checkout.
                          if [ "${_v_at_result:-0}" = 1 ]; then
                              proof_tool_verify_at_result "$_v_dim" "$_v_root" "$_v_story" || { printf '%s\n' "$PROOF_TOOL_VERIFY_REASON"; exit 1; }
                          else
                              proof_tool_verify "$_v_dim" "$_v_root" "$_v_story" || { printf '%s\n' "$PROOF_TOOL_VERIFY_REASON"; exit 1; }
                          fi ;;
        attach)           proof_tool_attach "$@" ;;     # attach --story <N> --attachment "<record>" (host only, keyed)
        receipt)          proof_tool_receipts "$@" ;;   # receipt --story <N>: the keyed-checked receipt records
        advreview-emit)   proof_advreview_emit "$@" ;;
        advreview-verify) proof_advreview_verify "$@" ;;
        changed-files)    # changed-files <dir> [--story <N>] [--mr-files <list>]: with a story merged by a merge commit, its merged change
                          # (or, with --mr-files, the files of the story's own merge requests the bridge read from GitLab)
                          _cf_dir="${1:-.}"; shift 2>/dev/null || true; _cf_story=""
                          while [ "$#" -gt 0 ]; do
                              case "$1" in
                                  --story) _cf_story="${2:-}"; shift 2 2>/dev/null || shift ;;
                                  --mr-files) _PTG_MR_FILES="${2:-}"; shift 2 2>/dev/null || shift ;;
                                  *) echo "proof-tool-gate.sh changed-files: unknown option '$1'" >&2; exit 2 ;;
                              esac
                          done
                          proof_tool_changed_files_for "$_cf_dir" "$_cf_story" ;;
        change-base)      # change-base <dir> --story <N>: the commit the story's change starts from on its trunk
                          _cb_dir="${1:-.}"; shift 2>/dev/null || true; _cb_story=""; _cb_ranges=""
                          while [ "$#" -gt 0 ]; do
                              case "$1" in
                                  --story) _cb_story="${2:-}"; shift 2 2>/dev/null || shift ;;
                                  --ranges) _cb_ranges=1; shift ;;
                                  *) echo "proof-tool-gate.sh change-base: unknown option '$1'" >&2; exit 2 ;;
                              esac
                          done
                          proof_tool_story_change_base "$_cb_dir" "$_cb_story" "$_cb_ranges" ;;
        changed-lines)    # changed-lines <dir> --story <N> <file>...: the lines of each file the story's change made
                          _cl_dir="${1:-.}"; shift 2>/dev/null || true; _cl_story=""; _cl_files=()
                          while [ "$#" -gt 0 ]; do
                              case "$1" in
                                  --story) _cl_story="${2:-}"; shift 2 2>/dev/null || shift ;;
                                  -*) echo "proof-tool-gate.sh changed-lines: unknown option '$1'" >&2; exit 2 ;;
                                  *) _cl_files+=("$1"); shift ;;
                              esac
                          done
                          proof_tool_story_changed_lines "$_cl_dir" "$_cl_story" "${_cl_files[@]}" ;;
        *) echo "usage: proof-tool-gate.sh {emit [--story <N>] [--root <dir>] [--attachment <record>] <dimension> <file>...|attach --story <N> --attachment <record>|receipt --story <N>|verify <dimension> [--story <N>] [--root <dir>] [--host-check] [--at-result]|advreview-emit <story> <report>|advreview-verify <story> <token>|changed-files <dir> [--story <N>]|changed-lines <dir> --story <N> <file>...|change-base <dir> --story <N> [--ranges]}" >&2; exit 2 ;;
    esac
fi
