#!/usr/bin/env bash
# kyklos-clone-staleness-surface.sh (Kyklos, SessionStart) -- the Kyklos guard HOOKS execute from the versioned
# plugin CACHE pinned in installed_plugins.json; the marketplace CLONE ($HOME/.claude/plugins/marketplaces/dogmasolutions) is
# the sync source that cache is repaired from. If the clone falls behind origin/main, or the pinned cache falls behind
# the clone (e.g. a transient fetch failure at container start left the launcher's boot-time sync a no-op), the WHOLE
# session silently runs STALE guards, and the launcher's stderr WARNING never reaches the AGENT.
#
# This SessionStart check makes the staleness SELF-HEALING and LOUD to the agent:
#   1. a BOUNDED fetch of origin/main (never wedges or delays the launch beyond the timeout);
#   2. if the clone is BEHIND, reset it to origin/main so the NEXT session is clean (self-heal);
#   3. SURFACE it to THIS session via additionalContext -- Claude loads hooks once at start, so the running session
#      may still hold the old guards; the agent is told to restart to load the current guards.
# Also clears / honours the launcher's on-failure marker. Fail-open everywhere: any error -> silent, never a block.
set +e -uo pipefail

MKT="${KYKLOS_MARKETPLACE_CLONE:-$HOME/.claude/plugins/marketplaces/dogmasolutions}"
MARKER="$HOME/.claude/plugins/.kyklos-clone-stale"     # written by the container launcher when its boot-time sync failed
[ -d "$MKT/.git" ] || exit 0

_bounded() { if command -v timeout >/dev/null 2>&1; then timeout "$1" "${@:2}"; else "${@:2}"; fi; }

behind=""
if _bounded 8 git -C "$MKT" fetch origin main >/dev/null 2>&1; then
    _head="$(git -C "$MKT" rev-parse HEAD 2>/dev/null || echo x)"
    _orig="$(git -C "$MKT" rev-parse origin/main 2>/dev/null || echo y)"
    if [ "$_head" != "$_orig" ]; then
        behind="$(git -C "$MKT" rev-list --count HEAD..origin/main 2>/dev/null || echo '?')"
        git -C "$MKT" reset --hard origin/main >/dev/null 2>&1 || true   # self-heal so the NEXT session runs the published hooks
    fi
    rm -f "$MARKER" 2>/dev/null || true                                 # fetch succeeded now -> clear any prior boot-failure marker
fi

# --- CACHE staleness: the ACTUALLY-LOADED hooks (the real gap) --------------------------------------------------
# Claude loads hooks from the version PINNED in installed_plugins.json (a versioned CACHE dir), NOT this clone. The
# clone can be FRESH while the cache is many releases BEHIND: the launcher pins the cache once at BOOT, so releases
# published during the session -- or a boot-time sync failure -- leave the loaded hooks stale. Result: a whole guard
# can be SILENTLY ABSENT from the running session. Detect it against the freshly-synced clone, REPAIR the cache + repin for the next
# session, and SURFACE it. jq-gated; every step guarded so a hiccup never blocks the launch.
cache_stale=""
_ipf="$HOME/.claude/plugins/installed_plugins.json"
_clone_pj="$MKT/plugins/kyklos/.claude-plugin/plugin.json"
if command -v jq >/dev/null 2>&1 && [ -f "$_ipf" ] && [ -f "$_clone_pj" ]; then
    _clonev="$(jq -r '.version // empty' "$_clone_pj" 2>/dev/null || true)"
    _cachev="$(jq -r '.plugins["kyklos@dogmasolutions"][0].version // empty' "$_ipf" 2>/dev/null || true)"
    if [ -n "$_clonev" ] && [ "$_cachev" != "$_clonev" ]; then
        cache_stale="${_cachev:-none} -> ${_clonev}"
        _dest="$HOME/.claude/plugins/cache/dogmasolutions/kyklos/$_clonev"
        [ -f "$_dest/.claude-plugin/plugin.json" ] || { mkdir -p "$_dest" 2>/dev/null && cp -a "$MKT/plugins/kyklos/." "$_dest/" 2>/dev/null; } || true
        _sha="$(git -C "$MKT" rev-parse HEAD 2>/dev/null || echo '')"
        _now="$(_bounded 3 date -u +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || echo '')"
        if jq --arg v "$_clonev" --arg p "$_dest" --arg s "$_sha" --arg t "$_now" \
            '.plugins["kyklos@dogmasolutions"] = [{scope:"user", installPath:$p, version:$v, installedAt:((.plugins["kyklos@dogmasolutions"][0].installedAt)//$t), lastUpdated:$t, gitCommitSha:$s}]' \
            "$_ipf" > "$_ipf.tmp" 2>/dev/null; then
            mv "$_ipf.tmp" "$_ipf" 2>/dev/null || rm -f "$_ipf.tmp" 2>/dev/null
        fi
    fi
fi

# Surface if the clone was behind, the LOADED CACHE was stale (the important one), or the launcher flagged a boot-sync failure.
if [ -n "$behind" ] || [ -n "$cache_stale" ] || [ -f "$MARKER" ]; then
    _detail=""
    [ -n "$behind" ] && _detail="the clone was ${behind} commit(s) behind origin. "
    [ -n "$cache_stale" ] && _detail="${_detail}the LOADED plugin cache was STALE (${cache_stale}) -- so this session may be running OLD or MISSING guards (e.g. the continue-guard). I repinned the cache for the next session. "
    _msg="[kyklos] WARNING: guard STALENESS at session start -- ${_detail}Claude loads hooks ONCE at start, so THIS session still holds the old set; RESTART to load the current guards. (Clone re-synced + cache repinned; next session is clean.)"
    if command -v jq >/dev/null 2>&1; then
        jq -nc --arg m "$_msg" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$m}}'
    else
        printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}' "$_msg"
    fi
fi
exit 0
