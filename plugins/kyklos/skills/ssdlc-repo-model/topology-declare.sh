#!/usr/bin/env bash
# topology-declare.sh - the SINGLE sanctioned way to declare a repo's Project Topology.
#
# Writes .claude/standards.env (KYKLOS_PROJECT_TOPOLOGY + the DERIVED legacy knobs the guards read) AND the
# CLAUDE.md '## Repository model' section, ATOMICALLY, from the topology alone. The ssdlc-repo-model interview
# asks the ONE 3-way topology question, then calls this - the agent sets NO knob by hand (zero effort, and the
# derived set can never be internally inconsistent). Idempotent: re-running rewrites the same content.
#
# Usage: topology-declare.sh <PriComPubSou|PriSta|PriSouPubArt|PriComPriSou> [--srcdir <dir>] [--dir <repo-root>]
# See the ssdlc-repo-model SKILL.md + hooks/lib/topology.sh.
set +e -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/../../hooks/lib/topology.sh"   # topology_valid, TOPOLOGY_VALUES

TOPO=""; SRCDIR="Repo"; ROOT="."; ARTIFACT=""; READONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --srcdir)          SRCDIR="${2:-}"; shift 2 || { printf 'topology-declare: missing value after %s\n' "$1" >&2; exit 2; } ;;
    --artifact-project) ARTIFACT="${2:-}"; shift 2 || { printf 'topology-declare: missing value after %s\n' "$1" >&2; exit 2; } ;;   # PriSouPubArt only: the PUBLIC ARTIFACT project id routing must AVOID
    --agent-readonly)  READONLY=1; shift ;;             # companion topologies only: the agent never commits in the nested source
    --dir)             ROOT="${2:-}"; shift 2 || { printf 'topology-declare: missing value after %s\n' "$1" >&2; exit 2; } ;;
    -*)                printf 'topology-declare: unknown flag %s\n' "$1" >&2; exit 2 ;;
    *)                 TOPO="$1"; shift ;;
  esac
done
topology_valid "$TOPO" || { printf 'topology-declare: invalid topology %s (want: %s)\n' "'$TOPO'" "$TOPOLOGY_VALUES" >&2; exit 2; }

# Derive the legacy shape/srcwf the guards read (repo-role.sh maps topology->shape too; writing the derived knobs
# keeps the not-yet-topology-aware guards - branch-cleanup, story-proof - working, consistently by construction).
case "$TOPO" in
  PriComPubSou) SHAPE=companion; SRCWF=gitflow; PROSE="companion + nested public source at \`$SRCDIR/\` (trunk companion / gitflow source)" ;;
  PriComPriSou) SHAPE=companion; SRCWF=gitflow; PROSE="companion + nested PRIVATE source(s) at \`$SRCDIR/\` (trunk companion / gitflow source; the source is private and may be many repos, remotes off our GitLab)" ;;
  PriSta)       SHAPE=internal;  SRCWF=gitflow; PROSE="single private repo, gitflow" ;;
  PriSouPubArt) SHAPE=internal;  SRCWF=gitflow; PROSE="private source; its public artifact is a non-cloned facade published by the pipeline" ;;
esac
# Both companion topologies carry a nested source dir; the standalone/artifact ones do not.
case "$TOPO" in PriComPubSou|PriComPriSou) HAS_SRCDIR=1 ;; *) HAS_SRCDIR=0 ;; esac

# --agent-readonly: the agent treats the nested source as READ-ONLY (the owner commits/pushes there; the agent only
# reads/builds/tests it). It is a STRENGTHENING overlay on the derived gitflow source workflow, so it is accepted ONLY
# for the companion topologies that HAVE a separate source. Declaring it on a standalone/artifact topology would leave
# the agent unable to commit its own work, so refuse up-front (write nothing) rather than declare an unusable state.
if [ "$READONLY" = 1 ]; then
  if [ "$HAS_SRCDIR" != 1 ]; then
    printf 'topology-declare: --agent-readonly applies only to a companion topology with a nested source (PriComPubSou / PriComPriSou); %s has none, so there is no source to make read-only.\n' "'$TOPO'" >&2; exit 2
  fi
  SRCWF=agent-readonly
  PROSE="$PROSE; the agent treats the source as READ-ONLY (agent-readonly: the owner commits/pushes there)"
fi

ENVF="$ROOT/.claude/standards.env"
CLAUDEMD="$ROOT/CLAUDE.md"
mkdir -p "$ROOT/.claude"; touch "$ENVF"

