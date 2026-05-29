#!/bin/bash
# daemon.sh — proceso único que queryea todos los servidores tmux y escribe el data file

# Forzar UTF-8 — bash 3.2 necesita el locale para pattern matching con caracteres multibyte
export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

TMUXBIN="$(command -v tmux 2>/dev/null)"; [[ -z "$TMUXBIN" ]] && TMUXBIN="tmux"
STATE_DIR="${TMPDIR:-/tmp}/agent-sidebar"
DATA_FILE="${STATE_DIR}/data"
SUMMARY_FILE="${STATE_DIR}/summary"
DIRTY_FILE="${STATE_DIR}/dirty"
PID_FILE="${STATE_DIR}/daemon.pid"
CLIENTS_DIR="${STATE_DIR}/clients"
CAPTURES_DIR="${STATE_DIR}/captures"
ORDER_FILE="${HOME}/.tmux-sidebar-order"
CLAUDE_SESSIONS_DIR="${HOME}/.claude/sessions"

mkdir -p "$STATE_DIR" "$CLIENTS_DIR" "$CAPTURES_DIR"

# ── Singleton con lock atómico ─────────────────────────────────────────────────
LOCK_DIR="${STATE_DIR}/daemon.lock"
_LOCK_PID_FILE="${LOCK_DIR}/pid"

_try_acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%d' "$$" > "$_LOCK_PID_FILE"
    printf '%d' "$$" > "$PID_FILE"
    return 0
  fi
  local _epid; _epid=$(cat "$_LOCK_PID_FILE" 2>/dev/null)
  [[ -z "$_epid" ]] && _epid=$(cat "$PID_FILE" 2>/dev/null)
  if [[ -n "$_epid" ]] && kill -0 "$_epid" 2>/dev/null; then
    return 1
  fi
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR" 2>/dev/null || return 1
  printf '%d' "$$" > "$_LOCK_PID_FILE"
  printf '%d' "$$" > "$PID_FILE"
  return 0
}

if ! _try_acquire_lock; then
  exit 0
fi
trap 'rm -f "$PID_FILE"; rm -rf "$LOCK_DIR"' EXIT INT TERM

# ── Helpers ───────────────────────────────────────────────────────────────────

current_server_name() {
  local _s="${TMUX%%,*}"; printf '%s' "${_s##*/}"
}

