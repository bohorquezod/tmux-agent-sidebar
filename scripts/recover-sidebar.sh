#!/bin/bash
set -euo pipefail
# recover-sidebar.sh — respawnea silenciosamente el pane sidebar muerto o zombie de la ventana activa
# Invocado por los hooks after-select-window y client-session-changed.
# "Zombie": pane vivo (pane_dead=0) pero sin tmux corriendo — perdió conexión al sidebar server.

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMUXBIN="$(command -v tmux 2>/dev/null)"
[[ -z "$TMUXBIN" ]] && TMUXBIN="tmux"
SERVER="tmux-agent-sidebar"
SESSION="sidebar"

SESS=$($TMUXBIN display-message -p '#S' 2>/dev/null) || exit 0
WIN_IDX=$($TMUXBIN display-message -p '#I' 2>/dev/null) || exit 0
[[ -z "$SESS" || -z "$WIN_IDX" ]] && exit 0

# Buscar pane muerto o zombie con título "Sessions"
DEAD_PANE=$($TMUXBIN list-panes -t "${SESS}:${WIN_IDX}" \
  -F '#{pane_dead}|#{pane_id}|#{pane_title}|#{pane_current_command}' 2>/dev/null \
  | awk -F'|' '$3=="Sessions" && ($1=="1" || $4!="tmux") {print $2; exit}') || true

[[ -z "$DEAD_PANE" ]] && exit 0

# Verificar que no haya ya un pane vivo corriendo tmux
LIVE_PANE=$($TMUXBIN list-panes -t "${SESS}:${WIN_IDX}" \
  -F '#{pane_dead}|#{pane_id}|#{pane_title}|#{pane_current_command}' 2>/dev/null \
  | awk -F'|' '$1!="1" && $3=="Sessions" && $4=="tmux" {print $2; exit}') || true
[[ -n "$LIVE_PANE" ]] && exit 0

# Asegurar que el sidebar server está corriendo
bash "$PLUGIN_DIR/scripts/server-start.sh" 2>/dev/null

# Respawnear sin robar foco — recuperación silenciosa
$TMUXBIN respawn-pane -t "$DEAD_PANE" -k \
  "exec $TMUXBIN -L $SERVER attach-session -t $SESSION" 2>/dev/null || true
$TMUXBIN select-pane -t "$DEAD_PANE" -T "Sessions" 2>/dev/null || true
