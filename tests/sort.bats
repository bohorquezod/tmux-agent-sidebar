#!/usr/bin/env bats
# sort.bats — tests for _sessions_sort_alpha and _windows_sort_alpha

load helpers/common

setup() {
  setup_state_dirs

  # Declare globals required by render.sh helpers
  declare -ga SESSIONS_FLAT=()
  declare -gA _win_meta=()

  source "$(lib_dir)/render.sh"
}

teardown() {
  rm -rf "$BATS_TMPDIR/state" "$BATS_TMPDIR/sessions"
}

# ── _sessions_sort_alpha ──────────────────────────────────────────────────────

@test "_sessions_sort_alpha: sorts sessions alphabetically by name" {
  SESSIONS_FLAT=("srv|zebra" "srv|alpha" "srv|mango")
  _sessions_sort_alpha
  [ "${SESSIONS_FLAT[0]}" = "srv|alpha" ]
  [ "${SESSIONS_FLAT[1]}" = "srv|mango" ]
  [ "${SESSIONS_FLAT[2]}" = "srv|zebra" ]
}

@test "_sessions_sort_alpha: already sorted stays sorted" {
  SESSIONS_FLAT=("srv|aaa" "srv|bbb" "srv|ccc")
  _sessions_sort_alpha
  [ "${SESSIONS_FLAT[0]}" = "srv|aaa" ]
  [ "${SESSIONS_FLAT[1]}" = "srv|bbb" ]
  [ "${SESSIONS_FLAT[2]}" = "srv|ccc" ]
}

@test "_sessions_sort_alpha: single element is a no-op" {
  SESSIONS_FLAT=("srv|only")
  _sessions_sort_alpha
  [ "${#SESSIONS_FLAT[@]}" = "1" ]
  [ "${SESSIONS_FLAT[0]}" = "srv|only" ]
}

@test "_sessions_sort_alpha: empty array is a no-op" {
  SESSIONS_FLAT=()
  _sessions_sort_alpha
  [ "${#SESSIONS_FLAT[@]}" = "0" ]
}

@test "_sessions_sort_alpha: sessions across different servers sort by server then session name" {
  SESSIONS_FLAT=("srv1|zebra" "srv2|apple" "srv1|cherry")
  _sessions_sort_alpha
  [ "${SESSIONS_FLAT[0]}" = "srv1|cherry" ]
  [ "${SESSIONS_FLAT[1]}" = "srv1|zebra" ]
  [ "${SESSIONS_FLAT[2]}" = "srv2|apple" ]
}

# ── _windows_sort_alpha ───────────────────────────────────────────────────────

@test "_windows_sort_alpha: sorts windows alphabetically by name" {
  _win_meta["srv|sess|2"]="zebra|idle||1"
  _win_meta["srv|sess|0"]="alpha|idle||0"
  _win_meta["srv|sess|1"]="mango|idle||0"
  local _wins=(2 0 1)
  _windows_sort_alpha "srv" "sess" _wins
  [ "${_wins[0]}" = "0" ]
  [ "${_wins[1]}" = "1" ]
  [ "${_wins[2]}" = "2" ]
}

@test "_windows_sort_alpha: already sorted stays sorted" {
  _win_meta["srv|sess|0"]="aaa|idle||0"
  _win_meta["srv|sess|1"]="bbb|idle||1"
  local _wins=(0 1)
  _windows_sort_alpha "srv" "sess" _wins
  [ "${_wins[0]}" = "0" ]
  [ "${_wins[1]}" = "1" ]
}

@test "_windows_sort_alpha: single window is a no-op" {
  _win_meta["srv|sess|0"]="only|idle||1"
  local _wins=(0)
  _windows_sort_alpha "srv" "sess" _wins
  [ "${#_wins[@]}" = "1" ]
  [ "${_wins[0]}" = "0" ]
}

@test "_windows_sort_alpha: windows with missing meta keep their index" {
  # Missing meta → name resolves to empty string → sorts first
  _win_meta["srv|sess|1"]="beta|idle||1"
  local _wins=(1 0)
  _windows_sort_alpha "srv" "sess" _wins
  # empty name sorts before "beta"
  [ "${_wins[0]}" = "0" ]
  [ "${_wins[1]}" = "1" ]
}
