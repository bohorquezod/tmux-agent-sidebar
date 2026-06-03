# shellcheck shell=bash
# cmd.sh — command buffer execution and hints
# Sourced by sidebar.sh. Assumes all sidebar globals are already set.
# No shebang — not executed directly.

# ── Live command hint ─────────────────────────────────────────────────────────
# Devuelve una línea de ayuda para el partial _CMD_BUF actual.
_cmd_hint() {
  local _b="$1"
  [[ ${#_b} -lt 2 ]] && return  # `:` solo no muestra hint
  # Strip leading colon for prefix matching against command names.
  # Pattern: [[ "commandname" == "${typed_prefix}"* ]] — true when the
  # full command name starts with what the user has typed so far.
  local _bk="${_b#:}"
  if [[ "$_b" =~ ^:?[0-9]+\.[0-9] ]]; then
    printf ':N.M — navigate to session N, window M'
  elif [[ "$_b" =~ ^:?[0-9]+$ ]]; then
    printf ':N — navigate to session N'
  elif [[ "filter" == "${_bk}"* ]] && [[ ${#_b} -ge 3 ]]; then
    printf ':filter working|idle|unread — show matching windows'
  elif [[ "rename" == "${_bk}"* ]]; then
    printf ':rename [N[.M]] <name> — rename session or window'
  elif [[ "kill" == "${_bk}"* ]]; then
    printf ':kill [N[.M]] — kill session or window'
  elif [[ "move" == "${_bk}"* ]]; then
    printf ':move N N2 — reorder session or window'
  elif [[ "new" == "${_bk}"* ]]; then
    printf ':new — create new session'
  fi
}

# ── Catálogo de comandos del command buffer ───────────────────────────────────
_exec_cmd() {
  local _c="$1"
  # Separar comando y args
  local _cmd="${_c%% *}" _args=""
  [[ "$_c" == *" "* ]] && _args="${_c#"$_cmd" }"

  case "$_cmd" in

    # ── :kill [N[.M]] — matar sesión o ventana ───────────────────────────
    :kill|:k)
      local _ci _ct _cr
      if [[ "$_args" =~ ^([0-9]+)\.([0-9]+)$ ]]; then
        _resolve_ordinal "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" || return
        # _ri_ci/_ri_ct/_ri_cr set by _resolve_ordinal in nav.sh (cross-module globals)
        # shellcheck disable=SC2154
        _ci="$_ri_ci"
        # shellcheck disable=SC2154
        _ct="$_ri_ct"
        # shellcheck disable=SC2154
        _cr="$_ri_cr"
      elif [[ "$_args" =~ ^([0-9]+)$ ]]; then
        _resolve_ordinal "${BASH_REMATCH[1]}" || return
        # shellcheck disable=SC2154
        _ci="$_ri_ci"
        # shellcheck disable=SC2154
        _ct="$_ri_ct"
        # shellcheck disable=SC2154
        _cr="$_ri_cr"
      else
        _ci="${ITEMS_FLAT[$SELECTED]:-}"; _ct="${_ci%%|*}"; _cr="${_ci#*|}"
      fi
      if [[ "$_ct" == "S" ]]; then
        local _srv="${_cr%%|*}" _sess="${_cr#*|}"
        local _tcmd=("${OUTER_TMUX[@]}")
        [[ "$_srv" != "$OUTER_SERVER" ]] && _tcmd=("$TMUXBIN" -S "$SOCKET_DIR/$_srv")
        "${_tcmd[@]}" kill-session -t "$_sess" 2>/dev/null
      elif [[ "$_ct" == "W" ]]; then
        local _srv="${_cr%%|*}" _wr="${_cr#*|}"
        local _sess="${_wr%%|*}" _wid="${_wr#*|}"
        local _tcmd=("${OUTER_TMUX[@]}")
        [[ "$_srv" != "$OUTER_SERVER" ]] && _tcmd=("$TMUXBIN" -S "$SOCKET_DIR/$_srv")
        "${_tcmd[@]}" kill-window -t "${_sess}:${_wid}" 2>/dev/null
      fi
      touch "$DIRTY_FILE"; return ;;

    # ── :new — crear nueva sesión en el servidor activo ──────────────────
    :new)
      "${OUTER_TMUX[@]}" new-session -d 2>/dev/null
      touch "$DIRTY_FILE"; return ;;

    # ── :rename [N[.M]] X — renombrar sesión o ventana ───────────────────
    :rename)
      [[ -z "$_args" ]] && return
      # Detectar target opcional al inicio de _args
      local _ci _ct _cr _newname="$_args"
      local _first="${_args%% *}"
      if [[ "$_first" =~ ^([0-9]+)\.([0-9]+)$ && "$_args" == *" "* ]]; then
        _resolve_ordinal "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" || return
        _ci="$_ri_ci"; _ct="$_ri_ct"; _cr="$_ri_cr"
        _newname="${_args#"$_first" }"
      elif [[ "$_first" =~ ^([0-9]+)$ && "$_args" == *" "* ]]; then
        _resolve_ordinal "${BASH_REMATCH[1]}" || return
        _ci="$_ri_ci"; _ct="$_ri_ct"; _cr="$_ri_cr"
        _newname="${_args#"$_first" }"
      else
        _ci="${ITEMS_FLAT[$SELECTED]:-}"; _ct="${_ci%%|*}"; _cr="${_ci#*|}"
      fi
      [[ -z "$_newname" ]] && return
      if [[ "$_ct" == "S" ]]; then
        local _srv="${_cr%%|*}" _sess="${_cr#*|}"
        local _tcmd=("${OUTER_TMUX[@]}")
        [[ "$_srv" != "$OUTER_SERVER" ]] && _tcmd=("$TMUXBIN" -S "$SOCKET_DIR/$_srv")
        "${_tcmd[@]}" rename-session -t "$_sess" "$_newname" 2>/dev/null
      elif [[ "$_ct" == "W" ]]; then
        local _srv="${_cr%%|*}" _wr="${_cr#*|}"
        local _sess="${_wr%%|*}" _wid="${_wr#*|}"
        local _tcmd=("${OUTER_TMUX[@]}")
        [[ "$_srv" != "$OUTER_SERVER" ]] && _tcmd=("$TMUXBIN" -S "$SOCKET_DIR/$_srv")
        "${_tcmd[@]}" rename-window -t "${_sess}:${_wid}" "$_newname" 2>/dev/null
      fi
      touch "$DIRTY_FILE"; return ;;

    # ── :move N N2 / N.M N2.M2 — reordenar por posición ─────────────────
    :move)
      local _src="${_args%% *}"
      local _dst="${_args#"$_src" }"
      [[ -z "$_src" || -z "$_dst" || "$_src" == "$_dst" ]] && return
      if [[ "$_src" =~ ^([0-9]+)\.([0-9]+)$ ]]; then
        # Mover ventana N.M → N2.M2
        local _ss="${BASH_REMATCH[1]}" _sw="${BASH_REMATCH[2]}"
        [[ "$_dst" =~ ^([0-9]+)\.([0-9]+)$ ]] || return
        local _ds="${BASH_REMATCH[1]}" _dw="${BASH_REMATCH[2]}"
        # Encontrar índice en ITEMS_FLAT de la ventana src
        local _n=0 _ii=0 _si=-1
        for _it in "${ITEMS_FLAT[@]}"; do
          [[ "${_it%%|*}" == "S" ]] && { (( _n++ )); [[ $_n -eq $_ss ]] && _si=$_ii; }
          (( _ii++ ))
        done
        [[ $_si -lt 0 ]] && return
        local _wn=0 _wi=$(( _si + 1 )) _src_idx=-1
        while [[ $_wi -lt ${#ITEMS_FLAT[@]} ]]; do
          [[ "${ITEMS_FLAT[$_wi]%%|*}" == "S" ]] && break
          [[ "${ITEMS_FLAT[$_wi]%%|*}" == "W" ]] && { (( _wn++ )); [[ $_wn -eq $_sw ]] && _src_idx=$_wi; }
          (( _wi++ ))
        done
        [[ $_src_idx -lt 0 ]] && return
        # Calcular ventana destino ordinal dentro de la misma sesión
        # Para cruzar sesiones usaríamos move-window; aquí solo reordenamos dentro de la misma
        local _delta=$(( _dw - _sw ))
        if [[ $_delta -gt 0 ]]; then
          local _d=0; while [[ $_d -lt $_delta ]]; do move_window_down $_src_idx; (( _src_idx++ )); (( _d++ )); done
        elif [[ $_delta -lt 0 ]]; then
          local _d=0; local _ad=$(( -_delta ))
          while [[ $_d -lt $_ad ]]; do move_window_up $_src_idx; (( _src_idx-- )); (( _d++ )); done
        fi
      elif [[ "$_src" =~ ^([0-9]+)$ ]]; then
        # Mover sesión N → N2
        [[ "$_dst" =~ ^([0-9]+)$ ]] || return
        local _sn="${BASH_REMATCH[1]}"  # dst session ordinal
        local _src_sn="${_src}"
        local _sf_src=$(( _src_sn - 1 )) _sf_dst=$(( _sn - 1 ))
        [[ $_sf_src -lt 0 || $_sf_dst -lt 0 || $_sf_src -ge ${#SESSIONS_FLAT[@]} ]] && return
        [[ $_sf_dst -ge ${#SESSIONS_FLAT[@]} ]] && _sf_dst=$(( ${#SESSIONS_FLAT[@]} - 1 ))
        local _delta=$(( _sf_dst - _sf_src ))
        CURSOR_ITEM="${SESSIONS_FLAT[$_sf_src]}"
        if [[ $_delta -gt 0 ]]; then
          local _d=0; while [[ $_d -lt $_delta ]]; do move_session_down $_sf_src; (( _sf_src++ )); (( _d++ )); done
        elif [[ $_delta -lt 0 ]]; then
          local _d=0; local _ad=$(( -_delta ))
          while [[ $_d -lt $_ad ]]; do move_session_up $_sf_src; (( _sf_src-- )); (( _d++ )); done
        fi
      fi
      return ;;

    # ── :filter <status> — filtrar vista por estado de icono ─────────────
    :filter)
      case "$_args" in
        working|idle|unread) _FILTER_STATUS="$_args" ;;
        *) _FILTER_STATUS="" ;;
      esac
      return ;;

  esac

  # ── Navegación numérica: N o N.M ─────────────────────────────────────────
  local _snum="" _wnum="" _cn="$_c"
  [[ "$_cn" == :* ]] && _cn="${_cn#:}"
  if [[ "$_cn" =~ ^([0-9]+)\.([0-9]+)$ ]]; then
    _snum="${BASH_REMATCH[1]}"; _wnum="${BASH_REMATCH[2]}"
  elif [[ "$_cn" =~ ^[0-9]+$ ]]; then
    _snum="$_cn"
  else
    return
  fi

  # Encontrar la sesión en posición ordinal _snum
  local _n=0 _ii=0 _si=-1
  for _it in "${ITEMS_FLAT[@]}"; do
    [[ "${_it%%|*}" == "S" ]] && { (( _n++ )); [[ $_n -eq $_snum ]] && { _si=$_ii; break; }; }
    (( _ii++ ))
  done
  [[ $_si -lt 0 ]] && return

  local _sr="${ITEMS_FLAT[$_si]#*|}"
  local _ssrv="${_sr%%|*}"
  local _ssess="${_sr#*|}"

  if [[ -n "$_wnum" ]]; then
    local _wn=0 _wi=$(( _si + 1 )) _wfound=-1
    while [[ $_wi -lt ${#ITEMS_FLAT[@]} ]]; do
      local _wit="${ITEMS_FLAT[$_wi]}"
      [[ "${_wit%%|*}" == "S" ]] && break
      if [[ "${_wit%%|*}" == "W" ]]; then
        (( _wn++ ))
        [[ $_wn -eq $_wnum ]] && { _wfound=$_wi; break; }
      fi
      (( _wi++ ))
    done
    [[ $_wfound -lt 0 ]] && return
    local _wr="${ITEMS_FLAT[$_wfound]#*|}"
    local _wsrv="${_wr%%|*}"
    local _wr2="${_wr#*|}"
    local _wsess="${_wr2%%|*}"
    local _wid="${_wr2#*|}"
    SELECTED=$_wfound
    CURSOR_ITEM="${ITEMS_FLAT[$_wfound]}"
    [[ "$_wsrv" == "$OUTER_SERVER" && -z "$POPUP_MODE" ]] && _ensure_sidebar "${_wsess}:${_wid}"
    jump_to "${_wsrv}|${_wsess}|${_wid}"
    [[ "$_wsrv" == "$OUTER_SERVER" ]] && printf '%s' "$_wsess" > "${STATE_DIR}/current_session"
    printf '%s' "${_wsrv}|${_wsess}:${_wid}" > "${STATE_DIR}/just_visited"
    $TMUXBIN send-keys -t "$PANE_ID" $'\x1e' 2>/dev/null
    [[ -n "$POPUP_MODE" ]] && exit 0
  else
    SELECTED=$_si
    # shellcheck disable=SC2034  # CURSOR_ITEM read by sidebar main loop and ops.sh
    CURSOR_ITEM="${ITEMS_FLAT[$_si]}"
    local _active_win; _active_win=$("${OUTER_TMUX[@]}" list-windows -t "$_ssess" \
      -F '#{window_active}|#{window_index}' 2>/dev/null | awk -F'|' '$1=="1"{print $2; exit}')
    [[ -n "$_active_win" && "$_ssrv" == "$OUTER_SERVER" && -z "$POPUP_MODE" ]] && _ensure_sidebar "${_ssess}:${_active_win}"
    jump_to "${_ssrv}|${_ssess}"
    [[ "$_ssrv" == "$OUTER_SERVER" ]] && printf '%s' "$_ssess" > "${STATE_DIR}/current_session"
    $TMUXBIN send-keys -t "$PANE_ID" $'\x1e' 2>/dev/null
    [[ -n "$POPUP_MODE" ]] && exit 0
  fi
}
