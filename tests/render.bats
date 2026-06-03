#!/usr/bin/env bats
# render.bats — tests for render() and file_mtime()

load helpers/common
load helpers/mock_tmux

setup() {
  setup_state_dirs
  mock_tmux_setup

  # Colors — empty so output is plain text (greppable without ANSI noise)
  PU="" R="" WH="" GR="" CY="" YL="" RD="" BG="" G=""

  # Spinner: simple ASCII strings; index 1 is used on the first render call
  # because render increments _SPIN_FRAME before rendering.
  _SPINNER=("[W0]" "[W1]" "[W2]" "[W3]" "[W4]" "[W5]" "[W6]" "[W7]" "[W8]" "[W9]")
  _SPIN_FRAME=0

  # Terminal size fallback (stty size fails without a real TTY)
  export COLUMNS=40
  export LINES=24

  # State paths
  DATA_FILE="$STATE_DIR/data"
  ORDER_FILE="$STATE_DIR/order"
  DIRTY_FILE="$STATE_DIR/dirty"

  # Outer server — set to mock so list-windows is never called with a live server
  local _mock_base="${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-${TMPDIR:-/tmp}}}"
  OUTER_TMUX=("$_mock_base/mock_bin/tmux")
  OUTER_SERVER="main"
  WIN_SESS=""
  WIN_IDX=""

  # Mode flags
  _HELP_MODE=0
  _SEARCH_MODE=0
  _RENDER_DATA_MTIME=""
  SELECTED=0
  CURSOR_ITEM=""
  _INITIAL_SELECT=0
  _CMD_BUF=""
  _RENAME_ITEM=""
  _RENAME_BUF=""
  _FILTER_STATUS=""
  _KILL_PENDING=""
  _RESIZE=0
  _HAS_WORKING=0
  PREVIEW_MODE=0
  POPUP_MODE=""
  PLUGIN_VERSION="test"

  # Flat arrays (declare as associative where render.sh requires it)
  SESSIONS_FLAT=()
  ITEMS_FLAT=()
  declare -Ag _win_meta _srv_cur _sess_act
  _win_meta=()
  _srv_cur=()
  _sess_act=()
  _win_keys=()

  # Additional globals for new render.sh architecture
  _INFO_MODE=0
  _CURRENT_W=0
  _CURRENT_H=0
  _outer_sess=""
  _outer_win=""

  # Needed so render's `cat current_session` exits 0 (empty session = no active window)
  touch "$STATE_DIR/current_session"

  # Source all three render modules; render.sh defines colors so override them after.
  source "$(lib_dir)/render-icons.sh"
  source "$(lib_dir)/render-row.sh"
  source "$(lib_dir)/render.sh"

  # Override colors to empty so output is plain text (greppable without ANSI noise).
  # render.sh defines these at module level, so they must be overridden after sourcing.
  R="" G="" BG="" PU="" GR="" RD="" YL="" CY="" WH=""
}

teardown() {
  # BATS_TEST_TMPDIR is cleaned up automatically by bats; remove only BATS_TMPDIR artifacts.
  local _base="${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-${TMPDIR:-/tmp}}}"
  rm -rf "$_base/state" "$_base/sessions" "$_base/mock_bin" \
         "$_base/out.txt" "$_base/tmux_calls.log" "$_base/tmux_response"
}

# ── file_mtime ─────────────────────────────────────────────────────────────────

@test "file_mtime: returns 0 for non-existent file" {
  result=$(file_mtime "$STATE_DIR/does_not_exist")
  [ "$result" = "0" ]
}

@test "file_mtime: returns a positive integer for an existing file" {
  touch "$STATE_DIR/testfile"
  result=$(file_mtime "$STATE_DIR/testfile")
  [[ "$result" =~ ^[0-9]+$ ]] && [ "$result" -gt 0 ]
}

# ── render: early-return cases ─────────────────────────────────────────────────

@test "render: missing DATA_FILE returns without writing rowmap" {
  # DATA_FILE intentionally absent
  render > /dev/null 2>&1
  [ ! -f "$STATE_DIR/rowmap" ]
}

@test "render: empty DATA_FILE writes rowmap" {
  touch "$DATA_FILE"
  render > /dev/null 2>&1
  [ -f "$STATE_DIR/rowmap" ]
}

# ── render: rowmap content ─────────────────────────────────────────────────────

@test "render: session row written to rowmap" {
  cp "$(fixtures_dir)/data_single_session.txt" "$DATA_FILE"
  render > /dev/null 2>&1
  grep -qF "main|work" "$STATE_DIR/rowmap"
}

