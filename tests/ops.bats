#!/usr/bin/env bats
# ops.bats — tests for _apply_rename

load helpers/common

setup() {
  setup_state_dirs
  export DIRTY_FILE="$STATE_DIR/dirty"
  export SESSIONS_FLAT=()
  export OUTER_SERVER="default"
  export SOCKET_DIR="$BATS_TMPDIR"

  # current_session must exist so `cat` in _apply_rename returns exit code 0
  touch "${STATE_DIR}/current_session"

  # Fake tmux: logs "subcommand arg1 arg2 ..." to a file per test
  _FAKE_TMUX_LOG="$STATE_DIR/tmux_calls"
  _FAKE_TMUX="$STATE_DIR/fake_tmux"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\n' "$_FAKE_TMUX_LOG" > "$_FAKE_TMUX"
  chmod +x "$_FAKE_TMUX"
  export OUTER_TMUX=("$_FAKE_TMUX")
  export TMUXBIN="$_FAKE_TMUX"

  export _RENAME_ITEM=""
  export _RENAME_BUF=""
  export _RENAME_TYPE=""

  source "$(lib_dir)/ops.sh"
}

teardown() {
  rm -rf "$BATS_TMPDIR/state" "$BATS_TMPDIR/sessions"
}

# ── _apply_rename ─────────────────────────────────────────────────────────────

@test "_apply_rename: does nothing when _RENAME_BUF is empty" {
  _RENAME_ITEM="S|default|mysession"
  _RENAME_TYPE="S"
  _RENAME_BUF=""
  _apply_rename
  [ ! -f "$DIRTY_FILE" ]
}

@test "_apply_rename: calls rename-session for session items" {
  _RENAME_ITEM="S|default|old-name"
  _RENAME_TYPE="S"
  _RENAME_BUF="new-name"
  SESSIONS_FLAT=("default|old-name")
  _apply_rename
  grep -q "rename-session -t old-name new-name" "$_FAKE_TMUX_LOG"
}

@test "_apply_rename: calls rename-window for window items" {
  _RENAME_ITEM="W|default|mysession|2"
  _RENAME_TYPE="W"
  _RENAME_BUF="new-win"
  _apply_rename
  grep -q "rename-window -t mysession:2 new-win" "$_FAKE_TMUX_LOG"
}

@test "_apply_rename: updates SESSIONS_FLAT entry after session rename" {
  _RENAME_ITEM="S|default|old-name"
  _RENAME_TYPE="S"
  _RENAME_BUF="new-name"
  SESSIONS_FLAT=("default|other" "default|old-name")
  _apply_rename
  [ "${SESSIONS_FLAT[0]}" = "default|other" ]
  [ "${SESSIONS_FLAT[1]}" = "default|new-name" ]
}

@test "_apply_rename: updates current_session file when renaming active session" {
  _RENAME_ITEM="S|default|active-sess"
  _RENAME_TYPE="S"
  _RENAME_BUF="renamed-sess"
  SESSIONS_FLAT=("default|active-sess")
  printf '%s' "active-sess" > "${STATE_DIR}/current_session"
  _apply_rename
  result=$(cat "${STATE_DIR}/current_session")
  [ "$result" = "renamed-sess" ]
}

@test "_apply_rename: does not update current_session when renaming inactive session" {
  _RENAME_ITEM="S|default|other-sess"
  _RENAME_TYPE="S"
  _RENAME_BUF="renamed"
  SESSIONS_FLAT=("default|other-sess")
  printf '%s' "active-sess" > "${STATE_DIR}/current_session"
  _apply_rename
  result=$(cat "${STATE_DIR}/current_session")
  [ "$result" = "active-sess" ]
}

@test "_apply_rename: touches DIRTY_FILE after session rename" {
  _RENAME_ITEM="S|default|mysession"
  _RENAME_TYPE="S"
  _RENAME_BUF="newname"
  SESSIONS_FLAT=("default|mysession")
  _apply_rename
  [ -f "$DIRTY_FILE" ]
}

@test "_apply_rename: touches DIRTY_FILE after window rename" {
  _RENAME_ITEM="W|default|mysession|0"
  _RENAME_TYPE="W"
  _RENAME_BUF="newwin"
  _apply_rename
  [ -f "$DIRTY_FILE" ]
}
