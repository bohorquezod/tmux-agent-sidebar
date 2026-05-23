# Research: Nested tmux Server Architecture (Issue #17)

## Background

The plugin runs the sidebar UI inside a separate tmux server (`tmux -L tmux-agent-sidebar`).
Each outer window shows the sidebar by running:

```bash
exec tmux -L tmux-agent-sidebar attach-session -t sidebar
```

The sidebar server is created with `-f /dev/null` (empty config) and the outer socket is
injected via `OUTER_TMUX_SOCKET`. The question is whether this nested server is necessary,
or if running `sidebar.sh` as a plain pane in the outer server would be sufficient.

## Finding 1 — Flat pane prototype: config isolation fails without nested server

A flat pane runs `sidebar.sh` directly inside the outer tmux server:

```bash
# toggle.sh (flat approach)
$TMUXBIN split-window -hb -l "$SIDEBAR_W" -t "$_target" \
  "bash $PLUGIN_DIR/scripts/sidebar.sh"
```

The sidebar pane then inherits the **outer server's full configuration**. This breaks in
several ways that are common in real user setups:

| Problem                       | Impact                                                                    |
| ----------------------------- | ------------------------------------------------------------------------- |
| TPM / plugin key bindings     | `j`, `k`, or `Enter` may be rebound by the user's plugins                |
| `mouse on` in `~/.tmux.conf`  | Scrolling in the sidebar triggers tmux copy mode instead of rendering     |
| `status-right` with plugins   | Status bar with battery/git shows below the sidebar pane                  |
| `client-session-changed` hook | Hook fires on every `switch-client` call from the sidebar itself          |
| `window-linked` hooks         | External plugin hooks see sidebar pane changes they should not see        |

Per-pane option overrides (`tmux set-option -p`) mitigate some of this in tmux ≥ 3.1:

```bash
$TMUXBIN set-option -p -t "$NEW_PANE_ID" prefix None
$TMUXBIN set-option -p -t "$NEW_PANE_ID" mouse off
```

But per-pane options **cannot** suppress hooks, status bar, or server-level settings.
TPM and other plugin managers register hooks at server level — there is no per-pane
escape hatch for them.

**Conclusion:** Config isolation requires a separate server. `-f /dev/null` per-pane is
not a tmux concept; the flag only applies when starting a new server process.

## Finding 2 — Shared cursor across windows requires a singleton process

With the nested server, all panes that display the sidebar run:

```bash
exec tmux -L tmux-agent-sidebar attach-session -t sidebar
```

They all attach to the **same session** → the same `sidebar.sh` process → one shared
cursor. Opening the sidebar in window 1 and window 2 shows the same cursor position,
the same spinner frame, and the same unread state.

With flat panes:

- Each window spawns an independent `sidebar.sh` process.
- Cursors diverge immediately on the first `j`/`k` keypress.
- To re-sync, every instance would need to:
  1. Write `SELECTED` to a shared state file on every keypress.
  2. Read and apply that file on every render cycle.
  3. Coordinate via signals (USR1) to force immediate re-render in peer instances.

The state-file approach works but adds ~300 ms of latency (next render poll) before
peers see a cursor update. For a UI that responds to keypresses, that lag is
perceptible. Signal-based coordination requires a pidfile registry and signal fan-out
logic — equivalent complexity to what the nested server provides for free.

**Conclusion:** Shared cursor is a natural property of the singleton nested-server
process. Replicating it in flat panes requires explicit shared-state machinery.

## Finding 3 — `tmux -f /dev/null` and `tmux -u` only help at server start

Both flags apply to the server process, not to individual panes:

- `-f /dev/null` — override config file. Must be passed when the server **starts**. A
  pane created inside an already-running server cannot retroactively change the server's
  config.
- `-u` — force UTF-8 mode. Useful flag, but irrelevant to config isolation.

The only way to run a pane with clean tmux config is to have that pane run inside a
server that was started with `-f /dev/null`. This is exactly what `server-start.sh` does.