@test "render: window row written to rowmap" {
  cp "$(fixtures_dir)/data_single_session.txt" "$DATA_FILE"
  render > /dev/null 2>&1
  grep -qF "main|work|0" "$STATE_DIR/rowmap"
}

@test "render: rowmap has at least one pipe-separated entry per visible item" {
  cp "$(fixtures_dir)/data_single_session.txt" "$DATA_FILE"
  render > /dev/null 2>&1
  # 1 session + 1 window = at least 2 non-empty lines with '|'
  local count
  count=$(grep -cF '|' "$STATE_DIR/rowmap")
  [ "$count" -ge 2 ]
}

@test "render: two-server data writes rows for both servers" {
  cp "$(fixtures_dir)/data_two_servers.txt" "$DATA_FILE"
  render > /dev/null 2>&1
  grep -qF "main|alpha" "$STATE_DIR/rowmap"
  grep -qF "laptop|session-1" "$STATE_DIR/rowmap"
}

# ── render: icon display mapping ───────────────────────────────────────────────

@test "render: E icon maps to · (empty dot)" {
  cp "$(fixtures_dir)/data_with_all_icons.txt" "$DATA_FILE"
  render > "${BATS_TEST_TMPDIR:-$BATS_TMPDIR}/out.txt" 2>&1
  grep -qF '· win-empty' "${BATS_TEST_TMPDIR:-$BATS_TMPDIR}/out.txt"
}

@test "render: W icon maps to spinner character" {
  cp "$(fixtures_dir)/data_with_all_icons.txt" "$DATA_FILE"
  # _SPIN_FRAME starts at 0; render increments it to 1 → _SPINNER[1]="[W1]"
  render > "${BATS_TEST_TMPDIR:-$BATS_TMPDIR}/out.txt" 2>&1
  grep -qF '[W1] win-working' "${BATS_TEST_TMPDIR:-$BATS_TMPDIR}/out.txt"
}

@test "render: I icon maps to ○" {
  cp "$(fixtures_dir)/data_with_all_icons.txt" "$DATA_FILE"
  render > "${BATS_TEST_TMPDIR:-$BATS_TMPDIR}/out.txt" 2>&1
  grep -qF '○ win-idle' "${BATS_TEST_TMPDIR:-$BATS_TMPDIR}/out.txt"
}

@test "render: P icon maps to ?" {
  cp "$(fixtures_dir)/data_with_all_icons.txt" "$DATA_FILE"
  render > "${BATS_TEST_TMPDIR:-$BATS_TMPDIR}/out.txt" 2>&1
  grep -qF '? win-blocked' "${BATS_TEST_TMPDIR:-$BATS_TMPDIR}/out.txt"
}

@test "render: L icon maps to ↺" {
  cp "$(fixtures_dir)/data_with_all_icons.txt" "$DATA_FILE"
  render > "${BATS_TEST_TMPDIR:-$BATS_TMPDIR}/out.txt" 2>&1
  grep -qF '↺ win-loop' "${BATS_TEST_TMPDIR:-$BATS_TMPDIR}/out.txt"
}

@test "render: X icon maps to ✗" {
  cp "$(fixtures_dir)/data_with_all_icons.txt" "$DATA_FILE"
  render > "${BATS_TEST_TMPDIR:-$BATS_TMPDIR}/out.txt" 2>&1
  grep -qF '✗ win-crashed' "${BATS_TEST_TMPDIR:-$BATS_TMPDIR}/out.txt"
}

# ── render: unread flag ────────────────────────────────────────────────────────

@test "render: unread flag on idle window shows ◉" {
  cp "$(fixtures_dir)/data_with_all_icons.txt" "$DATA_FILE"
  # win-idle is server=main, session=work, idx=2 → key main_work_2
  touch "$STATE_DIR/main_work_2.unread"
  render > "${BATS_TEST_TMPDIR:-$BATS_TMPDIR}/out.txt" 2>&1
  grep -qF '◉ win-idle' "${BATS_TEST_TMPDIR:-$BATS_TMPDIR}/out.txt"
}

@test "render: no unread file → idle window shows ○, not ◉" {
  cp "$(fixtures_dir)/data_with_all_icons.txt" "$DATA_FILE"
  # Ensure no stale unread flag
  rm -f "$STATE_DIR/main_work_2.unread"
  render > "${BATS_TEST_TMPDIR:-$BATS_TMPDIR}/out.txt" 2>&1
  grep -qF '○ win-idle' "${BATS_TEST_TMPDIR:-$BATS_TMPDIR}/out.txt"
  ! grep -qF '◉ win-idle' "${BATS_TEST_TMPDIR:-$BATS_TMPDIR}/out.txt"
}
