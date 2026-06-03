#!/usr/bin/env bats
# ops.bats — tests for move_session_up/down and _apply_rename

load helpers/common
load helpers/mock_tmux

setup() {
  setup_state_dirs
  mock_tmux_setup

  ORDER_FILE="$STATE_DIR/order"
  DIRTY_FILE="$STATE_DIR/dirty"
  local _mock_base="${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-${TMPDIR:-/tmp}}}"
  OUTER_TMUX=("$_mock_base/mock_bin/tmux")
  OUTER_SERVER="main"
  TMUXBIN="$_mock_base/mock_bin/tmux"
  SOCKET_DIR="$STATE_DIR/sockets"

  SESSIONS_FLAT=()
  ITEMS_FLAT=()
  SELECTED=0
  _RENAME_ITEM=""
  _RENAME_BUF=""
  _RENAME_TYPE=""

  # Needed so _apply_rename's `cat current_session` exits 0
  touch "$STATE_DIR/current_session"

  source "$(lib_dir)/ops.sh"
}

teardown() {
  local _base="${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-${TMPDIR:-/tmp}}}"
  rm -rf "$_base/state" "$_base/sessions" "$_base/mock_bin" \
         "$_base/tmux_calls.log" "$_base/tmux_response"
}

# ── save_session_order ─────────────────────────────────────────────────────────

@test "save_session_order: writes each session on its own line" {
  SESSIONS_FLAT=("main|alpha" "main|beta")
  save_session_order
  local lines
  lines=$(cat "$ORDER_FILE")
  [[ "$lines" == $'main|alpha\nmain|beta' ]]
}

@test "save_session_order: touches DIRTY_FILE" {
  SESSIONS_FLAT=("main|alpha")
  save_session_order
  [ -f "$DIRTY_FILE" ]
}

# ── move_session_up ────────────────────────────────────────────────────────────

@test "move_session_up: at index 0 does nothing" {
  SESSIONS_FLAT=("main|alpha" "main|beta")
  move_session_up 0
  [ "${SESSIONS_FLAT[0]}" = "main|alpha" ]
  [ "${SESSIONS_FLAT[1]}" = "main|beta" ]
}

@test "move_session_up: swaps session with the one above it" {
  SESSIONS_FLAT=("main|alpha" "main|beta")
  move_session_up 1
  [ "${SESSIONS_FLAT[0]}" = "main|beta" ]
  [ "${SESSIONS_FLAT[1]}" = "main|alpha" ]
}

@test "move_session_up: saves new order to ORDER_FILE" {
  SESSIONS_FLAT=("main|alpha" "main|beta")
  move_session_up 1
  grep -qF "main|beta" "$ORDER_FILE"
  head -1 "$ORDER_FILE" | grep -qF "main|beta"
}

@test "move_session_up: cross-server swap is blocked" {
  SESSIONS_FLAT=("main|session-a" "other|session-b")
  move_session_up 1
  [ "${SESSIONS_FLAT[0]}" = "main|session-a" ]
  [ "${SESSIONS_FLAT[1]}" = "other|session-b" ]
}

# ── move_session_down ──────────────────────────────────────────────────────────

@test "move_session_down: at last index does nothing" {
  SESSIONS_FLAT=("main|alpha" "main|beta")
  move_session_down 1
  [ "${SESSIONS_FLAT[0]}" = "main|alpha" ]
  [ "${SESSIONS_FLAT[1]}" = "main|beta" ]
}

@test "move_session_down: swaps session with the one below it" {
  SESSIONS_FLAT=("main|alpha" "main|beta")
  move_session_down 0
  [ "${SESSIONS_FLAT[0]}" = "main|beta" ]
  [ "${SESSIONS_FLAT[1]}" = "main|alpha" ]
}

@test "move_session_down: saves new order to ORDER_FILE" {
  SESSIONS_FLAT=("main|alpha" "main|beta")
  move_session_down 0
  grep -qF "main|beta" "$ORDER_FILE"
  head -1 "$ORDER_FILE" | grep -qF "main|beta"
}

@test "move_session_down: cross-server swap is blocked" {
  SESSIONS_FLAT=("main|session-a" "other|session-b")
  move_session_down 0
  [ "${SESSIONS_FLAT[0]}" = "main|session-a" ]
  [ "${SESSIONS_FLAT[1]}" = "other|session-b" ]
}

# ── _apply_rename ──────────────────────────────────────────────────────────────

@test "_apply_rename: no-op when _RENAME_BUF is empty" {
  _RENAME_BUF=""
  _RENAME_ITEM="S|main|old-session"
  _RENAME_TYPE="S"
  SESSIONS_FLAT=("main|old-session")
  _apply_rename
  # tmux must not be called
  local count
  count=$(tmux_call_count)
  [ "$count" -eq 0 ]
}

@test "_apply_rename: calls rename-session with correct args for session rename" {
  _RENAME_ITEM="S|main|old-session"
  _RENAME_TYPE="S"
  _RENAME_BUF="new-session"
  SESSIONS_FLAT=("main|old-session")
  _apply_rename
  local last
  last=$(tmux_last_call)
  [ "$last" = "rename-session -t old-session new-session" ]
}

@test "_apply_rename: updates SESSIONS_FLAT in-place for session rename" {
  _RENAME_ITEM="S|main|old-session"
  _RENAME_TYPE="S"
  _RENAME_BUF="new-session"
  SESSIONS_FLAT=("main|old-session")
  _apply_rename
  [ "${SESSIONS_FLAT[0]}" = "main|new-session" ]
}

@test "_apply_rename: propagates rename to current_session file" {
  printf 'old-session' > "$STATE_DIR/current_session"
  _RENAME_ITEM="S|main|old-session"
  _RENAME_TYPE="S"
  _RENAME_BUF="new-session"
  SESSIONS_FLAT=("main|old-session")
  _apply_rename
  [ "$(cat "$STATE_DIR/current_session")" = "new-session" ]
}

@test "_apply_rename: calls rename-window with correct args" {
  _RENAME_ITEM="W|main|my-session|2"
  _RENAME_TYPE="W"
  _RENAME_BUF="new-win-name"
  _apply_rename
  local last
  last=$(tmux_last_call)
  [ "$last" = "rename-window -t my-session:2 new-win-name" ]
}

@test "_apply_rename: touches DIRTY_FILE after rename" {
  _RENAME_ITEM="S|main|old-session"
  _RENAME_TYPE="S"
  _RENAME_BUF="new-session"
  SESSIONS_FLAT=("main|old-session")
  _apply_rename
  [ -f "$DIRTY_FILE" ]
}
