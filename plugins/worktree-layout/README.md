# Worktree Layout (Herdr plugin)

Applies a three-pane layout to every git worktree Herdr creates or opens:

```
+---------+---------+-------------------+
|         |         |                   |
| claude  | codex   |      nvim .       |
| (1/4)   | (1/4)   |      (1/2)        |
|         |         |                   |
+---------+---------+-------------------+
```

Each pane opens in the worktree's directory with its command already running.

## Files

| File                | Purpose                                                              |
|---------------------|----------------------------------------------------------------------|
| `herdr-plugin.toml` | Manifest. Subscribes to the event set below and runs the script.     |
| `apply-layout.sh`   | Generic hook: guards, dedupes, injects runtime values, sends layout. |
| `layout.json`       | The declarative `layout.apply` request. **Edit this to change the layout.** |

The script contains no layout JSON — change panes, commands, ratios, or labels
by editing `layout.json` only.

## Why it subscribes to several events

How a worktree is created determines which event Herdr emits. `herdr worktree
create` (CLI) reliably emits `worktree.created`, but on some versions the
interactive "new worktree" UI path emits only `workspace.focused`. To fire
regardless, the plugin subscribes to `worktree.created`, `worktree.opened`,
`workspace.created`, and `workspace.focused`, plus `worktree.removed` for
cleanup.

That set is intentionally noisy — `workspace.focused` fires on *every* focus,
including your main checkout — so the script protects itself two ways:

1. **Guard.** For ambiguous `workspace.*` events it acts only when the
   directory is a *linked* git worktree (git-dir differs from git-common-dir).
   The main checkout, non-git directories, and ordinary focus changes are
   skipped. `worktree.*` events are trusted without the check.
2. **Dedupe.** It takes an atomic claim (a directory named after a hash of the
   worktree path) under `HERDR_PLUGIN_STATE_DIR/claims`. The first event to
   claim a path applies the layout; simultaneous or later duplicate events for
   the same path exit without doing anything, so the layout is applied exactly
   once. `worktree.removed` releases the claim so a path reused by a future
   worktree can be set up again. A failed apply also releases the claim, so a
   subsequent event retries.

## Customizing the layout

`layout.json` is a normal `layout.apply` request. Leave `params.workspace_id`,
`params.tab_id`, and each pane's `cwd` as `null`; the script fills them in per
worktree. `ratio` is the fraction given to `first`, so `0.5` everywhere yields
two quarters on the left and a half on the right. A pane's `command` is an argv
array; the pane closes when that process exits, so wrap it (e.g.
`["sh","-lc","nvim .; exec $SHELL"]`) if you want a shell to survive quitting.

## Install

From a public GitHub repo (this directory at the repo root):

```sh
herdr plugin install <owner>/<repo>
```

Or link a local checkout while developing:

```sh
herdr plugin link /absolute/path/to/worktree-layout
```

## Requirements

- `bash`, `jq` (>= 1.6, for `walk`), `socat`, and `git` (>= 2.31, for the
  linked-worktree guard) on `PATH`.
- Herdr >= 0.8.0.
- The worktree must be created **through Herdr** for any event to fire. A raw
  `git worktree add` run by another tool is invisible to Herdr and triggers
  nothing.

## Verify the payloads on your version

Two things vary by Herdr version and should be confirmed once:

1. **Event name.** The script reads `HERDR_PLUGIN_EVENT` for the event name and
   falls back to inferring it from the payload if that variable is unset.
2. **Field paths.** `worktree.*` events carry `.worktree.path`; `workspace.*`
   events carry the directory under one of several candidate keys the script
   tries (`.workspace.cwd`, `.workspace.root`, `.workspace.path`, ...). If a
   worktree opens with the default single pane instead of the layout,
   temporarily add `log "$JSON"` near the top of `apply-layout.sh`, create a
   worktree each way (CLI and UI), read the output with `herdr plugin log`, and
   adjust the `jq` paths for `DIR`, `WS`, and `TAB` to match.
