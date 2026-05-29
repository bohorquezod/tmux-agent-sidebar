#!/usr/bin/env bats
# nav.bats — tests for _resolve_ordinal

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
