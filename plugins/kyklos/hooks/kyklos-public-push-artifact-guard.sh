#!/usr/bin/env bash
# kyklos-public-push-artifact-guard.sh (Kyklos) - PreToolUse Bash. Refuses a `git push` into a PUBLIC source repository
# (a companion's nested source, or a linked worktree of it) when what it pushes carries AI/agent artifacts: Stories/,
# CLAUDE.md, AGENTS.md, .claude/, .codex/ or .devcontainer/, at any depth.
#
# WHY: a public source must stay free of AI artifacts. The write guards stop the agent from writing them there, but a
# commit a TOOL makes (a hook, a script) bypasses those guards, and once pushed the files are on the public remote.
# This is the last barrier before the remote, and it binds every session, including a push-authorized one.
#
# What is checked, for every source ref the push sends (an explicit refspec, `--all`/`--mirror`, `--tags`, or HEAD
# for a bare push):
#   - the tip tree: a ref whose tree CARRIES an artifact;
#   - the commits the remote does not have yet: a commit that ADDS or changes an artifact, even when a later commit
#     removed it again (the history would still publish it).
# A delete pushes no content and is skipped. A private source (topology PriComPriSou), the companion and any standalone
# repository are outside its scope.
#
# DEFAULT-ON; the only opt-out is KYKLOS_PUBLIC_PUSH_GUARD=off (environment or .claude/standards.env).
#
# Wired: PreToolUse, matcher Bash.
set +e -uo pipefail
_PA_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_PA_HERE/lib/git-cmd-detect.sh"   # git_cmd_invokes / git_target_repo_dir: command-position detection (shared)
. "$_PA_HERE/lib/push-refspec.sh"     # push_positionals / push_options / push_is_delete: the shared push parser
. "$_PA_HERE/lib/repo-role.sh"        # repo_public_source_of: the single topology-fed resolver

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
. "$_PA_HERE/lib/standards-env.sh"; load_standards_env "$PROJECT_DIR/.claude/standards.env"
INPUT="$(cat || true)"
CMD_REAL="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
[ -n "$CMD_REAL" ] || CMD_REAL="${INPUT//\\\"/\"}"
HOOK_CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"

# The artifact paths a public source must never carry: a directory component or a file name, at any depth.
PA_ARTIFACT_RE='(^|/)(Stories|\.claude|\.codex|\.devcontainer)/|(^|/)(CLAUDE|AGENTS)\.md$'
PA_MAX_FINDINGS=10

git_cmd_invokes "$CMD_REAL" push || exit 0
push_is_delete "$CMD_REAL" && exit 0
# shellcheck source=lib/control-switch.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/control-switch.sh" 2>/dev/null || true   # kyklos_control_off: the one control-switch reader
kyklos_control_off "${KYKLOS_PUBLIC_PUSH_GUARD:-}" && { echo "[kyklos] public-push artifact guard: skipped (KYKLOS_PUBLIC_PUSH_GUARD=off)." >&2; exit 0; }

_pa_block() {
    local r="$1"
    r="${r//\\/\\\\}"; r="${r//\"/\\\"}"; r="$(printf '%s' "$r" | tr '\n\t' '  ')"
    printf '{"decision":"block","reason":"%s"}' "$r"
    exit 0
}

# An undecidable target (a command substitution feeds it) is refused by kyklos-no-push-guard for every session, so there
# is nothing this guard could judge.
TGT="$(git_target_repo_dir "$CMD_REAL" "$HOOK_CWD" "$PROJECT_DIR" push)"
[ "$TGT" = "__UNDECIDABLE__" ] && exit 0
TOP="$(git -C "$TGT" rev-parse --show-toplevel 2>/dev/null || echo "")"
[ -n "$TOP" ] || exit 0
repo_public_source_of "$TOP" >/dev/null || exit 0

# The remote and the refspecs, from the push's own positionals; the remote defaults to the branch's upstream remote.
_pos="$(push_positionals "$CMD_REAL")"
REMOTE="$(printf '%s\n' "$_pos" | sed -n 1p)"
if [ -z "$REMOTE" ]; then
    _br="$(git -C "$TOP" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
    REMOTE="$(git -C "$TOP" config "branch.$_br.remote" 2>/dev/null || echo origin)"
fi
_opts="$(push_options "$CMD_REAL")"

# The source refs the push sends.
srcs=()
if printf '%s\n' "$_opts" | grep -cxE -e '--all|--mirror|--branches' >/dev/null; then
    while IFS= read -r r; do [ -n "$r" ] && srcs+=("$r"); done < <(git -C "$TOP" for-each-ref --format='%(refname)' refs/heads)
fi
if printf '%s\n' "$_opts" | grep -cxE -e '--tags|--mirror|--follow-tags' >/dev/null; then
    while IFS= read -r r; do [ -n "$r" ] && srcs+=("$r"); done < <(git -C "$TOP" for-each-ref --format='%(refname)' refs/tags)
fi
while IFS= read -r rs; do
    [ -n "$rs" ] || continue
    rs="${rs#+}"; rs="${rs%%:*}"
    [ -n "$rs" ] && srcs+=("$rs")
done < <(printf '%s\n' "$_pos" | sed -n '2,$p')
[ "${#srcs[@]}" -gt 0 ] || srcs=(HEAD)

# [CySec] Prevents CWE-538 / CWE-200 (internal files published to a public repository): every pushed ref's tree and every
# commit the remote lacks are checked for AI artifacts before the push leaves. [RiskMitigation RA-02]
findings=()
for src in "${srcs[@]}"; do
    sha="$(git -C "$TOP" rev-parse --verify -q "$src^{commit}" 2>/dev/null)" || continue
    while IFS= read -r p; do
        [ -n "$p" ] && findings+=("$src carries $p")
    done < <(git -C "$TOP" ls-tree -r --name-only "$sha" 2>/dev/null | grep -E "$PA_ARTIFACT_RE" | head -n "$PA_MAX_FINDINGS")
    while IFS= read -r line; do
        [ -n "$line" ] && findings+=("$line")
    done < <(git -C "$TOP" log --format='@%h' --name-only --diff-filter=d "$sha" --not --remotes="$REMOTE" 2>/dev/null \
               | PA_RE="$PA_ARTIFACT_RE" awk '/^@/ { c = substr($0, 2); next } NF && $0 ~ ENVIRON["PA_RE"] { print "commit " c " adds " $0 }' \
               | head -n "$PA_MAX_FINDINGS")
done
[ "${#findings[@]}" -eq 0 ] && exit 0

list="$(printf '%s\n' "${findings[@]}" | awk '!seen[$0]++' | head -n "$PA_MAX_FINDINGS" | paste -sd ';' - | sed 's/;/; /g')"
_pa_block "Push BLOCKED - $TOP is a PUBLIC source repository and this push would publish AI/agent artifacts (Stories/, CLAUDE.md, AGENTS.md, .claude/, .codex/, .devcontainer/), which belong only in the private companion: $list. Remove them from the branch history (for an unpushed branch: rebuild it without those commits, or move the work to a clean branch) and push again. Such commits are often made by a tool run from a worktree of this repository; run story commands from the companion root. Opt-out (deliberate, greppable): KYKLOS_PUBLIC_PUSH_GUARD=off."
