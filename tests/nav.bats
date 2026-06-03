#!/usr/bin/env bats
# nav.bats — tests for _resolve_ordinal, jump_next_server, jump_prev_server

load helpers/common

setup() {
  setup_state_dirs

  # Source nav.sh — defines _resolve_ordinal and jump helpers
  source "$(lib_dir)/nav.sh"

  # Build a minimal ITEMS_FLAT for tests:
  #   S|server1|session-a         (session 1)
  #   W|server1|session-a|0       (window 1.1)
  #   W|server1|session-a|1       (window 1.2)
  #   S|server1|session-b         (session 2)
  #   W|server1|session-b|0       (window 2.1)
  ITEMS_FLAT=(
    "S|server1|session-a"
    "W|server1|session-a|0"
    "W|server1|session-a|1"
    "S|server1|session-b"
    "W|server1|session-b|0"
  )
}

teardown() {
  rm -rf "$BATS_TMPDIR/state" "$BATS_TMPDIR/sessions"
}

# ── _resolve_ordinal ──────────────────────────────────────────────────────────

@test "_resolve_ordinal: session 1 finds first S entry" {
  _resolve_ordinal 1
  [ "$_ri_ct" = "S" ]
  [ "$_ri_cr" = "server1|session-a" ]
}

@test "_resolve_ordinal: session 2 finds second S entry" {
  _resolve_ordinal 2
  [ "$_ri_ct" = "S" ]
  [ "$_ri_cr" = "server1|session-b" ]
}

@test "_resolve_ordinal: window 1.1 finds correct W entry" {
  _resolve_ordinal 1 1
  [ "$_ri_ct" = "W" ]
  [ "$_ri_cr" = "server1|session-a|0" ]
}

@test "_resolve_ordinal: window 1.2 finds second W of session 1" {
  _resolve_ordinal 1 2
  [ "$_ri_ct" = "W" ]
  [ "$_ri_cr" = "server1|session-a|1" ]
}

@test "_resolve_ordinal: window 2.1 finds first W of session 2" {
  _resolve_ordinal 2 1
  [ "$_ri_ct" = "W" ]
  [ "$_ri_cr" = "server1|session-b|0" ]
}

@test "_resolve_ordinal: session out of range returns 1" {
  run _resolve_ordinal 99
  [ "$status" -eq 1 ]
}

@test "_resolve_ordinal: window out of range returns 1" {
  run _resolve_ordinal 1 99
  [ "$status" -eq 1 ]
}

@test "_resolve_ordinal: session 0 (invalid ordinal) returns 1" {
  run _resolve_ordinal 0
  [ "$status" -eq 1 ]
}

@test "_resolve_ordinal: globals _ri_ci, _ri_ct, _ri_cr set correctly for session" {
  _resolve_ordinal 2
  [ "$_ri_ci" = "S|server1|session-b" ]
  [ "$_ri_ct" = "S" ]
  [ "$_ri_cr" = "server1|session-b" ]
}

@test "_resolve_ordinal: globals _ri_ci, _ri_ct, _ri_cr set correctly for window" {
  _resolve_ordinal 2 1
  [ "$_ri_ci" = "W|server1|session-b|0" ]
  [ "$_ri_ct" = "W" ]
  [ "$_ri_cr" = "server1|session-b|0" ]
}

# ── mark_all_read ─────────────────────────────────────────────────────────────

@test "mark_all_read: removes all .unread files from STATE_DIR" {
  touch "${STATE_DIR}/server1_session-a_0.unread"
  touch "${STATE_DIR}/server1_session-a_1.unread"
  touch "${STATE_DIR}/server1_session-b_0.unread"
  mark_all_read
  local _count
  _count=$(find "$STATE_DIR" -name "*.unread" | wc -l)
  [ "$_count" -eq 0 ]
}

@test "mark_all_read: no-op when no .unread files exist" {
  run mark_all_read
  [ "$status" -eq 0 ]
}

@test "mark_all_read: does not remove non-.unread files" {
  touch "${STATE_DIR}/server1_session-a_0.prev_icon"
  touch "${STATE_DIR}/server1_session-a_0.unread"
  mark_all_read
  [ -f "${STATE_DIR}/server1_session-a_0.prev_icon" ]
}

# ── jump_next_server / jump_prev_server ───────────────────────────────────────
# Multi-server fixture:
#   idx 0  S|server1|session-a   ← server1 section start
#   idx 1  W|server1|session-a|0
#   idx 2  S|server1|session-b
#   idx 3  W|server1|session-b|0
#   idx 4  S|server2|session-c   ← server2 section start
#   idx 5  W|server2|session-c|0
#   idx 6  S|server2|session-d
#   idx 7  S|server3|session-e   ← server3 section start

setup_multi_server() {
  ITEMS_FLAT=(
    "S|server1|session-a"
    "W|server1|session-a|0"
    "S|server1|session-b"
    "W|server1|session-b|0"
    "S|server2|session-c"
    "W|server2|session-c|0"
    "S|server2|session-d"
    "S|server3|session-e"
  )
}

@test "jump_next_server: from server1 goes to server2 section start" {
  setup_multi_server
  SELECTED=0
  jump_next_server
  [ "$SELECTED" -eq 4 ]
}

@test "jump_next_server: from server2 goes to server3 section start" {
  setup_multi_server
  SELECTED=4
  jump_next_server
  [ "$SELECTED" -eq 7 ]
}

@test "jump_next_server: from server3 wraps to server1" {
  setup_multi_server
  SELECTED=7
  jump_next_server
  [ "$SELECTED" -eq 0 ]
}

@test "jump_next_server: from window inside server1 goes to server2" {
  setup_multi_server
  SELECTED=1
  jump_next_server
  [ "$SELECTED" -eq 4 ]
}

@test "jump_next_server: single server does nothing" {
  SELECTED=2
  jump_next_server
  [ "$SELECTED" -eq 2 ]
}

@test "jump_prev_server: from server2 goes to server1 section start" {
  setup_multi_server
  SELECTED=4
  jump_prev_server
  [ "$SELECTED" -eq 0 ]
}

@test "jump_prev_server: from server3 goes to server2 section start" {
  setup_multi_server
  SELECTED=7
  jump_prev_server
  [ "$SELECTED" -eq 4 ]
}

@test "jump_prev_server: from server1 wraps to server3" {
  setup_multi_server
  SELECTED=0
  jump_prev_server
  [ "$SELECTED" -eq 7 ]
}

@test "jump_prev_server: from window inside server2 goes to server1" {
  setup_multi_server
  SELECTED=5
  jump_prev_server
  [ "$SELECTED" -eq 0 ]
}

@test "jump_prev_server: single server does nothing" {
  SELECTED=2
  jump_prev_server
  [ "$SELECTED" -eq 2 ]
}