# Devuelve el código de icono para un pane.
# Argumentos: ppid(pane_pid) cmd lines title pdead(pane_dead)
# Códigos de retorno: E W I P L X
detect_icon() {
  local _ppid="$1" _cmd="$2" _lines="$3" _title="${4:-}" _pdead="${5:-0}"

  # Pane muerto — sin icono activo; puede ser X si tenía sesión busy
  if [[ "$_pdead" == "1" ]]; then
    local _sf="${CLAUDE_SESSIONS_DIR}/${_ppid}.json"
    if [[ -f "$_sf" ]]; then
      local _st; _st=$(grep -o '"status":"[^"]*"' "$_sf" | cut -d'"' -f4 2>/dev/null)
      [[ "$_st" == "busy" ]] && { printf 'X'; return; }
    fi
    printf 'E'; return
  fi

  # Shell conocido → vacío
  case "$_cmd" in zsh|bash|sh|fish|dash) printf 'E'; return ;; esac

  # Fuente primaria: session file de Claude (~/.claude/sessions/{ppid}.json)
  local _sf="${CLAUDE_SESSIONS_DIR}/${_ppid}.json"
  if [[ -f "$_sf" ]]; then
    if ! kill -0 "$_ppid" 2>/dev/null; then
      # Proceso muerto con session file — crashed si estaba busy
      local _st; _st=$(grep -o '"status":"[^"]*"' "$_sf" | cut -d'"' -f4 2>/dev/null)
      [[ "$_st" == "busy" ]] && { printf 'X'; return; }
      printf 'E'; return
    fi
    local _st; _st=$(grep -o '"status":"[^"]*"' "$_sf" | cut -d'"' -f4 2>/dev/null)
    case "$_st" in
      busy) printf 'W'; return ;;
      idle)
        # Distinguir idle limpio de blocked (diálogo de permiso)
        if [[ -n "$_lines" ]] && \
           ( [[ "$_lines" == *"[Yes]"* ]] || [[ "$_lines" == *"[No]"* ]] || \
             [[ "$_lines" == *"[Always]"* ]] ); then
          printf 'P'; return
        fi
        printf 'I'; return ;;
    esac
  fi

  # Fallback nivel 1: pane title (Claude Code lo escribe vía OSC 2)
  if [[ -n "$_title" ]]; then
    local _fc="${_title:0:1}"
    if [[ "$_fc" == "✳" ]]; then
      # Idle según título — revisar si hay diálogo de permiso en contenido
      if [[ -n "$_lines" ]] && \
         ( [[ "$_lines" == *"[Yes]"* ]] || [[ "$_lines" == *"[No]"* ]] || \
           [[ "$_lines" == *"[Always]"* ]] ); then
        printf 'P'; return
      fi
      printf 'I'; return
    fi
    local _hex
    _hex=$(LC_ALL=C printf '%s' "$_fc" | od -A n -t x1 | tr -d ' \n')
    case "$_hex" in
      e2a0*|e2a1*|e2a2*|e2a3*) printf 'W'; return ;;
    esac
  fi

  # Fallback nivel 2: content scanning (versiones viejas / sin session file)
  [[ -z "$_lines" ]] && { printf 'E'; return; }

  local _wide="${_lines: -1500}"
  local _narrow="${_lines: -1000}"
  local _icon="E" _min=999999 _tmp _tlen

  _tmp="${_wide##*⏺}";            _tlen=${#_tmp}
  [[ "$_wide" == *"⏺"*        && $_tlen -lt $_min ]] && { _min=$_tlen; _icon="W"; }

  _tmp="${_narrow##*❯}";          _tlen=${#_tmp}
  [[ "$_narrow" == *"❯"*      && $_tlen -lt $_min ]] && { _min=$_tlen; _icon="I"; }

  # Permission patterns → P (más urgente que idle simple)
  _tmp="${_narrow##*\[Yes\]}";    _tlen=${#_tmp}
  [[ "$_narrow" == *"[Yes]"*  && $_tlen -lt $_min ]] && { _min=$_tlen; _icon="P"; }
  _tmp="${_narrow##*\[No\]}";     _tlen=${#_tmp}
  [[ "$_narrow" == *"[No]"*   && $_tlen -lt $_min ]] && { _min=$_tlen; _icon="P"; }
  _tmp="${_narrow##*\[Always\]}"; _tlen=${#_tmp}
  [[ "$_narrow" == *"[Always]"* && $_tlen -lt $_min ]] && { _min=$_tlen; _icon="P"; }

  printf '%s' "$_icon"
}

# Devuelve las siglas del sub-agente leyendo el campo "agent" del session file.
agent_sigla() {
  local _ppid="$1"
  local _sf="${CLAUDE_SESSIONS_DIR}/${_ppid}.json"
  [[ -f "$_sf" ]] || return
  local _agent
  _agent=$(grep -o '"agent":"[^"]*"' "$_sf" | cut -d'"' -f4 2>/dev/null)
  [[ -z "$_agent" ]] && return
  case "$_agent" in
    pl|tl)     printf '%s' "${_agent^^}" ;;
    developer) printf 'DV' ;;
    reviewer)  printf 'RV' ;;
    runner)    printf 'RN' ;;
    *)         printf '%s' "${_agent:0:2}" | tr '[:lower:]' '[:upper:]' ;;
  esac
}

