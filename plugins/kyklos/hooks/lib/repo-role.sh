#!/usr/bin/env bash
# repo-role.sh - THE single resolver: (declared model, target repo) -> role + workflow (hardened
# by an adversarial-review pass). Sourced by the guards; no guard re-implements the model read inline
# (test-no-inline-repo-workflow.sh enforces this). Topology-first (KYKLOS_PROJECT_TOPOLOGY, VALIDATED through
# topology.sh's single contract) with legacy KYKLOS_REPO_SHAPE back-compat. The model: the ssdlc-repo-model skill
# and lib/topology.sh.
#
# [CySec] Prevents CWE-94 / CWE-829 (code injection via an untrusted config file): the TARGET repo's
# .claude/standards.env is PARSED key-by-key (_rr_getkey), NEVER `.`-sourced - so a hostile repo the agent merely
# touches cannot execute code in the guard's process. (The container's OWN standards.env is trusted, and is loaded -
# parsed, never sourced - by the guard at startup via lib/standards-env.sh; that is the trust boundary.)

_RR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=/dev/null
. "$_RR_DIR/topology.sh"
# shellcheck source=/dev/null
. "$_RR_DIR/same-repository.sh"

# _rr_getkey <file> <KEY> -> value of `KEY=...` (last occurrence) on stdout; rc 1 if absent/empty. PARSE only, NO
# execution. Only a line beginning exactly `KEY=` (no leading space, no `#`) matches; a trailing carriage return (a
# file checked out with Windows line endings) is dropped, then one layer of surrounding single/double quotes.
_rr_getkey() {
    local f="$1" k="$2" v
    [ -f "$f" ] || return 1
    # Text mode: a NUL in the file must not make grep treat it as binary and hide the key (CWE-158).
    v="$(LC_ALL=C grep -aE "^${k}=" "$f" 2>/dev/null | tail -n1)"
    v="${v%$'\r'}"
    [ -n "$v" ] || return 1
    v="${v#*=}"
    case "$v" in
        \"*\") v="${v#\"}"; v="${v%\"}" ;;
        \'*\') v="${v#\'}"; v="${v%\'}" ;;
    esac
    [ -n "$v" ] || return 1
    printf '%s' "$v"
}

# _rr_declaring_companion_parent <top> -> 0 iff <top> is the INNER SOURCE of a companion whose PARENT declares it:
# the parent is itself a git repo, has its own .claude/standards.env, that file declares a companion model (either
# companion topology, PriComPubSou or PriComPriSou, OR legacy KYKLOS_REPO_SHAPE=companion) AND names THIS subdir as its KYKLOS_SOURCE_DIR. This is the
# on-disk, container-independent proof that a file-LESS nested source is a declared companion source. The parent file
# is PARSED (never sourced) - CWE-829. Mirrors _rr_is_inner_source's REAL-git-nesting guard (RA-01). [RiskMitigation RA-01]
_rr_declaring_companion_parent() {
    local top="$1" parent base pf psrcdir ptopo
    [ -n "$top" ] || return 1
    parent="$(dirname "$top")"; base="$(basename "$top")"
    pf="$parent/.claude/standards.env"
    [ -f "$pf" ] || return 1
    git -C "$parent" rev-parse --show-toplevel >/dev/null 2>&1 || return 1   # REAL git nesting (RA-01)
    psrcdir="$(_rr_getkey "$pf" KYKLOS_SOURCE_DIR || true)"
    [ "$psrcdir" = "$base" ] || return 1                                     # the parent names THIS dir as its source
    ptopo="$(_rr_getkey "$pf" KYKLOS_PROJECT_TOPOLOGY || true)"
    case "$ptopo" in PriComPubSou|PriComPriSou) return 0 ;; esac
    [ "$(_rr_getkey "$pf" KYKLOS_REPO_SHAPE || true)" = "companion" ] && return 0
    return 1
}

