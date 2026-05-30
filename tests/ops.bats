#!/usr/bin/env bats
# ops.bats — tests for ops.sh (session/window order, kill, rename)

load helpers/common
load helpers/mock_tmux

# Globals required by ops.sh
setup() {
  setup_state_dirs

  export ORDER_FILE="$BATS_TMPDIR/session_order"
  export DIRTY_FILE="$STATE_DIR/dirty"
  export SOCKET_DIR="$BATS_TMPDIR/sockets"
  export OUTER_SERVER="server1"
  export TMUXBIN="tmux"
  export SELECTED=0
  export CURSOR_ITEM=""
  declare -ga OUTER_TMUX=("tmux")
  declare -ga SESSIONS_FLAT=()
  declare -ga ITEMS_FLAT=()

  mkdir -p "$SOCKET_DIR"

  mock_tmux_setup
  rm -f "$BATS_TMPDIR/tmux_calls.log" "$BATS_TMPDIR/tmux_response"

  source "$(lib_dir)/ops.sh"
}

teardown() {
  rm -rf "$BATS_TMPDIR/state" "$BATS_TMPDIR/sessions" \
         "$BATS_TMPDIR/session_order" "$BATS_TMPDIR/sockets" \
         "$BATS_TMPDIR/mock_bin" "$BATS_TMPDIR/tmux_calls.log" \
         "$BATS_TMPDIR/tmux_response"
}

# ── save_session_order ────────────────────────────────────────────────────────

@test "save_session_order: writes SESSIONS_FLAT entries to ORDER_FILE" {
  SESSIONS_FLAT=("server1|alpha" "server1|beta" "server1|gamma")
  save_session_order
  run cat "$ORDER_FILE"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "server1|alpha" ]
  [ "${lines[1]}" = "server1|beta" ]
  [ "${lines[2]}" = "server1|gamma" ]
}

@test "save_session_order: creates DIRTY_FILE" {
  SESSIONS_FLAT=("server1|sess1")
  rm -f "$DIRTY_FILE"
  save_session_order
  [ -f "$DIRTY_FILE" ]
}

@test "save_session_order: truncates ORDER_FILE before writing" {
  # Pre-populate with stale data
  printf 'server1|stale\n' > "$ORDER_FILE"
  SESSIONS_FLAT=("server1|fresh")
  save_session_order
  run grep -c '' "$ORDER_FILE"
  [ "$output" = "1" ]
}

# ── move_session_up ───────────────────────────────────────────────────────────

@test "move_session_up: swaps session at index 1 with index 0 on same server" {
  SESSIONS_FLAT=("server1|alpha" "server1|beta")
  move_session_up 1
  [ "${SESSIONS_FLAT[0]}" = "server1|beta" ]
  [ "${SESSIONS_FLAT[1]}" = "server1|alpha" ]
}

@test "move_session_up: does nothing when index is 0" {
  SESSIONS_FLAT=("server1|alpha" "server1|beta")
  move_session_up 0
  [ "${SESSIONS_FLAT[0]}" = "server1|alpha" ]
  [ "${SESSIONS_FLAT[1]}" = "server1|beta" ]
}

@test "move_session_up: does not swap sessions on different servers" {
  SESSIONS_FLAT=("server1|alpha" "server2|beta")
  move_session_up 1
  [ "${SESSIONS_FLAT[0]}" = "server1|alpha" ]
  [ "${SESSIONS_FLAT[1]}" = "server2|beta" ]
}

# ── move_session_down ─────────────────────────────────────────────────────────

@test "move_session_down: swaps session at index 0 with index 1 on same server" {
  SESSIONS_FLAT=("server1|alpha" "server1|beta")
  move_session_down 0
  [ "${SESSIONS_FLAT[0]}" = "server1|beta" ]
  [ "${SESSIONS_FLAT[1]}" = "server1|alpha" ]
}

@test "move_session_down: does nothing when index is last" {
  SESSIONS_FLAT=("server1|alpha" "server1|beta")
  move_session_down 1
  [ "${SESSIONS_FLAT[0]}" = "server1|alpha" ]
  [ "${SESSIONS_FLAT[1]}" = "server1|beta" ]
}

@test "move_session_down: does not swap sessions on different servers" {
  SESSIONS_FLAT=("server1|alpha" "server2|beta")
  move_session_down 0
  [ "${SESSIONS_FLAT[0]}" = "server1|alpha" ]
  [ "${SESSIONS_FLAT[1]}" = "server2|beta" ]
}

@test "move_session_down: updates ORDER_FILE after swap" {
  SESSIONS_FLAT=("server1|first" "server1|second")
  move_session_down 0
  run cat "$ORDER_FILE"
  [ "${lines[0]}" = "server1|second" ]
  [ "${lines[1]}" = "server1|first" ]
}

# ── move_window_up ────────────────────────────────────────────────────────────