# Detecta si una ventana está en loop (≥3 transiciones W→I en 10 min).
# Actualiza los archivos de tracking. Retorna 0 si se debe aplicar estado L.
check_loop() {
  local _wkey="$1" _icon="$2"
  local _prev_f="${STATE_DIR}/${_wkey}.dprev"
  local _loop_f="${STATE_DIR}/${_wkey}.looptimes"
  local _prev; _prev=$(<"$_prev_f" 2>/dev/null)

  # Si el usuario visitó la ventana (sidebar borra .unread), resetear loop counter
  [[ ! -f "${STATE_DIR}/${_wkey}.unread" && -f "$_loop_f" ]] && {
    # Solo resetear si el estado actual es idle (agente terminó y el usuario lo revisó)
    [[ "$_icon" == "I" && "$_prev" == "L" ]] && { rm -f "$_loop_f"; printf '%s' "$_icon" > "$_prev_f"; return 1; }
  }

  # Registrar transición W→I
  if [[ ( "$_prev" == "W" || "$_prev" == "L" ) && ( "$_icon" == "I" || "$_icon" == "P" ) ]]; then
    local _now; _now=$(date +%s)
    printf '%s\n' "$_now" >> "$_loop_f"
    # Podar entradas antiguas (>600s)
    local _cutoff=$(( _now - 600 )) _trimmed="" _ts
    while IFS= read -r _ts; do
      [[ -n "$_ts" && "$_ts" -gt "$_cutoff" ]] && _trimmed+="${_ts}"$'\n'
    done < "$_loop_f"
    printf '%s' "$_trimmed" > "$_loop_f"
  fi

  # Actualizar estado previo del daemon
  local _save_icon="$_icon"

  # Verificar umbral de loop
  local _loop_count=0
  if [[ -f "$_loop_f" ]]; then
    _loop_count=$(grep -c '[0-9]' "$_loop_f" 2>/dev/null || echo 0)
  fi

  if [[ "${_loop_count:-0}" -ge 3 && ( "$_icon" == "I" || "$_icon" == "P" || "$_icon" == "L" ) ]]; then
    _save_icon="L"
    printf '%s' "L" > "$_prev_f"
    return 0
  fi

  printf '%s' "$_save_icon" > "$_prev_f"
  return 1
}

# ── Build data file ───────────────────────────────────────────────────────────
# Formato de línea (separador |):
#   S|server|is_current(0/1)
#   E|server|session|is_active(0/1)
#   W|server|session|win_idx|win_name|icon|agent_sigla|is_last(0/1)