# _rr_is_own_project <top> -> 0 iff <top> is a working tree of the CONTAINER'S OWN project (CLAUDE_PROJECT_DIR): its
# toplevel, a linked worktree of it, or a clone whose remotes all point at it (lib/same-repository.sh).
# This is the trust anchor for the ambient-env model: the container's env legitimately declares the model of ITS OWN
# project, but NOT of a FOREIGN / stray repo the agent merely clones or cd's into. Container env is already the trust
# boundary (the guard loads $CLAUDE_PROJECT_DIR/.claude/standards.env at startup, parsed via lib/standards-env.sh), so reading CLAUDE_PROJECT_DIR here
# stays inside it. [RiskMitigation RA-01]
_rr_is_own_project() {
    local top="$1" pd pdtop
    pd="${CLAUDE_PROJECT_DIR:-}"
    { [ -n "$pd" ] && [ -n "$top" ]; } || return 1
    pdtop="$(git -C "$pd" rev-parse --show-toplevel 2>/dev/null || echo "")"
    [ -n "$pdtop" ] || return 1
    [ "$top" = "$pdtop" ] && return 0
    # A linked worktree or a clone of the container's own project is that project (identity, not folder).
    same_repository "$top" "$pdtop"
}

# _rr_model <top> -> "SHAPE|SRCDIR|SRCWF|DECLARED". The model is read INTRINSICALLY, in priority: (A) the target's OWN
# .claude/standards.env; (B) -- for a companion's nested source that is AI-artifact-free (NO .claude/ of its own, by
# Tier-0) -- the PARENT companion's standards.env; (C) the ambient container env, BUT ONLY when the target IS the
# container's own project. A foreign file-less repo matches none -> undeclared (NOT seeded from the ambient env). Files
# are PARSED, never sourced. A declared KYKLOS_PROJECT_TOPOLOGY is VALIDATED + reconciled
# through topology_effective: an unknown value OR a topology-vs-legacy-shape conflict yields the "__INVALID__" shape
# (guards fail-hard on it - NO silent gitflow default); a valid topology is AUTHORITATIVE and DERIVES both the shape
# and the source workflow (so a stale legacy SOURCE_WORKFLOW=trunk can never silently switch GitFlow off on the source).
_rr_model() {
    local top="$1"
    # The model is read INTRINSICALLY -- it is NOT seeded from the ambient container env for an
    # arbitrary repo. A repo is declared by (A) its own .claude/standards.env, (B) a parent companion that declares it
    # as the nested source, or (C) the ambient env BUT ONLY when the target IS the container's own project. A FOREIGN
    # file-less repo (a stray clone the agent merely cd's into) matches NONE -> undeclared, which is what lets
    # KYKLOS_REPO_MODEL_REQUIRED (on by default) actually block it. Empty base -> the (else) is genuinely undeclared.
    local topo="" shape="" srcdir="" srcwf=""
    if [ -n "$top" ] && [ -f "$top/.claude/standards.env" ]; then
        # (A) The TARGET repo's OWN standards.env is AUTHORITATIVE for the WHOLE model. Do NOT inherit the ambient
        # container env (a DIFFERENT repo's -- e.g. the session PROJECT_DIR loads its own standards.env into env)
        # key-by-key: a target that declares shape-but-not-topology (a legacy companion) would then inherit the
        # CONTAINER's topology and yield a PHANTOM topology<->shape conflict (e.g. PriSta[env] x companion[file]),
        # blocking every infra session from editing any companion repo. A key ABSENT from the file resolves to EMPTY,
        # never the container's value.
        local f="$top/.claude/standards.env"
        topo="$(_rr_getkey "$f" KYKLOS_PROJECT_TOPOLOGY || true)"
        shape="$(_rr_getkey "$f" KYKLOS_REPO_SHAPE || true)"
        srcdir="$(_rr_getkey "$f" KYKLOS_SOURCE_DIR || true)"
        srcwf="$(_rr_getkey "$f" KYKLOS_SOURCE_WORKFLOW || true)"
    elif [ -n "$top" ] && _rr_declaring_companion_parent "$top"; then
        # (B) The target is the INNER SOURCE of a companion and is AI-artifact-free by Tier-0 (NO .claude/ in the public
        # mirror), so its model is read from the PARENT companion's standards.env (PARSED, never sourced) -- NOT from
        # the ambient container env. This makes the source's declaration INTRINSIC to the on-disk companion+source
        # structure: it resolves as source/gitflow/declared regardless of which container operates on it, and NEVER
        # needs a .claude/ of its own. Same env-isolation as branch (A): a key ABSENT from the parent file is EMPTY,
        # never the container's value -- so a cross-project (e.g. infra PriSta) session cannot contaminate it.
        # [RiskMitigation RA-01/RA-04]
        local pf; pf="$(dirname "$top")/.claude/standards.env"
        topo="$(_rr_getkey "$pf" KYKLOS_PROJECT_TOPOLOGY || true)"
        shape="companion"                       # the parent declares this subtree a companion source...
        srcdir="$(basename "$top")"             # ...rooted at THIS dir
        srcwf="$(_rr_getkey "$pf" KYKLOS_SOURCE_WORKFLOW || true)"
    elif [ -n "$top" ] && _rr_is_own_project "$top"; then
        # (C) The target IS the CONTAINER'S OWN project (top == CLAUDE_PROJECT_DIR toplevel). The container's trusted
        # env legitimately declares ITS OWN project's model (the documented "declare the model in the container" path).
        # A FOREIGN / stray file-less repo is NOT the container's project, so it does NOT reach here -> it stays
        # UNDECLARED (the removed hole that let a stray /tmp clone inherit the container shape and silently defeat
        # KYKLOS_REPO_MODEL_REQUIRED, on by default). [RiskMitigation RA-01]
        topo="${KYKLOS_PROJECT_TOPOLOGY:-}"; shape="${KYKLOS_REPO_SHAPE:-}"
        srcdir="${KYKLOS_SOURCE_DIR:-}"; srcwf="${KYKLOS_SOURCE_WORKFLOW:-}"
    fi
    # (else) A file-less repo that is NONE of (A)/(B)/(C) is FOREIGN -> topo/shape/srcdir/srcwf stay EMPTY -> undeclared.
    if [ -n "$topo" ]; then
        local eff
        if ! eff="$(topology_effective "$topo" "$shape" 2>/dev/null)"; then
            printf '__INVALID__|%s|%s|1' "$srcdir" "${srcwf:-gitflow}"; return   # unknown topology or topology<->shape conflict
        fi
        # A valid topology DERIVES the shape and the branch model (gitflow). The derived branch model OVERRIDES a
        # declared KYKLOS_SOURCE_WORKFLOW so a stale legacy 'trunk' can never silently switch GitFlow OFF on the
        # source (anti-weakening). The SOLE declared value kept is 'agent-readonly': it does not switch GitFlow off,
        # it ADDS a restriction (the agent commits nowhere in the source), so honouring it only STRENGTHENS. This is
        # the strengthening-overlay carve-out — captured BEFORE the derive so the case below cannot clobber it. It is
        # scoped to the COMPANION topologies on purpose: those have a SEPARATE source the agent treats read-only while
        # it still works the companion. On a standalone/artifact topology (no separate source) a stray agent-readonly
        # would lock the agent out of its OWN work, so it is ignored there (fall back to the derived gitflow).
        local _ovl=""
        case "$eff" in PriComPubSou|PriComPriSou) [ "$srcwf" = "agent-readonly" ] && _ovl="agent-readonly" ;; esac
        case "$eff" in
            PriComPubSou) shape=companion; srcwf=gitflow ;;
            PriComPriSou) shape=companion; srcwf=gitflow ;;   # private source(s); same companion shape as PriComPubSou
            PriSta)       shape=internal;  srcwf=gitflow ;;
            PriSouPubArt) shape=internal;  srcwf=gitflow ;;   # private source behaves as internal-gitflow locally
        esac
        [ -n "$_ovl" ] && srcwf="$_ovl"   # restore the strengthening read-only overlay over the derived branch model
        printf '%s|%s|%s|1' "$shape" "$srcdir" "$srcwf"; return
    fi
    # No topology declared: legacy shape+srcwf back-compat (undeclared -> the guards' gitflow default).
    [ -n "$srcwf" ] || srcwf="gitflow"
    local declared=""; [ -n "$shape" ] && declared=1
    printf '%s|%s|%s|%s' "$shape" "$srcdir" "$srcwf" "$declared"
}

