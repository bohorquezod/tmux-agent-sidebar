#!/bin/bash
set -euo pipefail
# click.sh — navega al target y abre/refresca el sidebar en destino

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMUXBIN="$(command -v tmux 2>/dev/null)"
[[ -z "$TMUXBIN" ]] && TMUXBIN="tmux"
STATE_DIR="${TMPDIR:-/tmp}/agent-sidebar"
MAPFILE_PATH="${STATE_DIR}/rowmap"
CLIENTS_DIR="${STATE_DIR}/clients"
SERVER="tmux-agent-sidebar"
SESSION="sidebar"

[[ -f "$MAPFILE_PATH" ]] || exit 0

ROW=$(($1 + 1))
TARGET=$(sed -n "${ROW}p" "$MAPFILE_PATH" 2>/dev/null)
[[ -z "$TARGET" ]] && exit 0

# Parsear target: "server|session" o "server|session|winidx"
TARGET_SRV="${TARGET%%|*}"
_rest="${TARGET#*|}"
TARGET_SESS="${_rest%%|*}"
TARGET_WIN="${_rest#*|}"
if [[ "$TARGET_WIN" == "$TARGET_SESS" ]]; then TARGET_WIN=""; fi

# Click en sesión sin ventana: no navegar (solo las ventanas redirigen)
[[ -z "$TARGET_WIN" ]] && exit 0

CURRENT_SERVER="${TMUX%%,*}"
CURRENT_SERVER="${CURRENT_SERVER##*/}"
SOCKET_DIR="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)"

# Capturar el ancho del sidebar en la ventana origen antes de navegar
_src_sess=$($TMUXBIN display-message -p '#S' 2>/dev/null)
_src_win=$($TMUXBIN display-message -p '#I' 2>/dev/null)
_src_w=$($TMUXBIN list-panes -t "${_src_sess}:${_src_win}" \
  -F '#{pane_dead}|#{pane_title}|#{pane_width}' 2>/dev/null \
  | awk -F'|' '$1!="1" && $2=="Sessions" {print $3; exit}')
_srv_key="${CURRENT_SERVER//[^a-zA-Z0-9_-]/_}"
_width_f="${STATE_DIR}/sidebar_width_${_srv_key}"
[[ ! -f "$_width_f" && -f "${STATE_DIR}/sidebar_width" ]] && cp "${STATE_DIR}/sidebar_width" "$_width_f"
[[ -n "$_src_w" ]] && printf '%s' "$_src_w" >"$_width_f"

_tmux_target="$TARGET_SESS"
[[ -n "$TARGET_WIN" ]] && _tmux_target="${TARGET_SESS}:${TARGET_WIN}"

# Normalizar el ancho del sidebar destino ANTES del switch para evitar el flash visual
if [[ -n "$TARGET_WIN" && "$TARGET_SRV" == "$CURRENT_SERVER" && -n "$_src_w" ]]; then
  _dest_live=$($TMUXBIN list-panes -t "${TARGET_SESS}:${TARGET_WIN}" \
    -F '#{pane_dead}|#{pane_id}|#{pane_title}|#{pane_current_command}' 2>/dev/null \
    | awk -F'|' '$1!="1" && $3=="Sessions" && $4=="tmux" {print $2; exit}') || true
  [[ -n "$_dest_live" ]] && $TMUXBIN resize-pane -t "$_dest_live" -x "$_src_w" 2>/dev/null || true
fi

if [[ "$TARGET_SRV" == "$CURRENT_SERVER" ]]; then
  $TMUXBIN switch-client -t "$_tmux_target" 2>/dev/null || exit 0
