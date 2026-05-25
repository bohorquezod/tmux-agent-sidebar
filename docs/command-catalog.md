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

### Live command hint

When the command buffer is active, a hint line appears immediately below the
input showing what the current partial matches:

```
◈  :ren▌
  · :rename [target] <name> — rename session or window
```

Rules:

- The hint updates on every keystroke.
- If the partial matches exactly one command, show its full signature and
  description.
- If the partial is ambiguous (e.g. `:r` matches `:rename`), show the first
  match.
- If the partial matches no command, show nothing (no hint line).
- The hint disappears when the buffer is cleared or cancelled.

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
pre-fills the command buffer with `:rename ` so the user types only the target
and new name, then presses Enter.

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

### Name filtering (default)

When the query does not match a status keyword, results are filtered by name
(session name or window name, case-insensitive substring match).

### Decision: `/` is always name search — status filtering lives in command buffer

`/query` always filters by name (session or window name, case-insensitive
substring). It never intercepts reserved words, so searching for a session
literally named "working" works correctly.

Status filtering is a separate operation reached via the command buffer:
`:filter <status>`. See the command catalog below.

### Decision: `/` activates search mode directly — not via `_CMD_BUF`

`/` must set `_SEARCH_MODE=1` and never write to `_CMD_BUF`. The current code
has a duplicate `case "/"` in `handle_key` (lines ~919 and ~924) where the
search-mode case is unreachable because the `_CMD_BUF="/"` case fires first.
Issue #1 must fix this by removing the `"/") _CMD_BUF="/" ;;` line and keeping
only the `_SEARCH_MODE` activation.

## Command buffer mode

Activated by `:` (which seeds the buffer with `:`) or by typing a digit (which
seeds the buffer with that digit). The display header shows `◈  input▌` plus a
live hint line (see "Live command hint" above).

All characters typed go into `_CMD_BUF`. `Enter` executes the buffer content.
`ESC` or `Backspace`-to-empty cancels and returns to navigation mode.

### Catalog of buffer commands

| Command              | Alias    | Action                                              |
| -------------------- | -------- | --------------------------------------------------- |
| `N`                  | —        | Navigate to session N (ordinal in list)             |
| `N.M`                | —        | Navigate to session N, window M (ordinal)           |
| `:kill [N[.M]]`      | `:k`     | Kill target; uses cursor if target is omitted       |
| `:new`               | —        | Create a new session on the active server           |
| `:rename [N[.M]] X`  | —        | Rename target to X; uses cursor if target omitted   |
| `:move N N2`         | —        | Move session N to position N2                       |
| `:move N.M N2.M2`   | —        | Move window N.M to position N2.M2                   |
| `:filter <status>`   | —        | Show only sessions/windows matching status          |

### Target resolution for `:kill` and `:rename`

Both commands accept an optional explicit target `N` (session) or `N.M`
(session + window). When the target is omitted, the item currently under the
cursor is used.

Examples:

```
:kill          → kills whatever is under the cursor
:kill 2        → kills session 2
:kill 2.3      → kills window 3 of session 2
:rename newname       → renames cursor item to "newname"
:rename 2 newname     → renames session 2 to "newname"
:rename 2.3 newname   → renames window 3 of session 2 to "newname"
```

### Decision: `:move` uses source→target positions

`J`/`K` hotkeys move the item under the cursor one step at a time. `:move`
accepts an explicit source and destination so any item can jump to any position
in a single command — no cursor movement required.

```
:move 2 4       → moves session 2 to position 4
:move 1.3 1.1   → moves window 1.3 to position 1.1 (first window of session 1)
```

The destination is always interpreted as an ordinal in the same list (sessions
for session moves, windows within the same session for window moves).

### Decision: `:filter` for status filtering — not `/`

`/query` is always a name search. To filter by icon state, use `:filter` in
the command buffer:

| Command            | Shows                                              |
| ------------------ | -------------------------------------------------- |
| `:filter working`  | Sessions with at least one ⚡ window; those windows only |
| `:filter idle`     | Sessions with at least one ○ window; those windows only |
| `:filter unread`   | Sessions with at least one ◉ window; those windows only |

`:filter` replaces the normal session/window list until cancelled with `ESC`
or another `:filter` call. It does not conflict with name search.

### Decision: prefixes are disjoint — no ambiguity with letters

The first character determines how the buffer is interpreted on `Enter`:

- **Digit** → numeric navigation (`N` or `N.M`).
- **`:`** → named command (`:kill`, `:new`, `:rename`, `:move`).

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
| #1    | `:filter <status>`  | Add `:filter` case in `_exec_cmd`; filter `ITEMS_FLAT` by icon in render |
| #2    | Kill shortcut `x`   | Add `"x") _exec_cmd :kill ;;` in navigation-mode `case`                |
| #2    | `:kill [N[.M]]`     | Parse optional target in `_exec_cmd`; fall back to cursor              |
| #3    | Rename shortcut `r` | Split `r|R` reload: `R` reloads, `r` sets `_CMD_BUF=":rename "`        |
| #3    | `:rename [N[.M]] X` | Parse optional target in `_exec_cmd`; fall back to cursor              |
| #14   | Mode separation `:` | Already implemented; this document is the deliverable                   |
| #14   | `:move N N2`        | Add `:move` case in `_exec_cmd`; compute delta and call move_* in loop |
| #14   | Live command hint   | In `render()`: after `_CMD_BUF` header line, add one hint line         |