build_data() {
  local _current _socket_dir _buf _tmpdir _servers
  _current=$(current_server_name)
  _socket_dir="${TMPDIR:-/tmp}/tmux-$(id -u)"
  _buf=""
  _tmpdir=$(mktemp -d)
  _servers=("$_current")

  if [[ -d "$_socket_dir" ]]; then
    for _sock in "$_socket_dir"/*; do
      [[ -S "$_sock" ]] || continue
      local _sname="${_sock##*/}"
      [[ "$_sname" == "$_current" ]] && continue
      [[ "$_sname" == "tmux-agent-sidebar" ]] && continue
      $TMUXBIN -S "$_sock" list-sessions &>/dev/null 2>&1 && _servers+=("$_sname")
    done
  fi

  for _server in "${_servers[@]}"; do
    local _sargs=()
    [[ "$_server" != "$_current" ]] && _sargs=(-S "$_socket_dir/$_server")
    local _is_cur=0; [[ "$_server" == "$_current" ]] && _is_cur=1
    _buf+="S|${_server}|${_is_cur}"$'\n'

    local _SESS _WINS _PANES
    _SESS=$($TMUXBIN "${_sargs[@]}" list-sessions -F '#{session_name}|#{session_attached}' 2>/dev/null) || continue
    _WINS=$($TMUXBIN "${_sargs[@]}" list-windows -a -F '#{session_name}|#{window_index}|#{window_name}' 2>/dev/null)
    # Formato: pane_id|pane_pid|pane_dead|session|window|cmd|title
    _PANES=$($TMUXBIN "${_sargs[@]}" list-panes -a \
      -F '#{pane_id}|#{pane_pid}|#{pane_dead}|#{session_name}|#{window_index}|#{pane_current_command}|#{pane_title}' 2>/dev/null)

    # Capturas en paralelo — omite panes que no necesitan content scan
    while IFS='|' read -r _paneid _ppid _pdead _s _w _c _pt; do
      # Pane muerto: no capturar, se maneja por estado
      [[ "$_pdead" == "1" ]] && continue
      # Shell conocido: no necesita contenido
      case "$_c" in zsh|bash|sh|fish|dash) continue ;; esac
      # Session file dice busy → es W seguro, skip captura
      local _sf="${CLAUDE_SESSIONS_DIR}/${_ppid}.json"
      if [[ -f "$_sf" ]] && kill -0 "$_ppid" 2>/dev/null; then
        local _st; _st=$(grep -o '"status":"[^"]*"' "$_sf" | cut -d'"' -f4 2>/dev/null)
        [[ "$_st" == "busy" ]] && continue
      fi
      # Braille en título → W seguro (fast path para versiones sin session file)
      if [[ -n "$_pt" ]]; then
        local _fc="${_pt:0:1}"
        local _hex; _hex=$(LC_ALL=C printf '%s' "$_fc" | od -A n -t x1 | tr -d ' \n')
        case "$_hex" in e2a0*|e2a1*|e2a2*|e2a3*) continue ;; esac
      fi
      # Capturar contenido para detección de P y fallback
      $TMUXBIN "${_sargs[@]}" capture-pane -t "$_paneid" -p \
        > "$_tmpdir/${_server}_${_paneid//[^a-zA-Z0-9]/_}" 2>/dev/null &
    done <<< "$_PANES"
    wait

    # Ordenar sesiones según ORDER_FILE
    local _sess_raw=() _sess_sorted=()
    while IFS='|' read -r _sn _sa; do
      [[ -z "$_sn" ]] && continue
      _sess_raw+=("${_sn}|${_sa}")
    done <<< "$_SESS"
    if [[ -f "$ORDER_FILE" ]]; then
      while IFS='|' read -r _osrv _osess; do
        [[ "$_osrv" == "$_server" ]] || continue
        for _se in "${_sess_raw[@]}"; do
          [[ "${_se%%|*}" == "$_osess" ]] && { _sess_sorted+=("$_se"); break; }
        done
      done < "$ORDER_FILE"
    fi
    for _se in "${_sess_raw[@]}"; do
      local _sfound=false
      for _so in "${_sess_sorted[@]}"; do
        [[ "${_se%%|*}" == "${_so%%|*}" ]] && { _sfound=true; break; }
      done
      [[ "$_sfound" == false ]] && _sess_sorted+=("$_se")
    done

    local _hidden_raw; _hidden_raw=$(cat "${STATE_DIR}/hidden_sessions" 2>/dev/null)

    for _sess_entry in "${_sess_sorted[@]}"; do
      local _sess="${_sess_entry%%|*}" _attached="${_sess_entry#*|}"

      if [[ -n "$_hidden_raw" ]]; then
        local _skip=false _hs
        for _hs in $_hidden_raw; do
          [[ "$_sess" == "$_hs" ]] && { _skip=true; break; }
        done
        [[ "$_skip" == true ]] && continue
      fi

      local _is_active=0; [[ "${_attached:-0}" -gt 0 ]] && _is_active=1

      local _wins=()
      while IFS='|' read -r _ws _wi _wn; do
        [[ "$_ws" == "$_sess" ]] && _wins+=("${_wi}|${_wn}")
      done <<< "$_WINS"
      local _wtotal=${#_wins[@]}

      _buf+="E|${_server}|${_sess}|${_is_active}"$'\n'

      local _wj=0
      for _wentry in "${_wins[@]}"; do
        local _widx="${_wentry%%|*}" _wname="${_wentry#*|}"
        local _capid="" _cappid="" _capdead="0" _capcmd="" _captitle=""
        # Tomar el primer pane no-sidebar de la ventana
        while IFS='|' read -r _paneid _ppid _pdead _ps _pw _pc _pt; do
          [[ "$_ps" == "$_sess" && "$_pw" == "$_widx" ]] || continue
          [[ "$_pt" == "Sessions" ]] && continue
          _capid="$_paneid"; _cappid="$_ppid"; _capdead="$_pdead"
          _capcmd="$_pc"; _captitle="$_pt"; break
        done <<< "$_PANES"

        local _lines="" _ck="${_capid//[^a-zA-Z0-9]/_}"
        [[ -n "$_capid" && -f "$_tmpdir/${_server}_${_ck}" ]] && _lines=$(<"$_tmpdir/${_server}_${_ck}")

        local _cap_key="${_server//[^a-zA-Z0-9_-]/_}_${_sess//[^a-zA-Z0-9_-]/_}_${_widx}"
        printf '%s' "$_lines" > "${CAPTURES_DIR}/${_cap_key}"

        local _icon; _icon=$(detect_icon "$_cappid" "$_capcmd" "$_lines" "$_captitle" "$_capdead")

        # Loop detection
        local _wkey="${_server//[^a-zA-Z0-9_-]/_}_${_sess//[^a-zA-Z0-9_-]/_}_${_widx}"
        check_loop "$_wkey" "$_icon" && _icon="L"

        # Agent sigla
        local _sigla=""; _sigla=$(agent_sigla "$_cappid")

        local _islast=0; (( _wj + 1 >= _wtotal )) && _islast=1
        _buf+="W|${_server}|${_sess}|${_widx}|${_wname}|${_icon}|${_sigla}|${_islast}"$'\n'
        (( _wj++ ))
      done
    done
  done

  rm -rf "$_tmpdir"
  printf '%s' "$_buf" > "${DATA_FILE}.tmp"
  mv "${DATA_FILE}.tmp" "$DATA_FILE"
}

