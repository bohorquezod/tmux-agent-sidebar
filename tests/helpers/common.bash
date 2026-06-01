# common.bash — shared test helpers for tmux-agent-sidebar bats tests

# Setup temporal: STATE_DIR y CLAUDE_SESSIONS_DIR en $BATS_TMPDIR
setup_state_dirs() {
  export STATE_DIR="$BATS_TMPDIR/state"
  export CLAUDE_SESSIONS_DIR="$BATS_TMPDIR/sessions"
  mkdir -p "$STATE_DIR" "$CLAUDE_SESSIONS_DIR"
}

# Crea un session file JSON para un PID dado con el status indicado.
# Uso: make_session_file <pid> <status>
make_session_file() {
  local _pid="$1" _status="$2"
  printf '{"status":"%s"}' "$_status" > "$CLAUDE_SESSIONS_DIR/${_pid}.json"
}

# Retorna la ruta absoluta de scripts/lib/ relativa a este repo
lib_dir() {
  local _repo_root
  _repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  printf '%s/scripts/lib' "$_repo_root"
}

# Carga lib/detect.sh con STATE_DIR y CLAUDE_SESSIONS_DIR ya seteados
load_detect() {
  setup_state_dirs
  source "$(lib_dir)/log.sh"
  source "$(lib_dir)/detect.sh"
}
