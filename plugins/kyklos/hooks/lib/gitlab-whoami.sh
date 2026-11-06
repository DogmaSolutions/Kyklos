#!/usr/bin/env bash
# gitlab-whoami.sh — print THIS agent's own GitLab username, resolved mechanically (the resolution order is owned
# by resolve-agent-identity.sh). A tiny convenience wrapper over resolve-agent-identity.sh so the
# agent (or a human) can ask "who am I in GitLab?" WITHOUT hand-crafting an API request. Exit 1 if it cannot be
# resolved. Usage: bash hooks/lib/gitlab-whoami.sh
set +e -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=resolve-agent-identity.sh
. "$HERE/resolve-agent-identity.sh"

if id="$(resolve_agent_identity)" && [ -n "$id" ]; then
    printf '%s\n' "$id"
    exit 0
fi
echo "gitlab-whoami: could not resolve this agent's GitLab identity: the bridge's coordination_whoami could not answer and no fallback applied (see resolve-agent-identity.sh for the order)." >&2
exit 1