else
  # Garantizar sidebar server activo antes de crear pane en destino
  bash "$PLUGIN_DIR/scripts/server-start.sh"

  # Crear sidebar pane en la ventana destino antes de cambiar de servidor
  _CTMUX=("$TMUXBIN" -S "$SOCKET_DIR/$TARGET_SRV")
  _tgt_key="${TARGET_SRV//[^a-zA-Z0-9_-]/_}"
  _tgt_w=$(cat "${STATE_DIR}/sidebar_width_${_tgt_key}" 2>/dev/null)
  [[ -z "$_tgt_w" || ! "$_tgt_w" =~ ^[0-9]+$ ]] && _tgt_w="${_src_w:-}"
  [[ -z "$_tgt_w" || ! "$_tgt_w" =~ ^[0-9]+$ ]] && _tgt_w=$($TMUXBIN show-option -gqv @agent-sidebar-width 2>/dev/null)
  [[ -z "$_tgt_w" || ! "$_tgt_w" =~ ^[0-9]+$ ]] && _tgt_w=28
  _dest_live_x=$("${_CTMUX[@]}" list-panes -t "${TARGET_SESS}:${TARGET_WIN}" \
    -F '#{pane_dead}|#{pane_id}|#{pane_title}|#{pane_current_command}' 2>/dev/null \
    | awk -F'|' '$1!="1" && $3=="Sessions" && $4=="tmux" {print $2; exit}') || true
  _dest_dead_x=$("${_CTMUX[@]}" list-panes -t "${TARGET_SESS}:${TARGET_WIN}" \
    -F '#{pane_dead}|#{pane_id}|#{pane_title}|#{pane_current_command}' 2>/dev/null \
    | awk -F'|' '$3=="Sessions" && ($1=="1" || $4!="tmux") {print $2; exit}') || true
  if [[ -n "$_dest_live_x" ]]; then
    "${_CTMUX[@]}" resize-pane -t "$_dest_live_x" -x "$_tgt_w" 2>/dev/null || true
  elif [[ -n "$_dest_dead_x" ]]; then
    "${_CTMUX[@]}" respawn-pane -t "$_dest_dead_x" -k \
      "exec $TMUXBIN -L $SERVER attach-session -t $SESSION" 2>/dev/null || true
    "${_CTMUX[@]}" select-pane -t "$_dest_dead_x" -T "Sessions" 2>/dev/null || true
  else
    _lmost_x=$("${_CTMUX[@]}" list-panes -t "${TARGET_SESS}:${TARGET_WIN}" \
      -F '#{pane_left}|#{pane_id}' 2>/dev/null \
      | sort -t'|' -k1 -n | head -1 | cut -d'|' -f2) || true
    _splittgt_x="${TARGET_SESS}:${TARGET_WIN}"
    [[ -n "$_lmost_x" ]] && _splittgt_x="$_lmost_x"
    _new_x=$("${_CTMUX[@]}" split-window -hb -l "$_tgt_w" -t "$_splittgt_x" -P -F '#{pane_id}' \
      "exec $TMUXBIN -L $SERVER attach-session -t $SESSION" 2>/dev/null) || true
    [[ -n "$_new_x" ]] && "${_CTMUX[@]}" select-pane -t "$_new_x" -T "Sessions" 2>/dev/null || true
  fi

  # Navegar: switch-client si ya hay cliente adjunto, sino detach+attach
  if ! "${_CTMUX[@]}" switch-client -t "$_tmux_target" 2>/dev/null; then
    $TMUXBIN detach-client -E \
      "exec $TMUXBIN -S \"$SOCKET_DIR/$TARGET_SRV\" attach-session -t \"$_tmux_target\"" 2>/dev/null || true
  fi
fi

# Recordar qué sesión se dejó en el servidor origen (para ▶ en servidores no-activos).
if [[ "$TARGET_SRV" != "$CURRENT_SERVER" && -n "$_src_sess" ]]; then
  printf '%s' "$_src_sess" >"${STATE_DIR}/last_session_${CURRENT_SERVER//[^a-zA-Z0-9_-]/_}"
fi

# Escribir current_session y current_server para re-render inmediato del sidebar.
[[ -n "$TARGET_SESS" ]] && printf '%s' "$TARGET_SESS" >"${STATE_DIR}/current_session"
printf '%s' "$TARGET_SRV" >"${STATE_DIR}/current_server"

# Despertar el read -n1 de sidebar.sh enviando un carácter invisible directo al pane.
$TMUXBIN -L "$SERVER" send-keys -t "$SESSION" $'\x1e' 2>/dev/null

# Solo gestionar sidebar en el servidor actual
[[ "$TARGET_SRV" != "$CURRENT_SERVER" ]] && exit 0

# Usar TARGET directamente (más confiable que display-message post-switch)
DEST_SESS="$TARGET_SESS"
if [[ -n "$TARGET_WIN" ]]; then
  DEST_WIN="$TARGET_WIN"
else
  DEST_WIN=$($TMUXBIN list-windows -t "$DEST_SESS" \
    -F '#{window_active}|#{window_index}' 2>/dev/null \
    | awk -F'|' '$1=="1"{print $2; exit}')
fi

# Handoff de just_visited para limpiar flag de unread (formato srv|sess:win)
printf '%s' "${TARGET_SRV}|${DEST_SESS}:${DEST_WIN}" >"${STATE_DIR}/just_visited"

# Detectar sidebar en destino por título
LIVE_PANE=$($TMUXBIN list-panes -t "$DEST_SESS:$DEST_WIN" \
  -F '#{pane_dead}|#{pane_id}|#{pane_title}|#{pane_current_command}' 2>/dev/null \
  | awk -F'|' '$1!="1" && $3=="Sessions" && $4=="tmux" {print $2; exit}') || true

