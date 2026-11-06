#!/usr/bin/env bash
# kyklos-proof-table-guard.sh — PreToolUse(Bash). HARD-BLOCK a raw HTTP/client write that posts or edits a PROOF
# TABLE (a `<!-- dogma:story-proof -->` note, or a rendered Quality-Dimension table / Tally) OUTSIDE the `story
# proof` tool. This is the circumvention that let an agent GREEN-WASH a proof: post the table straight to the GitLab
# notes API and thereby skip every proof enforcement the tool applies — the canonical-dimension SET check (so a
# MANDATORY dimension like Adversarial Review can be dropped), the metrics gate, the correlation gate, and the
# adversarial-review token verification.
#
# WHY a guard (not just the close gate): the close/shown gates catch a bad proof at CLOSE, but by then the note is
# already posted and a reader may trust it; and a raw `--apply`-shaped table can carry the marker while dropping a
# row. The ONLY sanctioned writers of a proof note are `story proof --set` / `--apply` (they validate against the
# canonical set before writing). Those invoke curl INSIDE a subprocess, so the top-level command the hook sees
# carries NO client keyword — the tool path is never caught here; only a top-level raw client is.
#
# SCOPE / HONESTY: pure string inspection — a strong DETERRENT for the realistic clients (curl/wget/python/node/
# glab), NOT an airtight sandbox (a compiled client or a body hidden in a shell var can slip). Acceptable because
# `story proof` is the path of least resistance and this makes the raw path HARDER + LOUD.
#
# DEFAULT-ON. FAIL-OPEN: no raw client, no proof-table content, or an escape present => exit 0 (allow).
# FAIL-HARD: the detector library missing, failing to load or lacking a function => every command refused, named.
# Escape for a deliberate migration/admin (e.g. bulk-repairing many stories' notes): env PROOF_RAW_OK=1, or an
# inline `# proof-raw-ok`. Wired: PreToolUse, matcher Bash.
set +e -uo pipefail

INPUT="$(cat || true)"
command -v jq >/dev/null 2>&1 || { echo "[kyklos] WARNING: proof-table guard INERT — jq is missing; the raw-proof-write deterrent is OFF. Install jq." >&2; exit 0; }
cmd="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
[ -n "$cmd" ] || exit 0

_PTG_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The shared detector decides. A guard that cannot load it completely (missing, a syntax error, a function gone), or
# that a library ends while loading, cannot tell a raw write from any other command, so it refuses every command,
# naming the library: lib/guard-prologue.sh arms an EXIT trap that blocks unless the guard reached a decision
# (guard_done). The inline trap below covers the prologue itself being missing or ending the shell.
trap 'printf %s "{\"decision\":\"block\",\"reason\":\"BLOCKED (broken kyklos install): the proof-table guard cannot load lib/guard-prologue.sh, so it refuses every command. Edit and Write still work, so it can be repaired in place. Repair: relaunch the container so the kyklos plugin is installed again.\"}"; exit 0' EXIT
# shellcheck source=lib/guard-prologue.sh
. "$_PTG_HERE/lib/guard-prologue.sh" 2>/dev/null && declare -F guard_arm guard_load guard_load_optional guard_done guard_refuse >/dev/null \
  && guard_arm "the proof-table guard" || exit 0
guard_load "$_PTG_HERE/lib/issue-api-detect.sh" var:IAD_CLIENT_RE var:IAD_NORMALISER_BROKEN iad_normalize_cmd iad_refuse_broken_normaliser || guard_refuse
# Program names and glab flags are read the way the shell and glab read them (c""url, glab -R a/b issue ...).
cmd="$(iad_normalize_cmd "$cmd")"
[[ $cmd == "$IAD_NORMALISER_BROKEN" ]] && { iad_refuse_broken_normaliser "proof-table"; exit 0; }

# In scope only if a supported raw client appears at all (the `story` tool's curl is a subprocess — invisible here).
printf '%s' "$cmd" | grep -Ec "$IAD_CLIENT_RE" >/dev/null || guard_done

# Escapes (deliberate migration/admin). Honour BOTH the env AND an inline assignment in the SAME command (the guard
# inspects the string before it runs, so an inline `PROOF_RAW_OK=1 curl ...` has not taken effect in the guard env yet).
[ "${PROOF_RAW_OK:-}" = "1" ] && guard_done
printf '%s' "$cmd" | grep -cE '(^|[[:space:];&|(])PROOF_RAW_OK=1([[:space:]]|;|&|\||$)' >/dev/null && guard_done
printf '%s' "$cmd" | grep -cE '#[[:space:]]*proof-raw-ok([[:space:]]|$)' >/dev/null && guard_done

block(){ local r="$1"; r="${r//\\/\\\\}"; r="${r//\"/\\\"}"; r="$(printf '%s' "$r" | tr '\n' ' ')"; printf '{"decision":"block","reason":"%s"}' "$r"; guard_done; }

# Detection is GLOBAL over the command (not per-segment), because a rendered Proof Table contains `|` pipes that a
# shell-segment splitter mistakes for pipelines — splitting the client away from the table content and defeating a
# per-segment co-occurrence check (the very evasion an agent could stumble into). Two signatures:
#   (1) the `<!-- dogma:story-proof -->` MARKER — unambiguous WRITE-intent: it only appears when an agent is
#       CONSTRUCTING a proof-note body (a read returns it in the RESPONSE, never in the command). Client + marker => block.
#   (2) the canonical HEADER (`| Quality Dimension |`) or a `Tally: N PROVEN/NOT_PERTINENT` line — these can also
#       appear in a READ/grep, so they block ONLY alongside a WRITE indicator (POST/PUT/PATCH, -d/--data*, -F, a
#       /notes target, a state_event, or `glab issue note|comment|create`).
_ptg_write_indicator='(-X[[:space:]=]*(POST|PUT|PATCH)|--request[[:space:]=]*(POST|PUT|PATCH)|--method[[:space:]=]*(POST|PUT|PATCH)|--data(-raw|-binary|-urlencode)?[[:space:]=]|[[:space:]]-d[[:space:]]|[[:space:]]-F[[:space:]]|/notes|state_event|glab[[:space:]]+issue[[:space:]]+(note|comment|create|new))'
if printf '%s' "$cmd" | grep -cE 'dogma:story-proof' \
 >/dev/null   || { printf '%s' "$cmd" | grep -cE '\|[[:space:]]*Quality Dimension[[:space:]]*\||Tally:[^|]*(PROVEN|NOT_PERTINENT)' \
 >/dev/null        && printf '%s' "$cmd" | grep -cE "$_ptg_write_indicator" >/dev/null; }; then
    block "BLOCKED: writing/editing a Proof Table via a raw curl/wget/python/node/glab call CIRCUMVENTS the SSDLC proof enforcement — it skips the canonical-dimension SET check (so a MANDATORY dimension like Adversarial Review can be silently dropped), the metrics gate, the correlation gate, and the adversarial-review token verification. Generate the Proof Table ONLY with the tool: 'story proof <id> --set \"<Dimension>=VERDICT|evidence|metrics\"' (repeatable), or 'story proof <id> --apply <file>' for a complete table (validated before write). If the tool genuinely cannot express what you need, DO NOT hand-post — send the tooling owner a message with 'agent-msg new --to <owner> ...' (see the ssdlc-agent-msg skill) requesting the improvement; and if the work is stuck, mark the story 'status::blocked' and move to another issue. (Deliberate migration/admin only: set PROOF_RAW_OK=1, or add '# proof-raw-ok' to the command.)"
fi

guard_done
