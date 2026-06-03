# log.sh — levelled logging for tmux-agent-sidebar
# Sourced by daemon.sh and sidebar.sh. STATE_DIR must be set before sourcing.
# AGENT_SIDEBAR_LOG: 0=off (default), 1=info, 2=debug

_LOG_FILE="${STATE_DIR}/debug.log"
_LOG_LEVEL="${AGENT_SIDEBAR_LOG:-0}"

_log_rotate() {
  [[ -f "$_LOG_FILE" ]] || return 0
  local _sz
  _sz=$(stat -f%z "$_LOG_FILE" 2>/dev/null || stat -c%s "$_LOG_FILE" 2>/dev/null || echo 0)
  ((_sz > 1048576)) && mv "$_LOG_FILE" "${_LOG_FILE}.1"
}

_log_debug() {
  ((_LOG_LEVEL >= 2)) || return 0
  printf '[DEBUG %s] %s\n' "$(date +%T)" "$*" >>"$_LOG_FILE"
}

_log_info() {
  ((_LOG_LEVEL >= 1)) || return 0
  printf '[INFO  %s] %s\n' "$(date +%T)" "$*" >>"$_LOG_FILE"
}

_log_warn() {
  printf '[WARN  %s] %s\n' "$(date +%T)" "$*" | tee -a "$_LOG_FILE" >&2
}
