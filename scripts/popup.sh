#!/bin/bash
# popup.sh — abre el sidebar como overlay flotante con display-popup (tmux 3.3+)
# Si la versión de tmux es anterior, hace fallback al modo split-pane.

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMUXBIN="$(command -v tmux 2>/dev/null)"; [[ -z "$TMUXBIN" ]] && TMUXBIN="tmux"
STATE_DIR="${TMPDIR:-/tmp}/agent-sidebar"

# Verificar versión tmux >= 3.3
_ver=$($TMUXBIN -V 2>/dev/null | awk '{print $2}')
_major=$(echo "$_ver" | cut -d. -f1)
_minor=$(echo "$_ver" | cut -d. -f2 | tr -d 'a-zA-Z')
if [[ "$_major" -lt 3 ]] || [[ "$_major" -eq 3 && "$_minor" -lt 3 ]]; then
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
