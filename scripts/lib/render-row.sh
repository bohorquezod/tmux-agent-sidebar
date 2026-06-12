# shellcheck shell=bash
# shellcheck disable=SC2154  # globals set by render() in render.sh before each call
# render-row.sh — per-row render helpers (session and window rows)
# Sourced by sidebar.sh. No shebang — not executed directly.
# Requires: render-icons.sh sourced first, all sidebar globals.
# Appends to the global buf and mapbuf set by render() each cycle.

# render_session_row <item> <srv> <sess>
# Appends one session row (plus server header when the server changes) to buf/mapbuf.
# Reads globals: buf mapbuf prev_server W max _sess_num _ii SELECTED _CMD_BUF
#   _cursor_parent_item _KILL_PENDING OUTER_SERVER _cur_sess _sess_act _srv_cur
#   _last_sess _drill_mode R GR YL WH BG RD CY
render_session_row() {
  local _rsr_item="$1" _rsr_srv="$2" _rsr_sess="$3"

  # Server header when the active server changes (normal mode only)
  if [[ "$_rsr_srv" != "$prev_server" ]]; then
    if [[ "$_drill_mode" == "0" ]]; then
      [[ -n "$prev_server" ]] && {
        buf+=$'\n'
        mapbuf+=$'\n'
      }
      local _sic="$GR"
      [[ "$_rsr_srv" == "$OUTER_SERVER" ]] && _sic="$CY"
      local _srvd="${_rsr_srv:0:$max}"
      [[ ${#_rsr_srv} -gt $max ]] && _srvd="${_rsr_srv:0:$((max - 1))}…"
      local _fill_len=$((W - 4 - ${#_srvd}))
      local _fill=""
      [[ $_fill_len -gt 0 ]] && _fill=$(printf '─%.0s' $(seq 1 $_fill_len))
      buf+="${_sic}── ${_srvd} ${_fill}${R}"$'\n'
      mapbuf+=$'\n'
    fi
    prev_server="$_rsr_srv"
  fi

  # Active indicator:
  #   ▶ bright green = you are HERE (current server, current session)
  #   ▶ gray        = you were here last (other server, remembered via click)
  local _is_act=0  # 1 = current server
  local _is_prev=0 # 1 = other server, last-visited session
  if [[ "$_rsr_srv" == "$OUTER_SERVER" ]]; then
    [[ "$_rsr_sess" == "$_cur_sess" ]] && _is_act=1
  else
    local _lk="${_rsr_srv//[^a-zA-Z0-9_-]/_}"
    local _last="${_last_sess[$_lk]:-}"
    [[ -n "$_last" && "$_rsr_sess" == "$_last" ]] && _is_prev=1
  fi

  local _cursor=" " _ic="$GR" _nc=""
  [[ $_ii -eq $SELECTED && -z "$_CMD_BUF" ]] && {
    _cursor="›"
    _ic="$YL"
  }
  if [[ "$_is_act" == "1" ]]; then
    _cursor="▶"
    _nc="$BG"
    [[ $_ii -eq $SELECTED ]] && _ic="$YL" || _ic="$BG"
  elif [[ "$_is_prev" == "1" ]]; then
    _cursor="▶"
    _nc="$GR"
    [[ $_ii -eq $SELECTED ]] && _ic="$YL" || _ic="$GR"
  fi
  [[ -n "$_cursor_parent_item" && "$_rsr_item" == "$_cursor_parent_item" ]] && _nc="$WH"
  [[ -n "$_KILL_PENDING" && "$_rsr_item" == "$_KILL_PENDING" ]] && {
    _ic="$RD"
    _nc="$RD"
    _cursor="✕"
  }

  local _sessd="${_rsr_sess:0:$max}"
  [[ ${#_rsr_sess} -gt $max ]] && _sessd="${_rsr_sess:0:$((max - 1))}…"

  if [[ "$_drill_mode" == "1" ]]; then
    buf+="${_ic}${_cursor} ${R}  ${_nc}${_sessd}${R}"$'\n'
  else
    buf+="${_ic}${_cursor} ${_sess_num}${R}  ${_nc}${_sessd}${R}"$'\n'
  fi
  mapbuf+="${_rsr_srv}|${_rsr_sess}"$'\n'
}

# render_window_row <item> <srv> <sess> <widx>
# Appends one window row to buf/mapbuf. Also manages unread state files.
# Reads globals: buf mapbuf _win_meta W max _ii SELECTED _CMD_BUF _KILL_PENDING
#   OUTER_SERVER _outer_sess _outer_win STATE_DIR _SPIN_FRAME _HAS_WORKING
#   _drill_mode _drill_wnum _win_ord R G GR YL WH RD CY PU
render_window_row() {
  local _rwr_item="$1" _rwr_srv="$2" _rwr_sess="$3" _rwr_widx="$4"

  local _wmeta="${_win_meta["${_rwr_srv}|${_rwr_sess}|${_rwr_widx}"]:-}"
  local _wname _wicon _wagent _islast _ptitle
  IFS='|' read -r _wname _wicon _wagent _islast _ptitle <<<"$_wmeta"
  [[ -z "$_wicon" ]] && _wicon="$STATE_EMPTY"
  # Recompute is_last from ITEMS_FLAT so alpha sort and manual reorder stay correct
  _islast="1"
  local _peek _pitm _ptyp _pr _psrv _pr2 _psess _pwid _visible _pm _pic _pfk
  _peek=$((_ii + 1))
  while [[ $_peek -lt ${#ITEMS_FLAT[@]} ]]; do
    _pitm="${ITEMS_FLAT[$_peek]}"
    _ptyp="${_pitm%%|*}"
    [[ "$_ptyp" == "S" ]] && break
    if [[ "$_ptyp" == "W" ]]; then
      _pr="${_pitm#*|}"
      _psrv="${_pr%%|*}"
      _pr2="${_pr#*|}"
      _psess="${_pr2%%|*}"
      _pwid="${_pr2#*|}"
      if [[ "$_psrv" == "$_rwr_srv" && "$_psess" == "$_rwr_sess" ]]; then
        _visible=1
        if [[ -n "${_FILTER_STATUS:-}" ]]; then
          _visible=0
          _pm="${_win_meta["${_psrv}|${_psess}|${_pwid}"]:-}"
          _pic="${_pm#*|}"
          _pic="${_pic%%|*}"
          _pfk="${_psrv//[^a-zA-Z0-9_-]/_}_${_psess//[^a-zA-Z0-9_-]/_}_${_pwid}"
          case "$_FILTER_STATUS" in
            working) [[ "$_pic" == "$STATE_WORKING" || "$_pic" == "$STATE_LOOP" ]] && _visible=1 ;;
            idle) [[ "$_pic" != "$STATE_EMPTY" && "$_pic" != "$STATE_WORKING" && "$_pic" != "$STATE_LOOP" && ! -f "${STATE_DIR}/${_pfk}.unread" ]] && _visible=1 ;;
            unread) [[ -f "${STATE_DIR}/${_pfk}.unread" ]] && _visible=1 ;;
          esac
        fi
        [[ "$_visible" == "1" ]] && {
          _islast="0"
          break
        }
      fi
    fi
    ((_peek++)) || true
  done

  # ── State computation ────────────────────────────────────────────────────────
  local _key="${_rwr_srv//[^a-zA-Z0-9_-]/_}_${_rwr_sess//[^a-zA-Z0-9_-]/_}_${_rwr_widx}"
  local _flag_f="${STATE_DIR}/${_key}.unread" _prev_f="${STATE_DIR}/${_key}.prev_icon"

  local _state
  case "$_wicon" in
    "$STATE_WORKING")
      _state="$STATE_WORKING"
      _HAS_WORKING=1
      ;;
    "$STATE_LOOP")
      _state="$STATE_LOOP"
      _HAS_WORKING=1
      ;;
    "$STATE_EMPTY" | "$STATE_BLOCKED" | "$STATE_CRASHED" | "$STATE_IDLE")
      _state="$_wicon"
      ;;
    *) _state="$STATE_IDLE" ;;
  esac

  if [[ "$_state" == "empty" ]]; then
    rm -f "$_flag_f" "$_prev_f"
  elif [[ "$_rwr_srv" == "$OUTER_SERVER" && "$_rwr_sess" == "$_outer_sess" && "$_rwr_widx" == "$_outer_win" ]]; then
    rm -f "$_flag_f"
    printf '💤' >"$_prev_f"
  else
    local _pi=""
    [[ -f "$_prev_f" ]] && _pi=$(<"$_prev_f")
    [[ "$_pi" == "$STATE_WORKING" && ("$_state" == "$STATE_IDLE" || "$_state" == "$STATE_BLOCKED" || "$_state" == "$STATE_LOOP") ]] && touch "$_flag_f"
    [[ "$_state" == "$STATE_WORKING" ]] && rm -f "$_flag_f"
    printf '%s' "$_wicon" >"$_prev_f"
    [[ -f "$_flag_f" && "$_state" != "working" ]] && _state="unread"
  fi

  # ── Icon and color ───────────────────────────────────────────────────────────
  local _display_icon _icon_col _name_col
  _display_icon=$(icon_to_char "$_state" "$_SPIN_FRAME")
  icon_to_color "$_state"

  local _agent_badge=""
  [[ -n "$_wagent" ]] && _agent_badge="[${_wagent}] "

  local _br='└─'
  [[ "$_islast" != "1" ]] && _br='├─'
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
    _wpfx="  "
    [[ $_ii -eq $SELECTED && -z "$_CMD_BUF" ]] && _wpfx=" ${YL}▸${R}"
  fi

  local _maxn=$((max - 3 - ${#_agent_badge})) _wdisp
  [[ $_maxn -lt 4 ]] && _maxn=4
  if [[ ${#_wname} -gt $_maxn ]]; then
    _wdisp="${_wname:0:$((_maxn - 1))}…"
  else
    _wdisp="${_wname:0:$_maxn}"
  fi

  local _badge_col="${PU}"
  if [[ -n "$_KILL_PENDING" && "$_rwr_item" == "$_KILL_PENDING" ]]; then
    buf+="${_wpfx}${RD}${_br}${R} ${RD}✕${R} ${RD}${_agent_badge}${_wdisp}${R}"$'\n'
  elif [[ "$_rwr_srv" == "$OUTER_SERVER" && "$_rwr_sess" == "$_outer_sess" && "$_rwr_widx" == "$_outer_win" ]]; then
    local _active_icon_col="$G"
    [[ "$_state" == "working" ]] && _active_icon_col="$CY"
    buf+="${_wpfx}${G}${_br}${R} ${_active_icon_col}${_display_icon}${R} ${_badge_col}${_agent_badge}${R}${G}${_wdisp}${R}"$'\n'
  else
    buf+="${_wpfx}${GR}${_br}${R} ${_icon_col}${_display_icon}${R} ${_badge_col}${_agent_badge}${R}${_name_col}${_wdisp}${R}"$'\n'
  fi
  mapbuf+="${_rwr_srv}|${_rwr_sess}|${_rwr_widx}"$'\n'
}
