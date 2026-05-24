#!/bin/bash
# sidebar.sh — cliente del sidebar: cursor plano sobre sesiones y ventanas

# Deshabilitar echo y asegurar que \n produzca \r\n (ONLCR) en la pty.
# Evita que keypresses se muestren como texto durante las transiciones de exec.
stty -echo onlcr 2>/dev/null

PLUGIN_DIR="${PLUGIN_DIR:-$(cd -P "$(dirname "$0")/.." && pwd)}"
TMUXBIN="$(command -v tmux 2>/dev/null)"; [[ -z "$TMUXBIN" ]] && TMUXBIN="tmux"
STATE_DIR="${STATE_DIR:-${TMPDIR:-/tmp}/agent-sidebar}"
DATA_FILE="${STATE_DIR}/data"
DIRTY_FILE="${STATE_DIR}/dirty"
CLIENTS_DIR="${STATE_DIR}/clients"
ORDER_FILE="${HOME}/.tmux-sidebar-order"

mkdir -p "$STATE_DIR" "$CLIENTS_DIR"

PANE_ID="$TMUX_PANE"
SOCKET_DIR="${TMPDIR:-/tmp}/tmux-$(id -u)"

# ── Detectar contexto: sidebar server vs standalone ───────────────────────────
if [[ -n "$OUTER_TMUX_SOCKET" ]]; then
  # Corriendo dentro del sidebar server — OUTER_TMUX opera el servidor principal
  OUTER_TMUX=("$TMUXBIN" -S "$OUTER_TMUX_SOCKET")
  OUTER_SERVER="${OUTER_TMUX_SOCKET##*/}"
  CLIENT_KEY="sidebar-server"
  STATE_FILE="${STATE_DIR}/sidebar_server"
else
  # Modo standalone (retrocompatibilidad / desarrollo directo)
  OUTER_TMUX=("$TMUXBIN")
  OUTER_SERVER="${TMUX%%,*}"; OUTER_SERVER="${OUTER_SERVER##*/}"
  WIN_SESS=$($TMUXBIN display-message -t "$PANE_ID" -p '#{session_name}' 2>/dev/null)
  WIN_IDX=$($TMUXBIN  display-message -t "$PANE_ID" -p '#{window_index}'  2>/dev/null)
  STATE_KEY="${WIN_SESS//[^a-zA-Z0-9]/_}_${WIN_IDX}"
  STATE_FILE="${STATE_DIR}/sidebar_${STATE_KEY}"
  CLIENT_KEY="$PANE_ID"
fi

printf '%d' "$$" > "$CLIENTS_DIR/$CLIENT_KEY"
printf '%s'  "$PANE_ID" > "$STATE_FILE"

_RELOADING=0
_ANIMATOR_PID=0
_sidebar_cleanup() {
  kill "$_ANIMATOR_PID" 2>/dev/null
  rm -f "$CLIENTS_DIR/$CLIENT_KEY" "$STATE_FILE" "${STATE_DIR}/animator_active"
  if [[ -z "$OUTER_TMUX_SOCKET" && "$_RELOADING" != "1" ]]; then
    $TMUXBIN select-pane -t "$PANE_ID" -T "" 2>/dev/null
  fi
}
trap '_sidebar_cleanup' EXIT INT TERM
trap '_RELOADING=1; kill "$_ANIMATOR_PID" 2>/dev/null; exec "$0"' USR1
_WAKE=0
trap '_WAKE=1' USR2

# Animator: despierta el read -t 1 cada 200ms cuando hay ventanas working → spinner a ~5 FPS
_start_animator() {
  local _sd="$STATE_DIR" _tb="$TMUXBIN" _pid="$PANE_ID"
  while true; do
    sleep 0.2
    [[ -f "${_sd}/animator_active" ]] && "$_tb" send-keys -t "$_pid" $'\x1e' 2>/dev/null
  done
}
_start_animator &
_ANIMATOR_PID=$!

# Arrancar daemon si no está corriendo — en ambos modos.
# En sidebar-server: usar OUTER_TMUX_SOCKET para que el daemon vea el servidor real (no sidebar).
_dpid_file="${STATE_DIR}/daemon.pid"
if [[ ! -f "$_dpid_file" ]] || ! kill -0 "$(<"$_dpid_file")" 2>/dev/null; then
  if [[ -n "$OUTER_TMUX_SOCKET" ]]; then
    TMUX="${OUTER_TMUX_SOCKET},0,0" nohup bash "$PLUGIN_DIR/scripts/daemon.sh" >/dev/null 2>&1 &
  else
    nohup bash "$PLUGIN_DIR/scripts/daemon.sh" >/dev/null 2>&1 &
  fi
  disown $! 2>/dev/null  # evita el mensaje "Killed: 9" cuando r mata el daemon
  _i=0
  while [[ ! -f "$DATA_FILE" && $_i -lt 20 ]]; do sleep 0.1; (( _i++ )); done
fi

if [[ -z "$OUTER_TMUX_SOCKET" ]]; then
  $TMUXBIN select-pane -t "$PANE_ID" -T "Sessions" 2>/dev/null
fi

if [[ -f "${STATE_DIR}/just_visited" ]]; then
  _jv=$(<"${STATE_DIR}/just_visited"); rm -f "${STATE_DIR}/just_visited"
  _jvk="${_jv//[^a-zA-Z0-9_-]/_}"
  rm -f "${STATE_DIR}/${_jvk}.unread"
  printf '💤' > "${STATE_DIR}/${_jvk}.prev_icon"
fi

R=$'\033[0m';  G=$'\033[32m';  BG=$'\033[1;32m'
PU=$'\033[1;35m'; GR=$'\033[90m'; RD=$'\033[31m'; YL=$'\033[1;33m'; CY=$'\033[1;36m'; WH=$'\033[1;37m'

_SPIN_FRAME=0
_SPINNER=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
_HAS_WORKING=0
_CMD_BUF=""
_SEARCH_MODE=0
_SEARCH_QUERY=""
_SEARCH_SEL=0
_SEARCH_ITEMS=()

# ── Estado de navegación ──────────────────────────────────────────────────────
# SESSIONS_FLAT: orden de sesiones (preserva J/K del usuario)
# ITEMS_FLAT:    lista plana S|server|session y W|server|session|winidx
# SELECTED:      índice en ITEMS_FLAT (cursor único)
# CURSOR_ITEM:   identidad del item actual para re-encontrarlo tras rebuild
SESSIONS_FLAT=()
ITEMS_FLAT=()
SELECTED=0
CURSOR_ITEM=""
_INITIAL_SELECT=1   # posicionar cursor en sesión actual al primer render

