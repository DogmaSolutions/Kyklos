#!/usr/bin/env bash
# story-backend.sh — the story-backend DISPATCHER + selector.
#
# Selects which backend implements the story-backend contract (see story-backend-fs.sh for the full contract
# and the FS implementation). The `story` CLI sources THIS file and then calls the `backend_*` contract
# functions — it never does filesystem I/O inline.
#
# Selection (env var STORY_BACKEND, no default):
#   local    -> the filesystem backend (story-backend-fs.sh).
#   gitlab   -> the GitLab-native backend (story-backend-gitlab.sh): stories are issues.
#   empty    -> a repo whose model was never declared: a clear error, exit 2 (never a silent fallback).
#   <other>  -> a clear error, exit 2 — it does NOT stub fake behavior.
#
# bash + coreutils only. Sourcing this file loads exactly ONE backend impl (or errors); it has no other
# side effects.

STORY_BACKEND_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Each library below must load completely. A failure is RECORDED in STORY_LIB_LOAD_FAILED and loading goes on as
# before, so the hooks that source this seam keep their behaviour; the story tool refuses to run when it is set.
# shellcheck source=../../../hooks/lib/require-lib.sh
. "$STORY_BACKEND_HERE/../../../hooks/lib/require-lib.sh" \
  || { require_lib() { . "$1"; }; STORY_LIB_LOAD_FAILED="${STORY_LIB_LOAD_FAILED:+$STORY_LIB_LOAD_FAILED, }require-lib.sh"; }

# [no-silent-default] NO `:-local` fallback: the backend must be resolved from the repo's declared model (the
# `story` CLI does this before sourcing us) or explicitly exported. An EMPTY backend is a repo whose model was
# never declared — FAIL HARD rather than silently writing to the local filesystem mirror (the source of truth may be
# GitLab). The story CLI's resolver already reads .claude/standards.env; this is the enforcement backstop.
case "${STORY_BACKEND:-}" in
  local)
    # shellcheck source=story-backend-fs.sh
    require_lib "$STORY_BACKEND_HERE/story-backend-fs.sh" || STORY_LIB_LOAD_FAILED="${STORY_LIB_LOAD_FAILED:+$STORY_LIB_LOAD_FAILED, }story-backend-fs.sh"
    ;;
  gitlab)
    # GitLab-native backend: Stories = Issues, id == iid.
    # shellcheck source=story-backend-gitlab.sh
    require_lib "$STORY_BACKEND_HERE/story-backend-gitlab.sh" || STORY_LIB_LOAD_FAILED="${STORY_LIB_LOAD_FAILED:+$STORY_LIB_LOAD_FAILED, }story-backend-gitlab.sh"
    ;;
  "")
    printf 'story: no story backend could be determined — this repo does not declare STORY_BACKEND in its .claude/standards.env and none is exported. Declare the repo model (run the ssdlc-repo-model interview) or export STORY_BACKEND=local|gitlab.\n' >&2
    exit 2
    ;;
  *)
    printf 'story: %s backend not available; STORY_BACKEND must be local or gitlab\n' \
      "${STORY_BACKEND}" >&2
    exit 2
    ;;
esac
