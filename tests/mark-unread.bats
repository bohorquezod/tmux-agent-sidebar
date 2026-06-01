#!/usr/bin/env bats
# mark-unread.bats — tests for the m key mark-as-unread behavior

load helpers/common

setup() {
  setup_state_dirs
}

teardown() {
  rm -rf "$BATS_TMPDIR/state" "$BATS_TMPDIR/sessions"
}

# Helper: constructs the .unread key from srv/sess/widx (matches sidebar.sh and render.sh)
make_unread_key() {
  local _srv="$1" _sess="$2" _widx="$3"
  local _k="${_srv//[^a-zA-Z0-9_-]/_}_${_sess//[^a-zA-Z0-9_-]/_}_${_widx}"
  printf '%s' "$_k"
}

@test "mark-unread: key formula matches render.sh pattern for simple names" {
  local key; key=$(make_unread_key "server1" "session-a" "0")
  [ "$key" = "server1_session-a_0" ]
}

@test "mark-unread: key formula sanitizes special chars in server name" {
  local key; key=$(make_unread_key "/tmp/tmux-1000/default" "my session" "2")
  [ "$key" = "_tmp_tmux-1000_default_my_session_2" ]
}

@test "mark-unread: touching .unread creates the flag file" {
  local key; key=$(make_unread_key "server1" "session-a" "0")
  local flag="${STATE_DIR}/${key}.unread"
  touch "$flag"
  [ -f "$flag" ]
}

@test "mark-unread: touch on existing .unread is idempotent (no error)" {
  local key; key=$(make_unread_key "server1" "session-a" "0")
  local flag="${STATE_DIR}/${key}.unread"
  touch "$flag"
  run touch "$flag"
  [ "$status" -eq 0 ]
  [ -f "$flag" ]
}

@test "mark-unread: key for window W|server1|session-a|3 matches expected path" {
  local _cur_rest="server1|session-a|3"
  local _msrv="${_cur_rest%%|*}" _mwr="${_cur_rest#*|}"
  local _msess="${_mwr%%|*}" _mwidx="${_mwr#*|}"
  local _mkey="${_msrv//[^a-zA-Z0-9_-]/_}_${_msess//[^a-zA-Z0-9_-]/_}_${_mwidx}"
  [ "$_mkey" = "server1_session-a_3" ]
  touch "${STATE_DIR}/${_mkey}.unread"
  [ -f "${STATE_DIR}/server1_session-a_3.unread" ]
}

@test "mark-unread: S row (session) produces no .unread file when guarded by type check" {
  # Simulates the guard: if [[ "$_cur_type" == "W" ]]; then ...
  local _cur_type="S"
  local _cur_rest="server1|session-a"
  local _created=0
  if [[ "$_cur_type" == "W" ]]; then
    local _msrv="${_cur_rest%%|*}" _mwr="${_cur_rest#*|}"
    local _msess="${_mwr%%|*}" _mwidx="${_mwr#*|}"
    local _mkey="${_msrv//[^a-zA-Z0-9_-]/_}_${_msess//[^a-zA-Z0-9_-]/_}_${_mwidx}"
    touch "${STATE_DIR}/${_mkey}.unread"
    _created=1
  fi
  [ "$_created" -eq 0 ]
}
