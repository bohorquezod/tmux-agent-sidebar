#!/bin/bash
# sidebar.sh — cliente del sidebar: cursor plano sobre sesiones y ventanas

# Deshabilitar echo y asegurar que \n produzca \r\n (ONLCR) en la pty.
# Evita que keypresses se muestren como texto durante las transiciones de exec.
stty -echo onlcr 2>/dev/null
printf '\033[?7l'  # deshabilitar auto-wrap: evita que el contenido antiguo se doble al achicar el pane
shopt -s checkwinsize 2>/dev/null  # bash actualiza $COLUMNS/$LINES en cada SIGWINCH

PLUGIN_DIR="${PLUGIN_DIR:-$(cd -P "$(dirname "$0")/.." && pwd)}"
TMUXBIN="$(command -v tmux 2>/dev/null)"; [[ -z "$TMUXBIN" ]] && TMUXBIN="tmux"
PLUGIN_VERSION="$(cat "$PLUGIN_DIR/VERSION" 2>/dev/null | tr -d '[:space:]')"
[[ -z "$PLUGIN_VERSION" ]] && PLUGIN_VERSION="dev"
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
  # Corriendo dentro del sidebar server o en modo popup — OUTER_TMUX opera el servidor principal
  OUTER_TMUX=("$TMUXBIN" -S "$OUTER_TMUX_SOCKET")
  OUTER_SERVER="${OUTER_TMUX_SOCKET##*/}"
  if [[ -n "$POPUP_MODE" ]]; then
    # Proceso standalone dentro del display-popup: CLIENT_KEY único por PID
    CLIENT_KEY="popup-$$"
    STATE_FILE="${STATE_DIR}/popup_$$"
  else
    CLIENT_KEY="sidebar-server"
    STATE_FILE="${STATE_DIR}/sidebar_server"
  fi
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
  printf '\033[?7h'  # re-habilitar auto-wrap al salir
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
_WINCH=0
_RESIZE=0
trap '_WINCH=1; _RESIZE=1' WINCH

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
_KILL_PENDING=""
_SEARCH_MODE=0
_SEARCH_QUERY=""
_SEARCH_SEL=0
_SEARCH_ITEMS=()
_RENAME_ITEM=""   # ITEMS_FLAT entry under rename
_RENAME_BUF=""    # rename edit buffer (initialized with current name)
_RENAME_TYPE=""   # "S" or "W"
_FILTER_STATUS="" # active icon filter: "working" | "idle" | "unread" | ""
_HELP_MODE=0

# Data arrays — global cache repopulado solo cuando DATA_FILE cambia
_S_srv=() _S_cur=()
_E_srv=() _E_sess=() _E_act=()
_W_srv=() _W_sess=() _W_widx=() _W_name=() _W_icon=() _W_agent=() _W_last=()
_RENDER_DATA_MTIME=""

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
PREVIEW_MODE=0      # p: toggle preview del pane bajo el cursor (off por defecto)

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

