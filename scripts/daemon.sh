#!/usr/bin/env bash
# daemon.sh — proceso único que queryea todos los servidores tmux y escribe el data file

# Require bash 4+
_bash_ver="${BASH_VERSINFO[0]:-0}"
if ((_bash_ver < 4)); then
  printf 'tmux-agent-sidebar requires bash 4+. Current: %s\n' "$BASH_VERSION" >&2
  exit 1
fi
set -u

# Forzar UTF-8
export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

TMUXBIN="$(command -v tmux 2>/dev/null)"
[[ -z "$TMUXBIN" ]] && TMUXBIN="tmux"
STATE_DIR="${TMPDIR:-/tmp}/agent-sidebar"
DATA_FILE="${STATE_DIR}/data"
SUMMARY_FILE="${STATE_DIR}/summary"
DIRTY_FILE="${STATE_DIR}/dirty"
PID_FILE="${STATE_DIR}/daemon.pid"
_BUILD_TMPDIR=""
_DATA_TMP=""
CLIENTS_DIR="${STATE_DIR}/clients"
CAPTURES_DIR="${STATE_DIR}/captures"
ORDER_FILE="${HOME}/.tmux-sidebar-order"
CLAUDE_SESSIONS_DIR="${HOME}/.claude/sessions"

# shellcheck disable=SC2034  # TAB reserved for future TSV output format
readonly TAB=$'\t'
readonly FIELD_SEP='|'
readonly DAEMON_SLEEP_INTERVAL=0.2
readonly CRASH_TTL_SECS=120

mkdir -p "$STATE_DIR" "$CLIENTS_DIR" "$CAPTURES_DIR"

# Source libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/log.sh"
source "${SCRIPT_DIR}/lib/states.sh"
source "${SCRIPT_DIR}/lib/detect.sh"

# ── Singleton con lock atómico ─────────────────────────────────────────────────
LOCK_DIR="${STATE_DIR}/daemon.lock"
_LOCK_PID_FILE="${LOCK_DIR}/pid"

_daemon_cleanup() {
  rm -f "$PID_FILE"
  rm -rf "$LOCK_DIR"
  [[ -n "${_BUILD_TMPDIR:-}" ]] && rm -rf "$_BUILD_TMPDIR"
  [[ -n "${_DATA_TMP:-}" ]] && rm -f "$_DATA_TMP"
}

_try_acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%d' "$$" >"$_LOCK_PID_FILE"
    printf '%d' "$$" >"$PID_FILE"
    return 0
  fi
  local _epid
  _epid=$(cat "$_LOCK_PID_FILE" 2>/dev/null)
  [[ -z "$_epid" ]] && _epid=$(cat "$PID_FILE" 2>/dev/null)
  if [[ -n "$_epid" ]] && kill -0 "$_epid" 2>/dev/null; then
    return 1
  fi
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR" 2>/dev/null || return 1
  printf '%d' "$$" >"$_LOCK_PID_FILE"
  printf '%d' "$$" >"$PID_FILE"
  return 0
}

if ! _try_acquire_lock; then
  exit 0
fi
trap '_daemon_cleanup' EXIT INT TERM

# ── Helpers ───────────────────────────────────────────────────────────────────

current_server_name() {
  local _s="${TMUX%%,*}"
  printf '%s' "${_s##*/}"
}

# ── Build data file ───────────────────────────────────────────────────────────
# Formato de línea (separador |):
#   S|server|is_current(0/1)
#   E|server|session|is_active(0/1)
#   W|server|session|win_idx|win_name|icon|agent_sigla|is_last(0/1)