# Pane muerto o zombie (vivo pero sin tmux corriendo — perdió conexión al server)
DEAD_PANE=$($TMUXBIN list-panes -t "$DEST_SESS:$DEST_WIN" \
  -F '#{pane_dead}|#{pane_id}|#{pane_title}|#{pane_current_command}' 2>/dev/null \
  | awk -F'|' '$3=="Sessions" && ($1=="1" || $4!="tmux") {print $2; exit}') || true

# Verificar que LIVE_PANE tiene el sidebar server activo y sidebar.sh corriendo
if [[ -n "$LIVE_PANE" ]]; then
  if ! $TMUXBIN -L "$SERVER" has-session -t "$SESSION" 2>/dev/null; then
    LIVE_PANE=""
  else
    _pid_file="$CLIENTS_DIR/sidebar-server"
    if [[ -f "$_pid_file" ]]; then
      _live_pid=$(<"$_pid_file")
      kill -0 "$_live_pid" 2>/dev/null || LIVE_PANE=""
    else
      LIVE_PANE=""
    fi
  fi
fi

_srv_key="${CURRENT_SERVER//[^a-zA-Z0-9_-]/_}"
_width_f="${STATE_DIR}/sidebar_width_${_srv_key}"
[[ ! -f "$_width_f" && -f "${STATE_DIR}/sidebar_width" ]] && cp "${STATE_DIR}/sidebar_width" "$_width_f"
SIDEBAR_W=$(cat "$_width_f" 2>/dev/null || true)
if [[ -z "$SIDEBAR_W" || ! "$SIDEBAR_W" =~ ^[0-9]+$ ]]; then
  SIDEBAR_W=$($TMUXBIN show-option -gqv @agent-sidebar-width 2>/dev/null)
  [[ -z "$SIDEBAR_W" || ! "$SIDEBAR_W" =~ ^[0-9]+$ ]] && SIDEBAR_W=28
fi

if [[ -n "$LIVE_PANE" ]]; then
  # Sidebar real corriendo: igualar ancho al origen y darle foco
  $TMUXBIN resize-pane -t "$LIVE_PANE" -x "$SIDEBAR_W" 2>/dev/null || true
  $TMUXBIN select-pane -t "$LIVE_PANE" 2>/dev/null || true
  exit 0
fi

# Asegurar sidebar server antes de crear/respawnear
bash "$PLUGIN_DIR/scripts/server-start.sh"

_dedup_sessions_panes() {
  local _win="$1" _keep="$2"
  if [[ -z "$_keep" ]]; then return 0; fi
  local _extras _dup
  _extras=$($TMUXBIN list-panes -t "$_win" \
    -F '#{pane_id}|#{pane_title}' 2>/dev/null \
    | awk -F'|' -v keep="$_keep" '$2=="Sessions" && $1!=keep {print $1}') || true
  while IFS= read -r _dup; do
    [[ -n "$_dup" ]] && $TMUXBIN kill-pane -t "$_dup" 2>/dev/null || true
  done <<<"$_extras"
  return 0
}

if [[ -n "$DEAD_PANE" ]]; then
  # Pane muerto: reconectar al sidebar server, restaurar título y limpiar duplicados
  $TMUXBIN respawn-pane -t "$DEAD_PANE" -k \
    "exec $TMUXBIN -L $SERVER attach-session -t $SESSION" || true
  $TMUXBIN select-pane -t "$DEAD_PANE" -T "Sessions" 2>/dev/null || true
  _dedup_sessions_panes "$DEST_SESS:$DEST_WIN" "$DEAD_PANE"
  exit 0
fi

# No hay sidebar en destino: crear uno a la izquierda al mismo ancho que el origen
LEFTMOST_PANE=$($TMUXBIN list-panes -t "$DEST_SESS:$DEST_WIN" \
  -F '#{pane_left}|#{pane_id}' 2>/dev/null \
  | sort -t'|' -k1 -n | head -1 | cut -d'|' -f2) || true

_target="$DEST_SESS:$DEST_WIN"
if [[ -n "$LEFTMOST_PANE" ]]; then _target="$LEFTMOST_PANE"; fi

$TMUXBIN split-window -hb -l "$SIDEBAR_W" -t "$_target" \
  "exec $TMUXBIN -L $SERVER attach-session -t $SESSION" || true

# split-window deja el foco en el nuevo pane — asignar título y mantener foco
NEW_PANE_ID=$($TMUXBIN display-message -p '#{pane_id}' 2>/dev/null)
[[ -n "$NEW_PANE_ID" ]] && $TMUXBIN select-pane -t "$NEW_PANE_ID" -T "Sessions" 2>/dev/null || true
_dedup_sessions_panes "$DEST_SESS:$DEST_WIN" "$NEW_PANE_ID"
exit 0