# ── Salto rápido: siguiente working (w) / siguiente unread (u) ────────────────
jump_next_working() {
  local _total=${#ITEMS_FLAT[@]}
  [[ $_total -eq 0 ]] && return
  local _start=$(( SELECTED + 1 )) _tries _i _item _type _irest _srv _wrest _sess _widx _icon
  for (( _tries=0; _tries<_total; _tries++ )); do
    _i=$(( (_start + _tries) % _total ))
    _item="${ITEMS_FLAT[$_i]}"; _type="${_item%%|*}"
    [[ "$_type" != "W" ]] && continue
    _irest="${_item#*|}"; _srv="${_irest%%|*}"; _wrest="${_irest#*|}"
    _sess="${_wrest%%|*}"; _widx="${_wrest#*|}"
    _icon=$(awk -F'|' -v s="$_srv" -v e="$_sess" -v w="$_widx" \
      '$1=="W"&&$2==s&&$3==e&&$4==w{print $6;exit}' "$DATA_FILE" 2>/dev/null)
    if [[ "$_icon" == "W" || "$_icon" == "L" ]]; then
      SELECTED=$_i
      [[ "$_srv" == "$OUTER_SERVER" ]] && _ensure_sidebar "${_sess}:${_widx}"
      jump_to "${_srv}|${_sess}|${_widx}"
      [[ "$_srv" == "$OUTER_SERVER" ]] && printf '%s' "$_sess" > "${STATE_DIR}/current_session"
      return
    fi
  done
}

jump_next_unread() {
  local _total=${#ITEMS_FLAT[@]}
  [[ $_total -eq 0 ]] && return
  local _start=$(( SELECTED + 1 )) _tries _i _item _type _irest _srv _wrest _sess _widx _key
  for (( _tries=0; _tries<_total; _tries++ )); do
    _i=$(( (_start + _tries) % _total ))
    _item="${ITEMS_FLAT[$_i]}"; _type="${_item%%|*}"
    [[ "$_type" != "W" ]] && continue
    _irest="${_item#*|}"; _srv="${_irest%%|*}"; _wrest="${_irest#*|}"
    _sess="${_wrest%%|*}"; _widx="${_wrest#*|}"
    _key="${_srv//[^a-zA-Z0-9_-]/_}_${_sess//[^a-zA-Z0-9_-]/_}_${_widx}"
    if [[ -f "${STATE_DIR}/${_key}.unread" ]]; then
      SELECTED=$_i
      [[ "$_srv" == "$OUTER_SERVER" ]] && _ensure_sidebar "${_sess}:${_widx}"
      jump_to "${_srv}|${_sess}|${_widx}"
      [[ "$_srv" == "$OUTER_SERVER" ]] && printf '%s' "$_sess" > "${STATE_DIR}/current_session"
      printf '%s' "${_srv}|${_sess}:${_widx}" > "${STATE_DIR}/just_visited"
      return
    fi
  done
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
    [[ $_parent_si -ge 0 ]] && CURSOR_ITEM="${ITEMS_FLAT[$_parent_si]}"
  fi

  touch "$DIRTY_FILE"
}

# ── Help overlay ─────────────────────────────────────────────────────────────
render_help() {
  local _sz W H
  _sz=$(stty size 2>/dev/null)
  W="${_sz##* }"; [[ ! "$W" =~ ^[0-9]+$ || "$W" -lt 4 ]] && W="${COLUMNS:-28}"; [[ "$W" -lt 4 ]] && W=28
  H="${_sz%% *}"; [[ ! "$H" =~ ^[0-9]+$ || "$H" -lt 4 ]] && H="${LINES:-24}";   [[ "$H" -lt 4 ]] && H=24
  local sep; sep=$(printf '─%.0s' $(seq 1 $W))
  local buf=""
  buf+=" ${PU}◈${R}  ${WH}Help${R}"$'\n'
  buf+="${GR}${sep}${R}"$'\n'
  buf+=$'\n'
  buf+=" ${GR}Navigation${R}"$'\n'
  buf+=" ${WH}j/↓${R}  next session/win"$'\n'
  buf+=" ${WH}k/↑${R}  prev session/win"$'\n'
  buf+=" ${WH}l/→${R}  enter windows"$'\n'
  buf+=" ${WH}h/←${R}  back to session"$'\n'
  buf+=" ${WH}↵${R}    jump to item"$'\n'
  buf+=$'\n'
  buf+=" ${GR}Jump${R}"$'\n'
  buf+=" ${WH}w${R}    next working ${CY}⠿${R}"$'\n'
  buf+=" ${WH}u${R}    next unread  ${YL}◉${R}"$'\n'
  buf+=$'\n'
  buf+=" ${GR}Reorder${R}"$'\n'
  buf+=" ${WH}J${R}    move down"$'\n'
  buf+=" ${WH}K${R}    move up"$'\n'
  buf+=$'\n'
  buf+=" ${GR}Other${R}"$'\n'
  buf+=" ${WH}:${R}    command  ${GR}N / N.M${R}"$'\n'
  buf+=" ${WH}r${R}    reload"$'\n'
  buf+=" ${WH}q${R}    quit"$'\n'
  buf+=$'\n'
  buf+="${GR}${sep}${R}"$'\n'
  buf+="${GR} ? or any key to close${R}"$'\n'
  buf+=" ${GR}v${PLUGIN_VERSION}${R}"
  printf '\033[H\033[J%s' "$buf"
}

# ── Render ────────────────────────────────────────────────────────────────────
render() {
  [[ "$_HELP_MODE" -eq 1 ]] && { render_help; return; }
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
  local _df_mtime; _df_mtime=$(file_mtime "$DATA_FILE")
  local _search_fast_path=0
  [[ "$_SEARCH_MODE" == "1" && "$_df_mtime" == "$_RENDER_DATA_MTIME" && ${#ITEMS_FLAT[@]} -gt 0 ]] && _search_fast_path=1
  if [[ -z "$_outer_sess" ]]; then
    _outer_sess="${WIN_SESS:-}"
    _outer_win="${WIN_IDX:-}"
  elif [[ "$_search_fast_path" == "0" ]]; then
    _outer_win=$("${OUTER_TMUX[@]}" list-windows -t "$_outer_sess" \
      -F '#{window_active}|#{window_index}' 2>/dev/null \
      | awk -F'|' '$1=="1"{print $2; exit}')
  fi

  # stty size lee TIOCGWINSZ directamente — refleja el tamaño real del pty incluso cuando
  # $COLUMNS no se ha actualizado aún (bash solo lo actualiza tras comandos externos, no read).
  local _sz W H
  _sz=$(stty size 2>/dev/null)
  W="${_sz##* }"; [[ ! "$W" =~ ^[0-9]+$ || "$W" -lt 4 ]] && W="${COLUMNS:-28}"; [[ "$W" -lt 4 ]] && W=28
  H="${_sz%% *}"; [[ ! "$H" =~ ^[0-9]+$ || "$H" -lt 4 ]] && H="${LINES:-24}";   [[ "$H" -lt 4 ]] && H=24
  # Persiste el ancho actual por servidor para que nuevas ventanas abran al mismo ancho.
  # Durante drag activo (SIGWINCH) sincronizar todos los panes sidebar para evitar que
  # el servidor rebote entre anchos de distintos clientes.
  local _srv_key="${OUTER_SERVER//[^a-zA-Z0-9_-]/_}"
  local _width_f="${STATE_DIR}/sidebar_width_${_srv_key}"
  [[ ! -f "$_width_f" && -f "${STATE_DIR}/sidebar_width" ]] && cp "${STATE_DIR}/sidebar_width" "$_width_f"
  local _sw; _sw=$(cat "$_width_f" 2>/dev/null)
  if [[ "$W" != "$_sw" ]]; then
    printf '%s' "$W" > "$_width_f"
    printf '%s' "$W" > "${STATE_DIR}/sidebar_width"
    if [[ "$_RESIZE" == "1" ]]; then
      _RESIZE=0
      "${OUTER_TMUX[@]}" list-panes -a -F '#{pane_id}|#{pane_title}|#{pane_width}' 2>/dev/null \
        | while IFS='|' read -r _spid _spt _spw; do
            [[ "$_spt" == "Sessions" && "$_spw" != "$W" ]] && \
              "${OUTER_TMUX[@]}" resize-pane -t "$_spid" -x "$W" 2>/dev/null
          done
    fi
  fi
  local max=$(( W - 6 )); [[ $max -lt 6 ]] && max=6
  local sep; sep=$(printf '─%.0s' $(seq 1 $W))

  if [[ "$_search_fast_path" == "0" ]]; then
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
  _S_srv=() _S_cur=()
  _E_srv=() _E_sess=() _E_act=()
  _W_srv=() _W_sess=() _W_widx=() _W_name=() _W_icon=() _W_agent=() _W_last=()
  while IFS='|' read -r _t _f1 _f2 _f3 _f4 _f5 _f6 _f7; do
    case "$_t" in
      S) _S_srv+=("$_f1"); _S_cur+=("$_f2") ;;
      E) _E_srv+=("$_f1"); _E_sess+=("$_f2"); _E_act+=("$_f3") ;;
      W) _W_srv+=("$_f1"); _W_sess+=("$_f2"); _W_widx+=("$_f3")
         _W_name+=("$_f4"); _W_icon+=("$_f5"); _W_agent+=("$_f6"); _W_last+=("$_f7") ;;
    esac
  done < "$DATA_FILE"
  _RENDER_DATA_MTIME="$_df_mtime"

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
  fi  # end fast-path guard
  [[ $SELECTED -ge ${#ITEMS_FLAT[@]} ]] && SELECTED=$(( ${#ITEMS_FLAT[@]} - 1 ))
  [[ $SELECTED -lt 0 ]] && SELECTED=0

  local _cur_sess="${_outer_sess:-}"

  # ── Precalcular conteos para el footer de estado ─────────────────────────
  local _wc=0 _uc=0 _ic_raw=0 _ec=0 _pc=0 _lc=0 _xc=0 _k2=0
  for _wi2 in "${_W_icon[@]}"; do
    case "$_wi2" in
      "W") (( _wc++ )); _HAS_WORKING=1 ;;
      "I") (( _ic_raw++ )) ;;
      "E") (( _ec++ )) ;;
      "P") (( _pc++ )) ;;
      "L") (( _lc++ )); _HAS_WORKING=1 ;;
      "X") (( _xc++ )) ;;
    esac
    if [[ "$_wi2" != "E" ]]; then
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
    buf+=" ${CY}⠿${R} ${_wc}  ${RD}?${R} ${_pc}  ${YL}↺${R} ${_lc}  ${RD}✗${R} ${_xc}  ${GR}○${R} $(( _ic_raw - _uc ))  ${YL}◉${R} ${_uc}  ${GR}·${R} ${_ec}"$'\n'
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

  # Mode indicator: [NAV] | [CMD] <buffer> | [SRCH] <query> (search: future)
  local _mode_label _hdr_text _hdr_len _pad_len _hdr_spaces
  if [[ -n "$_CMD_BUF" ]]; then
    _mode_label="[CMD]"
    _hdr_text="${_CMD_BUF}▌"
  elif [[ -n "$_RENAME_ITEM" ]]; then
    _mode_label="[REN]"
    _hdr_text="Rename: ${_RENAME_BUF}▌"
  else
    _mode_label="[NAV]"
    _hdr_text="Claude"
  fi
  # " ◈  " = 4 visible chars; 1 space before mode label
  _hdr_len=$(( 4 + ${#_hdr_text} ))
  _pad_len=$(( W - _hdr_len - 1 - ${#_mode_label} ))
  [[ $_pad_len -lt 0 ]] && _pad_len=0
  _hdr_spaces=$(printf '%*s' "$_pad_len" "")

  if [[ -n "$_CMD_BUF" ]]; then
    buf+="${PU} ◈${R}  ${YL}${_CMD_BUF}${GR}▌${R}${_hdr_spaces}${GR}${_mode_label}${R}"$'\n'
    mapbuf+=$'\n'
    local _hint; _hint=$(_cmd_hint "$_CMD_BUF")
    if [[ -n "$_hint" ]]; then
      buf+="${GR}  · ${_hint}${R}"$'\n'; mapbuf+=$'\n'
    fi
  elif [[ -n "$_RENAME_ITEM" ]]; then
    buf+="${PU} ◈${R}  ${CY}Rename:${R} ${YL}${_RENAME_BUF}${GR}▌${R}${_hdr_spaces}${GR}${_mode_label}${R}"$'\n'
    mapbuf+=$'\n'
  else
    buf+="${PU} ◈${R}  Claude${_hdr_spaces}${GR}${_mode_label}${R}"$'\n'
    mapbuf+=$'\n'
    if [[ -n "$_FILTER_STATUS" ]]; then
      buf+="${YL}  ⟨filter: ${_FILTER_STATUS}⟩${GR} [ESC]clear${R}"$'\n'; mapbuf+=$'\n'
    fi
  fi
  buf+="${GR}${sep}${R}"$'\n'; mapbuf+=$'\n'

  # Pre-scan para filtro de estado: construir lista de sesiones con ventanas matching
  local _filt_skeys=""
  if [[ -n "$_FILTER_STATUS" ]]; then
    local _fk=0
    for _wi2 in "${_W_icon[@]}"; do
      local _fmatch=0
      case "$_FILTER_STATUS" in
        working) [[ "$_wi2" == "W" || "$_wi2" == "L" ]] && _fmatch=1 ;;
        idle)
          local _fkey2="${_W_srv[$_fk]//[^a-zA-Z0-9_-]/_}_${_W_sess[$_fk]//[^a-zA-Z0-9_-]/_}_${_W_widx[$_fk]}"
          [[ "$_wi2" != "E" && "$_wi2" != "W" && "$_wi2" != "L" && ! -f "${STATE_DIR}/${_fkey2}.unread" ]] && _fmatch=1 ;;
        unread)
          local _fkey2="${_W_srv[$_fk]//[^a-zA-Z0-9_-]/_}_${_W_sess[$_fk]//[^a-zA-Z0-9_-]/_}_${_W_widx[$_fk]}"
          [[ -f "${STATE_DIR}/${_fkey2}.unread" ]] && _fmatch=1 ;;
      esac
      [[ "$_fmatch" == "1" ]] && _filt_skeys+=" ${_W_srv[$_fk]}|${_W_sess[$_fk]}"
      (( _fk++ ))
    done
  fi

  for _item in "${ITEMS_FLAT[@]}"; do
    local _itype="${_item%%|*}" _irest="${_item#*|}"

    if [[ "$_itype" == "S" ]]; then
      local _srv="${_irest%%|*}" _sess="${_irest#*|}"

      (( _sess_num++ ))

      # Filtro de estado: saltar sesiones sin ventanas matching
      if [[ -n "$_FILTER_STATUS" && "$_filt_skeys" != *" ${_srv}|${_sess}"* ]]; then
        (( _ii++ )); continue
      fi

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
          local _fill_len=$(( W - 4 - ${#_srvd} ))
          local _fill=""
          [[ $_fill_len -gt 0 ]] && _fill=$(printf '─%.0s' $(seq 1 $_fill_len))
          buf+="${_sic}── ${_srvd} ${_fill}${R}"$'\n'; mapbuf+=$'\n'
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
      [[ $_ii -eq $SELECTED && -z "$_CMD_BUF" ]] && { _cursor="›"; _ic="$YL"; }
      if [[ "$_is_act" == "1" ]]; then
        _cursor="▶"; _nc="$BG"
        [[ $_ii -eq $SELECTED ]] && _ic="$YL" || _ic="$BG"
      fi
      # Sesión padre del cursor en modo ventana → nombre en blanco brillante
      [[ -n "$_cursor_parent_item" && "$_item" == "$_cursor_parent_item" ]] && _nc="$WH"
      [[ -n "$_KILL_PENDING" && "$_item" == "$_KILL_PENDING" ]] && { _ic="$RD"; _nc="$RD"; _cursor="✕"; }
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
      local _wname="" _wicon="E" _wagent="" _islast="1"; _k=0
      for _ws in "${_W_srv[@]}"; do
        if [[ "$_ws" == "$_srv" && "${_W_sess[$_k]}" == "$_sess" && "${_W_widx[$_k]}" == "$_widx" ]]; then
          _wname="${_W_name[$_k]}"; _wicon="${_W_icon[$_k]}"
          _wagent="${_W_agent[$_k]:-}"; _islast="${_W_last[$_k]}"; break
        fi
        (( _k++ ))
      done

      # Filtro de estado: saltar ventanas que no coinciden
      if [[ -n "$_FILTER_STATUS" ]]; then
        local _fwkey="${_srv//[^a-zA-Z0-9_-]/_}_${_sess//[^a-zA-Z0-9_-]/_}_${_widx}"
        local _fwmatch=0
        case "$_FILTER_STATUS" in
          working) [[ "$_wicon" == "W" || "$_wicon" == "L" ]] && _fwmatch=1 ;;
          idle)    [[ "$_wicon" != "E" && "$_wicon" != "W" && "$_wicon" != "L" && ! -f "${STATE_DIR}/${_fwkey}.unread" ]] && _fwmatch=1 ;;
          unread)  [[ -f "${STATE_DIR}/${_fwkey}.unread" ]] && _fwmatch=1 ;;
        esac
        [[ "$_fwmatch" == "0" ]] && { (( _ii++ )); continue; }
      fi

      # ── Unread tracking ──────────────────────────────────────────────────────
      local _key="${_srv//[^a-zA-Z0-9_-]/_}_${_sess//[^a-zA-Z0-9_-]/_}_${_widx}"
      local _flag_f="${STATE_DIR}/${_key}.unread" _prev_f="${STATE_DIR}/${_key}.prev_icon"

      # Determinar estado base desde el icono del daemon
      local _state
      case "$_wicon" in
        "E") _state="empty" ;;
        "W") _state="working"; _HAS_WORKING=1 ;;
        "P") _state="blocked" ;;
        "L") _state="loop";    _HAS_WORKING=1 ;;
        "X") _state="crashed" ;;
        *)   _state="idle" ;;
      esac

      if [[ "$_state" == "empty" ]]; then
        rm -f "$_flag_f" "$_prev_f"
      elif [[ "$_srv" == "$OUTER_SERVER" && "$_sess" == "$_outer_sess" && "$_widx" == "$_outer_win" ]]; then
        rm -f "$_flag_f"; printf '💤' > "$_prev_f"
      else
        local _pi=""; [[ -f "$_prev_f" ]] && _pi=$(<"$_prev_f")
        # Unread: W→idle-like (incluye blocked, loop, idle)
        [[ "$_pi" == "W" && ( "$_state" == "idle" || "$_state" == "blocked" || "$_state" == "loop" ) ]] && touch "$_flag_f"
        [[ "$_state" == "working" ]] && rm -f "$_flag_f"
        printf '%s' "$_wicon" > "$_prev_f"
        [[ -f "$_flag_f" && "$_state" != "working" ]] && _state="unread"
      fi

      # Seleccionar icono y colores según estado
      local _display_icon _icon_col _name_col
      if [[ -n "$_wagent" ]]; then
        # Sub-agente con nombre: sigla como icono, color según estado
        _display_icon="$_wagent"
        case "$_state" in
          empty)   _icon_col="$GR"; _name_col="$GR" ;;
          working) _icon_col="$CY"; _name_col="$CY" ;;
          idle)    _icon_col="$GR"; _name_col="$GR" ;;
          blocked) _icon_col="$RD"; _name_col="$RD" ;;
          loop)    _icon_col="$YL"; _name_col="$YL" ;;
          crashed) _icon_col="$RD"; _name_col="$GR" ;;
          unread)  _icon_col="$YL"; _name_col="$YL" ;;
        esac
      else
        case "$_state" in
          empty)   _display_icon="·";                          _icon_col="$GR"; _name_col="$GR" ;;
          idle)    _display_icon="○";                          _icon_col="$GR"; _name_col="$GR" ;;
          working) _display_icon="${_SPINNER[$_SPIN_FRAME]}";  _icon_col="$CY"; _name_col="$CY" ;;
          blocked) _display_icon="?";                          _icon_col="$RD"; _name_col="$RD" ;;
          loop)    _display_icon="↺";                          _icon_col="$YL"; _name_col="$YL" ;;
          crashed) _display_icon="✗";                          _icon_col="$RD"; _name_col="$GR" ;;
          unread)  _display_icon="◉";                          _icon_col="$YL"; _name_col="$YL" ;;
        esac
      fi

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

      if [[ -n "$_KILL_PENDING" && "$_item" == "$_KILL_PENDING" ]]; then
        buf+="${_wpfx}${RD}${_br}${R} ${RD}✕${R} ${RD}${_wdisp}${R}"$'\n'
      elif [[ "$_srv" == "$OUTER_SERVER" && "$_sess" == "$_outer_sess" && "$_widx" == "$_outer_win" ]]; then
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

  # ── Área de preview ────────────────────────────────────────────────────────
  if [[ "$PREVIEW_MODE" == "1" ]]; then
    local _pitem="${ITEMS_FLAT[$SELECTED]:-}"
    if [[ "${_pitem%%|*}" == "W" ]]; then
      local _pr="${_pitem#*|}"
      local _psrv="${_pr%%|*}"
      local _pr2="${_pr#*|}"
      local _psess="${_pr2%%|*}"
      local _pwidx="${_pr2#*|}"
      local _pkey="${_psrv//[^a-zA-Z0-9_-]/_}_${_psess//[^a-zA-Z0-9_-]/_}_${_pwidx}"
      local _cap_file="${STATE_DIR}/captures/${_pkey}"
      local _preview_lines _pl
      _preview_lines=$(tail -n 10 "$_cap_file" 2>/dev/null)
      if [[ -n "$_preview_lines" ]]; then
        while IFS= read -r _pl || [[ -n "$_pl" ]]; do
          if [[ ${#_pl} -gt $W ]]; then _pl="${_pl:0:$(( W - 1 ))}…"; fi
          buf+="${GR}${_pl}${R}"$'\n'
          mapbuf+=$'\n'
        done <<< "$_preview_lines"
      fi
    fi
  fi

  buf+=" ${CY}⠿${R} ${_wc}  ${GR}○${R} $(( _ic_raw - _uc ))  ${YL}◉${R} ${_uc}  ${GR}·${R} ${_ec}"$'\n'
  if [[ -n "$POPUP_MODE" ]]; then
    buf+="${GR} [jk]nav [↵]go·close${R}"$'\n'
    buf+="${GR} [:]cmd [q][Esc]✕${R}"$'\n'
  elif [[ -n "$_KILL_PENDING" ]]; then
    buf+="${RD} [x]confirm kill · [ESC]cancel${R}"$'\n'
    buf+="${GR} [jk]nav [:]cmd [hl]mode [R]↺ [q]✕${R}"$'\n'
  else
    buf+="${GR} [jk]nav [JK]mv [↵]go [/]find${R}"$'\n'
    buf+="${GR} [:]cmd [hl]mode [p]👁 [x]kill [r]ren [R]↺ [q]✕${R}"$'\n'
  fi
  buf+=" ${GR}v${PLUGIN_VERSION}${R}"
  mapbuf+=$'\n\n\n'

  printf '%s' "$mapbuf" > "${STATE_DIR}/rowmap.tmp"
  mv "${STATE_DIR}/rowmap.tmp" "${STATE_DIR}/rowmap"
  printf '\033[H\033[J%s' "$buf"
}

# ── Live command hint ─────────────────────────────────────────────────────────
# Devuelve una línea de ayuda para el partial _CMD_BUF actual.
_cmd_hint() {
  local _b="$1"
  [[ ${#_b} -lt 2 ]] && return  # `:` solo no muestra hint
  if [[ "$_b" =~ ^:?[0-9]+\.[0-9] ]]; then
    printf ':N.M — navigate to session N, window M'
  elif [[ "$_b" =~ ^:?[0-9]+$ ]]; then
    printf ':N — navigate to session N'
  elif [[ ":filter" == "${_b%%[^:a-z]*}"* && ${#_b} -ge 3 ]]; then
    printf ':filter working|idle|unread — show matching windows'
  elif [[ ":kill" == "${_b%%[^:a-kl]*}"* ]]; then
    printf ':kill [N[.M]] — kill session or window'
  elif [[ ":move" == "${_b%%[^:a-mov]*}"* ]]; then
    printf ':move N N2 — reorder session or window'
  elif [[ ":new" == "${_b%%[^:a-new]*}"* ]]; then
    printf ':new — create new session'
  elif [[ ":rename" == "${_b%%[^:a-ren]*}"* ]]; then
    printf ':rename [N[.M]] <name> — rename session or window'
  fi
}

# ── Resolver item por ordinal (N o N.M) desde ITEMS_FLAT ─────────────────────
# Salida: escribe en las variables globales _ri_ci, _ri_ct, _ri_cr
# Retorna 1 si no encuentra el item.
_resolve_ordinal() {
  local _snum="$1" _wnum="${2:-}"
  _ri_ci=""; _ri_ct=""; _ri_cr=""
  local _n=0 _ii=0 _si=-1
  for _it in "${ITEMS_FLAT[@]}"; do
    [[ "${_it%%|*}" == "S" ]] && { (( _n++ )); [[ $_n -eq $_snum ]] && { _si=$_ii; break; }; }
    (( _ii++ ))
  done
  [[ $_si -lt 0 ]] && return 1
  if [[ -z "$_wnum" ]]; then
    _ri_ci="${ITEMS_FLAT[$_si]}"; _ri_ct="S"; _ri_cr="${_ri_ci#*|}"; return 0
  fi
  local _wn=0 _wi=$(( _si + 1 )) _wfound=-1
  while [[ $_wi -lt ${#ITEMS_FLAT[@]} ]]; do
    local _wit="${ITEMS_FLAT[$_wi]}"
    [[ "${_wit%%|*}" == "S" ]] && break
    [[ "${_wit%%|*}" == "W" ]] && { (( _wn++ )); [[ $_wn -eq $_wnum ]] && { _wfound=$_wi; break; }; }
    (( _wi++ ))
  done
  [[ $_wfound -lt 0 ]] && return 1
  _ri_ci="${ITEMS_FLAT[$_wfound]}"; _ri_ct="W"; _ri_cr="${_ri_ci#*|}"; return 0
}
_ri_ci="" _ri_ct="" _ri_cr=""

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
        _ci="$_ri_ci"; _ct="$_ri_ct"; _cr="$_ri_cr"
      elif [[ "$_args" =~ ^([0-9]+)$ ]]; then
        _resolve_ordinal "${BASH_REMATCH[1]}" || return
        _ci="$_ri_ci"; _ct="$_ri_ct"; _cr="$_ri_cr"
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
      local _src="${_args%% *}" _dst="${_args#"$_src" }"
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

# Asegura que el pane del sidebar existe en la ventana destino
_ensure_sidebar() {
  local _dest="$1"
  local _server="tmux-agent-sidebar" _session="sidebar"
  local _srv_key="${OUTER_SERVER//[^a-zA-Z0-9_-]/_}"
  local _width_f="${STATE_DIR}/sidebar_width_${_srv_key}"
  [[ ! -f "$_width_f" && -f "${STATE_DIR}/sidebar_width" ]] && cp "${STATE_DIR}/sidebar_width" "$_width_f"
  local _sw; _sw=$(cat "$_width_f" 2>/dev/null)
  if [[ -z "$_sw" || ! "$_sw" =~ ^[0-9]+$ ]]; then
    _sw=$("${OUTER_TMUX[@]}" show-option -gqv @agent-sidebar-width 2>/dev/null)
    [[ -z "$_sw" || ! "$_sw" =~ ^[0-9]+$ ]] && _sw=28
  fi

  local _live; _live=$("${OUTER_TMUX[@]}" list-panes -t "$_dest" \
    -F '#{pane_dead}|#{pane_id}|#{pane_title}' 2>/dev/null \
    | awk -F'|' '$1!="1" && $3=="Sessions"{print $2; exit}')
  if [[ -n "$_live" ]]; then
    local _live_w; _live_w=$("${OUTER_TMUX[@]}" display-message -t "$_live" -p '#{pane_width}' 2>/dev/null)
    [[ -n "$_live_w" && "$_live_w" != "$_sw" ]] && \
      "${OUTER_TMUX[@]}" resize-pane -t "$_live" -x "$_sw" 2>/dev/null
    "${OUTER_TMUX[@]}" select-pane -t "$_live" 2>/dev/null
    _kill_extra_sidebars "$_dest" "$_live"
    return
  fi

  bash "$PLUGIN_DIR/scripts/server-start.sh" 2>/dev/null

  local _dead; _dead=$("${OUTER_TMUX[@]}" list-panes -t "$_dest" \
    -F '#{pane_dead}|#{pane_id}|#{pane_title}' 2>/dev/null \
    | awk -F'|' '$1=="1" && $3=="Sessions"{print $2; exit}')

  if [[ -n "$_dead" ]]; then
    "${OUTER_TMUX[@]}" respawn-pane -t "$_dead" -k \
      "exec $TMUXBIN -L $_server attach-session -t $_session" 2>/dev/null
    "${OUTER_TMUX[@]}" select-pane -t "$_dead" -T "Sessions" 2>/dev/null
    _kill_extra_sidebars "$_dest" "$_dead"
  else
    local _lp; _lp=$("${OUTER_TMUX[@]}" list-panes -t "$_dest" \
      -F '#{pane_left}|#{pane_id}' 2>/dev/null \
      | sort -t'|' -k1 -n | head -1 | cut -d'|' -f2)
    local _tgt="${_dest}"; [[ -n "$_lp" ]] && _tgt="$_lp"
    local _np; _np=$("${OUTER_TMUX[@]}" split-window -hb -l "$_sw" -t "$_tgt" \
      -P -F '#{pane_id}' \
      "exec $TMUXBIN -L $_server attach-session -t $_session" 2>/dev/null)
    [[ -n "$_np" ]] && "${OUTER_TMUX[@]}" select-pane -t "$_np" -T "Sessions" 2>/dev/null
    _kill_extra_sidebars "$_dest" "$_np"
  fi
}

# Elimina panes "Sessions" duplicados (vivos Y muertos) en una ventana, preservando $_keep.
# Actúa como self-healing: si la ventana quedó con dos sidebars por cualquier motivo,
# la próxima navegación a ella limpia automáticamente los extras.
_kill_extra_sidebars() {
  local _dest="$1" _keep="$2"
  [[ -z "$_keep" ]] && return
  local _extras _dup
  _extras=$("${OUTER_TMUX[@]}" list-panes -t "$_dest" \
    -F '#{pane_id}|#{pane_title}' 2>/dev/null \
    | awk -F'|' -v keep="$_keep" '$2=="Sessions" && $1!=keep {print $1}')
  while IFS= read -r _dup; do
    [[ -n "$_dup" ]] && "${OUTER_TMUX[@]}" kill-pane -t "$_dup" 2>/dev/null
  done <<< "$_extras"
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

  # ── Modo rename inline ────────────────────────────────────────────────────
  if [[ -n "$_RENAME_ITEM" ]]; then
    case "$key" in
      $'\x1e') ;;
      ""|$'\n'|$'\r')  _apply_rename; _RENAME_ITEM=""; _RENAME_BUF=""; _RENAME_TYPE="" ;;
      ESC)             _RENAME_ITEM=""; _RENAME_BUF=""; _RENAME_TYPE="" ;;
      UP|DOWN|LEFT|RIGHT) ;;
      $'\x7f'|$'\x08') _RENAME_BUF="${_RENAME_BUF%?}" ;;
      *) _RENAME_BUF+="$key" ;;
    esac
    return
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

  # ── Help overlay activo: cualquier tecla real lo descarta ────────────────
  if [[ "$_HELP_MODE" -eq 1 ]]; then
    [[ "$key" == $'\x1e' ]] && return
    _HELP_MODE=0; return
  fi

  # ── Modo búsqueda inline ─────────────────────────────────────────────────────
  if [[ "$_SEARCH_MODE" == "1" ]]; then
    case "$key" in
      $'\x1e') ;;
      $'\x7f'|$'\x08')
        if [[ -z "$_SEARCH_QUERY" ]]; then
          _SEARCH_MODE=0; _SEARCH_SEL=0; _SEARCH_ITEMS=()
        else
          _SEARCH_QUERY="${_SEARCH_QUERY%?}"; _SEARCH_SEL=0
        fi ;;
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

  # Cancelar kill pendiente con cualquier tecla excepto x y wake-up
  [[ -n "$_KILL_PENDING" && "$key" != "x" && "$key" != $'\x1e' ]] && _KILL_PENDING=""

  case "$key" in
    $'\x1e') ;; # wake-up

    # `?` — mostrar/ocultar help overlay
    "?") _HELP_MODE=1 ;;

    # `:` y dígitos activan el command buffer; `/` activa búsqueda inline
    ":") _CMD_BUF=":" ;;
    "/") _SEARCH_MODE=1; _SEARCH_QUERY=""; _SEARCH_SEL=0; _SEARCH_ITEMS=() ;;
    [0-9]) _CMD_BUF="$key" ;;

    R)
      kill "$_ANIMATOR_PID" 2>/dev/null
      rm -f "${STATE_DIR}/animator_active"
      ps aux 2>/dev/null | grep "[d]aemon.sh" | grep -v grep | awk '{print $2}' \
        | xargs kill -9 2>/dev/null
      rm -f "${STATE_DIR}/daemon.pid"; rm -rf "${STATE_DIR}/daemon.lock"
      _RELOADING=1; exec "$0" ;;

    r)
      local _ri="${ITEMS_FLAT[$SELECTED]:-}"
      local _rtype="${_ri%%|*}" _rrest="${_ri#*|}"
      if [[ "$_rtype" == "S" ]]; then
        local _rsess="${_rrest#*|}"
        _RENAME_ITEM="$_ri"; _RENAME_TYPE="S"; _RENAME_BUF="$_rsess"
      elif [[ "$_rtype" == "W" ]]; then
        local _rsrv="${_rrest%%|*}" _rwr="${_rrest#*|}"
        local _rwsess="${_rwr%%|*}" _rwid="${_rwr#*|}"
        local _rtmux=("${OUTER_TMUX[@]}")
        [[ "$_rsrv" != "$OUTER_SERVER" ]] && _rtmux=("$TMUXBIN" -S "$SOCKET_DIR/$_rsrv")
        local _rname; _rname=$("${_rtmux[@]}" display-message -t "${_rwsess}:${_rwid}" \
          -p '#{window_name}' 2>/dev/null)
        _RENAME_ITEM="$_ri"; _RENAME_TYPE="W"; _RENAME_BUF="${_rname:-}"
      fi ;;

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

    # ← / h / Esc — volver al header S; limpiar filtro activo; cerrar popup
    LEFT|h|ESC)
      if [[ -n "$_FILTER_STATUS" && "$key" == "ESC" ]]; then
        _FILTER_STATUS=""; return
      fi
      if [[ "$_cur_type" == "W" ]]; then
        local _si=$SELECTED
        while (( _si > 0 )); do
          (( _si-- ))
          [[ "${ITEMS_FLAT[$_si]%%|*}" == "S" ]] && { SELECTED=$_si; break; }
        done
      elif [[ "$key" == "ESC" && -n "$POPUP_MODE" ]]; then
        exit 0
      fi ;;

    # Enter — navegar al item seleccionado y marcar como visitado (limpia unread)
    # En modo popup, también cierra el overlay después de navegar
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
        [[ "$_srv" == "$OUTER_SERVER" ]] && _ensure_sidebar "${_sess}:${_win}"
        jump_to "${_srv}|${_sess}|${_win}"
        [[ "$_srv" == "$OUTER_SERVER" ]] && printf '%s' "$_sess" > "${STATE_DIR}/current_session"
        printf '%s' "${_srv}|${_sess}:${_win}" > "${STATE_DIR}/just_visited"
      fi
      [[ -n "$POPUP_MODE" ]] && exit 0 ;;


    x)
      if [[ -n "$_KILL_PENDING" && "$_KILL_PENDING" == "$_cur_item" ]]; then
        _kill_current; _KILL_PENDING=""
      else
        _KILL_PENDING="$_cur_item"
      fi ;;

    p)
      if [[ "$PREVIEW_MODE" == "0" ]]; then PREVIEW_MODE=1; else PREVIEW_MODE=0; fi ;;

    # `w` — saltar al siguiente agente working (⚡), cíclico
    w) jump_next_working ;;

    # `u` — saltar al siguiente agente unread (◉), cíclico
    u) jump_next_unread ;;

    q|Q)
      if [[ -n "$POPUP_MODE" ]]; then
        exit 0
      elif [[ -n "$OUTER_TMUX_SOCKET" ]]; then
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
# Tamaño inicial para detectar cambios sin depender de SIGWINCH interrumpiendo read
LAST_SZ=$(stty size 2>/dev/null)
while true; do
  # Detectar resize por polling: en macOS bash 3.2 SIGWINCH no interrumpe read -t,
  # así que no podemos confiar en que _WINCH=1 llegue a tiempo durante el drag.
  # stty size consulta TIOCGWINSZ directamente → detecta el cambio en cada iteración.
  _cur_sz=$(stty size 2>/dev/null)
  [[ "$_cur_sz" != "$LAST_SZ" ]] && { LAST_SZ="$_cur_sz"; _WINCH=1; _RESIZE=1; }

  _cur_mtime=$(file_mtime "$DATA_FILE")
  _cur_sess_mtime=$(file_mtime "${STATE_DIR}/current_session")
  if [[ "$_cur_mtime" != "$DATA_MTIME" || "$_cur_sess_mtime" != "$SESS_MTIME" \
      || "$_WAKE" == "1" || "$_HAS_WORKING" == "1" \
      || "$_WINCH" == "1" ]] \
      || (( SECONDS - LAST_RENDER >= 2 )); then
    _WINCH=0
    _WAKE=0; _HAS_WORKING=0
    DATA_MTIME="$_cur_mtime"
    SESS_MTIME="$_cur_sess_mtime"
    render
    LAST_RENDER=$SECONDS
    [[ "$_HAS_WORKING" == "1" ]] && touch "${STATE_DIR}/animator_active" \
                                 || rm -f "${STATE_DIR}/animator_active"
  fi

  # Timeout de 0.1s: suficiente para respuesta fluida al resize sin sobrecargar CPU
  if IFS= read -r -s -n1 -t 0.1 key 2>/dev/null; then
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