# [poka-yoke: PREVENT] A PriSouPubArt without its public-artifact project is the exact misconfiguration the
# story-routing control (routing_check in hooks/lib/repo-role.sh) must never encounter — so make it IMPOSSIBLE to even declare, up-front, writing NOTHING on refusal
# (no half-declared/unprotected state). Accept an already-declared value (idempotent re-run) else refuse with the fix.
if [ "$TOPO" = "PriSouPubArt" ] && [ -z "$ARTIFACT" ]; then
  ARTIFACT="$(grep -E '^KYKLOS_ARTIFACT_PROJECT=' "$ENVF" 2>/dev/null | tail -n1 | sed -E 's/^[^=]+=//; s/[[:space:]]*#.*$//; s/^"//; s/"$//; s/^'\''//; s/'\''$//')"
  [ -n "$ARTIFACT" ] || { printf 'topology-declare: PriSouPubArt REQUIRES its public artifact project — re-run with --artifact-project <id>. The story-routing control (routing_check in repo-role.sh) cannot protect a private source whose artifact is unknown, so this is refused up-front rather than declared into an unprotected state.\n' >&2; exit 2; }
fi

# idempotent upsert / remove of a KEY=VALUE line (atomic via temp+rename)
_upsert(){ local f="$1" k="$2" v="$3"
  awk -v k="$k" -v v="$v" 'BEGIN{d=0} $0 ~ "^"k"=" {print k"="v; d=1; next} {print} END{if(!d)print k"="v}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"; }
_remove_key(){ local f="$1" k="$2"; [ -f "$f" ] || return 0; grep -vE "^${k}=" "$f" > "$f.tmp" 2>/dev/null; mv "$f.tmp" "$f"; }
_upsert "$ENVF" KYKLOS_PROJECT_TOPOLOGY "$TOPO"
_upsert "$ENVF" KYKLOS_REPO_SHAPE "$SHAPE"
_upsert "$ENVF" KYKLOS_SOURCE_WORKFLOW "$SRCWF"
if [ "$HAS_SRCDIR" = 1 ]; then _upsert "$ENVF" KYKLOS_SOURCE_DIR "$SRCDIR"
else _remove_key "$ENVF" KYKLOS_SOURCE_DIR; fi   # don't leave a stale SOURCE_DIR when re-declaring away from a companion topology
# Derived Routing the PUBLIC ARTIFACT project id (routing must never send a story/issue there). Only meaningful
# for PriSouPubArt: upsert when given; for any other topology it is meaningless, so strip it (never leave it stale).
# For PriSouPubArt re-run WITHOUT the flag, keep the existing value (it is input, like --srcdir, with no default).
if [ "$TOPO" = "PriSouPubArt" ]; then _upsert "$ENVF" KYKLOS_ARTIFACT_PROJECT "$ARTIFACT"   # guaranteed set (prevention check above)
else _remove_key "$ENVF" KYKLOS_ARTIFACT_PROJECT; fi

# write / replace the CLAUDE.md '## Repository model' section (atomic). Strip any existing section first.
SECTION="$(printf '## Repository model\n\n- Topology: **%s** - %s.\n- Derived: KYKLOS_REPO_SHAPE=%s, KYKLOS_SOURCE_WORKFLOW=%s%s%s.\n- Declared once via topology-declare.sh (ssdlc-repo-model interview) - to change, re-run the interview.\n' \
  "$TOPO" "$PROSE" "$SHAPE" "$SRCWF" \
  "$([ "$HAS_SRCDIR" = 1 ] && printf ', KYKLOS_SOURCE_DIR=%s' "$SRCDIR")" \
  "$([ "$TOPO" = PriSouPubArt ] && [ -n "$ARTIFACT" ] && printf ', KYKLOS_ARTIFACT_PROJECT=%s' "$ARTIFACT")")"
if [ -s "$CLAUDEMD" ]; then   # -s (non-empty), not -f: a 0-byte CLAUDE.md takes the create-fresh branch so it keeps its `# CLAUDE.md` title
  # remove an existing '## Repository model' section (up to the next top-level '## ' or EOF), then append fresh.
  # awk program externalized to strip-repo-model-section.awk (kcov mis-counts an inline multi-line awk).
  awk -f "$HERE/strip-repo-model-section.awk" "$CLAUDEMD" > "$CLAUDEMD.tmp"
  # ensure a trailing blank line, then the section
  printf '\n%s' "$SECTION" >> "$CLAUDEMD.tmp"
  mv "$CLAUDEMD.tmp" "$CLAUDEMD"
else
  printf '# CLAUDE.md\n\n%s' "$SECTION" > "$CLAUDEMD"
fi

printf 'topology-declare: %s -> shape=%s srcwf=%s%s ; wrote %s + CLAUDE.md ## Repository model\n' \
  "$TOPO" "$SHAPE" "$SRCWF" "$([ "$HAS_SRCDIR" = 1 ] && printf ' srcdir=%s' "$SRCDIR")" "$ENVF"
