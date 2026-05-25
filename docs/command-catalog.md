# Command Catalog — tmux-agent-sidebar

This document defines the complete command catalog for the sidebar's command
buffer and is the authoritative reference for issues #1, #2, #3, and #14.

## Three-mode architecture

The sidebar operates in exactly three modes. Every key press is interpreted
relative to the active mode.

| Mode       | Activated by        | Cancelled by     |
| ---------- | ------------------- | ---------------- |
| Navigation | default (startup)   | —                |
| Search     | `/` in navigation   | `ESC` or `Enter` |
| Command    | `:` or digit in nav | `ESC` or `Enter` |

Modes are mutually exclusive. Only one is active at a time.

## Navigation mode (default)

The cursor moves over sessions and windows. Single-key bindings take immediate
effect — no `Enter` needed.

| Key        | Action                                                |
| ---------- | ----------------------------------------------------- |
| `j` / `↓` | Move cursor down                                      |
| `k` / `↑` | Move cursor up                                        |
| `J`        | Move session or window down in order (reorder)        |
| `K`        | Move session or window up in order (reorder)          |
| `l` / `→` | Enter window mode (descend into session)              |
| `h` / `←` | Exit window mode (back to parent session)             |
| `Enter`    | Navigate to selected item                             |
| `q`        | Detach or close sidebar                               |
| `R`        | Reload sidebar (kill daemon + re-exec)                |
| `x`        | Kill item under cursor — shortcut for `:kill`         |
| `r`        | Rename — opens command buffer pre-filled `:rename `   |
| `/`        | Activate search mode                                  |
| `:`        | Activate command buffer (`:` prefix)                  |
| `1`–`9`   | Activate command buffer with digit as first char      |

### Decision: `r` moves to rename; reload becomes `R`

`r` (lowercase) was previously bound to reload alongside `R`. Since issue #3
assigns `r` to rename, reload is now uppercase-only (`R`). The rename shortcut
pre-fills the command buffer with `:rename ` so the user types only the new
name and presses Enter.

### Decision: `x` is a navigation-mode shortcut for kill

`x` lives in navigation mode — it calls `_exec_cmd :kill` immediately without
requiring the user to type `:kill` in the buffer. This matches the tmux
convention where `x` kills a window/pane from the tree view.

## Search mode

Activated by `/` from navigation mode. Uses a separate `_SEARCH_MODE` flag;
it does not write to `_CMD_BUF`. The display header shows `◈  /query▌`.

| Key         | Action                                 |
| ----------- | -------------------------------------- |
| any char    | Append to query; filter updates live   |
| `j` / `↓`  | Move selection down in results         |
| `k` / `↑`  | Move selection up in results           |
| `Enter`     | Navigate to selected result; exit mode |
| `ESC`       | Cancel; discard query; exit mode       |
| `Backspace` | Delete last query character            |

### Decision: `/` activates search mode directly — not via `_CMD_BUF`

`/` must set `_SEARCH_MODE=1` and never write to `_CMD_BUF`. The current code
has a duplicate `case "/"` in `handle_key` (lines ~919 and ~924) where the
search-mode case is unreachable because the `_CMD_BUF="/"` case fires first.
Issue #1 must fix this by removing the `"/") _CMD_BUF="/" ;;` line and keeping
only the `_SEARCH_MODE` activation.

## Command buffer mode

Activated by `:` (which seeds the buffer with `:`) or by typing a digit (which
seeds the buffer with that digit). The display header shows `◈  input▌`.

All characters typed go into `_CMD_BUF`. `Enter` executes the buffer content.
`ESC` or `Backspace`-to-empty cancels and returns to navigation mode.

### Catalog of buffer commands

| Command     | Alias | Action                                       |
| ----------- | ----- | -------------------------------------------- |
| `N`         | —     | Navigate to session N (ordinal in list)      |
| `N.M`       | —     | Navigate to session N, window M (ordinal)    |
| `:kill`     | `:k`  | Kill session or window under cursor          |
| `:new`      | —     | Create a new session on the active server    |
| `:rename X` | —     | Rename session or window under cursor to `X` |

### Decision: prefixes are disjoint — no ambiguity with letters

The first character determines how the buffer is interpreted on `Enter`:

- **Digit** → numeric navigation (`N` or `N.M`).
- **`:`** → named command (`:kill`, `:new`, `:rename X`).

Single letters that are navigation shortcuts (`j`, `k`, `J`, `K`, `h`, `l`,
`q`, `R`, `x`, `r`) are handled in navigation mode before the buffer is even
checked. Inside an active buffer they are literal text — no conflict arises
because the buffer is only active after an explicit activating key.

## Key-conflict matrix

The table below shows which mode owns each key category. A key is never
handled in two modes simultaneously.

| Key category    | Navigation           | Search          | Command buffer   |
| --------------- | -------------------- | --------------- | ---------------- |
| `j` `k` `J` `K` | owner               | `j`/`k` nav    | literal text     |
| `h` `l` arrows  | owner               | —               | literal text     |
| `Enter`         | owner                | owner           | owner (exec)     |
| `ESC`           | cancel mode          | cancel          | cancel           |
| `q` `R` `x`     | owner               | —               | literal text     |
| `r`             | shortcut → buffer    | —               | literal text     |
| `/`             | → search             | n/a             | literal text     |
| `:`             | → buffer             | —               | literal text     |
| `0`–`9`         | → buffer             | —               | literal text     |
| other printable | ignored              | append to query | append to buffer |

## Implementation mapping

| Issue | Feature             | Scope of change in `sidebar.sh`                                         |
| ----- | ------------------- | ----------------------------------------------------------------------- |
| #1    | Inline search `/`   | Remove `"/") _CMD_BUF="/" ;;`; keep only the `_SEARCH_MODE=1` path     |
| #2    | Kill shortcut `x`   | Add `"x") _exec_cmd :kill ;;` in navigation-mode `case`                |
| #3    | Rename shortcut `r` | Split `r|R` reload: `R` reloads, `r` sets `_CMD_BUF=":rename "`        |
| #14   | Mode separation `:` | Already implemented; this document is the deliverable                   |