# repo_model_declared <top> -> 0 iff a model is declared (topology OR legacy shape). A garbage topology IS declared
# (just broken) - repo_model_invalid distinguishes it, and the guards MUST check that first.
repo_model_declared() { case "$(_rr_model "$1")" in *'|1') return 0 ;; *) return 1 ;; esac; }

# repo_model_invalid <top> -> 0 iff the declared topology is unknown or conflicts with the legacy shape. The guards
# fail-hard on this (no silent default) - this is where topology.sh's fail-hard contract reaches the LIVE path.
repo_model_invalid() { case "$(_rr_model "$1")" in __INVALID__\|*) return 0 ;; *) return 1 ;; esac; }

# _rr_is_inner_source <top> <srcdir> -> 0 iff <top> is the INNER source of a companion (ends in /<srcdir> AND is a
# git repo nested inside another git repo). PROJECT_DIR-independent. [RiskMitigation RA-01]
_rr_is_inner_source() {
    local top="$1" srcdir="$2"
    [ -n "$srcdir" ] || return 1
    case "$top" in */"$srcdir") git -C "$(dirname "$top")" rev-parse --show-toplevel >/dev/null 2>&1 && return 0 ;; esac
    return 1
}

# _rr_main_checkout <top> -> the toplevel of the MAIN checkout when <top> is a LINKED worktree (`git worktree add`),
# rc 1 otherwise (a main checkout, a bare repository, or not a repository). A linked worktree's git dir differs from
# the common git dir it shares with the main checkout; the main checkout is the parent of that common `.git`.
_rr_main_checkout() {
    local top="$1" gd cd main
    [ -n "$top" ] || return 1
    # Both paths are made absolute without changing directory (a `cd` in a subshell would also move what a line
    # tracer such as a coverage tool reads as the current directory).
    gd="$(git -C "$top" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
    cd="$(git -C "$top" rev-parse --git-common-dir 2>/dev/null)" || return 1
    case "$cd" in /*|[A-Za-z]:/*) ;; *) cd="$top/$cd" ;; esac
    gd="$(realpath -m -- "$gd" 2>/dev/null)" || return 1
    cd="$(realpath -m -- "$cd" 2>/dev/null)" || return 1
    { [ -n "$gd" ] && [ -n "$cd" ] && [ "$gd" != "$cd" ]; } || return 1
    case "$cd" in */.git) ;; *) return 1 ;; esac
    main="$(git -C "${cd%/.git}" rev-parse --show-toplevel 2>/dev/null)" || return 1
    [ -n "$main" ] || return 1
    printf '%s' "$main"
}

