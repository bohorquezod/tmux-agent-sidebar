#!/usr/bin/env bats
# cmd.bats — tests for _cmd_hint

load helpers/common

setup() {
  setup_state_dirs
  # Source only cmd.sh (depends on globals set in sidebar.sh context)
  # _cmd_hint has no external deps — safe to source standalone
  source "$(lib_dir)/cmd.sh"
}

teardown() {
  rm -rf "$BATS_TMPDIR/state" "$BATS_TMPDIR/sessions"
}

@test "_cmd_hint: :1 returns session navigation hint" {
  result=$(_cmd_hint ":1")
  [ "$result" = ":N — navigate to session N" ]
}

@test "_cmd_hint: :1.2 returns window navigation hint" {
  result=$(_cmd_hint ":1.2")
  [ "$result" = ":N.M — navigate to session N, window M" ]
}

@test "_cmd_hint: :fi returns filter hint (prefix match, length>=3)" {
  result=$(_cmd_hint ":fi")
  # length 3 required; ":fi" is length 3
  [ "$result" = ":filter working|idle|unread — show matching windows" ]
}

@test "_cmd_hint: :filter returns filter hint" {
  result=$(_cmd_hint ":filter")
  [ "$result" = ":filter working|idle|unread — show matching windows" ]
}

@test "_cmd_hint: :kill returns kill hint" {
  result=$(_cmd_hint ":kill")
  [ "$result" = ":kill [N[.M]] — kill session or window" ]
}

@test "_cmd_hint: :ki returns kill hint (prefix match)" {
  result=$(_cmd_hint ":ki")
  [ "$result" = ":kill [N[.M]] — kill session or window" ]
}

@test "_cmd_hint: :rename returns rename hint" {
  result=$(_cmd_hint ":rename")
  [ "$result" = ":rename [N[.M]] <name> — rename session or window" ]
}

@test "_cmd_hint: :move returns move hint" {
  result=$(_cmd_hint ":move")
  [ "$result" = ":move N N2 — reorder session or window" ]
}

@test "_cmd_hint: :new returns new session hint" {
  result=$(_cmd_hint ":new")
  [ "$result" = ":new — create new session" ]
}

@test "_cmd_hint: : alone (length 1) returns nothing" {
  result=$(_cmd_hint ":")
  [ -z "$result" ]
}

@test "_cmd_hint: numeric :5 returns session navigation hint" {
  result=$(_cmd_hint ":5")
  [ "$result" = ":N — navigate to session N" ]
}

@test "_cmd_hint: :3.1 returns window navigation hint" {
  result=$(_cmd_hint ":3.1")
  [ "$result" = ":N.M — navigate to session N, window M" ]
}