# ── Build summary token ───────────────────────────────────────────────────────

build_summary() {
  local _working=0 _idle=0 _blocked=0 _loop=0 _crashed=0 _unread=0
  local _type _server _sess _widx _wname _icon _sigla _islast _f

  if [[ -f "$DATA_FILE" ]]; then
    while IFS='|' read -r _type _server _sess _widx _wname _icon _sigla _islast; do
      [[ "$_type" == "W" ]] || continue
      case "$_icon" in
        W) (( _working++ ))  ;;
        I) (( _idle++ ))     ;;
        P) (( _blocked++ ))  ;;
        L) (( _loop++ ))     ;;
        X) (( _crashed++ ))  ;;
      esac
    done < "$DATA_FILE"
  fi

  for _f in "$STATE_DIR"/*.unread; do
    [[ -f "$_f" ]] && (( _unread++ ))
  done

  local _token=""
  [[ $_working -gt 0 ]] && _token+="⚡${_working} "
  [[ $_blocked -gt 0 ]] && _token+="?${_blocked} "
  [[ $_loop    -gt 0 ]] && _token+="↺${_loop} "
  [[ $_crashed -gt 0 ]] && _token+="✗${_crashed} "
  [[ $_idle    -gt 0 ]] && _token+="⏸${_idle} "
  [[ $_unread  -gt 0 ]] && _token+="◉${_unread} "
  _token="${_token% }"

  printf '%s' "$_token" > "${SUMMARY_FILE}.tmp"
  mv "${SUMMARY_FILE}.tmp" "$SUMMARY_FILE"

  $TMUXBIN set-option -gq @agent_sidebar_summary "$_token" 2>/dev/null || true
}

# ── Lifecycle ─────────────────────────────────────────────────────────────────

has_clients() {
  local _f _pid
  for _f in "$CLIENTS_DIR"/*; do
    [[ -f "$_f" ]] || continue
    _pid=$(<"$_f") 2>/dev/null
    kill -0 "$_pid" 2>/dev/null && return 0
  done
  return 1
}

notify_clients() {
  local _f _pid
  for _f in "$CLIENTS_DIR"/*; do
    [[ -f "$_f" ]] || continue
    _pid=$(<"$_f") 2>/dev/null
    [[ -n "$_pid" ]] && kill -USR2 "$_pid" 2>/dev/null
  done
}

LAST_BUILD=-999
HAS_WORKING=false

while true; do
  _interval=$(cat "${STATE_DIR}/refresh_interval" 2>/dev/null)
  [[ "$_interval" =~ ^[0-9]+$ ]] || _interval=2

  _SB=false
  [[ -f "$DIRTY_FILE" ]] && { rm -f "$DIRTY_FILE"; _SB=true; }

  if [[ "$HAS_WORKING" == true ]]; then
    _SB=true
    _SLEEP=0.2
  else
    (( SECONDS - LAST_BUILD >= _interval )) && _SB=true
    _SLEEP=$_interval
  fi

  if [[ "$_SB" == true ]]; then
    build_data
    build_summary
    LAST_BUILD=$SECONDS
    HAS_WORKING=false
    grep -qE '\|(W|L)\|' "$DATA_FILE" 2>/dev/null && HAS_WORKING=true
    notify_clients
  fi

  has_clients || exit 0
  sleep "$_SLEEP"
done
