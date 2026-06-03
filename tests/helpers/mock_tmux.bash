# mock_tmux.bash — shadows the real tmux binary during bats tests
#
# Usage: load helpers/mock_tmux
#
# After mock_tmux_setup, any invocation of "tmux ..." in a test
# appends the call args to $BATS_TMPDIR/tmux_calls.log and returns
# whatever was set via tmux_set_response (empty by default).

mock_tmux_setup() {
  local _base="${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-${TMPDIR:-/tmp}}}"
  local mock_dir="$_base/mock_bin"
  mkdir -p "$mock_dir"
  # The stub uses $BATS_TEST_TMPDIR at runtime so each test's calls are isolated.
  cat > "$mock_dir/tmux" << 'STUB'
#!/usr/bin/env bash
_log="${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-${TMPDIR:-/tmp}}}/tmux_calls.log"
_resp="${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-${TMPDIR:-/tmp}}}/tmux_response"
printf '%s\n' "$*" >> "$_log"
cat "$_resp" 2>/dev/null || true
STUB
  chmod +x "$mock_dir/tmux"
  export PATH="$mock_dir:$PATH"
  local _base2="${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-${TMPDIR:-/tmp}}}"
  rm -f "$_base2/tmux_calls.log" "$_base2/tmux_response"
}

# Set what the mock tmux returns on its next invocation(s).
tmux_set_response() {
  local _base="${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-${TMPDIR:-/tmp}}}"
  printf '%s\n' "$@" > "$_base/tmux_response"
}

# Return the arguments of the most recent tmux call.
tmux_last_call() {
  local _base="${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-${TMPDIR:-/tmp}}}"
  tail -1 "$_base/tmux_calls.log" 2>/dev/null
}

# Return the number of tmux calls made so far.
tmux_call_count() {
  local _base="${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-${TMPDIR:-/tmp}}}"
  wc -l < "$_base/tmux_calls.log" 2>/dev/null || echo 0
}
