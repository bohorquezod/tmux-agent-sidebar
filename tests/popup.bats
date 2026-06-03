#!/usr/bin/env bats
# popup.bats — tests for popup mode version check

load helpers/common

setup() {
  setup_state_dirs
  # Source popup.sh to load _popup_version_ok; source guard skips main execution.
  source "${BATS_TEST_DIRNAME}/../scripts/popup.sh"
}

teardown() {
  rm -rf "$BATS_TMPDIR/state" "$BATS_TMPDIR/sessions"
}

# ── _popup_version_ok ─────────────────────────────────────────────────────────

@test "_popup_version_ok: 3.3 returns 0" {
  run _popup_version_ok "3.3"
  [ "$status" -eq 0 ]
}

@test "_popup_version_ok: 3.4 returns 0" {
  run _popup_version_ok "3.4"
  [ "$status" -eq 0 ]
}

@test "_popup_version_ok: 4.0 returns 0" {
  run _popup_version_ok "4.0"
  [ "$status" -eq 0 ]
}

@test "_popup_version_ok: 3.3a returns 0 (letter suffix stripped)" {
  run _popup_version_ok "3.3a"
  [ "$status" -eq 0 ]
}

@test "_popup_version_ok: 3.2 returns 1" {
  run _popup_version_ok "3.2"
  [ "$status" -eq 1 ]
}

@test "_popup_version_ok: 3.2a returns 1" {
  run _popup_version_ok "3.2a"
  [ "$status" -eq 1 ]
}

@test "_popup_version_ok: 3.0 returns 1" {
  run _popup_version_ok "3.0"
  [ "$status" -eq 1 ]
}

@test "_popup_version_ok: 2.9 returns 1" {
  run _popup_version_ok "2.9"
  [ "$status" -eq 1 ]
}
