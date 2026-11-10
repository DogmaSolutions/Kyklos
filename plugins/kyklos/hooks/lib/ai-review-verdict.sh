#!/usr/bin/env bash
# ai-review-verdict.sh — make the SSDLC close/merge gates mechanically AWARE of the `ai-review` job on a
# pipeline, so a gate can view its verdict + report and act on it (route the agent to the fix loop) instead of
# treating an AI review as invisible. Sourced by kyklos-story-proof-guard.sh (close-on-green) and
# kyklos-merge-green-guard.sh (merge-on-green).
#
# Transport: PREFERS the KyklosBridge `ci_jobs_list` verb (no container token), falling back to a direct token only
# under the launcher's direct-token exception — all through the shared ci-access.sh seam (the bridge Control Tower CI verbs).
#
# Contract — source this file, then call `ai_review_verdict <pipeline_id> [repository]` (legacy:
# `ai_review_verdict <api> <pid> <token-setting-name> <pipeline_id> [repository]`):
#   On success it PRINTS one tab-separated line:  <status>\t<web_url>
#     status  — the ai-review job's status: success | failed | running | canceled | manual | ...
#     web_url — the job page (where the findings / summary note / log live); may be empty (the bridge's compact job
#               shape omits the URL — callers render a sensible default when it is empty).
#   rc 0 : an `ai-review` job exists on that pipeline (line printed).
#   rc 1 : no ai-review job, or the verdict could not be determined (missing pipeline id / bridge down + no exception /
#          malformed). Callers MUST treat rc 1 as "no ai-review signal" and fall back to their normal behaviour —
#          a coordination-awareness helper must NEVER turn a missing signal into a block.
#
# The <api>/<pid>/<token-setting-name> arguments are accepted for backward compatibility; the transport (bridge vs
# direct) and its scope are now decided by ci-access.sh from the container's configuration, not by these arguments.

# shellcheck source=lib/json-answer.sh
. "$(dirname "${BASH_SOURCE[0]}")/json-answer.sh"   # json_test / json_read: an empty or cut answer is never valid
. "$(dirname "${BASH_SOURCE[0]}")/ci-access.sh"   # the bridge-first CI seam; the token never leaves its helpers

# The name of the GitLab CI job that runs the AI review.
AI_REVIEW_JOB_NAME="ai-review"

ai_review_verdict() {
    # ai_review_verdict <pipeline_id> [repository]: the pipeline id belongs to the project of [repository] (an origin
    # address, as the caller passed to its pipeline lookup), so its jobs are read there, not in the bridge's default
    # project. The legacy four-argument form <api> <pid> <token-setting> <pipeline_id> [repository] is still accepted.
    local pipe repository
    if [ "$#" -ge 4 ]; then pipe="${4:-}"; repository="${5:-}"; else pipe="${1:-}"; repository="${2:-}"; fi
    [ -n "$pipe" ] || return 1
    command -v jq >/dev/null 2>&1 || return 1

    local jobs
    jobs="$(ci_access_jobs "$pipe" "$repository")" || return 1
    printf '%s' "$jobs" | json_test '.jobs | type=="array"' || return 1

    # The LATEST ai-review job (max id — a retried job supersedes its earlier attempt).
    local line
    line="$(printf '%s' "$jobs" | jq -r --arg n "$AI_REVIEW_JOB_NAME" \
              '[.jobs[] | select(.name==$n)] | sort_by(.id) | last | select(.!=null) | "\(.status)\t\(.web_url // "")"' 2>/dev/null || true)"
    [ -n "$line" ] || return 1
    printf '%s\n' "$line"
    return 0
}

# ai_review_note <status> <web_url> — a one-line, agent-facing sentence the gates append to a block reason when
# the ai-review job did NOT pass, pointing at the report + the fix loop. Empty for a passing/absent verdict.
ai_review_note() {
    local status="$1" url="$2"
    case "$status" in
        success|"") printf '' ;;
        failed)
            printf 'The ai-review job on this pipeline FAILED — an AI code review flagged blocking findings (or the reviewer errored). View its report: %s and run the ssdlc-ai-fix-loop skill to work through the findings before retrying (if it is an infra/image error rather than findings, fix that instead).' "${url:-<the ai-review job page>}" ;;
        running|pending|created)
            printf 'The ai-review job on this pipeline is still %s — wait for the AI review to finish (view: %s) before deciding; it may yet flag blocking findings.' "$status" "${url:-<the ai-review job page>}" ;;
        *)
            printf 'The ai-review job on this pipeline is %s (not success) — view its report: %s and run the ssdlc-ai-fix-loop skill if it flagged findings.' "$status" "${url:-<the ai-review job page>}" ;;
    esac
}
