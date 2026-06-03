#!/bin/bash
# popup.sh — abre el sidebar como overlay flotante con display-popup (tmux 3.3+)
# Si la versión de tmux es anterior, hace fallback al modo split-pane.

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMUXBIN="$(command -v tmux 2>/dev/null)"; [[ -z "$TMUXBIN" ]] && TMUXBIN="tmux"
STATE_DIR="${TMPDIR:-/tmp}/agent-sidebar"

# Returns 0 if the given version string satisfies tmux >= 3.3, 1 otherwise.
_popup_version_ok() {
  local _ver="$1"
  local _major _minor
  _major=$(printf '%s' "$_ver" | cut -d. -f1)
  _minor=$(printf '%s' "$_ver" | cut -d. -f2 | tr -d 'a-zA-Z')
  [[ "$_major" -gt 3 ]] && return 0
  [[ "$_major" -eq 3 && "$_minor" -ge 3 ]] && return 0
  return 1
}

# When sourced for testing, skip main execution.
[[ "${BASH_SOURCE[0]}" != "${0}" ]] && return 0

# Verificar versión tmux >= 3.3
_ver=$($TMUXBIN -V 2>/dev/null | awk '{print $2}')
if ! _popup_version_ok "$_ver"; then
  bash "$PLUGIN_DIR/scripts/toggle.sh"
  exit 0
fi

# Leer dimensiones configuradas
_W=$($TMUXBIN show-option -gqv @agent-sidebar-popup-width 2>/dev/null)
[[ -z "$_W" ]] && _W=32
_H=$($TMUXBIN show-option -gqv @agent-sidebar-popup-height 2>/dev/null)
[[ -z "$_H" ]] && _H="80%"

OUTER_SOCKET="${TMUX%%,*}"

$TMUXBIN display-popup -w "$_W" -h "$_H" -E \
  "OUTER_TMUX_SOCKET='$OUTER_SOCKET' POPUP_MODE=1 PLUGIN_DIR='$PLUGIN_DIR' STATE_DIR='$STATE_DIR' exec bash '$PLUGIN_DIR/scripts/sidebar.sh'"
