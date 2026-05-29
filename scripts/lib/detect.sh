# detect.sh — icon detection and loop tracking
# Sourced by daemon.sh. Assumes STATE_DIR, CLAUDE_SESSIONS_DIR are already set.
# No shebang — not executed directly.

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
      waiting)
        # Verificar que el contenido todavía muestra la UI de pregunta/permiso.
        # Si la sesión dice "waiting" pero el pane ya no muestra nada relevante,
        # el estado es stale → tratar como idle.
        if [[ -n "$_lines" ]] && \
           ( [[ "$_lines" == *"[Yes]"* ]] || [[ "$_lines" == *"[No]"* ]] || \
             [[ "$_lines" == *"[Always]"* ]] || [[ "$_lines" == *"Enter to select"* ]] ); then
          printf 'P'; return
        fi
        printf 'I'; return ;;
      idle)
        # Doble chequeo: idle con diálogo de permiso visible en contenido
        if [[ -n "$_lines" ]] && \
           ( [[ "$_lines" == *"[Yes]"* ]] || [[ "$_lines" == *"[No]"* ]] || \
             [[ "$_lines" == *"[Always]"* ]] || [[ "$_lines" == *"Enter to select"* ]] ); then
          printf 'P'; return
        fi
        printf 'I'; return ;;
    esac
  fi

  # Fallback nivel 1: pane title (Claude Code lo escribe vía OSC 2)
  if [[ -n "$_title" ]]; then
    local _fc="${_title:0:1}"
    if [[ "$_fc" == "✳" ]]; then
      # Idle según título — revisar si el contenido indica espera de input del usuario
      if [[ -n "$_lines" ]] && \
         ( [[ "$_lines" == *"[Yes]"* ]] || [[ "$_lines" == *"[No]"* ]] || \
           [[ "$_lines" == *"[Always]"* ]] || [[ "$_lines" == *"Enter to select"* ]] ); then
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

  # Permission/question patterns → P (necesitan acción del usuario)
  _tmp="${_narrow##*\[Yes\]}";          _tlen=${#_tmp}
  [[ "$_narrow" == *"[Yes]"*         && $_tlen -lt $_min ]] && { _min=$_tlen; _icon="P"; }
  _tmp="${_narrow##*\[No\]}";           _tlen=${#_tmp}
  [[ "$_narrow" == *"[No]"*          && $_tlen -lt $_min ]] && { _min=$_tlen; _icon="P"; }
  _tmp="${_narrow##*\[Always\]}";       _tlen=${#_tmp}
  [[ "$_narrow" == *"[Always]"*      && $_tlen -lt $_min ]] && { _min=$_tlen; _icon="P"; }
  _tmp="${_narrow##*Enter to select}";  _tlen=${#_tmp}
  [[ "$_narrow" == *"Enter to select"* && $_tlen -lt $_min ]] && { _min=$_tlen; _icon="P"; }

  printf '%s' "$_icon"
}

# Resuelve el PID real de Claude: el propio pane_pid si tiene session file,
# o el primer hijo que tenga session file (cuando Claude corre dentro de un shell).
effective_claude_pid() {
  local _ppid="$1"
  [[ -f "${CLAUDE_SESSIONS_DIR}/${_ppid}.json" ]] && { printf '%s' "$_ppid"; return; }
  # Buscar en hijos directos
  local _cp
  while IFS= read -r _cp; do
    [[ -n "$_cp" && -f "${CLAUDE_SESSIONS_DIR}/${_cp}.json" ]] && { printf '%s' "$_cp"; return; }
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
  local _prev; _prev=$(cat "$_prev_f" 2>/dev/null)

  # Si el usuario visitó la ventana (sidebar borra .unread), resetear loop counter
  [[ ! -f "${STATE_DIR}/${_wkey}.unread" && -f "$_loop_f" ]] && {
    # Solo resetear si el estado actual es idle (agente terminó y el usuario lo revisó)
    [[ "$_icon" == "I" && "$_prev" == "L" ]] && { rm -f "$_loop_f"; printf '%s' "$_icon" > "$_prev_f"; return 1; }
  }

  # Registrar transición W→I solo si hay suficiente separación desde la última.
  # Mínimo 60s entre transiciones: distingue conversaciones activas (W→I cada pocos
  # segundos) de loops reales (ciclos separados por minutos).
  if [[ ( "$_prev" == "W" || "$_prev" == "L" ) && ( "$_icon" == "I" || "$_icon" == "P" ) ]]; then
    local _now; _now=$(date +%s)
    # Leer la última entrada para verificar espaciado mínimo
    local _last_ts="0"
    [[ -f "$_loop_f" ]] && _last_ts=$(tail -1 "$_loop_f" 2>/dev/null)
    [[ -z "$_last_ts" || ! "$_last_ts" =~ ^[0-9]+$ ]] && _last_ts=0
    if (( _now - _last_ts >= 60 )); then
      printf '%s\n' "$_now" >> "$_loop_f"
    fi
    # Podar entradas antiguas (>600s)
    local _cutoff=$(( _now - 600 )) _trimmed="" _ts
    [[ -f "$_loop_f" ]] && while IFS= read -r _ts; do
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