file_mtime() { stat -f '%m' "$1" 2>/dev/null || stat -c '%Y' "$1" 2>/dev/null || echo 0; }

# ── Jump multi-servidor ───────────────────────────────────────────────────────
jump_to() {
  local _srv _rest _sess _win _t
  _srv="${1%%|*}"; _rest="${1#*|}"
  _sess="${_rest%%|*}"; _win="${_rest#*|}"
  [[ "$_win" == "$_sess" ]] && _win=""
  _t="$_sess"; [[ -n "$_win" ]] && _t="${_sess}:${_win}"
  if [[ "$_srv" == "$OUTER_SERVER" ]]; then
    "${OUTER_TMUX[@]}" switch-client -t "$_t" 2>/dev/null
  else
    "$TMUXBIN" -S "$SOCKET_DIR/$_srv" switch-client -t "$_t" 2>/dev/null
  fi
}

# ── Reordenamiento de sesiones ────────────────────────────────────────────────
save_session_order() {
  > "$ORDER_FILE"
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

# ── Render ────────────────────────────────────────────────────────────────────
render() {
  [[ ! -f "$DATA_FILE" ]] && return

  (( _SPIN_FRAME = (_SPIN_FRAME + 1) % 10 ))

  # Procesar just_visited: limpiar unread y marcar 💤 para evitar falso trigger posterior
  if [[ -f "${STATE_DIR}/just_visited" ]]; then
    local _jv; _jv=$(<"${STATE_DIR}/just_visited"); rm -f "${STATE_DIR}/just_visited"
    local _jvk="${_jv//[^a-zA-Z0-9_-]/_}"
    rm -f "${STATE_DIR}/${_jvk}.unread"
    printf '💤' > "${STATE_DIR}/${_jvk}.prev_icon"
  fi

  # Resolver sesión y ventana activa del outer server en este ciclo de render
  local _outer_sess _outer_win
  _outer_sess=$(cat "${STATE_DIR}/current_session" 2>/dev/null)
  if [[ -z "$_outer_sess" ]]; then
    _outer_sess="${WIN_SESS:-}"
    _outer_win="${WIN_IDX:-}"
  elif [[ -n "$_outer_sess" ]]; then
    _outer_win=$("${OUTER_TMUX[@]}" list-windows -t "$_outer_sess" \
      -F '#{window_active}|#{window_index}' 2>/dev/null \
      | awk -F'|' '$1=="1"{print $2; exit}')
  fi

  local W; W=$($TMUXBIN display-message -t "$PANE_ID" -p '#{pane_width}' 2>/dev/null)
  [[ -z "$W" ]] && W=28
  # Persiste el ancho actual para que nuevas ventanas abran el sidebar al mismo ancho
  local _sw; _sw=$(cat "${STATE_DIR}/sidebar_width" 2>/dev/null)
  [[ "$W" != "$_sw" ]] && printf '%s' "$W" > "${STATE_DIR}/sidebar_width"
  local max=$(( W - 6 )); [[ $max -lt 6 ]] && max=6
  local sep; sep=$(printf '─%.0s' $(seq 1 $W))

  # ── Actualizar SESSIONS_FLAT ──────────────────────────────────────────────
  local _data_sess=()
  while IFS='|' read -r _t _f1 _f2 _f3 _f4 _f5 _f6; do
    [[ "$_t" == "E" ]] && _data_sess+=("${_f1}|${_f2}")
  done < "$DATA_FILE"

  if [[ ${#SESSIONS_FLAT[@]} -eq 0 ]]; then
    if [[ -f "$ORDER_FILE" ]]; then
      local _o_srv _o_sess _target _found _d
      while IFS='|' read -r _o_srv _o_sess; do
        [[ -z "$_o_srv" || -z "$_o_sess" ]] && continue
        _target="${_o_srv}|${_o_sess}"; _found=false
        for _d in "${_data_sess[@]}"; do [[ "$_d" == "$_target" ]] && { _found=true; break; }; done
        [[ "$_found" == true ]] && SESSIONS_FLAT+=("$_target")
      done < "$ORDER_FILE"
    fi
    local _d _found _s
    for _d in "${_data_sess[@]}"; do
      _found=false
      for _s in "${SESSIONS_FLAT[@]}"; do [[ "$_d" == "$_s" ]] && { _found=true; break; }; done
      [[ "$_found" == false ]] && SESSIONS_FLAT+=("$_d")
    done
  elif [[ ${#_data_sess[@]} -ne ${#SESSIONS_FLAT[@]} ]]; then
    local _merged=() _e _d _found
    for _e in "${SESSIONS_FLAT[@]}"; do
      _found=false
      for _d in "${_data_sess[@]}"; do [[ "$_e" == "$_d" ]] && { _found=true; break; }; done
      [[ "$_found" == true ]] && _merged+=("$_e")
    done
    for _d in "${_data_sess[@]}"; do
      _found=false
      for _e in "${_merged[@]}"; do [[ "$_d" == "$_e" ]] && { _found=true; break; }; done
      [[ "$_found" == false ]] && _merged+=("$_d")
    done
    SESSIONS_FLAT=("${_merged[@]}")
  fi

  # ── Pre-leer DATA_FILE en arrays paralelos ────────────────────────────────
  local _S_srv=() _S_cur=()
  local _E_srv=() _E_sess=() _E_act=()
  local _W_srv=() _W_sess=() _W_widx=() _W_name=() _W_icon=() _W_last=()
  while IFS='|' read -r _t _f1 _f2 _f3 _f4 _f5 _f6; do
    case "$_t" in
      S) _S_srv+=("$_f1"); _S_cur+=("$_f2") ;;
      E) _E_srv+=("$_f1"); _E_sess+=("$_f2"); _E_act+=("$_f3") ;;
      W) _W_srv+=("$_f1"); _W_sess+=("$_f2"); _W_widx+=("$_f3")
         _W_name+=("$_f4"); _W_icon+=("$_f5"); _W_last+=("$_f6") ;;
    esac
  done < "$DATA_FILE"

  # ── Construir ITEMS_FLAT en orden del usuario ─────────────────────────────
  # Preservar orden de ventanas ya en ITEMS_FLAT si el conteo no cambió
  # (evita revertir orden tras un swap-window antes de que el daemon actualice DATA_FILE)
  local _old_items=("${ITEMS_FLAT[@]}")
  ITEMS_FLAT=()
  local _entry _srv _sess _k
  for _entry in "${SESSIONS_FLAT[@]}"; do
    _srv="${_entry%%|*}"; _sess="${_entry#*|}"
    ITEMS_FLAT+=("S|${_srv}|${_sess}")

    # Ventanas en DATA_FILE para este session
    local _data_wins=()
    _k=0
    for _ws in "${_W_srv[@]}"; do
      [[ "$_ws" == "$_srv" && "${_W_sess[$_k]}" == "$_sess" ]] && \
        _data_wins+=("${_W_widx[$_k]}")
      (( _k++ ))
    done
    [[ ${#_data_wins[@]} -eq 0 ]] && continue

    # Ventanas ya en ITEMS_FLAT (orden del usuario, puede diferir de DATA_FILE)
    local _old_wins=()
    local _oi _or _osrv _or2 _osess _owid
    for _oi in "${_old_items[@]}"; do
      [[ "${_oi%%|*}" != "W" ]] && continue
      _or="${_oi#*|}"
      _osrv="${_or%%|*}"
      _or2="${_or#*|}"
      _osess="${_or2%%|*}"
      _owid="${_or2#*|}"
      [[ "$_osrv" == "$_srv" && "$_osess" == "$_sess" ]] && _old_wins+=("$_owid")
    done

    # Si el conteo es igual: preservar orden existente; si cambió: merge
    local _wins=()
    if [[ ${#_old_wins[@]} -eq ${#_data_wins[@]} && ${#_old_wins[@]} -gt 0 ]]; then
      _wins=("${_old_wins[@]}")
    elif [[ ${#_old_wins[@]} -gt 0 ]]; then
      local _ow _dw _found
      for _ow in "${_old_wins[@]}"; do
        _found=false
        for _dw in "${_data_wins[@]}"; do [[ "$_ow" == "$_dw" ]] && { _found=true; break; }; done
        [[ "$_found" == true ]] && _wins+=("$_ow")
      done
      for _dw in "${_data_wins[@]}"; do
        _found=false
        for _ow in "${_wins[@]}"; do [[ "$_dw" == "$_ow" ]] && { _found=true; break; }; done
        [[ "$_found" == false ]] && _wins+=("$_dw")
      done
    else
      _wins=("${_data_wins[@]}")
    fi

    local _wid
    for _wid in "${_wins[@]}"; do
      ITEMS_FLAT+=("W|${_srv}|${_sess}|${_wid}")
    done
  done

  # Primer render: posicionar el cursor en la sesión donde vive este sidebar
  # (evita que SELECTED=0 apunte a la primera sesión de la lista, que puede no ser la actual)
  if [[ "$_INITIAL_SELECT" == "1" && ${#ITEMS_FLAT[@]} -gt 0 ]]; then
    _INITIAL_SELECT=0
    local _ini=0 _init_item _iir _iis
    local _init_target="${_outer_sess:-${WIN_SESS:-}}"
    for _init_item in "${ITEMS_FLAT[@]}"; do
      if [[ "${_init_item%%|*}" == "S" ]]; then
        _iir="${_init_item#*|}"; _iis="${_iir#*|}"
        [[ "$_iis" == "$_init_target" ]] && { SELECTED=$_ini; break; }
      fi
      (( _ini++ ))
    done
  fi

  # Re-encontrar el cursor si cambió el orden (después de J/K)
  if [[ -n "$CURSOR_ITEM" ]]; then
    local _ci=0 _cfound=false
    for _item in "${ITEMS_FLAT[@]}"; do
      [[ "$_item" == "$CURSOR_ITEM" ]] && { SELECTED=$_ci; _cfound=true; break; }
      (( _ci++ ))
    done
    CURSOR_ITEM=""
  fi
  [[ $SELECTED -ge ${#ITEMS_FLAT[@]} ]] && SELECTED=$(( ${#ITEMS_FLAT[@]} - 1 ))
  [[ $SELECTED -lt 0 ]] && SELECTED=0

  local _cur_sess="${_outer_sess:-}"

  # ── Precalcular conteos para el footer de estado ─────────────────────────
  local _wc=0 _uc=0 _ic_raw=0 _ec=0 _k2=0
  for _wi2 in "${_W_icon[@]}"; do
    case "$_wi2" in
      "⚡") (( _wc++ )); _HAS_WORKING=1 ;;
      "⏸") (( _ic_raw++ )) ;;
      "·")  (( _ec++ )) ;;
    esac
    if [[ "$_wi2" != "·" ]]; then
      local _uk2="${_W_srv[$_k2]//[^a-zA-Z0-9_-]/_}_${_W_sess[$_k2]//[^a-zA-Z0-9_-]/_}_${_W_widx[$_k2]}"
      [[ -f "${STATE_DIR}/${_uk2}.unread" ]] && (( _uc++ ))
    fi
    (( _k2++ ))
  done

  # ── Modo búsqueda inline ─────────────────────────────────────────────────────
  if [[ "$_SEARCH_MODE" == "1" ]]; then
    local _ql _fit _ftype _frest _fname _fl _si2 _stotal
    _ql=$(printf '%s' "$_SEARCH_QUERY" | tr '[:upper:]' '[:lower:]')
    _SEARCH_ITEMS=()
    for _fit in "${ITEMS_FLAT[@]}"; do
      _ftype="${_fit%%|*}"; _frest="${_fit#*|}"
      _fname=""
      if [[ "$_ftype" == "S" ]]; then
        _fname="${_frest#*|}"
      elif [[ "$_ftype" == "W" ]]; then
        local _fsrv="${_frest%%|*}" _fwr="${_frest#*|}"
        local _fss="${_fwr%%|*}" _fwid="${_fwr#*|}" _kk=0
        for _ws3 in "${_W_srv[@]}"; do
          if [[ "$_ws3" == "$_fsrv" && "${_W_sess[$_kk]}" == "$_fss" && "${_W_widx[$_kk]}" == "$_fwid" ]]; then
            _fname="${_W_name[$_kk]}"; break
          fi
          (( _kk++ ))
        done
      fi
      _fl=$(printf '%s' "$_fname" | tr '[:upper:]' '[:lower:]')
      if [[ -z "$_ql" || "$_fl" == *"$_ql"* ]]; then
        _SEARCH_ITEMS+=("$_fit")
      fi
    done

    _stotal=${#_SEARCH_ITEMS[@]}
    [[ $_SEARCH_SEL -ge $_stotal && $_stotal -gt 0 ]] && _SEARCH_SEL=$(( _stotal - 1 ))
    [[ $_SEARCH_SEL -lt 0 ]] && _SEARCH_SEL=0

    local buf="" mapbuf=""
    buf="${PU} ◈${R}  /${YL}${_SEARCH_QUERY}${GR}▌${R}"$'\n'
    mapbuf=$'\n'
    buf+="${GR}${sep}${R}"$'\n'; mapbuf+=$'\n'

    if [[ $_stotal -eq 0 ]]; then
      buf+="${GR} (sin resultados)${R}"$'\n'; mapbuf+=$'\n'
    else
      _si2=0
      for _fit in "${_SEARCH_ITEMS[@]}"; do
        _ftype="${_fit%%|*}"; _frest="${_fit#*|}"
        local _fc="$GR" _fcur=" "
        [[ $_si2 -eq $_SEARCH_SEL ]] && { _fc="$YL"; _fcur="›"; }
        if [[ "$_ftype" == "S" ]]; then
          local _fsess="${_frest#*|}"
          local _sessd="${_fsess:0:$max}"
          [[ ${#_fsess} -gt $max ]] && _sessd="${_fsess:0:$(( max - 1 ))}…"
          buf+="${_fc}${_fcur}   ${_sessd}${R}"$'\n'
          mapbuf+="${_frest%%|*}|${_fsess}"$'\n'
        elif [[ "$_ftype" == "W" ]]; then
          local _fsrv2="${_frest%%|*}" _fwr2="${_frest#*|}"
          local _fss2="${_fwr2%%|*}" _fwid2="${_fwr2#*|}" _wn2="" _kk2=0
          for _ws4 in "${_W_srv[@]}"; do
            if [[ "$_ws4" == "$_fsrv2" && "${_W_sess[$_kk2]}" == "$_fss2" && "${_W_widx[$_kk2]}" == "$_fwid2" ]]; then
              _wn2="${_W_name[$_kk2]}"; break
            fi
            (( _kk2++ ))
          done
          local _maxn2=$(( max - 3 )) _wdisp2
          [[ ${#_wn2} -gt $_maxn2 ]] && _wdisp2="${_wn2:0:$(( _maxn2 - 1 ))}…" || _wdisp2="${_wn2:0:$_maxn2}"
          buf+="${_fc}${_fcur}   ${_wdisp2}${R}"$'\n'
          mapbuf+="${_fsrv2}|${_fss2}|${_fwid2}"$'\n'
        fi
        (( _si2++ ))
      done
    fi

    buf+=$'\n'; mapbuf+=$'\n'
    buf+="${GR}${sep}${R}"$'\n'; mapbuf+=$'\n'
    buf+=" ${CY}⠿${R} ${_wc}  ${GR}○${R} $(( _ic_raw - _uc ))  ${YL}◉${R} ${_uc}  ${GR}·${R} ${_ec}"$'\n'
    buf+="${GR} [jk]nav [↵]go [Esc]cancel${R}"$'\n'
    mapbuf+=$'\n\n'

    printf '%s' "$mapbuf" > "${STATE_DIR}/rowmap.tmp"
    mv "${STATE_DIR}/rowmap.tmp" "${STATE_DIR}/rowmap"
    printf '\033[H\033[J%s' "$buf"
    return
  fi

  # Detectar sesión padre del cursor (para resaltado blanco en modo ventana)
  local _cursor_parent_item=""
  if [[ "${ITEMS_FLAT[$SELECTED]%%|*}" == "W" ]]; then
    local _cpi=$SELECTED
    while (( _cpi > 0 )); do
      (( _cpi-- ))
      if [[ "${ITEMS_FLAT[$_cpi]%%|*}" == "S" ]]; then
        _cursor_parent_item="${ITEMS_FLAT[$_cpi]}"; break
      fi
    done
  fi

  # ── Drill-down mode: "N." o "N.M" en el buffer → mostrar solo esa sesión ──
  local _drill_mode=0 _drill_snum=0 _drill_wnum="" _in_drill_sess=0 _win_ord=0
  if [[ "$_CMD_BUF" =~ ^:?([0-9]+)\.([0-9]*)$ ]]; then
    _drill_mode=1
    _drill_snum="${BASH_REMATCH[1]}"
    _drill_wnum="${BASH_REMATCH[2]}"
  fi

  # ── Construir buffer de display ───────────────────────────────────────────
  local buf="" mapbuf="" prev_server="" _sess_num=0 _ii=0

  if [[ -n "$_CMD_BUF" ]]; then
    buf+="${PU} ◈${R}  ${YL}${_CMD_BUF}${GR}▌${R}"$'\n'
  else
    buf+="${PU} ◈${R}  Claude"$'\n'
  fi
  mapbuf+=$'\n'
  buf+="${GR}${sep}${R}"$'\n'; mapbuf+=$'\n'

  for _item in "${ITEMS_FLAT[@]}"; do
    local _itype="${_item%%|*}" _irest="${_item#*|}"

    if [[ "$_itype" == "S" ]]; then
      local _srv="${_irest%%|*}" _sess="${_irest#*|}"

      (( _sess_num++ ))

      # En drill-down: saltar sesiones que no coinciden
      if [[ "$_drill_mode" == "1" ]]; then
        if [[ $_sess_num -ne $_drill_snum ]]; then
          _in_drill_sess=0; (( _ii++ )); continue
        fi
        _in_drill_sess=1; _win_ord=0
      fi

      # Header de servidor si cambia (solo en modo normal)
      if [[ "$_srv" != "$prev_server" ]]; then
        if [[ "$_drill_mode" == "0" ]]; then
          [[ -n "$prev_server" ]] && { buf+=$'\n'; mapbuf+=$'\n'; }
          local _is_cur=0; _k=0
          for _sn in "${_S_srv[@]}"; do
            [[ "$_sn" == "$_srv" ]] && { _is_cur="${_S_cur[$_k]}"; break; }; (( _k++ ))
          done
          local _sic="$GR"; [[ "$_is_cur" == "1" ]] && _sic="$CY"
          local _srvd="${_srv:0:$max}"; [[ ${#_srv} -gt $max ]] && _srvd="${_srv:0:$(( max-1 ))}…"
          buf+="${_sic}◎ ${_srvd}${R}"$'\n'; mapbuf+=$'\n'
        fi
        prev_server="$_srv"
      fi

      # ▶ indica la sesión que el cliente está viendo (current_session, actualizado por hook).
      local _is_act=0
      if [[ "$_srv" == "$OUTER_SERVER" ]]; then
        [[ "$_sess" == "$_cur_sess" ]] && _is_act=1
      else
        _k=0
        for _en in "${_E_srv[@]}"; do
          [[ "$_en" == "$_srv" && "${_E_sess[$_k]}" == "$_sess" ]] && { _is_act="${_E_act[$_k]}"; break; }
          (( _k++ ))
        done
      fi

      local _cursor=" " _ic="$GR" _nc=""
      [[ $_ii -eq $SELECTED ]] && { _cursor="›"; _ic="$YL"; }
      if [[ "$_is_act" == "1" ]]; then
        _cursor="▶"; _nc="$BG"
        [[ $_ii -eq $SELECTED ]] && _ic="$YL" || _ic="$BG"
      fi
      # Sesión padre del cursor en modo ventana → nombre en blanco brillante
      [[ -n "$_cursor_parent_item" && "$_item" == "$_cursor_parent_item" ]] && _nc="$WH"
      local _sessd="${_sess:0:$max}"; [[ ${#_sess} -gt $max ]] && _sessd="${_sess:0:$(( max-1 ))}…"
      if [[ "$_drill_mode" == "1" ]]; then
        # Drill-down: solo nombre, sin número ordinal
        buf+="${_ic}${_cursor} ${R}  ${_nc}${_sessd}${R}"$'\n'
      else
        buf+="${_ic}${_cursor} ${_sess_num}${R}  ${_nc}${_sessd}${R}"$'\n'
      fi
      mapbuf+="${_srv}|${_sess}"$'\n'

    elif [[ "$_itype" == "W" ]]; then
      # En drill-down: saltar ventanas de sesiones que no son la drill
      if [[ "$_drill_mode" == "1" && "$_in_drill_sess" == "0" ]]; then
        (( _ii++ )); continue
      fi
      (( _win_ord++ ))

      local _srv="${_irest%%|*}" _wrest="${_irest#*|}"
      local _sess="${_wrest%%|*}" _widx="${_wrest#*|}"

      # Buscar datos de la ventana
      local _wname="" _wicon="·" _islast="1"; _k=0
      for _ws in "${_W_srv[@]}"; do
        if [[ "$_ws" == "$_srv" && "${_W_sess[$_k]}" == "$_sess" && "${_W_widx[$_k]}" == "$_widx" ]]; then
          _wname="${_W_name[$_k]}"; _wicon="${_W_icon[$_k]}"; _islast="${_W_last[$_k]}"; break
        fi
        (( _k++ ))
      done

      # ── Unread tracking ──────────────────────────────────────────────────────
      local _key="${_srv//[^a-zA-Z0-9_-]/_}_${_sess//[^a-zA-Z0-9_-]/_}_${_widx}"
      local _flag_f="${STATE_DIR}/${_key}.unread" _prev_f="${STATE_DIR}/${_key}.prev_icon"

      # Determinar estado base desde el icono del daemon
      local _state
      case "$_wicon" in
        "·") _state="empty" ;;
        "⚡") _state="working"; _HAS_WORKING=1 ;;
        *)   _state="idle" ;;
      esac

      if [[ "$_state" == "empty" ]]; then
        rm -f "$_flag_f" "$_prev_f"
      elif [[ "$_srv" == "$OUTER_SERVER" && "$_sess" == "$_outer_sess" && "$_widx" == "$_outer_win" ]]; then
        rm -f "$_flag_f"; printf '💤' > "$_prev_f"
      else
        local _pi=""; [[ -f "$_prev_f" ]] && _pi=$(<"$_prev_f")
        [[ "$_pi" == "⚡" && "$_state" == "idle" ]] && touch "$_flag_f"
        [[ "$_state" == "working" ]] && rm -f "$_flag_f"
        printf '%s' "$_wicon" > "$_prev_f"
        [[ -f "$_flag_f" ]] && _state="unread"
      fi

      # Seleccionar icono y colores según estado
      local _display_icon _icon_col _name_col
      case "$_state" in
        empty)   _display_icon="·";                          _icon_col="$GR"; _name_col="$GR" ;;
        idle)    _display_icon="○";                          _icon_col="$GR"; _name_col="$GR" ;;
        working) _display_icon="${_SPINNER[$_SPIN_FRAME]}";  _icon_col="$CY"; _name_col="$CY" ;;
        unread)  _display_icon="◉";                          _icon_col="$YL"; _name_col="$YL" ;;
      esac

      local _br='└─'; [[ "$_islast" != "1" ]] && _br='├─'
      local _wpfx
      if [[ "$_drill_mode" == "1" ]]; then
        if [[ $_ii -eq $SELECTED ]]; then
          _wpfx="${YL}${_win_ord}▸${R}"
        elif [[ -n "$_drill_wnum" && "$_win_ord" -eq "$_drill_wnum" ]]; then
          _wpfx="${WH}${_win_ord} ${R}"
        else
          _wpfx="${GR}${_win_ord} ${R}"
        fi
      else
        _wpfx="  "; [[ $_ii -eq $SELECTED && -z "$_CMD_BUF" ]] && _wpfx=" ${YL}▸${R}"
      fi

      # Truncar nombre con … si excede el ancho
      local _maxn=$(( max-3 )) _wdisp
      if [[ ${#_wname} -gt $_maxn ]]; then
        _wdisp="${_wname:0:$(( _maxn - 1 ))}…"
      else
        _wdisp="${_wname:0:$_maxn}"
      fi

      if [[ "$_srv" == "$OUTER_SERVER" && "$_sess" == "$_outer_sess" && "$_widx" == "$_outer_win" ]]; then
        # Ventana activa: nombre siempre verde (foco), icono usa su color de estado
        # working=cyan spinner, idle=verde, para distinguir "aquí+working" de "aquí+idle"
        local _active_icon_col="$G"
        [[ "$_state" == "working" ]] && _active_icon_col="$CY"
        buf+="${_wpfx}${G}${_br}${R} ${_active_icon_col}${_display_icon}${R} ${G}${_wdisp}${R}"$'\n'
      else
        buf+="${_wpfx}${GR}${_br}${R} ${_icon_col}${_display_icon}${R} ${_name_col}${_wdisp}${R}"$'\n'
      fi
      mapbuf+="${_srv}|${_sess}|${_widx}"$'\n'
    fi

    (( _ii++ ))
  done

  [[ -n "$prev_server" ]] && { buf+=$'\n'; mapbuf+=$'\n'; }
  buf+="${GR}${sep}${R}"$'\n'
  buf+=" ${CY}⠿${R} ${_wc}  ${GR}○${R} $(( _ic_raw - _uc ))  ${YL}◉${R} ${_uc}  ${GR}·${R} ${_ec}"$'\n'
  buf+="${GR} [jk]nav [JK]mv [↵]go [/]find${R}"$'\n'
  buf+="${GR} [hl]mode [r]↺ [q]✕${R}"$'\n'
  mapbuf+=$'\n\n\n'

  printf '%s' "$mapbuf" > "${STATE_DIR}/rowmap.tmp"
  mv "${STATE_DIR}/rowmap.tmp" "${STATE_DIR}/rowmap"
  printf '\033[H\033[J%s' "$buf"
}

# ── Catálogo de comandos del command buffer ───────────────────────────────────
#
# DISEÑO:
#   1. `:` y dígitos activan el command buffer (estilo vim/tmux).
#      Los dígitos son el flujo más frecuente (N y N.M); no requieren prefijo.
#      ESC cancela el buffer y vuelve al modo normal.
#   2. `/` activa el modo búsqueda inline (_SEARCH_MODE) con navegación j/k
#      y Enter para navegar al resultado — no usa _CMD_BUF.
#   3. Shortcuts de una letra (r, q, j, k, J, K, h, l) viven FUERA del buffer
#      (modo navegación). Dentro del buffer son texto literal. Sin colisiones.
#
# CATÁLOGO — prefijos disjuntos: dígito, /, :
#   N          navegar a la sesión N (ordinal en la lista)
#   N.M        navegar a la sesión N, ventana M
#   /          búsqueda inline por nombre (modo _SEARCH_MODE, ver handle_key)
#   :kill      matar el item bajo el cursor (sesión o ventana)
#   :new       crear nueva sesión en el servidor activo
#   :rename X  renombrar el item bajo el cursor a X
_exec_cmd() {
  local _c="$1"

  case "$_c" in
    # ── :kill — matar sesión o ventana bajo el cursor ─────────────────────
    :kill|:k)
      local _ci="${ITEMS_FLAT[$SELECTED]:-}"
      local _ct="${_ci%%|*}" _cr="${_ci#*|}"
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
      touch "$DIRTY_FILE"
      return ;;

    # ── :new — crear nueva sesión en el servidor activo ───────────────────
    :new)
      "${OUTER_TMUX[@]}" new-session -d 2>/dev/null
      touch "$DIRTY_FILE"
      return ;;

    # ── :rename X — renombrar sesión o ventana bajo el cursor ─────────────
    :rename\ *)
      local _newname="${_c#:rename }"
      [[ -z "$_newname" ]] && return
      local _ci="${ITEMS_FLAT[$SELECTED]:-}"
      local _ct="${_ci%%|*}" _cr="${_ci#*|}"
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
      touch "$DIRTY_FILE"
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
    jump_to "${_wsrv}|${_wsess}|${_wid}"
    [[ "$_wsrv" == "$OUTER_SERVER" ]] && printf '%s' "$_wsess" > "${STATE_DIR}/current_session"
    printf '%s' "${_wsrv}|${_wsess}:${_wid}" > "${STATE_DIR}/just_visited"
    _ensure_sidebar "${_wsess}:${_wid}"
    $TMUXBIN send-keys -t "$PANE_ID" $'\x1e' 2>/dev/null
  else
    SELECTED=$_si
    jump_to "${_ssrv}|${_ssess}"
    [[ "$_ssrv" == "$OUTER_SERVER" ]] && printf '%s' "$_ssess" > "${STATE_DIR}/current_session"
    local _active_win; _active_win=$("${OUTER_TMUX[@]}" list-windows -t "$_ssess" \
      -F '#{window_active}|#{window_index}' 2>/dev/null | awk -F'|' '$1=="1"{print $2; exit}')
    [[ -n "$_active_win" ]] && _ensure_sidebar "${_ssess}:${_active_win}"
    $TMUXBIN send-keys -t "$PANE_ID" $'\x1e' 2>/dev/null
  fi
}

# Asegura que el pane del sidebar existe en la ventana destino
_ensure_sidebar() {
  local _dest="$1"
  local _server="tmux-agent-sidebar" _session="sidebar"
  local _sw; _sw=$(cat "${STATE_DIR}/sidebar_width" 2>/dev/null)
  [[ -z "$_sw" || ! "$_sw" =~ ^[0-9]+$ ]] && _sw=28

  local _live; _live=$("${OUTER_TMUX[@]}" list-panes -t "$_dest" \
    -F '#{pane_dead}|#{pane_id}|#{pane_title}' 2>/dev/null \
    | awk -F'|' '$1!="1" && $3=="Sessions"{print $2; exit}')
  if [[ -n "$_live" ]]; then
    "${OUTER_TMUX[@]}" select-pane -t "$_live" 2>/dev/null
    return
  fi

  bash "$PLUGIN_DIR/scripts/server-start.sh" 2>/dev/null

  local _dead; _dead=$("${OUTER_TMUX[@]}" list-panes -t "$_dest" \
    -F '#{pane_dead}|#{pane_id}|#{pane_title}' 2>/dev/null \
    | awk -F'|' '$1=="1" && $3=="Sessions"{print $2; exit}')

  if [[ -n "$_dead" ]]; then
    "${OUTER_TMUX[@]}" respawn-pane -t "$_dead" -k \
      "exec $TMUXBIN -L $_server attach-session -t $_session" 2>/dev/null
    "${OUTER_TMUX[@]}" select-pane -t "$_dead" 2>/dev/null
  else
    local _lp; _lp=$("${OUTER_TMUX[@]}" list-panes -t "$_dest" \
      -F '#{pane_left}|#{pane_id}' 2>/dev/null \
      | sort -t'|' -k1 -n | head -1 | cut -d'|' -f2)
    local _tgt="${_dest}"; [[ -n "$_lp" ]] && _tgt="$_lp"
    "${OUTER_TMUX[@]}" split-window -hb -l "$_sw" -t "$_tgt" \
      "exec $TMUXBIN -L $_server attach-session -t $_session" 2>/dev/null
    local _np; _np=$("${OUTER_TMUX[@]}" display-message -p '#{pane_id}' 2>/dev/null)
    [[ -n "$_np" ]] && "${OUTER_TMUX[@]}" select-pane -t "$_np" -T "Sessions" 2>/dev/null
  fi
}

# ── Manejo de teclas ──────────────────────────────────────────────────────────
handle_key() {
  local key="$1"
  local _total=${#ITEMS_FLAT[@]}

  # Detectar flechas
  if [[ "$key" == $'\033' ]]; then
    local _seq=""
    IFS= read -r -s -n2 -t 1 _seq 2>/dev/null
    case "$_seq" in
      "[A") key="UP" ;;   "[B") key="DOWN" ;;
      "[C") key="RIGHT" ;; "[D") key="LEFT" ;;
      *)    key="ESC" ;;
    esac
  fi

  # ── Modo comando: buffer activo — todo va al buffer ───────────────────────
  if [[ -n "$_CMD_BUF" ]]; then
    case "$key" in
      $'\x1e') ;;
      ""|$'\n'|$'\r') _exec_cmd "$_CMD_BUF"; _CMD_BUF="" ;;
      ESC)             _CMD_BUF="" ;;
      $'\x7f'|$'\x08') _CMD_BUF="${_CMD_BUF%?}" ;;
      *) _CMD_BUF+="$key" ;;
    esac
    return
  fi

  # ── Modo búsqueda inline ─────────────────────────────────────────────────────
  if [[ "$_SEARCH_MODE" == "1" ]]; then
    case "$key" in
      $'\x1e') ;;
      $'\x7f'|$'\x08')
        _SEARCH_QUERY="${_SEARCH_QUERY%?}"; _SEARCH_SEL=0 ;;
      $'\n'|$'\r')
        local _stotal=${#_SEARCH_ITEMS[@]}
        if [[ $_stotal -gt 0 && $_SEARCH_SEL -lt $_stotal ]]; then
          local _sit="${_SEARCH_ITEMS[$_SEARCH_SEL]}"
          local _stype="${_sit%%|*}" _srest="${_sit#*|}"
          if [[ "$_stype" == "S" ]]; then
            local _srv="${_srest%%|*}" _sess="${_srest#*|}"
            jump_to "${_srv}|${_sess}"
            [[ "$_srv" == "$OUTER_SERVER" ]] && printf '%s' "$_sess" > "${STATE_DIR}/current_session"
          elif [[ "$_stype" == "W" ]]; then
            local _srv="${_srest%%|*}" _wr="${_srest#*|}"
            local _sess="${_wr%%|*}" _win="${_wr#*|}"
            jump_to "${_srv}|${_sess}|${_win}"
            [[ "$_srv" == "$OUTER_SERVER" ]] && printf '%s' "$_sess" > "${STATE_DIR}/current_session"
            printf '%s' "${_srv}|${_sess}:${_win}" > "${STATE_DIR}/just_visited"
          fi
          local _sfi=0
          for _sfit in "${ITEMS_FLAT[@]}"; do
            [[ "$_sfit" == "$_sit" ]] && { SELECTED=$_sfi; break; }; (( _sfi++ ))
          done
        fi
        _SEARCH_MODE=0; _SEARCH_QUERY=""; _SEARCH_SEL=0; _SEARCH_ITEMS=() ;;
      ESC)
        _SEARCH_MODE=0; _SEARCH_QUERY=""; _SEARCH_SEL=0; _SEARCH_ITEMS=() ;;
      j|DOWN)
        [[ $(( _SEARCH_SEL + 1 )) -lt ${#_SEARCH_ITEMS[@]} ]] && (( _SEARCH_SEL++ )) ;;
      k|UP)
        [[ $_SEARCH_SEL -gt 0 ]] && (( _SEARCH_SEL-- )) ;;
      *)
        if [[ ${#key} -eq 1 ]]; then _SEARCH_QUERY+="$key"; _SEARCH_SEL=0; fi ;;
    esac
    return
  fi

  # ── Modo navegación normal ────────────────────────────────────────────────
  local _cur_item="${ITEMS_FLAT[$SELECTED]:-}"
  local _cur_type="${_cur_item%%|*}"
  local _cur_rest="${_cur_item#*|}"

  case "$key" in
    $'\x1e') ;; # wake-up

    # `:`, `/` y dígitos activan el buffer directamente (ver catálogo de comandos)
    ":") _CMD_BUF=":" ;;
    "/") _CMD_BUF="/" ;;
    [0-9]) _CMD_BUF="$key" ;;

    # `/` activa el modo búsqueda inline
    "/") _SEARCH_MODE=1; _SEARCH_QUERY=""; _SEARCH_SEL=0; _SEARCH_ITEMS=() ;;

    r|R)
      kill "$_ANIMATOR_PID" 2>/dev/null
      rm -f "${STATE_DIR}/animator_active"
      ps aux 2>/dev/null | grep "[d]aemon.sh" | grep -v grep | awk '{print $2}' \
        | xargs kill -9 2>/dev/null
      rm -f "${STATE_DIR}/daemon.pid"; rm -rf "${STATE_DIR}/daemon.lock"
      _RELOADING=1; exec "$0" ;;

    j|DOWN)
      if [[ "$_cur_type" == "S" ]]; then
        # Modo sesión: saltar al próximo S ignorando ventanas intermedias
        local _i=$SELECTED
        while (( _i + 1 < _total )); do
          (( _i++ ))
          [[ "${ITEMS_FLAT[$_i]%%|*}" == "S" ]] && { SELECTED=$_i; break; }
        done
      else
        # Modo ventana: moverse al próximo item solo si es W (pertenece al mismo session por estructura)
        local _next=$(( SELECTED + 1 ))
        [[ $_next -lt $_total && "${ITEMS_FLAT[$_next]%%|*}" == "W" ]] && SELECTED=$_next
      fi ;;

    k|UP)
      if [[ "$_cur_type" == "S" ]]; then
        # Modo sesión: saltar al S anterior
        local _i=$SELECTED
        while (( _i > 0 )); do
          (( _i-- ))
          [[ "${ITEMS_FLAT[$_i]%%|*}" == "S" ]] && { SELECTED=$_i; break; }
        done
      else
        # Modo ventana: item anterior solo si es W
        local _prev=$(( SELECTED - 1 ))
        [[ $_prev -ge 0 && "${ITEMS_FLAT[$_prev]%%|*}" == "W" ]] && SELECTED=$_prev
      fi ;;

    J)
      if [[ "$_cur_type" == "S" ]]; then
        local _sf_idx=0 _k=0
        for _e in "${SESSIONS_FLAT[@]}"; do
          [[ "$_e" == "$_cur_rest" ]] && { _sf_idx=$_k; break; }; (( _k++ ))
        done
        CURSOR_ITEM="$_cur_item"; move_session_down $_sf_idx
      elif [[ "$_cur_type" == "W" ]]; then
        move_window_down $SELECTED
      fi ;;

    K)
      if [[ "$_cur_type" == "S" ]]; then
        local _sf_idx=0 _k=0
        for _e in "${SESSIONS_FLAT[@]}"; do
          [[ "$_e" == "$_cur_rest" ]] && { _sf_idx=$_k; break; }; (( _k++ ))
        done
        CURSOR_ITEM="$_cur_item"; move_session_up $_sf_idx
      elif [[ "$_cur_type" == "W" ]]; then
        move_window_up $SELECTED
      fi ;;

    # → / l — entrar a las ventanas: ITEMS_FLAT garantiza que el siguiente item es W de este session
    RIGHT|l)
      if [[ "$_cur_type" == "S" ]]; then
        local _next=$(( SELECTED + 1 ))
        [[ $_next -lt $_total && "${ITEMS_FLAT[$_next]%%|*}" == "W" ]] && SELECTED=$_next
      fi ;;

    # ← / h / Esc — volver al header S: caminar atrás hasta el primer S
    LEFT|h|ESC)
      if [[ "$_cur_type" == "W" ]]; then
        local _si=$SELECTED
        while (( _si > 0 )); do
          (( _si-- ))
          [[ "${ITEMS_FLAT[$_si]%%|*}" == "S" ]] && { SELECTED=$_si; break; }
        done
      fi ;;

    # Enter — navegar al item seleccionado y marcar como visitado (limpia unread)
    $'\n'|$'\r')
      if [[ "$_cur_type" == "S" ]]; then
        local _srv="${_cur_rest%%|*}" _sess="${_cur_rest#*|}"
        jump_to "${_srv}|${_sess}"
        [[ "$_srv" == "$OUTER_SERVER" ]] && printf '%s' "$_sess" > "${STATE_DIR}/current_session"
        # Marcar la primera ventana del session como visitada
        local _first_win="" _ii2=0
        for _it2 in "${ITEMS_FLAT[@]}"; do
          if [[ "${_it2%%|*}" == "W" ]]; then
            local _r2="${_it2#*|}"; local _s2="${_r2%%|*}" _r3="${_r2#*|}" _ss2="${_r3%%|*}"
            [[ "$_s2" == "$_srv" && "$_ss2" == "$_sess" ]] && { _first_win="${_s2}:${_r3#*|}"; break; }
          fi
          (( _ii2++ ))
        done
        [[ -n "$_first_win" ]] && printf '%s' "${_srv}|${_first_win}" > "${STATE_DIR}/just_visited"
      elif [[ "$_cur_type" == "W" ]]; then
        local _srv="${_cur_rest%%|*}" _wr="${_cur_rest#*|}"
        local _sess="${_wr%%|*}" _win="${_wr#*|}"
        jump_to "${_srv}|${_sess}|${_win}"
        [[ "$_srv" == "$OUTER_SERVER" ]] && printf '%s' "$_sess" > "${STATE_DIR}/current_session"
        printf '%s' "${_srv}|${_sess}:${_win}" > "${STATE_DIR}/just_visited"
      fi ;;


    q|Q)
      if [[ -n "$OUTER_TMUX_SOCKET" ]]; then
        # Sidebar server: desconectar el cliente attach-session sin matar sidebar.sh
        $TMUXBIN detach-client 2>/dev/null
      else
        $TMUXBIN kill-pane -t "$PANE_ID" 2>/dev/null; exit 0
      fi ;;
  esac
}

