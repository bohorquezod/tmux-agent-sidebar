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

mkdir -p "$STATE_DIR" "$CLIENTS_DIR" "$CAPTURES_DIR"

# ── Singleton con lock atómico ─────────────────────────────────────────────────
# El PID se guarda DENTRO del lock dir para eliminar la ventana de race entre
# mkdir y la escritura del PID_FILE separado. Quien lee el lock siempre tiene el PID.
LOCK_DIR="${STATE_DIR}/daemon.lock"
_LOCK_PID_FILE="${LOCK_DIR}/pid"

_try_acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%d' "$$" > "$_LOCK_PID_FILE"
    printf '%d' "$$" > "$PID_FILE"
    return 0
  fi
  # Lock existe — leer PID desde dentro del lock dir
  local _epid; _epid=$(cat "$_LOCK_PID_FILE" 2>/dev/null)
  [[ -z "$_epid" ]] && _epid=$(cat "$PID_FILE" 2>/dev/null)
  if [[ -n "$_epid" ]] && kill -0 "$_epid" 2>/dev/null; then
    return 1  # Daemon activo, no tomar control
  fi
  # Proceso muerto: limpiar y reintentar
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

detect_icon() {
  local _cmd="$1" _lines="$2" _title="${3:-}" _icon="·"
  case "$_cmd" in zsh|bash|sh|fish|dash) printf '·'; return ;; esac

  # Fast path: el pane title codifica el estado de Claude Code de forma fiable.
  # ✳ (U+2733) = idle esperando input.
  # Braille block (U+2800-U+28FF, UTF-8: E2 A0-A3 xx) = spinner = working.
  if [[ -n "$_title" ]]; then
    local _fc="${_title:0:1}"
    if [[ "$_fc" == "✳" ]]; then
      printf '⏸'; return
    fi
    local _hex
    _hex=$(LC_ALL=C printf '%s' "$_fc" | od -A n -t x1 | tr -d ' \n')
    case "$_hex" in
      e2a0*|e2a1*|e2a2*|e2a3*) printf '⚡'; return ;;
    esac
  fi

  # Fallback: content scanning para casos sin título reconocido
  [[ -z "$_lines" ]] && { printf '·'; return; }

  local _wide="${_lines: -1500}"
  local _narrow="${_lines: -1000}"
  local _min=999999 _tmp _tlen

  # ⏺ — Claude ejecutando herramienta
  _tmp="${_wide##*⏺}";            _tlen=${#_tmp}
  [[ "$_wide" == *"⏺"*        && $_tlen -lt $_min ]] && { _min=$_tlen; _icon="⚡"; }

  # ❯ — prompt de Claude esperando input
  _tmp="${_narrow##*❯}";          _tlen=${#_tmp}
  [[ "$_narrow" == *"❯"*      && $_tlen -lt $_min ]] && { _min=$_tlen; _icon="⏸"; }

  # Permisos [Yes/No/Always] — Claude bloqueado esperando al usuario
  _tmp="${_narrow##*\[Yes\]}";    _tlen=${#_tmp}
  [[ "$_narrow" == *"[Yes]"*  && $_tlen -lt $_min ]] && { _min=$_tlen; _icon="⏸"; }
  _tmp="${_narrow##*\[No\]}";     _tlen=${#_tmp}
  [[ "$_narrow" == *"[No]"*   && $_tlen -lt $_min ]] && { _min=$_tlen; _icon="⏸"; }
  _tmp="${_narrow##*\[Always\]}"; _tlen=${#_tmp}
  [[ "$_narrow" == *"[Always]"* && $_tlen -lt $_min ]] && { _min=$_tlen; _icon="⏸"; }

  printf '%s' "$_icon"
}

# ── Build data file ───────────────────────────────────────────────────────────
# Formato de línea (separador |):
#   S|server|is_current(0/1)
#   E|server|session|is_active(0/1)
#   W|server|session|win_idx|win_name|icon|is_last(0/1)

build_data() {
  local _current _socket_dir _buf _tmpdir _servers
  _current=$(current_server_name)
  _socket_dir="${TMPDIR:-/tmp}/tmux-$(id -u)"
  _buf=""
  _tmpdir=$(mktemp -d)
  _servers=("$_current")

  # Descubrir otros servidores activos
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
    _WINS=$($TMUXBIN "${_sargs[@]}" list-windows  -a -F '#{session_name}|#{window_index}|#{window_name}' 2>/dev/null)
    _PANES=$($TMUXBIN "${_sargs[@]}" list-panes -a \
      -F '#{pane_id}|#{session_name}|#{window_index}|#{pane_current_command}|#{pane_title}' 2>/dev/null)

    # Capturas en paralelo — omite panes cuyo título ya codifica estado Claude o cuyo comando es shell conocido
    while IFS='|' read -r _pid _s _w _c _pt; do
      case "$_c" in zsh|bash|sh|fish|dash) continue ;; esac
      if [[ -n "$_pt" ]]; then
        _fc="${_pt:0:1}"
        if [[ "$_fc" == "✳" ]]; then continue; fi
        _hex=$(LC_ALL=C printf '%s' "$_fc" | od -A n -t x1 | tr -d ' \n')
        case "$_hex" in e2a0*|e2a1*|e2a2*|e2a3*) continue ;; esac
      fi
      $TMUXBIN "${_sargs[@]}" capture-pane -t "$_pid" -p \
        > "$_tmpdir/${_server}_${_pid//[^a-zA-Z0-9]/_}" 2>/dev/null &
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

    for _sess_entry in "${_sess_sorted[@]}"; do
      local _sess="${_sess_entry%%|*}" _attached="${_sess_entry#*|}"
      local _is_active=0; [[ "${_attached:-0}" -gt 0 ]] && _is_active=1

      # Recopilar ventanas del session para saber cuál es la última
      local _wins=()
      while IFS='|' read -r _ws _wi _wn; do
        [[ "$_ws" == "$_sess" ]] && _wins+=("${_wi}|${_wn}")
      done <<< "$_WINS"
      local _wtotal=${#_wins[@]}

      _buf+="E|${_server}|${_sess}|${_is_active}"$'\n'

      local _wj=0
      for _wentry in "${_wins[@]}"; do
        local _widx="${_wentry%%|*}" _wname="${_wentry#*|}"
        local _capid="" _capcmd="" _captitle=""
        while IFS='|' read -r _pid _ps _pw _pc _pt; do
          [[ "$_ps" == "$_sess" && "$_pw" == "$_widx" ]] || continue
          [[ "$_pt" == "Sessions" ]] && continue  # saltar el pane del sidebar
          _capid="$_pid"; _capcmd="$_pc"; _captitle="$_pt"; break
        done <<< "$_PANES"

        local _lines="" _ck="${_capid//[^a-zA-Z0-9]/_}"
        [[ -n "$_capid" && -f "$_tmpdir/${_server}_${_ck}" ]] && _lines=$(<"$_tmpdir/${_server}_${_ck}")

        local _cap_key="${_server//[^a-zA-Z0-9_-]/_}_${_sess//[^a-zA-Z0-9_-]/_}_${_widx}"
        printf '%s' "$_lines" > "${CAPTURES_DIR}/${_cap_key}"

        local _icon; _icon=$(detect_icon "$_capcmd" "$_lines" "$_captitle")
        local _islast=0; (( _wj + 1 >= _wtotal )) && _islast=1
        _buf+="W|${_server}|${_sess}|${_widx}|${_wname}|${_icon}|${_islast}"$'\n'
        (( _wj++ ))
      done
    done  # _sess_sorted
  done

  rm -rf "$_tmpdir"
  printf '%s' "$_buf" > "${DATA_FILE}.tmp"
  mv "${DATA_FILE}.tmp" "$DATA_FILE"
}

# ── Build summary token ───────────────────────────────────────────────────────
# Escribe ${STATE_DIR}/summary con conteos compactos de estado de agentes.
# También actualiza la user-option @agent_sidebar_summary en el servidor actual
# para que el usuario pueda referenciarla con #{@agent_sidebar_summary}.

build_summary() {
  local _working=0 _idle=0 _unread=0
  local _type _server _sess _widx _wname _icon _islast _f

  if [[ -f "$DATA_FILE" ]]; then
    while IFS='|' read -r _type _server _sess _widx _wname _icon _islast; do
      [[ "$_type" == "W" ]] || continue
      [[ "$_icon" == "⚡" ]] && (( _working++ ))
      [[ "$_icon" == "⏸" ]] && (( _idle++ ))
    done < "$DATA_FILE"
  fi

  for _f in "$STATE_DIR"/*.unread; do
    [[ -f "$_f" ]] && (( _unread++ ))
  done

  local _token=""
  [[ $_working -gt 0 ]] && _token+="⚡${_working} "
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

LAST_BUILD=0
while true; do
  _SB=false
  [[ -f "$DIRTY_FILE" ]] && { rm -f "$DIRTY_FILE"; _SB=true; }
  (( SECONDS - LAST_BUILD >= 2 )) && _SB=true
  [[ "$_SB" == true ]] && { build_data; build_summary; LAST_BUILD=$SECONDS; }
  has_clients || exit 0
  sleep 0.3
done
