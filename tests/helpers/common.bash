# common.bash — shared test helpers for tmux-agent-sidebar bats tests

# Setup temporal: STATE_DIR y CLAUDE_SESSIONS_DIR usando BATS_TEST_TMPDIR (per-test,
# garantizado por bats 1.7+). Si no está disponible se cae a BATS_TMPDIR o $TMPDIR.
setup_state_dirs() {
  local _base="${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-${TMPDIR:-/tmp}}}"
  export STATE_DIR="$_base/state"
  export CLAUDE_SESSIONS_DIR="$_base/sessions"
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
  source "$(lib_dir)/detect.sh"
}

# Retorna la ruta absoluta de tests/helpers/fixtures/
fixtures_dir() {
  local _repo_root
  _repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  printf '%s/tests/helpers/fixtures' "$_repo_root"
}
