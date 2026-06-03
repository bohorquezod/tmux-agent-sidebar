# shellcheck shell=bash
# render.sh — sidebar rendering entry point and frame loop
# Sourced by sidebar.sh. No shebang — not executed directly.
# Requires: render-icons.sh and render-row.sh sourced first.

# ── ANSI color palette ────────────────────────────────────────────────────────
R=$'\033[0m'
# shellcheck disable=SC2034  # G used in render-row.sh
G=$'\033[32m'
# shellcheck disable=SC2034  # BG used in render-row.sh
BG=$'\033[1;32m'
PU=$'\033[1;35m'; GR=$'\033[90m'; RD=$'\033[31m'; YL=$'\033[1;33m'; CY=$'\033[1;36m'; WH=$'\033[1;37m'

file_mtime() { stat -f '%m' "$1" 2>/dev/null || stat -c '%Y' "$1" 2>/dev/null || echo 0; }

# Sorts SESSIONS_FLAT in-place by session name (alpha order)
_sessions_sort_alpha() {
  [[ ${#SESSIONS_FLAT[@]} -le 1 ]] && return
  local _sorted=()
  while IFS= read -r _e; do [[ -n "$_e" ]] && _sorted+=("$_e"); done \
    < <(printf '%s\n' "${SESSIONS_FLAT[@]}" | sort -t'|' -k2)
  SESSIONS_FLAT=("${_sorted[@]}")
}

# Sorts a _data_wins array in-place by window name via _win_meta.
# Args: <server> <session> <nameref to array>
_windows_sort_alpha() {
  local _srv="$1" _sess="$2"
  local -n _wref="$3"
  [[ ${#_wref[@]} -le 1 ]] && return
  local _named=() _dw _nm
  for _dw in "${_wref[@]}"; do
    _nm="${_win_meta["${_srv}|${_sess}|${_dw}"]%%|*}"
    _named+=("${_nm}|${_dw}")
  done
  _wref=()
  while IFS= read -r _line; do [[ -n "$_line" ]] && _wref+=("${_line#*|}"); done \
    < <(printf '%s\n' "${_named[@]}" | sort -t'|' -k1)
}

# ── Differential rendering state ─────────────────────────────────────────────
declare -a _DIFF_LINES=()
_DIFF_W=0
_DIFF_H=0
_DIFF_MODE=""

# _diff_print <buf> <W> <H> <mode>
# Emits only the lines that changed since last call. Full redraw on first
# render, resize, or mode transition (main / search / help).
_diff_print() {
  local buf="$1" w="$2" h="$3" mode="${4:-main}"
  local _E=$'\033'

  local -a _new=()
  local _ln
  while IFS= read -r _ln; do
    _new+=("$_ln")
  done <<<"$buf"

  local _nlen=${#_new[@]} _plen=${#_DIFF_LINES[@]}

  # Full redraw: first render, resize, or mode change.
  # Overwrite in place (home → write+erase-line per line → clear rest) — never clears screen first,
  # so there is no blank-screen flash even when the whole buffer needs to change.
  if [[ "$w" != "$_DIFF_W" || "$h" != "$_DIFF_H" || $_plen -eq 0 || "$mode" != "$_DIFF_MODE" ]]; then
    local _NL=$'\n' _EL=$'\033[K'
    printf '\033[?25l\033[H%s\033[J' "${buf//$_NL/${_EL}${_NL}}"
    _DIFF_LINES=("${_new[@]}")
    _DIFF_W=$w
    _DIFF_H=$h
    _DIFF_MODE=$mode
    return
  fi

  local _out='' _i
  for ((_i = 0; _i < _nlen; _i++)); do
    [[ "${_new[$_i]}" != "${_DIFF_LINES[$_i]:-}" ]] \
      && _out+="${_E}[$((_i + 1));1H${_new[$_i]}${_E}[K"
  done
  # Clear leftover lines if new render is shorter than previous
  ((_plen > _nlen)) && _out+="${_E}[$((_nlen + 1));1H${_E}[J"
  [[ -n "$_out" ]] && printf '\033[?25l%s' "$_out"
  _DIFF_LINES=("${_new[@]}")
}

# ── Help overlay ─────────────────────────────────────────────────────────────
render_help() {
  local _sz W H
  _sz=$(stty size 2>/dev/null)
  W="${_sz##* }"
  [[ ! "$W" =~ ^[0-9]+$ || "$W" -lt 4 ]] && W="${COLUMNS:-28}"
  [[ "$W" -lt 4 ]] && W=28
  H="${_sz%% *}"
  [[ ! "$H" =~ ^[0-9]+$ || "$H" -lt 4 ]] && H="${LINES:-24}"
  [[ "$H" -lt 4 ]] && H=24
  local sep
  sep=$(printf '─%.0s' $(seq 1 $W))
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
  buf+=" ${WH}U${R}    mark all read"$'\n'
  buf+=" ${WH}m${R}    mark unread  ${YL}◉${R}"$'\n'
  buf+=$'\n'
  buf+=" ${GR}Reorder${R}"$'\n'
  buf+=" ${WH}J${R}    move down"$'\n'
  buf+=" ${WH}K${R}    move up"$'\n'
  buf+=$'\n'
  buf+=" ${GR}Other${R}"$'\n'
  buf+=" ${WH}i${R}    window info"$'\n'
  buf+=" ${WH}:${R}    command  ${GR}N / N.M${R}"$'\n'
  buf+=" ${WH}a${R}    sort alpha/manual"$'\n'
  buf+=" ${WH}r${R}    rename"$'\n'
  buf+=" ${WH}R${R}    reload"$'\n'
  buf+=" ${WH}q${R}    quit"$'\n'
  buf+=$'\n'
  buf+="${GR}${sep}${R}"$'\n'
  buf+="${GR} ? or any key to close${R}"$'\n'
  buf+=" ${GR}v${PLUGIN_VERSION}${R}"
  _diff_print "$buf" "$W" "$H" "help"
}

# ── Info overlay ─────────────────────────────────────────────────────────────
render_info() {
  local _sz W
  _sz=$(stty size 2>/dev/null)
  W="${_sz##* }"
  [[ ! "$W" =~ ^[0-9]+$ || "$W" -lt 4 ]] && W="${COLUMNS:-28}"
  [[ "$W" -lt 4 ]] && W=28
  local sep
  sep=$(printf '─%.0s' $(seq 1 $W))
  local buf=""
  buf+=" ${PU}◈${R}  ${WH}Window Info${R}"$'\n'
  buf+="${GR}${sep}${R}"$'\n'
  buf+=$'\n'

  local _maxw=$((W - 12))
  [[ $_maxw -lt 6 ]] && _maxw=6

  # Window name
  local _wn_disp="${_INFO_WNAME:0:$_maxw}"
  [[ ${#_INFO_WNAME} -gt $_maxw ]] && _wn_disp="${_INFO_WNAME:0:$((_maxw - 1))}…"
  buf+=" ${GR}window ${R} ${WH}${_wn_disp}${R}"$'\n'

  # Status
  local _slabel _scol
  case "$_INFO_STATUS" in
    W)
      _slabel="working"
      _scol="$CY"
      ;;
    I)
      _slabel="idle"
      _scol="$GR"
      ;;
    P)
      _slabel="blocked"
      _scol="$RD"
      ;;
    L)
      _slabel="loop"
      _scol="$YL"
      ;;
    X)
      _slabel="crashed"
      _scol="$RD"
      ;;
    *)
      _slabel="empty"
      _scol="$GR"
      ;;
  esac
  buf+=" ${GR}status ${R} ${_scol}${_slabel}${R}"$'\n'
  buf+=$'\n'

  # Project
  if [[ -n "$_INFO_PROJECT" ]]; then
    local _proj_disp="${_INFO_PROJECT:0:$_maxw}"
    [[ ${#_INFO_PROJECT} -gt $_maxw ]] && _proj_disp="${_INFO_PROJECT:0:$((_maxw - 1))}…"
    buf+=" ${GR}project${R} ${WH}${_proj_disp}${R}"$'\n'
  fi

  # Branch
  if [[ -n "$_INFO_BRANCH" ]]; then
    local _br_disp="${_INFO_BRANCH:0:$_maxw}"
    [[ ${#_INFO_BRANCH} -gt $_maxw ]] && _br_disp="${_INFO_BRANCH:0:$((_maxw - 1))}…"
    buf+=" ${GR}branch ${R} ${WH}${_br_disp}${R}"$'\n'
  fi

  # PR
  if [[ -n "$_INFO_PR_URL" ]]; then
    local _pr_disp="${_INFO_PR_URL:0:$_maxw}"
    [[ ${#_INFO_PR_URL} -gt $_maxw ]] && _pr_disp="${_INFO_PR_URL:0:$((_maxw - 1))}…"
    buf+=" ${GR}pr     ${R} ${CY}${_pr_disp}${R}"$'\n'
  fi

  # Agent sigla
  if [[ -n "$_INFO_AGENT" ]]; then
    buf+=" ${GR}agent  ${R} ${PU}${_INFO_AGENT}${R}"$'\n'
  fi

  buf+=$'\n'
  buf+="${GR}${sep}${R}"$'\n'
  buf+="${GR} [i] or [Esc] to close${R}"$'\n'
  printf '\033[H\033[J%s' "$buf"
}

# ── Render ────────────────────────────────────────────────────────────────────
render() {
  [[ "$_HELP_MODE" -eq 1 ]] && {
    render_help
    return
  }
  [[ "$_INFO_MODE" -eq 1 ]] && {
    render_info
    return
  }
  [[ ! -f "$DATA_FILE" ]] && return

  ((_SPIN_FRAME = (_SPIN_FRAME + 1) % 10))

  # Procesar just_visited: limpiar unread y marcar 💤 para evitar falso trigger posterior
  if [[ -f "${STATE_DIR}/just_visited" ]]; then
    local _jv
    _jv=$(<"${STATE_DIR}/just_visited")
    rm -f "${STATE_DIR}/just_visited"
    local _jvk="${_jv//[^a-zA-Z0-9_-]/_}"
    rm -f "${STATE_DIR}/${_jvk}.unread"
    printf '💤' >"${STATE_DIR}/${_jvk}.prev_icon"
  fi

  # Resolver sesión y ventana activa del outer server en este ciclo de render
  # _outer_sess and _outer_win are globals so render_window_row can read them
  _outer_sess=$(cat "${STATE_DIR}/current_session" 2>/dev/null)
  _outer_win=""
  local _df_mtime
  _df_mtime=$(file_mtime "$DATA_FILE")
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

  # _CURRENT_W/_CURRENT_H se actualizan en sidebar.sh desde el pane externo (fuente de verdad)
  # o desde stty. Son siempre más frescos que llamar stty aquí porque se sincronizan antes de
  # que SIGWINCH propague. stty es el fallback cuando los globales aún no están inicializados.
  local _sz W H
  _sz=$(stty size 2>/dev/null)
  W="${_sz##* }"
  [[ ! "$W" =~ ^[0-9]+$ || "$W" -lt 4 ]] && W="${COLUMNS:-28}"
  [[ "$W" -lt 4 ]] && W=28
  H="${_sz%% *}"
  [[ ! "$H" =~ ^[0-9]+$ || "$H" -lt 4 ]] && H="${LINES:-24}"
  [[ "$H" -lt 4 ]] && H=24
  [[ "${_CURRENT_W:-0}" -ge 4 ]] && W="$_CURRENT_W"
  [[ "${_CURRENT_H:-0}" -ge 4 ]] && H="$_CURRENT_H"
  # Persiste el ancho actual por servidor para que nuevas ventanas abran al mismo ancho.
  # Durante drag activo (SIGWINCH) sincronizar todos los panes sidebar para evitar que
  # el servidor rebote entre anchos de distintos clientes.
  local _srv_key="${OUTER_SERVER//[^a-zA-Z0-9_-]/_}"
  local _width_f="${STATE_DIR}/sidebar_width_${_srv_key}"
  [[ ! -f "$_width_f" && -f "${STATE_DIR}/sidebar_width" ]] && cp "${STATE_DIR}/sidebar_width" "$_width_f"
  local _sw
  _sw=$(cat "$_width_f" 2>/dev/null)
  if [[ "$W" != "$_sw" ]]; then
    printf '%s' "$W" >"$_width_f"
    printf '%s' "$W" >"${STATE_DIR}/sidebar_width"
  fi
  max=$((W - 6))
  [[ $max -lt 6 ]] && max=6
  local sep
  sep=$(printf '─%.0s' $(seq 1 $W))

  if [[ "$_search_fast_path" == "0" ]]; then
    # ── Actualizar SESSIONS_FLAT ──────────────────────────────────────────────
    local _data_sess=()
    while IFS='|' read -r _t _f1 _f2 _f3 _f4 _f5 _f6; do
      [[ "$_t" == "E" ]] && _data_sess+=("${_f1}|${_f2}")
    done <"$DATA_FILE"

    if [[ ${#SESSIONS_FLAT[@]} -eq 0 ]]; then
      if [[ -f "$ORDER_FILE" ]]; then
        local _o_srv _o_sess _target _found _d
        while IFS='|' read -r _o_srv _o_sess; do
          [[ -z "$_o_srv" || -z "$_o_sess" ]] && continue
          _target="${_o_srv}|${_o_sess}"
          _found=false
          for _d in "${_data_sess[@]}"; do [[ "$_d" == "$_target" ]] && {
            _found=true
            break
          }; done
          [[ "$_found" == true ]] && SESSIONS_FLAT+=("$_target")
        done <"$ORDER_FILE"
      fi
      local _d _found _s
      for _d in "${_data_sess[@]}"; do
        _found=false
        for _s in "${SESSIONS_FLAT[@]}"; do [[ "$_d" == "$_s" ]] && {
          _found=true
          break
        }; done
        [[ "$_found" == false ]] && SESSIONS_FLAT+=("$_d")
      done
    else
      # Merge cuando hay diferencia de count O de contenido (sesión reemplazada con mismo count)
      local _needs_merge=0
      [[ ${#_data_sess[@]} -ne ${#SESSIONS_FLAT[@]} ]] && _needs_merge=1
      if [[ "$_needs_merge" -eq 0 ]]; then
        local _e _d _found
        for _e in "${SESSIONS_FLAT[@]}"; do
          _found=false
          for _d in "${_data_sess[@]}"; do [[ "$_e" == "$_d" ]] && {
            _found=true
            break
          }; done
          [[ "$_found" == false ]] && {
            _needs_merge=1
            break
          }
        done
      fi
      if [[ "$_needs_merge" -eq 1 ]]; then
        local _merged=() _e _d _found
        for _e in "${SESSIONS_FLAT[@]}"; do
          _found=false
          for _d in "${_data_sess[@]}"; do [[ "$_e" == "$_d" ]] && {
            _found=true
            break
          }; done
          [[ "$_found" == true ]] && _merged+=("$_e")
        done
        for _d in "${_data_sess[@]}"; do
          _found=false
          for _e in "${_merged[@]}"; do [[ "$_d" == "$_e" ]] && {
            _found=true
            break
          }; done
          [[ "$_found" == false ]] && _merged+=("$_d")
        done
        SESSIONS_FLAT=("${_merged[@]}")
      fi
    fi
    [[ "$SORT_MODE" == "alpha" ]] && _sessions_sort_alpha

    # ── Pre-leer DATA_FILE en arrays asociativos (bash 4) ────────────────────
    _win_keys=()
    _srv_cur=()
    _sess_act=()
    _win_meta=()
    while IFS='|' read -r _t _f1 _f2 _f3 _f4 _f5 _f6 _f7 _f8; do
      case "$_t" in
        S) _srv_cur["$_f1"]="$_f2" ;;
        E) _sess_act["${_f1}|${_f2}"]="$_f3" ;;
        W)
          _win_keys+=("${_f1}|${_f2}|${_f3}")
          _win_meta["${_f1}|${_f2}|${_f3}"]="${_f4}|${_f5}|${_f6}|${_f7}|${_f8}"
          ;;
      esac
    done <"$DATA_FILE"
    _RENDER_DATA_MTIME="$_df_mtime"

    # ── Construir ITEMS_FLAT en orden del usuario ─────────────────────────
    # Preservar orden de ventanas ya en ITEMS_FLAT si el conteo no cambió
    # (evita revertir orden tras un swap-window antes de que el daemon actualice DATA_FILE)
    local _old_items=("${ITEMS_FLAT[@]}")
    ITEMS_FLAT=()
    local _entry _srv _sess _k
    for _entry in "${SESSIONS_FLAT[@]}"; do
      _srv="${_entry%%|*}"
      _sess="${_entry#*|}"
      ITEMS_FLAT+=("S|${_srv}|${_sess}")

      # Ventanas en DATA_FILE para este session (O(1) lookup via _win_keys)
      local _data_wins=()
      local _wk
      for _wk in "${_win_keys[@]}"; do
        local _wk_srv="${_wk%%|*}" _wk_rest="${_wk#*|}"
        local _wk_sess="${_wk_rest%%|*}" _wk_widx="${_wk_rest#*|}"
        [[ "$_wk_srv" == "$_srv" && "$_wk_sess" == "$_sess" ]] && _data_wins+=("$_wk_widx")
      done
      [[ ${#_data_wins[@]} -eq 0 ]] && continue
      [[ "$SORT_MODE" == "alpha" ]] && _windows_sort_alpha "$_srv" "$_sess" _data_wins

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
      if [[ "$SORT_MODE" != "alpha" && ${#_old_wins[@]} -eq ${#_data_wins[@]} && ${#_old_wins[@]} -gt 0 ]]; then
        _wins=("${_old_wins[@]}")
      elif [[ ${#_old_wins[@]} -gt 0 ]]; then
        local _ow _dw _found
        for _ow in "${_old_wins[@]}"; do
          _found=false
          for _dw in "${_data_wins[@]}"; do [[ "$_ow" == "$_dw" ]] && {
            _found=true
            break
          }; done
          [[ "$_found" == true ]] && _wins+=("$_ow")
        done
        for _dw in "${_data_wins[@]}"; do
          _found=false
          for _ow in "${_wins[@]}"; do [[ "$_dw" == "$_ow" ]] && {
            _found=true
            break
          }; done
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
    if [[ "$_INITIAL_SELECT" == "1" && ${#ITEMS_FLAT[@]} -gt 0 ]]; then
      _INITIAL_SELECT=0
      local _ini=0 _init_item _iir _iis
      local _init_target="${_outer_sess:-${WIN_SESS:-}}"
      for _init_item in "${ITEMS_FLAT[@]}"; do
        if [[ "${_init_item%%|*}" == "S" ]]; then
          _iir="${_init_item#*|}"
          _iis="${_iir#*|}"
          [[ "$_iis" == "$_init_target" ]] && {
            SELECTED=$_ini
            break
          }
        fi
        ((_ini++))
      done
    fi

    # Re-encontrar el cursor si cambió el orden (después de J/K)
    if [[ -n "$CURSOR_ITEM" ]]; then
      local _ci=0 _cfound=false
      for _item in "${ITEMS_FLAT[@]}"; do
        [[ "$_item" == "$CURSOR_ITEM" ]] && {
          SELECTED=$_ci
          _cfound=true
          break
        }
        ((_ci++))
      done
      CURSOR_ITEM=""
    fi
  fi # end fast-path guard
  [[ $SELECTED -ge ${#ITEMS_FLAT[@]} ]] && SELECTED=$((${#ITEMS_FLAT[@]} - 1))
  [[ $SELECTED -lt 0 ]] && SELECTED=0

  _cur_sess="${_outer_sess:-}"

  # ── Precalcular conteos para el footer de estado ─────────────────────────
  local _wc=0 _uc=0 _ic_raw=0 _ec=0 _pc=0 _lc=0 _xc=0
  local _wk2
  for _wk2 in "${_win_keys[@]}"; do
    local _wmeta2="${_win_meta[$_wk2]:-}"
    local _wi2="${_wmeta2#*|}" # skip name field
    _wi2="${_wi2%%|*}"         # extract icon field
    case "$_wi2" in
      "$STATE_WORKING")
        ((_wc++))
        _HAS_WORKING=1
        ;;
      "$STATE_IDLE") ((_ic_raw++)) ;;
      "$STATE_EMPTY") ((_ec++)) ;;
      "$STATE_BLOCKED") ((_pc++)) ;;
      "$STATE_LOOP")
        ((_lc++))
        _HAS_WORKING=1
        ;;
      "$STATE_CRASHED") ((_xc++)) ;;
    esac
    if [[ "$_wi2" != "$STATE_EMPTY" ]]; then
      local _uk2="${_wk2//[^a-zA-Z0-9_-]/_}"
      _uk2="${_uk2//|/_}"
      [[ -f "${STATE_DIR}/${_uk2}.unread" ]] && ((_uc++))
    fi
  done

  # ── Modo búsqueda inline ─────────────────────────────────────────────────────
  if [[ "$_SEARCH_MODE" == "1" ]]; then
    local _ql _fit _ftype _frest _fname _fl _si2 _stotal
    _ql=$(printf '%s' "$_SEARCH_QUERY" | tr '[:upper:]' '[:lower:]')
    _SEARCH_ITEMS=()
    for _fit in "${ITEMS_FLAT[@]}"; do
      _ftype="${_fit%%|*}"
      _frest="${_fit#*|}"
      _fname=""
      if [[ "$_ftype" == "S" ]]; then
        _fname="${_frest#*|}"
      elif [[ "$_ftype" == "W" ]]; then
        local _fsrv="${_frest%%|*}" _fwr="${_frest#*|}"
        local _fss="${_fwr%%|*}" _fwid="${_fwr#*|}"
        local _fmeta="${_win_meta["${_fsrv}|${_fss}|${_fwid}"]:-}"
        _fname="${_fmeta%%|*}"
      fi
      _fl=$(printf '%s' "$_fname" | tr '[:upper:]' '[:lower:]')
      if [[ -z "$_ql" || "$_fl" == *"$_ql"* ]]; then
        _SEARCH_ITEMS+=("$_fit")
      fi
    done

    _stotal=${#_SEARCH_ITEMS[@]}
    [[ $_SEARCH_SEL -ge $_stotal && $_stotal -gt 0 ]] && _SEARCH_SEL=$((_stotal - 1))
    [[ $_SEARCH_SEL -lt 0 ]] && _SEARCH_SEL=0

    local buf="" mapbuf=""
    buf="${PU} ◈${R}  /${YL}${_SEARCH_QUERY}${GR}▌${R}"$'\n'
    mapbuf=$'\n'
    buf+="${GR}${sep}${R}"$'\n'
    mapbuf+=$'\n'

    if [[ $_stotal -eq 0 ]]; then
      buf+="${GR} (sin resultados)${R}"$'\n'
      mapbuf+=$'\n'
    else
      _si2=0
      for _fit in "${_SEARCH_ITEMS[@]}"; do
        _ftype="${_fit%%|*}"
        _frest="${_fit#*|}"
        local _fc="$GR" _fcur=" "
        [[ $_si2 -eq $_SEARCH_SEL ]] && {
          _fc="$YL"
          _fcur="›"
        }
        if [[ "$_ftype" == "S" ]]; then
          local _fsess="${_frest#*|}"
          local _sessd="${_fsess:0:$max}"
          [[ ${#_fsess} -gt $max ]] && _sessd="${_fsess:0:$((max - 1))}…"
          buf+="${_fc}${_fcur}   ${_sessd}${R}"$'\n'
          mapbuf+="${_frest%%|*}|${_fsess}"$'\n'
        elif [[ "$_ftype" == "W" ]]; then
          local _fsrv2="${_frest%%|*}" _fwr2="${_frest#*|}"
          local _fss2="${_fwr2%%|*}" _fwid2="${_fwr2#*|}"
          local _fmeta2="${_win_meta["${_fsrv2}|${_fss2}|${_fwid2}"]:-}"
          local _wn2="${_fmeta2%%|*}"
          local _maxn2=$((max - 3)) _wdisp2
          [[ ${#_wn2} -gt $_maxn2 ]] && _wdisp2="${_wn2:0:$((_maxn2 - 1))}…" || _wdisp2="${_wn2:0:$_maxn2}"
          buf+="${_fc}${_fcur}   ${_wdisp2}${R}"$'\n'
          mapbuf+="${_fsrv2}|${_fss2}|${_fwid2}"$'\n'
        fi
        ((_si2++))
      done
    fi

    buf+=$'\n'
    mapbuf+=$'\n'
    buf+="${GR}${sep}${R}"$'\n'
    mapbuf+=$'\n'
    buf+=" ${CY}⠿${R} ${_wc}  ${RD}?${R} ${_pc}  ${YL}↺${R} ${_lc}  ${RD}✗${R} ${_xc}  ${GR}○${R} $((_ic_raw - _uc))  ${YL}◉${R} ${_uc}  ${GR}·${R} ${_ec}"$'\n'
    buf+="${GR} [jk]nav [↵]go [Esc]cancel${R}"$'\n'
    mapbuf+=$'\n\n'

    printf '%s' "$mapbuf" >"${STATE_DIR}/rowmap.tmp"
    mv "${STATE_DIR}/rowmap.tmp" "${STATE_DIR}/rowmap"
    _diff_print "$buf" "$W" "$H" "search"
    return
  fi

  # Detectar sesión padre del cursor (para resaltado blanco en modo ventana)
  _cursor_parent_item=""
  if [[ "${ITEMS_FLAT[$SELECTED]%%|*}" == "W" ]]; then
    local _cpi=$SELECTED
    while ((_cpi > 0)); do
      ((_cpi--))
      if [[ "${ITEMS_FLAT[$_cpi]%%|*}" == "S" ]]; then
        _cursor_parent_item="${ITEMS_FLAT[$_cpi]}"
        break
      fi
    done
  fi

  # ── Drill-down mode: "N." o "N.M" en el buffer → mostrar solo esa sesión ──
  _drill_mode=0
  _drill_snum=0
  _drill_wnum=""
  _in_drill_sess=0
  _win_ord=0
  if [[ "$_CMD_BUF" =~ ^:?([0-9]+)\.([0-9]*)$ ]]; then
    _drill_mode=1
    _drill_snum="${BASH_REMATCH[1]}"
    _drill_wnum="${BASH_REMATCH[2]}"
  fi

  # ── Construir buffer de display ───────────────────────────────────────────
  buf="" mapbuf="" prev_server="" _sess_num=0 _ii=0

  # Mode indicator: [NAV] | [CMD] <buffer> | [SRCH] <query>
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
  _hdr_len=$((4 + ${#_hdr_text}))
  _pad_len=$((W - _hdr_len - 1 - ${#_mode_label}))
  [[ $_pad_len -lt 0 ]] && _pad_len=0
  _hdr_spaces=$(printf '%*s' "$_pad_len" "")

  if [[ -n "$_CMD_BUF" ]]; then
    buf+="${PU} ◈${R}  ${YL}${_CMD_BUF}${GR}▌${R}${_hdr_spaces}${GR}${_mode_label}${R}"$'\n'
    mapbuf+=$'\n'
    local _hint
    _hint=$(_cmd_hint "$_CMD_BUF")
    if [[ -n "$_hint" ]]; then
      buf+="${GR}  · ${_hint}${R}"$'\n'
      mapbuf+=$'\n'
    fi
  elif [[ -n "$_RENAME_ITEM" ]]; then
    buf+="${PU} ◈${R}  ${CY}Rename:${R} ${YL}${_RENAME_BUF}${GR}▌${R}${_hdr_spaces}${GR}${_mode_label}${R}"$'\n'
    mapbuf+=$'\n'
  else
    buf+="${PU} ◈${R}  Claude${_hdr_spaces}${GR}${_mode_label}${R}"$'\n'
    mapbuf+=$'\n'
    if [[ -n "$_FILTER_STATUS" ]]; then
      buf+="${YL}  ⟨filter: ${_FILTER_STATUS}⟩${GR} [ESC]clear${R}"$'\n'
      mapbuf+=$'\n'
    fi
    [[ "$SORT_MODE" == "alpha" ]] && {
      buf+="${CY}  ⟨sort: α⟩${GR} [a]toggle${R}"$'\n'
      mapbuf+=$'\n'
    }
  fi
  buf+="${GR}${sep}${R}"$'\n'
  mapbuf+=$'\n'

  # Pre-scan para filtro de estado: construir lista de sesiones con ventanas matching
  local _filt_skeys=""
  if [[ -n "$_FILTER_STATUS" ]]; then
    local _fk
    for _fk in "${_win_keys[@]}"; do
      local _fmeta="${_win_meta[$_fk]:-}"
      local _fk_srv="${_fk%%|*}" _fk_rest="${_fk#*|}"
      local _fk_sess="${_fk_rest%%|*}"
      local _fk_icon
      _fk_icon=$(printf '%s' "$_fmeta" | cut -d'|' -f2)
      local _fk_widx="${_fk_rest#*|}"
      local _fmatch=0
      case "$_FILTER_STATUS" in
        working) [[ "$_fk_icon" == "$STATE_WORKING" || "$_fk_icon" == "$STATE_LOOP" ]] && _fmatch=1 ;;
        idle)
          local _fkey2="${_fk//[^a-zA-Z0-9_-|]/_}"
          _fkey2="${_fkey2//|/_}"
          [[ "$_fk_icon" != "$STATE_EMPTY" && "$_fk_icon" != "$STATE_WORKING" && "$_fk_icon" != "$STATE_LOOP" && ! -f "${STATE_DIR}/${_fkey2}.unread" ]] && _fmatch=1
          ;;
        unread)
          local _fkey2="${_fk//[^a-zA-Z0-9_-|]/_}"
          _fkey2="${_fkey2//|/_}"
          [[ -f "${STATE_DIR}/${_fkey2}.unread" ]] && _fmatch=1
          ;;
      esac
      [[ "$_fmatch" == "1" ]] && _filt_skeys+=" ${_fk_srv}|${_fk_sess}"
    done
  fi

  # ── Main display loop ─────────────────────────────────────────────────────
  local _item
  for _item in "${ITEMS_FLAT[@]}"; do
    local _itype="${_item%%|*}" _irest="${_item#*|}"

    if [[ "$_itype" == "S" ]]; then
      local _srv="${_irest%%|*}" _sess="${_irest#*|}"
      ((_sess_num++))

      # Filter: skip sessions with no matching windows
      if [[ -n "$_FILTER_STATUS" && "$_filt_skeys" != *" ${_srv}|${_sess}"* ]]; then
        ((_ii++))
        continue
      fi

      # Drill-down: skip sessions that don't match; update drill state
      if [[ "$_drill_mode" == "1" ]]; then
        if [[ $_sess_num -ne $_drill_snum ]]; then
          _in_drill_sess=0
          ((_ii++))
          continue
        fi
        _in_drill_sess=1
        _win_ord=0
      fi

      render_session_row "$_item" "$_srv" "$_sess"

    elif [[ "$_itype" == "W" ]]; then
      # Drill-down: skip windows outside the drill session
      if [[ "$_drill_mode" == "1" && "$_in_drill_sess" == "0" ]]; then
        ((_ii++))
        continue
      fi
      ((_win_ord++))

      local _srv="${_irest%%|*}" _wrest="${_irest#*|}"
      local _sess="${_wrest%%|*}" _widx="${_wrest#*|}"

      # Filter: skip windows that don't match
      if [[ -n "$_FILTER_STATUS" ]]; then
        local _fwmeta="${_win_meta["${_srv}|${_sess}|${_widx}"]:-}"
        local _fwkey="${_srv//[^a-zA-Z0-9_-]/_}_${_sess//[^a-zA-Z0-9_-]/_}_${_widx}"
        local _fwicon
        _fwicon=$(printf '%s' "$_fwmeta" | cut -d'|' -f2)
        local _fwmatch=0
        case "$_FILTER_STATUS" in
          working) [[ "$_fwicon" == "$STATE_WORKING" || "$_fwicon" == "$STATE_LOOP" ]] && _fwmatch=1 ;;
          idle) [[ "$_fwicon" != "$STATE_EMPTY" && "$_fwicon" != "$STATE_WORKING" && "$_fwicon" != "$STATE_LOOP" && ! -f "${STATE_DIR}/${_fwkey}.unread" ]] && _fwmatch=1 ;;
          unread) [[ -f "${STATE_DIR}/${_fwkey}.unread" ]] && _fwmatch=1 ;;
        esac
        [[ "$_fwmatch" == "0" ]] && {
          ((_ii++))
          continue
        }
      fi

      render_window_row "$_item" "$_srv" "$_sess" "$_widx"
    fi

    ((_ii++))
  done

  [[ -n "$prev_server" ]] && {
    buf+=$'\n'
    mapbuf+=$'\n'
  }
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
          if [[ ${#_pl} -gt $W ]]; then _pl="${_pl:0:$((W - 1))}…"; fi
          buf+="${GR}${_pl}${R}"$'\n'
          mapbuf+=$'\n'
        done <<<"$_preview_lines"
      fi
    fi
  fi

  buf+=" ${CY}⠿${R} ${_wc}  ${GR}○${R} $((_ic_raw - _uc))  ${YL}◉${R} ${_uc}  ${GR}·${R} ${_ec}"$'\n'
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

  printf '%s' "$mapbuf" >"${STATE_DIR}/rowmap.tmp"
  mv "${STATE_DIR}/rowmap.tmp" "${STATE_DIR}/rowmap"
  _diff_print "$buf" "$W" "$H" "main"
}
