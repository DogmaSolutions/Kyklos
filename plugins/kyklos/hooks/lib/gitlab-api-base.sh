#!/usr/bin/env bash
# gitlab-api-base.sh - the ONE way the Kyklos finds the GitLab API base URL (e.g. https://gitlab.example.com/api/v4).
#
# There is deliberately no built-in default: a tool that talks to GitLab must be told which instance, so nothing
# silently calls a host the user never configured. The base comes from the first of these that is set:
#   1. the tool-specific settings named by the caller (e.g. STORY_GITLAB_API, AI_FIX_API), in order;
#   2. KYKLOS_ISSUES_API, the container-wide setting the launcher provides;
#   3. CI_API_V4_URL, which GitLab CI sets in every job.
# With none set, gitlab_api_base prints nothing, writes ONE message naming the settings to stderr and returns 1, so
# every entry point reports the same missing setting.
#
# Usage (after sourcing this file):
#   base="$(gitlab_api_base STORY_GITLAB_API)" || exit 2

# gitlab_api_base [<setting-name>...] -> the API base on stdout (no trailing slash); rc 1 + a message when none is set.
gitlab_api_base() {
    local name value
    for name in "$@" KYKLOS_ISSUES_API CI_API_V4_URL; do
        # Only a valid variable name may be dereferenced (the list comes from callers, never from input).
        [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        value="${!name:-}"
        if [ -n "$value" ]; then
            printf '%s' "${value%/}"
            return 0
        fi
    done
    local names="" n
    for n in "$@" KYKLOS_ISSUES_API; do names="${names:+$names, }$n"; done
    printf 'kyklos: no GitLab API base URL is configured. Set %s (for example https://gitlab.example.com/api/v4); inside GitLab CI, CI_API_V4_URL is used.\n' "$names" >&2
    return 1
}