# _rr_inner_source_top <top> -> print the checkout that IS a companion's nested source for the repository at <top>, and
# return 0: <top> itself when it sits at the declared source directory, or - for a LINKED WORKTREE of that source,
# which can live anywhere (e.g. <companion>/.wt/<name>/Repo) - its main checkout. rc 1 when neither is the nested
# source. A worktree carries the same public tree as the source it was added from, so every guard must treat it as
# the source. [CySec] Hardens against CWE-538: a worktree outside <companion>/<srcdir> no longer escapes the
# nested-source classification, so internal story files are never written or committed there. [RiskMitigation RA-01]
_rr_inner_source_top() {
    local top="$1" cand m shape srcdir
    [ -n "$top" ] || return 1
    for cand in "$top" "$(_rr_main_checkout "$top" 2>/dev/null || true)"; do
        [ -n "$cand" ] || continue
        m="$(_rr_model "$cand" 2>/dev/null || echo "")"
        shape="${m%%|*}"; srcdir="${m#*|}"; srcdir="${srcdir%%|*}"
        if [ "$shape" = companion ] && _rr_is_inner_source "$cand" "$srcdir"; then printf '%s' "$cand"; return 0; fi
    done
    return 1
}

# repo_inner_source_of <path> -> print the git toplevel holding <path> and return 0 when that repository is the nested
# source of a companion (its model says companion and it sits at the declared source directory) or a linked worktree
# of it; return 1 otherwise. <path> may be relative (to $PWD) and need not exist yet: the nearest existing ancestor is
# probed, so a directory about to be created is judged by the repository it would land in.
repo_inner_source_of() {
    local path="$1" probe top
    [ -n "$path" ] || return 1
    case "$path" in /*) ;; *) path="$PWD/$path" ;; esac
    probe="$path"
    while [ ! -d "$probe" ] && [ "$probe" != "/" ]; do probe="$(dirname "$probe")"; done
    top="$(git -C "$probe" rev-parse --show-toplevel 2>/dev/null || echo "")"
    [ -n "$top" ] || return 1
    _rr_inner_source_top "$top" >/dev/null || return 1
    printf '%s' "$top"
}

# repo_companion_root <dir> -> the directory that owns the AI artifacts (Stories/, .claude/) for <dir>: the companion
# root when <dir> lies inside a companion's nested source (or a linked worktree of it, wherever that worktree lives),
# else <dir> unchanged. Hooks derive their project directory from CLAUDE_PROJECT_DIR or the session working directory,
# either of which can be the nested source; resolving it here keeps every Stories/ read and write at the companion.
repo_companion_root() {
    local dir="$1" inner src
    if inner="$(repo_inner_source_of "$dir")" && src="$(_rr_inner_source_top "$inner")"; then
        git -C "$(dirname "$src")" rev-parse --show-toplevel 2>/dev/null || dirname "$src"
        return 0
    fi
    printf '%s' "$dir"
}

# repo_workspace_root -> the directory whose .claude/standards.env and Stories/ belong to the caller (empty if none):
# CLAUDE_PROJECT_DIR when set, else the git toplevel of the working directory, resolved UP to the companion root when
# that is a companion's nested source (the story tree and the settings never live inside the source repository).
repo_workspace_root() {
    local top="${CLAUDE_PROJECT_DIR:-}"
    [ -n "$top" ] || top="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || echo "")"
    if [ -n "$top" ]; then top="$(repo_companion_root "$top")"; fi
    printf '%s' "$top"
}

# repo_setting <KEY> -> the value of <KEY> for the caller: the exported environment value when set (a deliberate
# override wins), else the value the workspace root's .claude/standards.env declares (PARSED, never sourced, CWE-829).
# rc 1 when neither has a value, so a caller can try a second key or fail loud naming both places.
# [RiskMitigation RA-02] the settings file is data: a hostile line can never run in the caller's process.
repo_setting() {
    local k="$1" v root
    case "$k" in ''|[!A-Za-z_]*|*[!A-Za-z0-9_]*) return 1 ;; esac
    v="${!k:-}"
    if [ -z "$v" ]; then
        root="$(repo_workspace_root)"
        [ -n "$root" ] && v="$(_rr_getkey "$root/.claude/standards.env" "$k")" || v=""
    fi
    [ -n "$v" ] || return 1
    printf '%s' "$v"
}

# repo_public_source_of <dir> -> print the git toplevel of <dir> and return 0 when it is a companion's nested source
# (or a linked worktree of it) that is PUBLIC-bound: every companion source except one declared PriComPriSou (private
# sources). An unknown or legacy-shape topology counts as public - the stricter reading. rc 1 otherwise. The topology is
# PARSED from the source's own or its companion's standards.env (never sourced, CWE-829); the container env is read
# only when neither file exists (the container's own project).
repo_public_source_of() {
    local dir="$1" top src topo="" f found=0
    top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || echo "")"
    [ -n "$top" ] || return 1
    src="$(_rr_inner_source_top "$top")" || return 1
    for f in "$src/.claude/standards.env" "$(dirname "$src")/.claude/standards.env"; do
        [ -f "$f" ] || continue
        found=1; topo="$(_rr_getkey "$f" KYKLOS_PROJECT_TOPOLOGY || true)"; break
    done
    [ "$found" = 1 ] || topo="${KYKLOS_PROJECT_TOPOLOGY:-}"
    [ "$topo" = PriComPriSou ] && return 1
    printf '%s' "$top"
}

# repo_workflow <dir> -> 'trunk' | 'gitflow' | '__INVALID__'. An invalid declared model returns '__INVALID__' (NOT a
# silent gitflow) so a caller can fail-hard; a valid companion nests (inner=srcwf / outer=trunk); internal->srcwf;
# undeclared->gitflow (back-compat).
repo_workflow() {
    local dir="$1" top
    top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || echo "")"
    [ -z "$top" ] && { printf 'gitflow'; return; }
    # A linked worktree of the nested source follows the source's workflow, wherever the worktree lives.
    local _src; _src="$(_rr_inner_source_top "$top")" && top="$_src"
    local m; m="$(_rr_model "$top")"
    local shape="${m%%|*}" r="${m#*|}"; local srcdir="${r%%|*}" r2="${r#*|}"; local srcwf="${r2%%|*}"
    case "$shape" in
        __INVALID__) printf '__INVALID__' ;;
        companion)   if _rr_is_inner_source "$top" "$srcdir"; then printf '%s' "$srcwf"; else printf 'trunk'; fi ;;
        internal)    printf '%s' "$srcwf" ;;
        "")          printf 'gitflow' ;;   # UNDECLARED -> gitflow (documented back-compat; the no-default gate is separate)
        # [no-fail-open] an UNEXPECTED non-empty shape token must NEVER silently pick a workflow — surface it as
        # __INVALID__ so a caller fails hard (mirrors topology.sh's no-`*)`-default poka-yoke) rather than assuming gitflow.
        *)           printf '__INVALID__' ;;
    esac
}

# routing_check <dir> -> 0 if issue/story routing is consistent with the topology; 1 (with a loud message) if a
# routing knob points at the PUBLIC ARTIFACT project. The load-bearing
# PriSouPubArt invariant: stories/issues live in the PRIVATE SOURCE, NEVER the public artifact facade — routing one
# INTO the facade would leak dev-history into a public-bound repo. The artifact project is DECLARED once, as
# KYKLOS_ARTIFACT_PROJECT (env, or PARSED — never sourced — from the target's .claude/standards.env, like every
# other knob), by the topology interview for PriSouPubArt only.
#   NOT-APPLICABLE (pass) when the topology has NO artifact (any topology other than PriSouPubArt): there is genuinely nothing to
#     contradict — this is "not applicable", not a swallowed failure.
#   FAIL-HARD when the topology IS PriSouPubArt but KYKLOS_ARTIFACT_PROJECT is UNSET — the routing control CANNOT
#     be enforced without knowing the artifact, so the story/issue could silently leak into the public facade. That
#     is a fail-open we REFUSE (project directive: no fail-open / silent fails) — surface it and block.
#   FAIL-HARD when STORY_GITLAB_PROJECT or KYKLOS_ISSUES_PROJECT equals the artifact project — a hand-set knob
#     cannot silently mis-route a story/issue into the public facade.
routing_check() {
    local dir="$1" top art v topo
    top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || echo "")"
    art="${KYKLOS_ARTIFACT_PROJECT:-}"
    topo="${KYKLOS_PROJECT_TOPOLOGY:-}"
    if [ -n "$top" ] && [ -f "$top/.claude/standards.env" ]; then
        v="$(_rr_getkey "$top/.claude/standards.env" KYKLOS_ARTIFACT_PROJECT)" && art="$v"
        v="$(_rr_getkey "$top/.claude/standards.env" KYKLOS_PROJECT_TOPOLOGY)" && topo="$v"
    fi
    if [ -z "$art" ]; then
        # A PriSouPubArt project MUST declare its artifact — without it the routing control is silently absent.
        if [ "$topo" = "PriSouPubArt" ]; then
            printf 'repo-role: ROUTING MISCONFIGURED - topology is PriSouPubArt but KYKLOS_ARTIFACT_PROJECT is UNSET; the routing control cannot protect against leaking a story/issue into the public facade. Declare it (topology-declare.sh --artifact-project <id>) - refusing rather than silently skipping.\n' >&2
            return 1
        fi
        return 0   # no artifact + not PriSouPubArt -> NOT APPLICABLE (only PriSouPubArt has an artifact)
    fi
    local bad=0 knob val
    for knob in STORY_GITLAB_PROJECT KYKLOS_ISSUES_PROJECT; do
        val="${!knob:-}"
        if [ -n "$val" ] && [ "$val" = "$art" ]; then
            printf 'repo-role: ROUTING REFUSED - %s=%s is the PUBLIC ARTIFACT project (KYKLOS_ARTIFACT_PROJECT=%s); a story/issue must route to the PRIVATE SOURCE, never the public facade.\n' "$knob" "$val" "$art" >&2
            bad=1
        fi
    done
    return "$bad"
}

# repo_role <dir> -> companion | source | standalone | artifact | invalid | unknown. For observability + the no-push
# artifact-facade block. `artifact` is a repo declaring KYKLOS_ARTIFACT_FACADE=1 (the public facade, never cloned
# in practice; a mis-declared local clone is then refused by the no-push guard). Parses (never sources) the key.
repo_role() {
    local dir="$1" top
    top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || echo "")"
    [ -z "$top" ] && { printf 'unknown'; return; }
    local facade="${KYKLOS_ARTIFACT_FACADE:-}" v
    if [ -f "$top/.claude/standards.env" ]; then v="$(_rr_getkey "$top/.claude/standards.env" KYKLOS_ARTIFACT_FACADE)" && facade="$v"; fi
    [ "$facade" = "1" ] && { printf 'artifact'; return; }
    # A linked worktree of the nested source IS the source (same public tree), wherever the worktree lives.
    _rr_inner_source_top "$top" >/dev/null && { printf 'source'; return; }
    local m; m="$(_rr_model "$top")"
    local shape="${m%%|*}" r="${m#*|}"; local srcdir="${r%%|*}"
    case "$shape" in
        __INVALID__) printf 'invalid' ;;
        companion)   if _rr_is_inner_source "$top" "$srcdir"; then printf 'source'; else printf 'companion'; fi ;;
        internal)    printf 'standalone' ;;
        *)           printf 'unknown' ;;
    esac
}
