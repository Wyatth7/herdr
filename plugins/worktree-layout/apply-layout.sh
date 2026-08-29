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
RAW="$HERDR_PLUGIN_EVENT_JSON"

# Herdr >= 0.8 wraps every hook payload as {"event":"<name>","data":{...}}.
# Older builds passed the inner object directly. Accept both shapes.
JSON="$(jq -c '.data // .' <<<"$RAW")"

# --- pull values from whichever payload shape arrived ------------------------
# worktree.* events carry .worktree.path (absolute checkout path).
# workspace.* events carry .workspace.worktree.checkout_path instead — note the
# different field name; there is no .workspace.cwd/.root/.path on any version.
DIR="$(jq -r '
    .worktree.path
    // .workspace.worktree.checkout_path
    // .workspace.worktree.path
    // empty' <<<"$JSON")"
WS="$(jq -r '.workspace.workspace_id // .workspace.id // empty' <<<"$JSON")"
TAB="$(jq -r '.workspace.active_tab_id // .workspace.tab_id // empty' <<<"$JSON")"

# If Herdr did not set HERDR_PLUGIN_EVENT, fall back to the envelope's own name
# ("worktree_created" -> "worktree.created"), then to payload shape.
if [ -z "$EVENT" ]; then
  EVENT="$(jq -r '.event // empty' <<<"$RAW")"
  EVENT="${EVENT/_/.}"
fi
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
# layout.apply rejects a request carrying BOTH workspace_id and tab_id
# ("invalid_target: use either tab_id or workspace_id, not both"), so send
# exactly one and delete the other placeholder from layout.json.
request="$(
  jq -c --arg ws "$WS" --arg tab "$TAB" --arg cwd "$DIR" '
      (if $tab == ""
       then .params.workspace_id = $ws | del(.params.tab_id)
       else .params.tab_id = $tab | del(.params.workspace_id)
       end)
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
# NB: match on the error field alone. The old check keyed on id == "apply-layout"
# while layout.json sends id "a", so every error reply was silently swallowed.
if printf '%s' "$reply" | jq -e 'has("error")' >/dev/null 2>&1; then
  log "layout.apply returned an error: $reply"
  release_on_fail
  exit 1
fi

log "applied layout to workspace $WS at $DIR (via $EVENT)"