@test "move_window_up: swaps two adjacent windows in ITEMS_FLAT" {
  ITEMS_FLAT=(
    "S|server1|sess"
    "W|server1|sess|0"
    "W|server1|sess|1"
  )
  SELECTED=2
  move_window_up 2
  [ "${ITEMS_FLAT[1]}" = "W|server1|sess|1" ]
  [ "${ITEMS_FLAT[2]}" = "W|server1|sess|0" ]
}

@test "move_window_up: does nothing when previous item is a session header" {
  ITEMS_FLAT=(
    "S|server1|sess"
    "W|server1|sess|0"
  )
  SELECTED=1
  move_window_up 1
  [ "${ITEMS_FLAT[1]}" = "W|server1|sess|0" ]
}

@test "move_window_up: updates SELECTED to point at moved window" {
  ITEMS_FLAT=(
    "S|server1|sess"
    "W|server1|sess|0"
    "W|server1|sess|1"
  )
  SELECTED=2
  move_window_up 2
  [ "$SELECTED" -eq 1 ]
}

@test "move_window_up: calls tmux swap-window" {
  ITEMS_FLAT=(
    "S|server1|sess"
    "W|server1|sess|0"
    "W|server1|sess|1"
  )
  SELECTED=2
  move_window_up 2
  run tmux_last_call
  [[ "$output" == *"swap-window"* ]]
}

# ── move_window_down ──────────────────────────────────────────────────────────

@test "move_window_down: swaps two adjacent windows in ITEMS_FLAT" {
  ITEMS_FLAT=(
    "S|server1|sess"
    "W|server1|sess|0"
    "W|server1|sess|1"
  )
  SELECTED=1
  move_window_down 1
  [ "${ITEMS_FLAT[1]}" = "W|server1|sess|1" ]
  [ "${ITEMS_FLAT[2]}" = "W|server1|sess|0" ]
}

@test "move_window_down: does nothing when next item is a session header" {
  ITEMS_FLAT=(
    "S|server1|sess-a"
    "W|server1|sess-a|0"
    "S|server1|sess-b"
  )
  SELECTED=1
  move_window_down 1
  [ "${ITEMS_FLAT[1]}" = "W|server1|sess-a|0" ]
}

@test "move_window_down: updates SELECTED to point at moved window" {
  ITEMS_FLAT=(
    "S|server1|sess"
    "W|server1|sess|0"
    "W|server1|sess|1"
  )
  SELECTED=1
  move_window_down 1
  [ "$SELECTED" -eq 2 ]
}

# ── _apply_rename ─────────────────────────────────────────────────────────────

@test "_apply_rename: does nothing when _RENAME_BUF is empty" {
  _RENAME_BUF=""
  _RENAME_ITEM="S|server1|oldsess"
  _RENAME_TYPE="S"
  _apply_rename
  run tmux_call_count
  [ "$output" -eq 0 ]
}

@test "_apply_rename: calls tmux rename-session for session type" {
  _RENAME_BUF="newsess"
  _RENAME_ITEM="S|server1|oldsess"
  _RENAME_TYPE="S"
  SESSIONS_FLAT=("server1|oldsess")
  _apply_rename
  run tmux_last_call
  [[ "$output" == *"rename-session"* ]]
  [[ "$output" == *"newsess"* ]]
}

@test "_apply_rename: updates SESSIONS_FLAT in-place for session rename" {
  _RENAME_BUF="newsess"
  _RENAME_ITEM="S|server1|oldsess"
  _RENAME_TYPE="S"
  SESSIONS_FLAT=("server1|oldsess" "server1|other")
  _apply_rename
  [ "${SESSIONS_FLAT[0]}" = "server1|newsess" ]
  [ "${SESSIONS_FLAT[1]}" = "server1|other" ]
}

@test "_apply_rename: updates current_session file when renaming active session" {
  _RENAME_BUF="newsess"
  _RENAME_ITEM="S|server1|oldsess"
  _RENAME_TYPE="S"
  SESSIONS_FLAT=("server1|oldsess")
  printf '%s' "oldsess" > "${STATE_DIR}/current_session"
  _apply_rename
  run cat "${STATE_DIR}/current_session"
  [ "$output" = "newsess" ]
}

@test "_apply_rename: does not change current_session when renaming non-active session" {
  _RENAME_BUF="newsess"
  _RENAME_ITEM="S|server1|oldsess"
  _RENAME_TYPE="S"
  SESSIONS_FLAT=("server1|oldsess")
  printf '%s' "othersess" > "${STATE_DIR}/current_session"
  _apply_rename
  run cat "${STATE_DIR}/current_session"
  [ "$output" = "othersess" ]
}

@test "_apply_rename: calls tmux rename-window for window type" {
  _RENAME_BUF="newwin"
  _RENAME_ITEM="W|server1|mysess|0"
  _RENAME_TYPE="W"
  SESSIONS_FLAT=()
  _apply_rename
  run tmux_last_call
  [[ "$output" == *"rename-window"* ]]
  [[ "$output" == *"newwin"* ]]
}
