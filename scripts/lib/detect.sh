# detect.sh — icon detection and loop tracking
# Sourced by daemon.sh. Assumes STATE_DIR, CLAUDE_SESSIONS_DIR, STATE_* are already set.
# No shebang — not executed directly.

readonly LOOP_WINDOW_SECS=600
readonly LOOP_MIN_TRANSITIONS=3
readonly LOOP_MIN_SPACING_SECS=60
readonly CONTENT_SCAN_WIDE=1500
readonly CONTENT_SCAN_NARROW=1000

# detect_icon ppid cmd lines title pdead → empty|working|idle|blocked|loop|crashed
detect_icon() {
  local _ppid="$1" _cmd="$2" _lines="$3" _title="${4:-}" _pdead="${5:-0}"
  local _r

  # Pane muerto — sin icono activo; puede ser crashed si tenía sesión busy
  if [[ "$_pdead" == "1" ]]; then
    local _sf="${CLAUDE_SESSIONS_DIR}/${_ppid}.json"
    if [[ -f "$_sf" ]]; then
      local _st
      _st=$(grep -o '"status":"[^"]*"' "$_sf" | cut -d'"' -f4 2>/dev/null)
      if [[ "$_st" == "busy" ]]; then
        _log_debug "detect_icon: ppid=$_ppid cmd=$_cmd → crashed"
        printf '%s' "$STATE_CRASHED"
        return
      fi
    fi
    _log_debug "detect_icon: ppid=$_ppid cmd=$_cmd → empty (dead)"
    printf '%s' "$STATE_EMPTY"
    return
  fi

  # Shell conocido → vacío
  case "$_cmd" in zsh | bash | sh | fish | dash)
    _log_debug "detect_icon: ppid=$_ppid cmd=$_cmd → empty (shell)"
    printf '%s' "$STATE_EMPTY"
    return
    ;;
  esac

  # Fuente primaria: session file de Claude (~/.claude/sessions/{ppid}.json)
  local _sf="${CLAUDE_SESSIONS_DIR}/${_ppid}.json"
  if [[ -f "$_sf" ]]; then
    if ! kill -0 "$_ppid" 2>/dev/null; then
      # Proceso muerto con session file — crashed si estaba busy
      local _st
      _st=$(grep -o '"status":"[^"]*"' "$_sf" | cut -d'"' -f4 2>/dev/null)
      [[ "$_st" == "busy" ]] && {
        _log_debug "detect_icon: ppid=$_ppid cmd=$_cmd → crashed"
        printf '%s' "$STATE_CRASHED"
        return
      }
      _log_debug "detect_icon: ppid=$_ppid cmd=$_cmd → empty (dead+session)"
      printf '%s' "$STATE_EMPTY"
      return
    fi
    local _st
    _st=$(grep -o '"status":"[^"]*"' "$_sf" | cut -d'"' -f4 2>/dev/null)
    case "$_st" in
      busy)
        _log_debug "detect_icon: ppid=$_ppid cmd=$_cmd → working"
        printf '%s' "$STATE_WORKING"
        return
        ;;
      waiting | idle)
        if [[ -n "$_lines" ]]; then
          local _pcheck
          if [[ "$_lines" == *"❯"* ]]; then
            _pcheck="${_lines##*❯}"
          else
            _pcheck="$_lines"
          fi
          if [[ "$_pcheck" == *"[Yes]"* ]] || [[ "$_pcheck" == *"[No]"* ]] \
            || [[ "$_pcheck" == *"[Always]"* ]] || [[ "$_pcheck" == *"Enter to select"* ]]; then
            _log_debug "detect_icon: ppid=$_ppid cmd=$_cmd → blocked"
            printf '%s' "$STATE_BLOCKED"
            return
          fi
        fi
        _log_debug "detect_icon: ppid=$_ppid cmd=$_cmd → idle"
        printf '%s' "$STATE_IDLE"
        return
        ;;
    esac
  fi

  # Fallback nivel 1: pane title (Claude Code lo escribe vía OSC 2)
  if [[ -n "$_title" ]]; then
    local _fc="${_title:0:1}"
    if [[ "$_fc" == "✳" ]]; then
      # Idle según título — revisar si el contenido indica espera de input del usuario
      if [[ -n "$_lines" ]] \
        && ([[ "$_lines" == *"[Yes]"* ]] || [[ "$_lines" == *"[No]"* ]] \
          || [[ "$_lines" == *"[Always]"* ]] || [[ "$_lines" == *"Enter to select"* ]]); then
        _log_debug "detect_icon: ppid=$_ppid cmd=$_cmd → blocked (title)"
        printf '%s' "$STATE_BLOCKED"
        return
      fi
      _log_debug "detect_icon: ppid=$_ppid cmd=$_cmd → idle (title)"
      printf '%s' "$STATE_IDLE"
      return
    fi
    local _hex
    _hex=$(LC_ALL=C printf '%s' "$_fc" | od -A n -t x1 | tr -d ' \n')
    case "$_hex" in
      e2a0* | e2a1* | e2a2* | e2a3*)
        _log_debug "detect_icon: ppid=$_ppid cmd=$_cmd → working (title braille)"
        printf '%s' "$STATE_WORKING"
        return
        ;;
    esac
  fi

  # Fallback nivel 2: content scanning (versiones viejas / sin session file)
  if [[ -z "$_lines" ]]; then
    _log_debug "detect_icon: ppid=$_ppid cmd=$_cmd → empty (no content)"
    printf '%s' "$STATE_EMPTY"
    return
  fi

  local _wide="${_lines: -${CONTENT_SCAN_WIDE}}"
  local _narrow="${_lines: -${CONTENT_SCAN_NARROW}}"
  local _icon="$STATE_EMPTY" _min=999999 _tmp _tlen

  _tmp="${_wide##*⏺}"
  _tlen=${#_tmp}
  [[ "$_wide" == *"⏺"* && $_tlen -lt $_min ]] && {
    _min=$_tlen
    _icon="$STATE_WORKING"
  }

  _tmp="${_narrow##*❯}"
  _tlen=${#_tmp}
  [[ "$_narrow" == *"❯"* && $_tlen -lt $_min ]] && {
    _min=$_tlen
    _icon="$STATE_IDLE"
  }

  # Permission/question patterns → blocked (necesitan acción del usuario)
  _tmp="${_narrow##*\[Yes\]}"
  _tlen=${#_tmp}
  [[ "$_narrow" == *"[Yes]"* && $_tlen -lt $_min ]] && {
    _min=$_tlen
    _icon="$STATE_BLOCKED"
  }
  _tmp="${_narrow##*\[No\]}"
  _tlen=${#_tmp}
  [[ "$_narrow" == *"[No]"* && $_tlen -lt $_min ]] && {
    _min=$_tlen
    _icon="$STATE_BLOCKED"
  }
  _tmp="${_narrow##*\[Always\]}"
  _tlen=${#_tmp}
  [[ "$_narrow" == *"[Always]"* && $_tlen -lt $_min ]] && {
    _min=$_tlen
    _icon="$STATE_BLOCKED"
  }
  _tmp="${_narrow##*Enter to select}"
  _tlen=${#_tmp}
  [[ "$_narrow" == *"Enter to select"* && $_tlen -lt $_min ]] && {
    _min=$_tlen
    _icon="$STATE_BLOCKED"
  }

  _r="$_icon"
  _log_debug "detect_icon: ppid=$_ppid cmd=$_cmd → $_r"
  printf '%s' "$_r"
}

# Resuelve el PID real de Claude: el propio pane_pid si tiene session file,
# o el primer hijo que tenga session file (cuando Claude corre dentro de un shell).
effective_claude_pid() {
  local _ppid="$1"
  [[ -f "${CLAUDE_SESSIONS_DIR}/${_ppid}.json" ]] && {
    printf '%s' "$_ppid"
    return
  }
  # Buscar en hijos directos
  local _cp
  while IFS= read -r _cp; do
    [[ -n "$_cp" && -f "${CLAUDE_SESSIONS_DIR}/${_cp}.json" ]] && {
      printf '%s' "$_cp"
      return
    }
  done < <(pgrep -P "$_ppid" 2>/dev/null)
  printf '%s' "$_ppid"
}

# Devuelve el nombre completo del sub-agente leyendo el campo "agent" del session file.
agent_sigla() {
  local _ppid="$1"
  local _sf="${CLAUDE_SESSIONS_DIR}/${_ppid}.json"
  [[ -f "$_sf" ]] || return
  local _agent
  _agent=$(grep -o '"agent":"[^"]*"' "$_sf" | cut -d'"' -f4 2>/dev/null)
  [[ -z "$_agent" ]] && return
  printf '%s' "$_agent"
}

# Detecta si una ventana está en loop (≥3 transiciones W→I en 10 min).
# Actualiza los archivos de tracking. Retorna 0 si se debe aplicar estado L.
check_loop() {
  local _wkey="$1" _icon="$2"
  local _prev_f="${STATE_DIR}/${_wkey}.dprev"
  local _loop_f="${STATE_DIR}/${_wkey}.looptimes"
  local _prev
  _prev=$(cat "$_prev_f" 2>/dev/null)

  # Si el usuario visitó la ventana (sidebar borra .unread), resetear loop counter
  [[ ! -f "${STATE_DIR}/${_wkey}.unread" && -f "$_loop_f" ]] && {
    # Solo resetear si el estado actual es idle (agente terminó y el usuario lo revisó)
    [[ "$_icon" == "$STATE_IDLE" && "$_prev" == "$STATE_LOOP" ]] && {
      rm -f "$_loop_f"
      printf '%s' "$_icon" >"$_prev_f"
      return 1
    }
  }

  # Registrar transición working→idle solo si hay suficiente separación desde la última.
  # Mínimo 60s entre transiciones: distingue conversaciones activas de loops reales.
  if [[ ("$_prev" == "$STATE_WORKING" || "$_prev" == "$STATE_LOOP") && ("$_icon" == "$STATE_IDLE" || "$_icon" == "$STATE_BLOCKED") ]]; then
    local _now
    _now=$(date +%s)
    # Leer la última entrada para verificar espaciado mínimo
    local _last_ts="0"
    [[ -f "$_loop_f" ]] && _last_ts=$(tail -1 "$_loop_f" 2>/dev/null)
    [[ -z "$_last_ts" || ! "$_last_ts" =~ ^[0-9]+$ ]] && _last_ts=0
    if ((_now - _last_ts >= LOOP_MIN_SPACING_SECS)); then
      printf '%s\n' "$_now" >>"$_loop_f"
    fi
    # Podar entradas antiguas (>LOOP_WINDOW_SECS)
    local _cutoff=$((_now - LOOP_WINDOW_SECS)) _trimmed="" _ts
    [[ -f "$_loop_f" ]] && while IFS= read -r _ts; do
      [[ -n "$_ts" && "$_ts" -gt "$_cutoff" ]] && _trimmed+="${_ts}"$'\n'
    done <"$_loop_f"
    printf '%s' "$_trimmed" >"$_loop_f"
  fi

  # Actualizar estado previo del daemon
  local _save_icon="$_icon"

  # Verificar umbral de loop
  local _loop_count=0
  if [[ -f "$_loop_f" ]]; then
    _loop_count=$(grep -c '[0-9]' "$_loop_f" 2>/dev/null || echo 0)
  fi

  if [[ "${_loop_count:-0}" -ge $LOOP_MIN_TRANSITIONS && ("$_icon" == "$STATE_IDLE" || "$_icon" == "$STATE_BLOCKED" || "$_icon" == "$STATE_LOOP") ]]; then
    _save_icon="$STATE_LOOP"
    printf '%s' "$STATE_LOOP" >"$_prev_f"
    return 0
  fi

  printf '%s' "$_save_icon" >"$_prev_f"
  return 1
}