There is no `tmux set-option -g` call that can undo a plugin's `bind-key` or `run-shell`
hook after the fact.

**Conclusion:** The nested server is the only reliable way to achieve a clean tmux
environment for the sidebar pane.

## Finding 4 — Startup time: nested server vs flat pane

Measured on Apple Silicon (M1/M2) with bash 3.2:

| Scenario                                       | Time (approx.) |
| ---------------------------------------------- | -------------- |
| First `prefix+m` (server not running)          | 200–400 ms     |
| Subsequent `prefix+m` (server already running) | 40–60 ms       |
| Flat pane: every open                          | 50–80 ms       |

The first open has higher latency because `tmux -L tmux-agent-sidebar new-session` starts
a new OS process. After that, `attach-session` to the running server is nearly identical
in latency to launching a new bash process.

The flat approach removes the one-time startup cost but does not make subsequent opens
faster — in fact, spawning a new `sidebar.sh` and waiting for its first render is
comparable to attaching to an already-rendered session.

**Conclusion:** The startup cost difference is only meaningful for the very first open
per boot. The nested server does not impose an ongoing performance penalty.

## Prototype — `scripts/sidebar-flat.sh`

A working prototype of the flat pane approach is provided in `scripts/sidebar-flat.sh`.
It demonstrates the required changes and their trade-offs:

1. Removed `OUTER_TMUX_SOCKET` detection — the flat pane is always in the outer server.
2. Added per-pane option overrides (`prefix None`, `mouse off`) for tmux ≥ 3.1.
3. Added cursor state sync via `${STATE_DIR}/cursor` file — read on every render.
4. Simplified `_ensure_sidebar` — no server spawn, just check for existing pane.

The prototype is **runnable but not recommended** — see Recommendation below.

To test manually:

```bash
# In an outer tmux session:
bash scripts/sidebar-flat.sh
```

The prototype reveals two regressions not visible from static analysis:

1. **Plugin key conflicts.** With `oh-my-tmux` or `tmux-sensible`, `j` and `k` are
   typically unbound, so navigation works. But `Enter` is often rebound to send a
   literal newline with `send-keys -t`, which breaks the sidebar's jump action.

2. **Status bar pollution.** The sidebar pane has its own entry in `window-status`, which
   confuses status bar plugins that count panes or show pane titles.

## Recommendation: Keep the nested server architecture

The nested tmux server is **necessary and justified**. The three concrete reasons are:

### 1. Config isolation is non-negotiable

The plugin targets users who have complex `~/.tmux.conf` setups — TPM users, oh-my-tmux
users, tmux-sensible users. Running inside the outer server would produce unpredictable
behavior that is impossible to debug or document because it depends on each user's config.
The nested server provides a stable, reproducible environment.

### 2. Shared cursor is a design feature

All sidebar panes showing the same session/window tree with the same cursor position is
not an implementation accident — it is the intended UX. A user switching between windows
should see their sidebar exactly as they left it. The nested server delivers this for
free; flat panes require significant shared-state complexity to replicate.

### 3. Ongoing performance is equivalent

The one-time first-open cost (200–400 ms) is the only real penalty. After the server is
running, subsequent opens are ≤60 ms. The server stays alive as long as at least one
sidebar pane exists, so the startup cost is paid at most once per tmux session.

### Where the architecture can be improved

The research identified a few friction points that are worth addressing independently:

| Issue                                                                    | Suggested fix                                           |
| ------------------------------------------------------------------------ | ------------------------------------------------------- |
| First open latency (200–400 ms)                                          | Pre-start the server in the plugin's `run-shell` hook   |
| `server-start.sh` polls up to 2 s for daemon data file                  | Reduce poll interval to 50 ms; bail earlier if timeout  |
| `OUTER_TMUX_SOCKET` injected via `-e` is invisible to debug sessions     | Document the env var in CLAUDE.md                       |
| `_ensure_sidebar` always calls `server-start.sh` even when server is up | Cache `has-session` result to avoid redundant spawns    |
