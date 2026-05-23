# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Development workflow

No build step. Edit a script and reload with `prefix+M` (triggers `reload-all.sh`), which kills the sidebar server, daemon, and all state, then recreates everything from scratch. For changes to `tmux-agent-sidebar.tmux` itself, also run `tmux source-file tmux-agent-sidebar.tmux` in the outer server.

There are no automated tests. Validation is manual: open the sidebar (`prefix+m`), navigate sessions and windows, and verify behavior.

## Architecture

The plugin runs across three processes:

**1. Daemon** (`scripts/daemon.sh`) — singleton background process. Queries all tmux servers every ~0.3 s and writes a structured data file to the state directory. Uses an atomic lock via `mkdir` to prevent duplicate instances. Exits when no sidebar clients remain.

**2. Sidebar server** — a separate tmux server (`tmux -L tmux-agent-sidebar`) running with a clean config (`-f /dev/null`). Its single session (`sidebar`) runs `sidebar.sh` in an isolated environment, preventing plugin hooks and user config from interfering with the sidebar UI.

**3. Sidebar client** (`scripts/sidebar.sh`) — the interactive UI. Runs inside the sidebar server, reads the data file, renders the session/window tree, and handles keyboard input. Also manages the `_ensure_sidebar` function that creates or respawns a sidebar pane in the destination window when navigating.

Supporting scripts:

- `toggle.sh` — `prefix+m`: open/close/focus the sidebar pane
- `server-start.sh` — idempotent: starts daemon and creates sidebar server session if missing
- `click.sh` — mouse click handler: resolves row→target from `rowmap`, navigates, ensures sidebar in destination
- `reload-all.sh` — `prefix+M`: nuclear reload for development
- `track-session.sh` — `client-session-changed` hook: writes active session to state dir for the active indicator

## State files

All runtime state lives in `${TMPDIR:-/tmp}/agent-sidebar/`. Key files:

| File                       | Purpose                                                     |
| -------------------------- | ----------------------------------------------------------- |
| `data`                     | Tab-separated snapshot written by daemon (see format below) |
| `dirty`                    | Touch-file: signals daemon to rebuild immediately           |
| `daemon.pid` / `daemon.lock/` | Daemon singleton lock                                    |
| `clients/<key>`            | PID of each running `sidebar.sh` instance                  |
| `current_session`          | Active session name (written by hook and `sidebar.sh`)     |
| `rowmap`                   | Maps display row → `server\|session[\|winidx]` for clicks  |
| `sidebar_width`            | Persisted pane width (used when creating new sidebar panes)|
| `<key>.unread`             | Touch-file: unread notification for a window               |
| `<key>.prev_icon`          | Last icon seen for a window (used to detect transitions)   |

`~/.tmux-sidebar-order` persists user-defined session order across reloads.

## Data file format

Each line is pipe-separated:

```
S|server_name|is_current(0/1)
E|server_name|session_name|is_active(0/1)
W|server_name|session_name|win_idx|win_name|icon|is_last(0/1)
```

Icons used in `W` lines: `·` (empty/shell), `⚡` (working), `⏸` (idle/awaiting input).

## Icon detection

`detect_icon` in `daemon.sh` identifies Claude Code state from a pane:

1. **Fast path (pane title)**: Claude Code sets its title to `✳` when idle and a Braille spinner (`U+2800–U+28FF`) when working. This is the reliable path.
2. **Fallback (content scan)**: Looks for `⏺` (tool execution), `❯` (prompt), or `[Yes]/[No]/[Always]` (permission dialogs) in the last ~1500 chars of captured pane output.

## Bash compatibility

All scripts must be compatible with **bash 3.2** (macOS system default). Avoid:

- `mapfile` / `readarray` (bash 4+)
- `declare -A` associative arrays (bash 4+)
- `[[ -v var ]]` variable-set test (bash 4.2+)

Use `IFS= read -r` loops and indexed arrays (`${arr[@]}`) instead.
