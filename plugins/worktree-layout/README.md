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

Each pane opens in the worktree's directory preventing you from needing to manage worktrees by hand. 

Personally, I hate the friction of manually creating and managing worktrees in any type of agentic program 
(Claude, Supacode, Orca, etc.), so this is useful when skills and prompts tell my agent to create a new worktree.

Please note that the creation of worktrees MUST be handled through the Herdr CLI. Herdr only listens for it's own `herdr worktree ...` events. 
Using `git worktree ...` commands will not run this plugin.

## Install

From a public GitHub repo (this directory at the repo root):

```sh
 herdr plugin install Wyatth7/herdr/plugins/worktree-layout

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