# ── Loop principal ────────────────────────────────────────────────────────────
# read -t acepta solo enteros en bash 3.2 (macOS default)
# DIRTY_FILE es SOLO para el daemon — el sidebar no lo toca para evitar race conditions

# Render inicial inmediato
render
LAST_RENDER=$SECONDS
DATA_MTIME=$(file_mtime "$DATA_FILE")
SESS_MTIME=$(file_mtime "${STATE_DIR}/current_session")

while true; do
  # Re-render cuando DATA_FILE cambia (daemon), current_session cambia (navegación),
  # o cada 2s como fallback
  _cur_mtime=$(file_mtime "$DATA_FILE")
  _cur_sess_mtime=$(file_mtime "${STATE_DIR}/current_session")
  if [[ "$_cur_mtime" != "$DATA_MTIME" || "$_cur_sess_mtime" != "$SESS_MTIME" \
      || "$_WAKE" == "1" || "$_HAS_WORKING" == "1" ]] \
      || (( SECONDS - LAST_RENDER >= 2 )); then
    _WAKE=0; _HAS_WORKING=0
    DATA_MTIME="$_cur_mtime"
    SESS_MTIME="$_cur_sess_mtime"
    render
    LAST_RENDER=$SECONDS
    [[ "$_HAS_WORKING" == "1" ]] && touch "${STATE_DIR}/animator_active" \
                                 || rm -f "${STATE_DIR}/animator_active"
  fi

  if IFS= read -r -s -n1 -t 1 key 2>/dev/null; then
    handle_key "$key"
    _HAS_WORKING=0
    render
    DATA_MTIME=$(file_mtime "$DATA_FILE")
    SESS_MTIME=$(file_mtime "${STATE_DIR}/current_session")
    LAST_RENDER=$SECONDS
    [[ "$_HAS_WORKING" == "1" ]] && touch "${STATE_DIR}/animator_active" \
                                 || rm -f "${STATE_DIR}/animator_active"
  fi
done
