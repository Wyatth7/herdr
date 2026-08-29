#!/usr/bin/env bash
#
# apply-layout.sh — Herdr worktree bootstrap hook (version-safe).
#
# Subscribed (in herdr-plugin.toml) to a broad event set so it fires no matter
# how the worktree was created:
#     worktree.created, worktree.opened, workspace.created, workspace.focused
# plus worktree.removed (to release the claim so a reused path can set up again).
#
# That set is deliberately noisy: workspace.focused fires on EVERY focus, and
# the interactive "new worktree" UI path may emit only workspace.focused. So the
# script:
#   1. resolves the worktree directory from whichever payload arrived;
#   2. for ambiguous workspace.* events, acts only if that directory is a
#      *linked* git worktree (not the main checkout, not a non-git dir);
#   3. dedupes by worktree path with an atomic claim in the plugin state dir,
#      so the layout is applied exactly once per worktree.
#
# No layout JSON lives here — the structure is data-driven from layout.json.
# Requires: bash, jq (>= 1.6, for `walk`), socat, git (>= 2.31, for the guard).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LAYOUT_FILE="$SCRIPT_DIR/layout.json"
log() { printf 'apply-layout: %s\n' "$*" >&2; } # goes to the Herdr plugin log

# --- preconditions -----------------------------------------------------------
command -v jq >/dev/null 2>&1 || {
  log "jq is required"
  exit 1
}
command -v socat >/dev/null 2>&1 || {
  log "socat is required"
  exit 1
}
command -v git >/dev/null 2>&1 || {
  log "git is required"
  exit 1
}
[ -f "$LAYOUT_FILE" ] || {
  log "layout file not found: $LAYOUT_FILE"
  exit 1
}
: "${HERDR_SOCKET_PATH:?HERDR_SOCKET_PATH is unset (run me as a Herdr hook)}"
: "${HERDR_PLUGIN_EVENT_JSON:?HERDR_PLUGIN_EVENT_JSON is unset}"

STATE_DIR="${HERDR_PLUGIN_STATE_DIR:-${TMPDIR:-/tmp}/herdr-worktree-layout}"
mkdir -p "$STATE_DIR/claims"

EVENT="${HERDR_PLUGIN_EVENT:-}"
JSON="$HERDR_PLUGIN_EVENT_JSON"

# --- pull values from whichever payload shape arrived ------------------------
# NOTE: verify these key paths on your Herdr version by logging "$JSON" once
#       (see README). worktree.* events carry .worktree.path; workspace.* events
#       carry the directory under one of the candidates below.
DIR="$(jq -r '
    .worktree.path
    // .workspace.worktree.path
    // .workspace.cwd
    // .workspace.root
    // .workspace.path
    // empty' <<<"$JSON")"
WS="$(jq -r '.workspace.workspace_id // .workspace.id // empty' <<<"$JSON")"
TAB="$(jq -r '.workspace.tab_id // empty' <<<"$JSON")"

# If Herdr did not set HERDR_PLUGIN_EVENT, infer the class from the payload.
if [ -z "$EVENT" ]; then
  if [ "$(jq -r 'has("worktree")' <<<"$JSON")" = "true" ]; then
    EVENT="worktree.inferred"
  else
    EVENT="workspace.inferred"
  fi
fi

claim_key() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | cut -c1-32
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | cut -c1-32
  else
    printf '%s' "$1" | cksum | tr -d ' '
  fi
}

# --- worktree.removed: release the claim, then stop --------------------------
case "$EVENT" in
worktree.removed)
  [ -n "$DIR" ] || exit 0
  rmdir "$STATE_DIR/claims/$(claim_key "$DIR")" 2>/dev/null || true
  log "released claim for $DIR"
  exit 0
  ;;
esac

# --- need a directory to do anything -----------------------------------------
[ -n "$DIR" ] || {
  log "no worktree directory in $EVENT payload; skipping"
  exit 0
}

# --- guard: on ambiguous workspace.* events, act only on a *linked* worktree
is_linked_worktree() {
  local d="$1" gitdir commondir
  gitdir="$(git -C "$d" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  commondir="$(git -C "$d" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  [ "$gitdir" != "$commondir" ] # linked worktrees have a per-worktree gitdir
}
case "$EVENT" in
worktree.created | worktree.opened | worktree.inferred) : ;; # trusted: it's a worktree
*) is_linked_worktree "$DIR" || exit 0 ;;                    # filter focus/other noise
esac

# --- dedupe: atomic claim by path; only the first event does the work --------
CLAIM="$STATE_DIR/claims/$(claim_key "$DIR")"
if ! mkdir "$CLAIM" 2>/dev/null; then
  exit 0 # already claimed (done, or another instance is mid-apply)
fi
release_on_fail() { rmdir "$CLAIM" 2>/dev/null || true; }

[ -n "$WS" ] || {
  log "no workspace_id in $EVENT payload for $DIR"
  release_on_fail
  exit 1
}

# --- build the request from layout.json, injecting the dynamic fields --------
request="$(
  jq -c --arg ws "$WS" --arg tab "$TAB" --arg cwd "$DIR" '
      .params.workspace_id = $ws
      | (if $tab == "" then . else .params.tab_id = $tab end)
      | .params.root |= walk(
          if type == "object" and .type == "pane" then .cwd = $cwd else . end
        )
  ' "$LAYOUT_FILE"
)" || {
  log "failed to build request from layout.json"
  release_on_fail
  exit 1
}

# --- send it and check the reply ---------------------------------------------
reply="$(printf '%s\n' "$request" | socat -t 5 - "UNIX-CONNECT:$HERDR_SOCKET_PATH" 2>/dev/null || true)"
if printf '%s' "$reply" | jq -e 'select(.id == "apply-layout") | has("error")' >/dev/null 2>&1; then
  log "layout.apply returned an error: $reply"
  release_on_fail
  exit 1
fi

log "applied layout to workspace $WS at $DIR (via $EVENT)"
