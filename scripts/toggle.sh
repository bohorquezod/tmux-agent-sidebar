#!/bin/bash
# toggle.sh — abre/cierra el sidebar conectando al sidebar server tmux-agent-sidebar

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMUXBIN="$(command -v tmux 2>/dev/null)"; [[ -z "$TMUXBIN" ]] && TMUXBIN="tmux"
STATE_DIR="${TMPDIR:-/tmp}/agent-sidebar"
SERVER="tmux-agent-sidebar"
SESSION="sidebar"

OUTER_SERVER="${TMUX%%,*}"; OUTER_SERVER="${OUTER_SERVER##*/}"

SESS=$($TMUXBIN display-message -p '#S')
WIN_IDX=$($TMUXBIN display-message -p '#I')
ACTIVE_PANE=$($TMUXBIN display-message -p '#{pane_id}')

# Detectar sidebar por título — más confiable que STATE_FILE
LIVE_PANE=$($TMUXBIN list-panes -t "$SESS:$WIN_IDX" \
  -F '#{pane_dead}|#{pane_id}|#{pane_title}' 2>/dev/null \
  | awk -F'|' '$1!="1" && $3=="Sessions" {print $2; exit}')

DEAD_PANE=$($TMUXBIN list-panes -t "$SESS:$WIN_IDX" \
  -F '#{pane_dead}|#{pane_id}|#{pane_title}' 2>/dev/null \
  | awk -F'|' '$1=="1" && $3=="Sessions" {print $2; exit}')

if [[ -n "$LIVE_PANE" ]]; then
  if [[ "$ACTIVE_PANE" == "$LIVE_PANE" ]]; then
    # Sidebar tiene el foco → cerrar
    $TMUXBIN kill-pane -t "$LIVE_PANE" 2>/dev/null
  else
    # Sidebar existe pero no tiene el foco → darle foco
    $TMUXBIN select-pane -t "$LIVE_PANE" 2>/dev/null
  fi
  exit 0
fi

# Asegurar que el sidebar server está corriendo
bash "$PLUGIN_DIR/scripts/server-start.sh"

_srv_key="${OUTER_SERVER//[^a-zA-Z0-9_-]/_}"
_width_f="${STATE_DIR}/sidebar_width_${_srv_key}"
[[ ! -f "$_width_f" && -f "${STATE_DIR}/sidebar_width" ]] && cp "${STATE_DIR}/sidebar_width" "$_width_f"
SIDEBAR_W=$(cat "$_width_f" 2>/dev/null)
if [[ -z "$SIDEBAR_W" || ! "$SIDEBAR_W" =~ ^[0-9]+$ ]]; then
  SIDEBAR_W=$($TMUXBIN show-option -gqv @agent-sidebar-width 2>/dev/null)
  [[ -z "$SIDEBAR_W" || ! "$SIDEBAR_W" =~ ^[0-9]+$ ]] && SIDEBAR_W=28
fi

if [[ -n "$DEAD_PANE" ]]; then
  # Pane muerto: reutilizar reconectando al sidebar server y darle foco
  $TMUXBIN respawn-pane -t "$DEAD_PANE" -k \
    "exec $TMUXBIN -L $SERVER attach-session -t $SESSION"
  $TMUXBIN select-pane -t "$DEAD_PANE" 2>/dev/null
  exit 0
fi

# No hay sidebar: crear uno a la izquierda del pane más a la izquierda
LEFTMOST_PANE=$($TMUXBIN list-panes -t "$SESS:$WIN_IDX" \
  -F '#{pane_left}|#{pane_id}' 2>/dev/null \
  | sort -t'|' -k1 -n | head -1 | cut -d'|' -f2)

_target="$SESS:$WIN_IDX"
[[ -n "$LEFTMOST_PANE" ]] && _target="$LEFTMOST_PANE"

$TMUXBIN split-window -hb -l "$SIDEBAR_W" -t "$_target" \
  "exec $TMUXBIN -L $SERVER attach-session -t $SESSION"

# Asignar título "Sessions" al nuevo pane — split-window ya lo deja con foco
NEW_PANE_ID=$($TMUXBIN display-message -p '#{pane_id}' 2>/dev/null)
[[ -n "$NEW_PANE_ID" ]] && $TMUXBIN select-pane -t "$NEW_PANE_ID" -T "Sessions" 2>/dev/null
