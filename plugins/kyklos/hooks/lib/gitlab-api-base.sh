#!/usr/bin/env bash
# gitlab-api-base.sh - the ONE way the Kyklos finds the GitLab API base URL (e.g. https://gitlab.example.com/api/v4).
#
# There is deliberately no built-in default: a tool that talks to GitLab must be told which instance, so nothing
# silently calls a host the user never configured. The base comes from the first of these that is set:
#   1. the tool-specific settings named by the caller (e.g. STORY_GITLAB_API, AI_FIX_API), in order;
#   2. KYKLOS_ISSUES_API, the container-wide setting the launcher provides;
#   3. KYKLOS_GITLAB_URL, the project's GitLab address (without the API path, which is added here once), so a
#      container whose configuration names only that address still finds the API;
#   4. CI_API_V4_URL, which GitLab CI sets in every job.
# With none set, gitlab_api_base prints nothing, writes ONE message naming the settings to stderr and returns 1, so
# every entry point reports the same missing setting.
#
# Usage (after sourcing this file):
#   base="$(gitlab_api_base STORY_GITLAB_API)" || exit 2

# gitlab_api_base [<setting-name>...] -> the API base on stdout (no trailing slash); rc 1 + a message when none is set.
gitlab_api_base() {
    local name value
    for name in "$@" KYKLOS_ISSUES_API KYKLOS_GITLAB_URL CI_API_V4_URL; do
        # Only a valid variable name may be dereferenced (the list comes from callers, never from input).
        [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        value="${!name:-}"
        if [ -n "$value" ]; then
            value="${value%/}"
            # The GitLab address is the server, not its API: the API path is added once (an address that already ends
            # with it is kept), the same rule the launcher applies when it derives the API settings from it.
            if [ "$name" = KYKLOS_GITLAB_URL ]; then
                case "$value" in */api/v4) ;; *) value="$value/api/v4" ;; esac
            fi
            printf '%s' "$value"
            return 0
        fi
    done
    local names="" n
    for n in "$@" KYKLOS_ISSUES_API KYKLOS_GITLAB_URL; do names="${names:+$names, }$n"; done
    printf 'kyklos: no GitLab API base URL is configured. Set %s (for example https://gitlab.example.com/api/v4, or the GitLab address https://gitlab.example.com for KYKLOS_GITLAB_URL); inside GitLab CI, CI_API_V4_URL is used.\n' "$names" >&2
    return 1
}