build_data() {
  local _current _socket_dir _buf _servers
  _current=$(current_server_name)
  _socket_dir="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)"
  _buf=""
  _BUILD_TMPDIR=$(mktemp -d)
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
    local _is_cur=0
    [[ "$_server" == "$_current" ]] && _is_cur=1
    _buf+="S${FIELD_SEP}${_server}${FIELD_SEP}${_is_cur}"$'\n'

    local _SESS _WINS _PANES
    _SESS=$($TMUXBIN "${_sargs[@]}" list-sessions -F '#{session_name}|#{session_attached}' 2>/dev/null) || continue
    _log_debug "build_data: server=$_server sessions=$(printf '%s\n' "$_SESS" | grep -c '.' 2>/dev/null || echo 0)"
    _WINS=$($TMUXBIN "${_sargs[@]}" list-windows -a -F '#{session_name}|#{window_index}|#{window_name}' 2>/dev/null)
    # Formato: pane_id|pane_pid|pane_dead|session|window|cmd|title
    _PANES=$($TMUXBIN "${_sargs[@]}" list-panes -a \
      -F '#{pane_id}|#{pane_pid}|#{pane_dead}|#{session_name}|#{window_index}|#{pane_current_command}|#{pane_title}' 2>/dev/null)

    # Capturas en paralelo — omite panes que no necesitan content scan
    while IFS="$FIELD_SEP" read -r _paneid _ppid _pdead _s _w _c _pt; do
      # Pane muerto: no capturar, se maneja por estado
      [[ "$_pdead" == "1" ]] && continue
      # Shell conocido: no necesita contenido
      case "$_c" in zsh | bash | sh | fish | dash) continue ;; esac
      # Session file dice busy → es W seguro, skip captura
      local _eff_ppid
      _eff_ppid=$(effective_claude_pid "$_ppid")
      local _sf="${CLAUDE_SESSIONS_DIR}/${_eff_ppid}.json"
      if [[ -f "$_sf" ]] && kill -0 "$_eff_ppid" 2>/dev/null; then
        local _st
        _st=$(grep -o '"status":"[^"]*"' "$_sf" | cut -d'"' -f4 2>/dev/null)
        [[ "$_st" == "busy" ]] && continue
      fi
      # Braille en título → W seguro (fast path para versiones sin session file)
      if [[ -n "$_pt" ]]; then
        local _fc="${_pt:0:1}"
        local _hex
        _hex=$(LC_ALL=C printf '%s' "$_fc" | od -A n -t x1 | tr -d ' \n')
        case "$_hex" in e2a0* | e2a1* | e2a2* | e2a3*) continue ;; esac
      fi
      # Capturar contenido para detección de P y fallback
      $TMUXBIN "${_sargs[@]}" capture-pane -t "$_paneid" -p \
        >"$_BUILD_TMPDIR/${_server}_${_paneid//[^a-zA-Z0-9]/_}" 2>/dev/null &
    done <<<"$_PANES"
    wait

    # Ordenar sesiones según ORDER_FILE
    local _sess_raw=() _sess_sorted=()
    while IFS="$FIELD_SEP" read -r _sn _sa; do
      [[ -z "$_sn" ]] && continue
      _sess_raw+=("${_sn}|${_sa}")
    done <<<"$_SESS"
    if [[ -f "$ORDER_FILE" ]]; then
      while IFS="$FIELD_SEP" read -r _osrv _osess; do
        [[ "$_osrv" == "$_server" ]] || continue
        for _se in "${_sess_raw[@]}"; do
          [[ "${_se%%|*}" == "$_osess" ]] && {
            _sess_sorted+=("$_se")
            break
          }
        done
      done <"$ORDER_FILE"
    fi
    for _se in "${_sess_raw[@]}"; do
      local _sfound=false
      for _so in "${_sess_sorted[@]}"; do
        [[ "${_se%%|*}" == "${_so%%|*}" ]] && {
          _sfound=true
          break
        }
      done
      [[ "$_sfound" == false ]] && _sess_sorted+=("$_se")
    done

    local _hidden_raw
    _hidden_raw=$(cat "${STATE_DIR}/hidden_sessions" 2>/dev/null)

    for _sess_entry in "${_sess_sorted[@]}"; do
      local _sess="${_sess_entry%%|*}" _attached="${_sess_entry#*|}"

      if [[ -n "$_hidden_raw" ]]; then
        local _skip=false _hs
        for _hs in $_hidden_raw; do
          [[ "$_sess" == "$_hs" ]] && {
            _skip=true
            break
          }
        done
        [[ "$_skip" == true ]] && continue
      fi

      local _is_active=0
      [[ "${_attached:-0}" -gt 0 ]] && _is_active=1

      local _wins=()
      while IFS="$FIELD_SEP" read -r _ws _wi _wn; do
        [[ "$_ws" == "$_sess" ]] && _wins+=("${_wi}|${_wn}")
      done <<<"$_WINS"
      local _wtotal=${#_wins[@]}

      _buf+="E${FIELD_SEP}${_server}${FIELD_SEP}${_sess}${FIELD_SEP}${_is_active}"$'\n'

      local _wj=0
      for _wentry in "${_wins[@]}"; do
        local _widx="${_wentry%%|*}" _wname="${_wentry#*|}"
        local _capid="" _cappid="" _capdead="0" _capcmd="" _captitle=""
        # Tomar el primer pane no-sidebar de la ventana
        while IFS="$FIELD_SEP" read -r _paneid _ppid _pdead _ps _pw _pc _pt; do
          [[ "$_ps" == "$_sess" && "$_pw" == "$_widx" ]] || continue
          [[ "$_pt" == "Sessions" ]] && continue
          _capid="$_paneid"
          _cappid="$_ppid"
          _capdead="$_pdead"
          _capcmd="$_pc"
          _captitle="$_pt"
          break
        done <<<"$_PANES"

        local _lines="" _ck="${_capid//[^a-zA-Z0-9]/_}"
        [[ -n "$_capid" && -f "$_BUILD_TMPDIR/${_server}_${_ck}" ]] && _lines=$(<"$_BUILD_TMPDIR/${_server}_${_ck}")

        local _cap_key="${_server//[^a-zA-Z0-9_-]/_}_${_sess//[^a-zA-Z0-9_-]/_}_${_widx}"
        printf '%s' "$_lines" >"${CAPTURES_DIR}/${_cap_key}"

        # Resolver PID real de Claude (puede ser hijo del pane_pid si arrancó desde shell)
        local _eff_pid
        _eff_pid=$(effective_claude_pid "$_cappid")

        local _icon
        _icon=$(detect_icon "$_eff_pid" "$_capcmd" "$_lines" "$_captitle" "$_capdead")

        # Window key para archivos de estado
        local _wkey="${_server//[^a-zA-Z0-9_-]/_}_${_sess//[^a-zA-Z0-9_-]/_}_${_widx}"

        # Loop detection
        check_loop "$_wkey" "$_icon" && _icon="$STATE_LOOP"

        # Crashed detection (shell volvió pero Claude murió mientras estaba busy)
        # Guardamos el último PID conocido de Claude por ventana
        if [[ "$_icon" == "$STATE_EMPTY" ]]; then
          local _cpid_f="${STATE_DIR}/${_wkey}.last_cpid"
          if [[ -f "$_cpid_f" ]]; then
            local _last_cpid
            _last_cpid=$(cat "$_cpid_f" 2>/dev/null)
            if [[ -n "$_last_cpid" ]] && ! kill -0 "$_last_cpid" 2>/dev/null; then
              local _csf="${CLAUDE_SESSIONS_DIR}/${_last_cpid}.json"
              if [[ -f "$_csf" ]]; then
                local _cst
                _cst=$(grep -o '"status":"[^"]*"' "$_csf" | cut -d'"' -f4 2>/dev/null)
                if [[ "$_cst" == "busy" ]]; then
                  # Verificar que el X no es demasiado viejo (max 120s)
                  local _xcf="${STATE_DIR}/${_wkey}.xctime"
                  [[ ! -f "$_xcf" ]] && printf '%s' "$(date +%s)" >"$_xcf"
                  local _xct
                  _xct=$(cat "$_xcf" 2>/dev/null)
                  local _now
                  _now=$(date +%s)
                  if ((_now - _xct < CRASH_TTL_SECS)); then
                    _icon="$STATE_CRASHED"
                  else
                    rm -f "$_cpid_f" "$_xcf"
                  fi
                else
                  rm -f "$_cpid_f" "${STATE_DIR}/${_wkey}.xctime"
                fi
              fi
            else
              rm -f "${STATE_DIR}/${_wkey}.xctime"
            fi
          fi
        else
          # Guardar PID cuando Claude está activo (no shell)
          [[ -n "$_eff_pid" && "$_eff_pid" != "$_cappid" || -f "${CLAUDE_SESSIONS_DIR}/${_eff_pid}.json" ]] \
            && printf '%s' "$_eff_pid" >"${STATE_DIR}/${_wkey}.last_cpid"
          rm -f "${STATE_DIR}/${_wkey}.xctime"
        fi

        # Agent sigla
        local _sigla=""
        _sigla=$(agent_sigla "$_eff_pid")

        # Título del pane — quitar indicador de estado inicial (✳ o Braille) y pipes
        local _ptitle="${_captitle}"
        _ptitle="${_ptitle#✳ }"
        _ptitle=$(printf '%s' "$_ptitle" | LC_ALL=C sed 's/^[[:space:]]*//; s/|//g')
        # Quitar indicador de estado al inicio: ✳ (idle) o spinner Braille (working)
        _ptitle="${_ptitle#✳ }"
        # Braille u otro multi-byte + espacio: si el 1er char pesa >1 byte y el 2do es espacio
        if [[ "${_ptitle:1:1}" == " " ]] \
          && [[ "$(printf '%s' "${_ptitle:0:1}" | wc -c | tr -d '[:space:]')" -gt 1 ]]; then
          _ptitle="${_ptitle:2}"
        fi

        local _islast=0
        ((_wj + 1 >= _wtotal)) && _islast=1
        _buf+="W${FIELD_SEP}${_server}${FIELD_SEP}${_sess}${FIELD_SEP}${_widx}${FIELD_SEP}${_wname}${FIELD_SEP}${_icon}${FIELD_SEP}${_sigla}${FIELD_SEP}${_islast}${FIELD_SEP}${_ptitle}"$'\n'
        ((_wj++))
      done
    done
  done

  rm -rf "$_BUILD_TMPDIR"
  _BUILD_TMPDIR=""
  _DATA_TMP=$(mktemp "${DATA_FILE}.XXXXXX")
  printf '%s' "$_buf" >"$_DATA_TMP"
  mv "$_DATA_TMP" "$DATA_FILE"
  _DATA_TMP=""
}

