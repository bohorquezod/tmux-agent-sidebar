# log.sh — levelled logging for tmux-agent-sidebar
# shellcheck shell=bash
# Sourced by daemon.sh and sidebar.sh.
# Requires STATE_DIR to be set by the parent script.
#
# Usage:
#   AGENT_SIDEBAR_LOG=0  (default) — logging off
#   AGENT_SIDEBAR_LOG=1            — info + warnings
#   AGENT_SIDEBAR_LOG=2            — debug (verbose)

_LOG_LEVEL="${AGENT_SIDEBAR_LOG:-0}"

_log_debug() {
  (( _LOG_LEVEL >= 2 )) || return 0
  printf '[DEBUG %s] %s\n' "$(date +%T)" "$*" >> "${STATE_DIR}/debug.log"
}

_log_info() {
  (( _LOG_LEVEL >= 1 )) || return 0
  printf '[INFO  %s] %s\n' "$(date +%T)" "$*" >> "${STATE_DIR}/debug.log"
}

_log_warn() {
  printf '[WARN  %s] %s\n' "$(date +%T)" "$*" | tee -a "${STATE_DIR}/debug.log" >&2
}
