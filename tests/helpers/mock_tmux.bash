# tests/helpers/mock_tmux.bash
# Helper to stub the tmux binary during bats tests.

mock_tmux_setup() {
  local mock_dir="$BATS_TMPDIR/mock_bin"
  mkdir -p "$mock_dir"
  cat > "$mock_dir/tmux" << 'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BATS_TMPDIR/tmux_calls.log"
cat "$BATS_TMPDIR/tmux_response" 2>/dev/null || true
STUB
  chmod +x "$mock_dir/tmux"
  export PATH="$mock_dir:$PATH"
}

tmux_set_response() { printf '%s\n' "$@" > "$BATS_TMPDIR/tmux_response"; }
tmux_last_call()    { tail -1 "$BATS_TMPDIR/tmux_calls.log" 2>/dev/null; }
tmux_call_count()   { grep -c '' "$BATS_TMPDIR/tmux_calls.log" 2>/dev/null || echo 0; }