# ── Build summary token ───────────────────────────────────────────────────────

build_summary() {
  local _working=0 _idle=0 _blocked=0 _loop=0 _crashed=0 _unread=0
  local _type _server _sess _widx _wname _icon _sigla _islast _f

  if [[ -f "$DATA_FILE" ]]; then
    while IFS="$FIELD_SEP" read -r _type _server _sess _widx _wname _icon _sigla _islast _ptitle; do
      [[ "$_type" == "W" ]] || continue
      case "$_icon" in
        "$STATE_WORKING") ((_working++)) ;;
        "$STATE_IDLE") ((_idle++)) ;;
        "$STATE_BLOCKED") ((_blocked++)) ;;
        "$STATE_LOOP") ((_loop++)) ;;
        "$STATE_CRASHED") ((_crashed++)) ;;
      esac
    done <"$DATA_FILE"
  fi

  for _f in "$STATE_DIR"/*.unread; do
    [[ -f "$_f" ]] && ((_unread++))
  done

  local _token=""
  [[ $_working -gt 0 ]] && _token+="⚡${_working} "
  [[ $_blocked -gt 0 ]] && _token+="?${_blocked} "
  [[ $_loop -gt 0 ]] && _token+="↺${_loop} "
  [[ $_crashed -gt 0 ]] && _token+="✗${_crashed} "
  [[ $_idle -gt 0 ]] && _token+="⏸${_idle} "
  [[ $_unread -gt 0 ]] && _token+="◉${_unread} "
  _token="${_token% }"

  printf '%s' "$_token" >"${SUMMARY_FILE}.tmp"
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
  [[ -f "$DIRTY_FILE" ]] && {
    rm -f "$DIRTY_FILE"
    _SB=true
  }

  if [[ "$HAS_WORKING" == true ]]; then
    _SB=true
    _SLEEP=$DAEMON_SLEEP_INTERVAL
  else
    ((SECONDS - LAST_BUILD >= _interval)) && _SB=true
    _SLEEP=$_interval
  fi

  if [[ "$_SB" == true ]]; then
    _log_rotate
    build_data
    build_summary
    LAST_BUILD=$SECONDS
    HAS_WORKING=false
    grep -qE "\|(${STATE_WORKING}|${STATE_LOOP})\|" "$DATA_FILE" 2>/dev/null && HAS_WORKING=true
    notify_clients
  fi

  has_clients || exit 0
  sleep "$_SLEEP"
done
