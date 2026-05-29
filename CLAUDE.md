# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Development workflow

No build step. Edit a script and reload with `prefix+M` (triggers `reload-all.sh`), which kills the sidebar server, daemon, and all state, then recreates everything from scratch. For changes to `tmux-agent-sidebar.tmux` itself, also run `tmux source-file tmux-agent-sidebar.tmux` in the outer server.

Run automated tests with `bash tests/run_tests.sh` (requires bats-core — either the submodule at `tests/bats/` or `brew install bats-core`). Validation of UI behavior is manual: open the sidebar (`prefix+m`), navigate sessions and windows, and verify behavior.

## Architecture

The plugin runs across three processes:

**1. Daemon** (`scripts/daemon.sh`) — singleton background process. Queries all tmux servers every ~0.3 s and writes a structured data file to the state directory. Uses an atomic lock via `mkdir` to prevent duplicate instances. Exits when no sidebar clients remain.

**2. Sidebar server** — a separate tmux server (`tmux -L tmux-agent-sidebar`) running with a clean config (`-f /dev/null`). Its single session (`sidebar`) runs `sidebar.sh` in an isolated environment, preventing plugin hooks and user config from interfering with the sidebar UI.

**3. Sidebar client** (`scripts/sidebar.sh`) — the interactive UI. Runs inside the sidebar server, reads the data file, renders the session/window tree, and handles keyboard input. Also manages the `_ensure_sidebar` function that creates or respawns a sidebar pane in the destination window when navigating.

### Library modules (`scripts/lib/`)

Shared code extracted from daemon and sidebar into sourced modules (no shebang — not executed directly):

| Module               | Contents                                                                                |
| -------------------- | --------------------------------------------------------------------------------------- |
| `lib/detect.sh`      | `detect_icon`, `effective_claude_pid`, `agent_sigla`, `check_loop`                      |
| `lib/nav.sh`         | `jump_to`, `jump_next_working`, `jump_next_unread`, `_resolve_ordinal`                  |
| `lib/ops.sh`         | `save_session_order`, `move_session_up/down`, `move_window_up/down`, `_kill_current`, `_apply_rename` |
| `lib/render.sh`      | `render`, `render_help`, `file_mtime`                                                   |
| `lib/cmd.sh`         | `_exec_cmd`, `_cmd_hint`                                                                |
| `lib/sidebar-utils.sh` | `_ensure_sidebar`, `_kill_extra_sidebars`, `_start_animator`, `_sidebar_cleanup`      |

`daemon.sh` sources `lib/detect.sh`. `sidebar.sh` sources all six modules.

Supporting scripts:

- `toggle.sh` — `prefix+m`: open/close/focus the sidebar pane
- `server-start.sh` — idempotent: starts daemon and creates sidebar server session if missing
- `click.sh` — mouse click handler: resolves row→target from `rowmap`, navigates, ensures sidebar in destination
- `reload-all.sh` — `prefix+M`: nuclear reload for development
- `track-session.sh` — `client-session-changed` hook: writes active session to state dir for the active indicator

## State files

All runtime state lives in `${TMPDIR:-/tmp}/agent-sidebar/`. Key files:

| File                          | Purpose                                                     |
| ----------------------------- | ----------------------------------------------------------- |
| `data`                        | Tab-separated snapshot written by daemon (see format below) |
| `dirty`                       | Touch-file: signals daemon to rebuild immediately           |
| `daemon.pid` / `daemon.lock/` | Daemon singleton lock                                       |
| `clients/<key>`               | PID of each running `sidebar.sh` instance                  |
| `current_session`             | Active session name (written by hook and `sidebar.sh`)     |
| `rowmap`                      | Maps display row → `server\|session[\|winidx]` for clicks  |
| `sidebar_width_<server>`      | Persisted pane width per tmux server socket name           |
| `<key>.unread`                | Touch-file: unread notification for a window               |
| `<key>.prev_icon`             | Last icon seen for a window (used to detect transitions)   |

`~/.tmux-sidebar-order` persists user-defined session order across reloads.

## Data file format

Each line is pipe-separated:

```
S|server_name|is_current(0/1)
E|server_name|session_name|is_active(0/1)
W|server_name|session_name|win_idx|win_name|icon|agent_sigla|is_last(0/1)
```

Icon codes in `W` lines — internal codes mapped to display icons by `sidebar.sh`:

| Code | Display | Meaning                                                                    |
| ---- | ------- | -------------------------------------------------------------------------- |
| `E`  | `·`     | Empty / shell — no Claude agent running                                    |
| `W`  | spinner | Working — Claude is actively executing tools or processing                 |
| `I`  | `○`     | Idle — Claude is waiting for the next user message                         |
| `P`  | `?`     | Blocked — permission dialog visible (`[Yes]`, `[No]`, `[Always]`)          |
| `L`  | `↺`     | Loop — ≥3 `W→I` transitions in 10 min with ≥60 s spacing                  |
| `X`  | `✗`     | Crashed — Claude process died while session file shows `status: busy`      |

## Icon detection

`detect_icon` in `lib/detect.sh` returns one of six codes (`E`, `W`, `I`, `P`, `L`, `X`). Detection
runs in priority order:

1. **Session file** (`~/.claude/sessions/<pid>.json`) — primary source. Reads the `status` field:
   `busy → W`; `idle/waiting → I` (or `P` if a permission dialog is also visible in pane content).
   If the process is dead and `status` was `busy`, returns `X`.
2. **Pane title** (OSC 2) — fast fallback for versions without a session file. `✳` = idle (`I`);
   Braille spinner (`U+2800–U+28FF`) = working (`W`).
3. **Content scan** — last resort. Scans the last ~1 500 chars of captured pane output for `⏺`
   (tool execution → `W`), `❯` (prompt → `I`), or permission patterns → `P`.

`L` and `X` are applied after `detect_icon` returns, by `check_loop` and the crashed-detection
block in `build_data`, respectively:

- **`L` (loop)**: `check_loop` records each `W→I` transition timestamp. When ≥3 transitions occur
  within 10 min with ≥60 s between each, the code is overridden to `L`. Resets when the user
  visits the window (`.unread` file is removed).
- **`X` (crashed)**: when a window falls back to `E` but the last known Claude PID has a session
  file with `status: busy`, the code is set to `X` for up to 120 s, then clears automatically.

`sidebar.sh` derives a seventh display state, **unread** (`◉`), from a `.unread` flag file written
when a window transitions `W → I` while the user is not looking at it.

## Bash compatibility

Scripts require **bash 4+** (install via Homebrew: `brew install bash`). The entry point
`tmux-agent-sidebar.tmux` checks the version and aborts with a message if bash 3 is detected.

`scripts/lib/` modules are sourced (not executed) so they have no shebang and inherit the
calling script's bash process. All globals (`STATE_DIR`, `TMUXBIN`, etc.) must be defined
in the parent script before sourcing.
