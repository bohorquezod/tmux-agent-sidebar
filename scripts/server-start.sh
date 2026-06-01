#!/bin/bash
# server-start.sh — garantiza que el sidebar server tmux-agent-sidebar está corriendo
# Idempotente: puede llamarse múltiples veces sin efecto secundario

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMUXBIN="$(command -v tmux 2>/dev/null)"; [[ -z "$TMUXBIN" ]] && TMUXBIN="tmux"

# Localizar bash 4+ — prioriza Homebrew (Apple Silicon y Intel), luego PATH
_find_bash4() {
  local _b
  for _b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "$_b" && "$("$_b" -c 'echo ${BASH_VERSINFO[0]}')" -ge 4 ]]; then
      echo "$_b"; return
    fi
  done
  # Fallback: usar bash del PATH si ya es 4+
  local _pb; _pb="$(command -v bash 2>/dev/null)"
  if [[ -n "$_pb" && "$("$_pb" -c 'echo ${BASH_VERSINFO[0]}')" -ge 4 ]]; then
    echo "$_pb"; return
  fi
  echo ""
}
BASH4="$(_find_bash4)"
if [[ -z "$BASH4" ]]; then
  tmux display-message "tmux-agent-sidebar: bash 4+ not found. Install via: brew install bash" 2>/dev/null
  exit 1
fi
STATE_DIR="${TMPDIR:-/tmp}/agent-sidebar"
CLIENTS_DIR="${STATE_DIR}/clients"
SERVER="tmux-agent-sidebar"
SESSION="sidebar"
OUTER_SOCKET="${TMUX%%,*}"

mkdir -p "$STATE_DIR" "$CLIENTS_DIR"

# 1. Arrancar daemon en el contexto del outer server (hereda $TMUX del outer server)
_dpid_file="${STATE_DIR}/daemon.pid"
if [[ ! -f "$_dpid_file" ]] || ! kill -0 "$(<"$_dpid_file")" 2>/dev/null; then
  nohup "$BASH4" "$PLUGIN_DIR/scripts/daemon.sh" >/dev/null 2>&1 &
  _i=0
  while [[ ! -f "${STATE_DIR}/data" && $_i -lt 20 ]]; do sleep 0.1; ((_i++)); done
fi

# 2. Si el sidebar server ya tiene la sesión activa: nada que hacer
$TMUXBIN -L "$SERVER" has-session -t "$SESSION" 2>/dev/null && exit 0

# 3. Determinar ancho inicial por servidor
OUTER_SERVER="${OUTER_SOCKET##*/}"
_srv_key="${OUTER_SERVER//[^a-zA-Z0-9_-]/_}"
_width_f="${STATE_DIR}/sidebar_width_${_srv_key}"
[[ ! -f "$_width_f" && -f "${STATE_DIR}/sidebar_width" ]] && cp "${STATE_DIR}/sidebar_width" "$_width_f"
WIDTH=$(cat "$_width_f" 2>/dev/null)
if [[ -z "$WIDTH" || ! "$WIDTH" =~ ^[0-9]+$ ]]; then
  WIDTH=$($TMUXBIN show-option -gqv @agent-sidebar-width 2>/dev/null)
  [[ -z "$WIDTH" || ! "$WIDTH" =~ ^[0-9]+$ ]] && WIDTH=28
fi

# 4. Crear sesión en sidebar server con config vacía (sin ~/.tmux.conf, sin plugins)
# Leer el alto real del pane Sessions si existe; fallback a las dimensiones del terminal actual.
HEIGHT=$($TMUXBIN list-panes -a -F '#{pane_title}|#{pane_height}' 2>/dev/null \
  | awk -F'|' '$1=="Sessions"{print $2; exit}')
if [[ -z "$HEIGHT" || ! "$HEIGHT" =~ ^[0-9]+$ ]]; then
  HEIGHT=$(stty size 2>/dev/null | awk '{print $1}')
  [[ -z "$HEIGHT" || ! "$HEIGHT" =~ ^[0-9]+$ ]] && HEIGHT=50
fi
$TMUXBIN -L "$SERVER" -f /dev/null new-session -d -s "$SESSION" -x "$WIDTH" -y "$HEIGHT" \
  -e "OUTER_TMUX_SOCKET=$OUTER_SOCKET" \
  -e "PLUGIN_DIR=$PLUGIN_DIR" \
  -e "STATE_DIR=$STATE_DIR" \
  "exec $BASH4 $PLUGIN_DIR/scripts/sidebar.sh"

# 5. Configurar sidebar server: sin status bar, sin prefix, sin mouse
$TMUXBIN -L "$SERVER" set-option -g status off
$TMUXBIN -L "$SERVER" set-option -g prefix None
$TMUXBIN -L "$SERVER" set-option -g mouse off
# window-size manual: el tamaño de sesión solo cambia vía resize-window explícito.
# Evita que el sidebar rebote entre anchos de distintos clientes al hacer render.
$TMUXBIN -L "$SERVER" set-option -g window-size manual
