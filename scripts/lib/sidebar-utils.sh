# shellcheck shell=bash
# sidebar-utils.sh — sidebar pane management and animator
# Sourced by sidebar.sh. Assumes all sidebar globals are already set.
# No shebang — not executed directly.

# Animator: despierta el read -t 1 cada 200ms cuando hay ventanas working → spinner a ~5 FPS
_start_animator() {
  local _sd="$STATE_DIR" _tb="$TMUXBIN" _pid="$PANE_ID"
  while true; do
    sleep 0.2
    [[ -f "${_sd}/animator_active" ]] && "$_tb" send-keys -t "$_pid" $'\x1e' 2>/dev/null
  done
}

# Asegura que el pane del sidebar existe en la ventana destino
_ensure_sidebar() {
  local _dest="$1"
  _log_info "_ensure_sidebar: dest=$_dest"
  local _server="tmux-agent-sidebar" _session="sidebar"
  local _srv_key="${OUTER_SERVER//[^a-zA-Z0-9_-]/_}"
  local _width_f="${STATE_DIR}/sidebar_width_${_srv_key}"
  [[ ! -f "$_width_f" && -f "${STATE_DIR}/sidebar_width" ]] && cp "${STATE_DIR}/sidebar_width" "$_width_f"
  local _sw
  _sw=$(cat "$_width_f" 2>/dev/null)
  if [[ -z "$_sw" || ! "$_sw" =~ ^[0-9]+$ ]]; then
    _sw=$("${OUTER_TMUX[@]}" show-option -gqv @agent-sidebar-width 2>/dev/null)
    [[ -z "$_sw" || ! "$_sw" =~ ^[0-9]+$ ]] && _sw=28
  fi

  local _live
  _live=$("${OUTER_TMUX[@]}" list-panes -t "$_dest" \
    -F '#{pane_dead}|#{pane_id}|#{pane_title}|#{pane_current_command}' 2>/dev/null \
    | awk -F'|' '$1!="1" && $3=="Sessions" && $4=="tmux"{print $2; exit}')
  if [[ -n "$_live" ]]; then
    _log_info "_ensure_sidebar: reusing live pane=$_live"
    local _live_w
    _live_w=$("${OUTER_TMUX[@]}" display-message -t "$_live" -p '#{pane_width}' 2>/dev/null)
    [[ -n "$_live_w" && "$_live_w" != "$_sw" ]] \
      && "${OUTER_TMUX[@]}" resize-pane -t "$_live" -x "$_sw" 2>/dev/null
    "${OUTER_TMUX[@]}" select-pane -t "$_live" 2>/dev/null
    _kill_extra_sidebars "$_dest" "$_live"
    return
  fi

  bash "$PLUGIN_DIR/scripts/server-start.sh" 2>/dev/null

  local _dead
  # Muerto o zombie (vivo pero sin tmux — perdió conexión al server)
  _dead=$("${OUTER_TMUX[@]}" list-panes -t "$_dest" \
    -F '#{pane_dead}|#{pane_id}|#{pane_title}|#{pane_current_command}' 2>/dev/null \
    | awk -F'|' '$3=="Sessions" && ($1=="1" || $4!="tmux"){print $2; exit}')

  if [[ -n "$_dead" ]]; then
    _log_info "_ensure_sidebar: respawning dead pane=$_dead"
    "${OUTER_TMUX[@]}" respawn-pane -t "$_dead" -k \
      "exec $TMUXBIN -L $_server attach-session -t $_session" 2>/dev/null
    "${OUTER_TMUX[@]}" select-pane -t "$_dead" -T "Sessions" 2>/dev/null
    _kill_extra_sidebars "$_dest" "$_dead"
  else
    local _lp
    _lp=$("${OUTER_TMUX[@]}" list-panes -t "$_dest" \
      -F '#{pane_left}|#{pane_id}' 2>/dev/null \
      | sort -t'|' -k1 -n | head -1 | cut -d'|' -f2)
    local _tgt="${_dest}"
    [[ -n "$_lp" ]] && _tgt="$_lp"
    local _np
    _np=$("${OUTER_TMUX[@]}" split-window -hb -l "$_sw" -t "$_tgt" \
      -P -F '#{pane_id}' \
      "exec $TMUXBIN -L $_server attach-session -t $_session" 2>/dev/null)
    _log_info "_ensure_sidebar: created new pane=$_np"
    [[ -n "$_np" ]] && "${OUTER_TMUX[@]}" select-pane -t "$_np" -T "Sessions" 2>/dev/null
    _kill_extra_sidebars "$_dest" "$_np"
  fi
}

# Elimina panes "Sessions" duplicados (vivos Y muertos) en una ventana, preservando $_keep.
_kill_extra_sidebars() {
  local _dest="$1" _keep="$2"
  [[ -z "$_keep" ]] && return
  local _extras _dup
  _extras=$("${OUTER_TMUX[@]}" list-panes -t "$_dest" \
    -F '#{pane_id}|#{pane_title}' 2>/dev/null \
    | awk -F'|' -v keep="$_keep" '$2=="Sessions" && $1!=keep {print $1}')
  while IFS= read -r _dup; do
    [[ -n "$_dup" ]] && "${OUTER_TMUX[@]}" kill-pane -t "$_dup" 2>/dev/null
  done <<<"$_extras"
}

# Cleanup handler — called from sidebar.sh trap
_sidebar_cleanup() {
  printf '\033[?7h\033[?25h' # re-habilitar auto-wrap y restaurar cursor al salir
  kill "$_ANIMATOR_PID" 2>/dev/null
  rm -f "$CLIENTS_DIR/$CLIENT_KEY" "$STATE_FILE" "${STATE_DIR}/animator_active"
  if [[ -z "$OUTER_TMUX_SOCKET" && "$_RELOADING" != "1" ]]; then
    $TMUXBIN select-pane -t "$PANE_ID" -T "" 2>/dev/null
  fi
}
