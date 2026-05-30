# shellcheck shell=bash
# render.sh — sidebar rendering (render, render_help, file_mtime)
# Sourced by sidebar.sh. Assumes all sidebar globals are already set.
# No shebang — not executed directly.

file_mtime() { stat -f '%m' "$1" 2>/dev/null || stat -c '%Y' "$1" 2>/dev/null || echo 0; }

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

  # ── Pre-leer DATA_FILE en arrays asociativos (bash 4) ────────────────────
  _win_keys=()
  _srv_cur=()
  _sess_act=()
  _win_meta=()
  while IFS='|' read -r _t _f1 _f2 _f3 _f4 _f5 _f6 _f7; do
    case "$_t" in
      S) _srv_cur["$_f1"]="$_f2" ;;
      E) _sess_act["${_f1}|${_f2}"]="$_f3" ;;
      W) _win_keys+=("${_f1}|${_f2}|${_f3}")
         _win_meta["${_f1}|${_f2}|${_f3}"]="${_f4}|${_f5}|${_f6}|${_f7}" ;;
    esac
  done < "$DATA_FILE"
  _RENDER_DATA_MTIME="$_df_mtime"

  # ── Construir ITEMS_FLAT en orden del usuario ─────────────────────────
  # Preservar orden de ventanas ya en ITEMS_FLAT si el conteo no cambió
  # (evita revertir orden tras un swap-window antes de que el daemon actualice DATA_FILE)
  local _old_items=("${ITEMS_FLAT[@]}")
  ITEMS_FLAT=()
  local _entry _srv _sess _k
  for _entry in "${SESSIONS_FLAT[@]}"; do
    _srv="${_entry%%|*}"; _sess="${_entry#*|}"
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
  local _wc=0 _uc=0 _ic_raw=0 _ec=0 _pc=0 _lc=0 _xc=0
  local _wk2
  for _wk2 in "${_win_keys[@]}"; do
    local _wmeta2="${_win_meta[$_wk2]:-}"
    local _wi2="${_wmeta2#*|}"  # skip name field
    _wi2="${_wi2%%|*}"          # extract icon field
    case "$_wi2" in
      "W") (( _wc++ )); _HAS_WORKING=1 ;;
      "I") (( _ic_raw++ )) ;;
      "E") (( _ec++ )) ;;
      "P") (( _pc++ )) ;;
      "L") (( _lc++ )); _HAS_WORKING=1 ;;
      "X") (( _xc++ )) ;;
    esac
    if [[ "$_wi2" != "E" ]]; then
      local _uk2="${_wk2//[^a-zA-Z0-9_-]/_}"
      _uk2="${_uk2//|/_}"
      [[ -f "${STATE_DIR}/${_uk2}.unread" ]] && (( _uc++ ))
    fi
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
          local _fss2="${_fwr2%%|*}" _fwid2="${_fwr2#*|}"
          local _fmeta2="${_win_meta["${_fsrv2}|${_fss2}|${_fwid2}"]:-}"
          local _wn2="${_fmeta2%%|*}"
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
    local _fk
    for _fk in "${_win_keys[@]}"; do
      local _fmeta="${_win_meta[$_fk]:-}"
      local _fk_srv="${_fk%%|*}" _fk_rest="${_fk#*|}"
      local _fk_sess="${_fk_rest%%|*}" _fk_widx="${_fk_rest#*|}"
      # icon is second field of meta: name|icon|agent|last
      local _fk_icon; _fk_icon=$(printf '%s' "$_fmeta" | cut -d'|' -f2)
      local _fmatch=0
      case "$_FILTER_STATUS" in
        working) [[ "$_fk_icon" == "W" || "$_fk_icon" == "L" ]] && _fmatch=1 ;;
        idle)
          local _fkey2="${_fk//[^a-zA-Z0-9_-|]/_}"; _fkey2="${_fkey2//|/_}"
          [[ "$_fk_icon" != "E" && "$_fk_icon" != "W" && "$_fk_icon" != "L" && ! -f "${STATE_DIR}/${_fkey2}.unread" ]] && _fmatch=1 ;;
        unread)
          local _fkey2="${_fk//[^a-zA-Z0-9_-|]/_}"; _fkey2="${_fkey2//|/_}"
          [[ -f "${STATE_DIR}/${_fkey2}.unread" ]] && _fmatch=1 ;;
      esac
      [[ "$_fmatch" == "1" ]] && _filt_skeys+=" ${_fk_srv}|${_fk_sess}"
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
          local _is_cur="${_srv_cur[$_srv]:-0}"
          local _sic="$GR"; [[ "$_is_cur" == "1" ]] && _sic="$CY"
          local _srvd="${_srv:0:$max}"; [[ ${#_srv} -gt $max ]] && _srvd="${_srv:0:$(( max-1 ))}…"
          local _fill_len=$(( W - 4 - ${#_srvd} ))
          local _fill=""
          [[ $_fill_len -gt 0 ]] && _fill=$(printf '─%.0s' $(seq 1 $_fill_len))
          buf+="${_sic}── ${_srvd} ${_fill}${R}"$'\n'; mapbuf+=$'\n'
        fi
        prev_server="$_srv"
      fi

      # ▶ indica la sesión que el cliente está viendo
      local _is_act=0
      if [[ "$_srv" == "$OUTER_SERVER" ]]; then
        [[ "$_sess" == "$_cur_sess" ]] && _is_act=1
      else
        _is_act="${_sess_act["${_srv}|${_sess}"]:-0}"
      fi

      local _cursor=" " _ic="$GR" _nc=""
      [[ $_ii -eq $SELECTED && -z "$_CMD_BUF" ]] && { _cursor="›"; _ic="$YL"; }
      if [[ "$_is_act" == "1" ]]; then
        _cursor="▶"; _nc="$BG"
        [[ $_ii -eq $SELECTED ]] && _ic="$YL" || _ic="$BG"
      fi
      [[ -n "$_cursor_parent_item" && "$_item" == "$_cursor_parent_item" ]] && _nc="$WH"
      [[ -n "$_KILL_PENDING" && "$_item" == "$_KILL_PENDING" ]] && { _ic="$RD"; _nc="$RD"; _cursor="✕"; }
      local _sessd="${_sess:0:$max}"; [[ ${#_sess} -gt $max ]] && _sessd="${_sess:0:$(( max-1 ))}…"
      if [[ "$_drill_mode" == "1" ]]; then
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

      # Lookup O(1) via array asociativo
      local _wmeta="${_win_meta["${_srv}|${_sess}|${_widx}"]:-}"
      local _wname _wicon _wagent _islast
      IFS='|' read -r _wname _wicon _wagent _islast <<< "$_wmeta"
      [[ -z "$_wicon" ]] && _wicon="E"
      [[ -z "$_islast" ]] && _islast="1"

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
        [[ "$_pi" == "W" && ( "$_state" == "idle" || "$_state" == "blocked" || "$_state" == "loop" ) ]] && touch "$_flag_f"
        [[ "$_state" == "working" ]] && rm -f "$_flag_f"
        printf '%s' "$_wicon" > "$_prev_f"
        [[ -f "$_flag_f" && "$_state" != "working" ]] && _state="unread"
      fi

      # Seleccionar icono y colores según estado
      local _display_icon _icon_col _name_col
      case "$_state" in
        empty)   _display_icon="·";                          _icon_col="$GR"; _name_col="$GR" ;;
        idle)    _display_icon="○";                          _icon_col="$GR"; _name_col="$GR" ;;
        working) _display_icon="${_SPINNER[$_SPIN_FRAME]}";  _icon_col="$CY"; _name_col="$CY" ;;
        blocked) _display_icon="?";                          _icon_col="$RD"; _name_col="$RD" ;;
        loop)    _display_icon="↺";                          _icon_col="$YL"; _name_col="$YL" ;;
        crashed) _display_icon="✗";                          _icon_col="$RD"; _name_col="$GR" ;;
        unread)  _display_icon="◉";                          _icon_col="$YL"; _name_col="$YL" ;;
      esac
      local _agent_badge=""
      [[ -n "$_wagent" ]] && _agent_badge="[${_wagent}] "

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

      local _maxn=$(( max - 3 - ${#_agent_badge} )) _wdisp
      [[ $_maxn -lt 4 ]] && _maxn=4
      if [[ ${#_wname} -gt $_maxn ]]; then
        _wdisp="${_wname:0:$(( _maxn - 1 ))}…"
      else
        _wdisp="${_wname:0:$_maxn}"
      fi

      local _badge_col="${PU}"
      if [[ -n "$_KILL_PENDING" && "$_item" == "$_KILL_PENDING" ]]; then
        buf+="${_wpfx}${RD}${_br}${R} ${RD}✕${R} ${RD}${_agent_badge}${_wdisp}${R}"$'\n'
      elif [[ "$_srv" == "$OUTER_SERVER" && "$_sess" == "$_outer_sess" && "$_widx" == "$_outer_win" ]]; then
        local _active_icon_col="$G"
        [[ "$_state" == "working" ]] && _active_icon_col="$CY"
        buf+="${_wpfx}${G}${_br}${R} ${_active_icon_col}${_display_icon}${R} ${_badge_col}${_agent_badge}${R}${G}${_wdisp}${R}"$'\n'
      else
        buf+="${_wpfx}${GR}${_br}${R} ${_icon_col}${_display_icon}${R} ${_badge_col}${_agent_badge}${R}${_name_col}${_wdisp}${R}"$'\n'
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
