# shellcheck shell=bash
# ops.sh — session/window order operations and kill/rename
# Sourced by sidebar.sh. Assumes all sidebar globals are already set.
# No shebang — not executed directly.

# ── Reordenamiento de sesiones ────────────────────────────────────────────────
save_session_order() {
  : > "$ORDER_FILE"
  local _e
  for _e in "${SESSIONS_FLAT[@]}"; do printf '%s\n' "$_e" >> "$ORDER_FILE"; done
  touch "$DIRTY_FILE"
}

move_session_up() {
  local _idx=$1
  [[ $_idx -le 0 ]] && return
  local _prev=$(( _idx - 1 ))
  [[ "${SESSIONS_FLAT[$_idx]%%|*}" != "${SESSIONS_FLAT[$_prev]%%|*}" ]] && return
  local _tmp="${SESSIONS_FLAT[$_idx]}"
  SESSIONS_FLAT[$_idx]="${SESSIONS_FLAT[$_prev]}"; SESSIONS_FLAT[$_prev]="$_tmp"
  save_session_order
}

move_session_down() {
  local _idx=$1
  local _last=$(( ${#SESSIONS_FLAT[@]} - 1 ))
  [[ $_idx -ge $_last ]] && return
  local _next=$(( _idx + 1 ))
  [[ "${SESSIONS_FLAT[$_idx]%%|*}" != "${SESSIONS_FLAT[$_next]%%|*}" ]] && return
  local _tmp="${SESSIONS_FLAT[$_idx]}"
  SESSIONS_FLAT[$_idx]="${SESSIONS_FLAT[$_next]}"; SESSIONS_FLAT[$_next]="$_tmp"
  save_session_order
}

# ── Reordenamiento de ventanas ────────────────────────────────────────────────
move_window_up() {
  local _idx=$1
  local _item="${ITEMS_FLAT[$_idx]}"
  local _prev="${ITEMS_FLAT[$(( _idx - 1 ))]}"
  [[ $_idx -le 0 || "${_prev%%|*}" != "W" ]] && return

  # Parsear ventana actual
  local _crest="${_item#*|}"
  local _csrv="${_crest%%|*}"
  local _cr2="${_crest#*|}"
  local _csess="${_cr2%%|*}"
  local _cwin="${_cr2#*|}"
  # Parsear ventana anterior
  local _prest="${_prev#*|}"
  local _pr2="${_prest#*|}"
  local _psess="${_pr2%%|*}"
  local _pwin="${_pr2#*|}"

  local _tmux_cmd=("${OUTER_TMUX[@]}")
  [[ "$_csrv" != "$OUTER_SERVER" ]] && _tmux_cmd=("$TMUXBIN" -S "$SOCKET_DIR/$_csrv")
  "${_tmux_cmd[@]}" swap-window -s "${_csess}:${_cwin}" -t "${_psess}:${_pwin}" 2>/dev/null

  # Swap inmediato en ITEMS_FLAT para que el render refleje el cambio sin esperar al daemon
  ITEMS_FLAT[$(( _idx - 1 ))]="$_item"
  ITEMS_FLAT[$_idx]="$_prev"
  SELECTED=$(( _idx - 1 ))
  touch "$DIRTY_FILE"
}

move_window_down() {
  local _idx=$1
  local _item="${ITEMS_FLAT[$_idx]}"
  local _last=$(( ${#ITEMS_FLAT[@]} - 1 ))
  local _next="${ITEMS_FLAT[$(( _idx + 1 ))]}"
  [[ $_idx -ge $_last || "${_next%%|*}" != "W" ]] && return

  # Parsear ventana actual
  local _crest="${_item#*|}"
  local _csrv="${_crest%%|*}"
  local _cr2="${_crest#*|}"
  local _csess="${_cr2%%|*}"
  local _cwin="${_cr2#*|}"
  # Parsear ventana siguiente
  local _nrest="${_next#*|}"
  local _nr2="${_nrest#*|}"
  local _nsess="${_nr2%%|*}"
  local _nwin="${_nr2#*|}"

  local _tmux_cmd=("${OUTER_TMUX[@]}")
  [[ "$_csrv" != "$OUTER_SERVER" ]] && _tmux_cmd=("$TMUXBIN" -S "$SOCKET_DIR/$_csrv")
  "${_tmux_cmd[@]}" swap-window -s "${_csess}:${_cwin}" -t "${_nsess}:${_nwin}" 2>/dev/null

  # Swap inmediato en ITEMS_FLAT
  ITEMS_FLAT[$_idx]="$_next"
  ITEMS_FLAT[$(( _idx + 1 ))]="$_item"
  SELECTED=$(( _idx + 1 ))
  touch "$DIRTY_FILE"
}

# ── Kill sesión o ventana bajo el cursor ─────────────────────────────────────
_kill_current() {
  local _item="${ITEMS_FLAT[$SELECTED]:-}"
  local _itype="${_item%%|*}"
  local _irest="${_item#*|}"
  local _total=${#ITEMS_FLAT[@]}

  if [[ "$_itype" == "S" ]]; then
    local _srv="${_irest%%|*}" _sess="${_irest#*|}"
    local _tmux_cmd=("${OUTER_TMUX[@]}")
    [[ "$_srv" != "$OUTER_SERVER" ]] && _tmux_cmd=("$TMUXBIN" -S "$SOCKET_DIR/$_srv")

    # Buscar próxima S (primero adelante, luego atrás) para reposicionar el cursor
    local _next_si=-1 _scan
    _scan=$(( SELECTED + 1 ))
    while (( _scan < _total )); do
      [[ "${ITEMS_FLAT[$_scan]%%|*}" == "S" ]] && { _next_si=$_scan; break; }
      (( _scan++ ))
    done
    if [[ $_next_si -lt 0 ]]; then
      _scan=$(( SELECTED - 1 ))
      while (( _scan >= 0 )); do
        [[ "${ITEMS_FLAT[$_scan]%%|*}" == "S" ]] && { _next_si=$_scan; break; }
        (( _scan-- ))
      done
    fi

    # Si la sesión matada es la activa en el servidor externo, cambiar clientes primero
    local _cur_active; _cur_active=$(cat "${STATE_DIR}/current_session" 2>/dev/null)
    if [[ "$_srv" == "$OUTER_SERVER" && "$_sess" == "$_cur_active" && $_next_si -ge 0 ]]; then
      local _ns_rest="${ITEMS_FLAT[$_next_si]#*|}"
      local _ns_sess="${_ns_rest#*|}"
      "${OUTER_TMUX[@]}" switch-client -t "$_ns_sess" 2>/dev/null
      printf '%s' "$_ns_sess" > "${STATE_DIR}/current_session"
    fi

    "${_tmux_cmd[@]}" kill-session -t "$_sess" 2>/dev/null
    [[ $_next_si -ge 0 ]] && CURSOR_ITEM="${ITEMS_FLAT[$_next_si]}"

  elif [[ "$_itype" == "W" ]]; then
    local _srv="${_irest%%|*}" _wrest="${_irest#*|}"
    local _sess="${_wrest%%|*}" _widx="${_wrest#*|}"
    local _tmux_cmd=("${OUTER_TMUX[@]}")
    [[ "$_srv" != "$OUTER_SERVER" ]] && _tmux_cmd=("$TMUXBIN" -S "$SOCKET_DIR/$_srv")

    # Encontrar la S padre para devolver el cursor
    local _parent_si=-1 _scan=$SELECTED
    while (( _scan >= 0 )); do
      [[ "${ITEMS_FLAT[$_scan]%%|*}" == "S" ]] && { _parent_si=$_scan; break; }
      (( _scan-- ))
    done

    "${_tmux_cmd[@]}" kill-window -t "${_sess}:${_widx}" 2>/dev/null
    # shellcheck disable=SC2034  # CURSOR_ITEM read by sidebar main loop
    [[ $_parent_si -ge 0 ]] && CURSOR_ITEM="${ITEMS_FLAT[$_parent_si]}"
  fi

  touch "$DIRTY_FILE"
}

# ── Aplicar rename inline ─────────────────────────────────────────────────────
_apply_rename() {
  [[ -z "$_RENAME_BUF" ]] && return
  local _rest="${_RENAME_ITEM#*|}"
  local _srv="${_rest%%|*}"
  local _tmux_cmd=("${OUTER_TMUX[@]}")
  [[ "$_srv" != "$OUTER_SERVER" ]] && _tmux_cmd=("$TMUXBIN" -S "$SOCKET_DIR/$_srv")

  if [[ "$_RENAME_TYPE" == "S" ]]; then
    local _old_sess="${_rest#*|}"
    "${_tmux_cmd[@]}" rename-session -t "$_old_sess" "$_RENAME_BUF" 2>/dev/null
    # Actualizar SESSIONS_FLAT en-place para preservar el orden del usuario
    local _si2=0
    for _sf in "${SESSIONS_FLAT[@]}"; do
      [[ "$_sf" == "${_srv}|${_old_sess}" ]] && { SESSIONS_FLAT[$_si2]="${_srv}|${_RENAME_BUF}"; break; }
      (( _si2++ ))
    done
    # Propagar a current_session si era la sesión activa
    local _cs; _cs=$(cat "${STATE_DIR}/current_session" 2>/dev/null)
    [[ "$_cs" == "$_old_sess" ]] && printf '%s' "$_RENAME_BUF" > "${STATE_DIR}/current_session"
  elif [[ "$_RENAME_TYPE" == "W" ]]; then
    local _wr="${_rest#*|}"
    local _sess="${_wr%%|*}" _wid="${_wr#*|}"
    "${_tmux_cmd[@]}" rename-window -t "${_sess}:${_wid}" "$_RENAME_BUF" 2>/dev/null
  fi
  touch "$DIRTY_FILE"
}
