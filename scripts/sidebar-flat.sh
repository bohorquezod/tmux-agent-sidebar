#!/bin/bash
# sidebar-flat.sh — PROTOTYPE: sidebar as a plain pane in the outer tmux server
#
# This is a research prototype for issue #17. It demonstrates the flat-pane approach
# and its trade-offs. It is NOT the production implementation.
#
# Key differences from sidebar.sh:
#   - No nested server: runs inside the outer tmux server directly
#   - No OUTER_TMUX_SOCKET: OUTER_TMUX == $TMUXBIN (same server)
#   - Per-pane option overrides to reduce config interference (tmux >= 3.1)
#   - Cursor state written to ${STATE_DIR}/cursor and read by peer instances
#
# Known regressions vs the nested server:
#   - User's key bindings may conflict (Enter, prefix, etc.)
#   - Status bar plugins see this pane and may misbehave
#   - Cursor sync between windows has ~300ms latency (next render cycle)
#   - hooks (client-session-changed, etc.) fire in the outer server context

PLUGIN_DIR="${PLUGIN_DIR:-$(cd -P "$(dirname "$0")/.." && pwd)}"
TMUXBIN="$(command -v tmux 2>/dev/null)"; [[ -z "$TMUXBIN" ]] && TMUXBIN="tmux"
STATE_DIR="${STATE_DIR:-${TMPDIR:-/tmp}/agent-sidebar}"
DATA_FILE="${STATE_DIR}/data"
DIRTY_FILE="${STATE_DIR}/dirty"
CLIENTS_DIR="${STATE_DIR}/clients"
ORDER_FILE="${HOME}/.tmux-sidebar-order"
CURSOR_FILE="${STATE_DIR}/cursor"

mkdir -p "$STATE_DIR" "$CLIENTS_DIR"

PANE_ID="$TMUX_PANE"

# Flat pane: OUTER_TMUX is the same server — no socket indirection needed
OUTER_TMUX=("$TMUXBIN")
OUTER_SERVER="${TMUX%%,*}"; OUTER_SERVER="${OUTER_SERVER##*/}"

WIN_SESS=$($TMUXBIN display-message -t "$PANE_ID" -p '#{session_name}' 2>/dev/null)
WIN_IDX=$($TMUXBIN display-message -t "$PANE_ID" -p '#{window_index}' 2>/dev/null)

STATE_KEY="${WIN_SESS//[^a-zA-Z0-9]/_}_${WIN_IDX}"
STATE_FILE="${STATE_DIR}/sidebar_${STATE_KEY}"
CLIENT_KEY="$PANE_ID"

# Per-pane isolation: disable prefix and mouse (tmux >= 3.1 required).
# This does NOT suppress plugins, hooks, or server-level settings.
$TMUXBIN set-option -p -t "$PANE_ID" prefix None 2>/dev/null
$TMUXBIN set-option -p -t "$PANE_ID" mouse off  2>/dev/null

# Label pane "Sessions" so toggle.sh can find it by title
$TMUXBIN select-pane -t "$PANE_ID" -T "Sessions" 2>/dev/null

stty -echo onlcr 2>/dev/null

printf '%d' "$$" > "$CLIENTS_DIR/$CLIENT_KEY"
printf '%s'  "$PANE_ID" > "$STATE_FILE"

_RELOADING=0
_ANIMATOR_PID=0
_sidebar_cleanup() {
  kill "$_ANIMATOR_PID" 2>/dev/null
  rm -f "$CLIENTS_DIR/$CLIENT_KEY" "$STATE_FILE" "${STATE_DIR}/animator_active"
  $TMUXBIN select-pane -t "$PANE_ID" -T "" 2>/dev/null
  # Restore per-pane options
  $TMUXBIN set-option -p -u -t "$PANE_ID" prefix 2>/dev/null
  $TMUXBIN set-option -p -u -t "$PANE_ID" mouse  2>/dev/null
}
trap '_sidebar_cleanup' EXIT INT TERM
trap '_RELOADING=1; kill "$_ANIMATOR_PID" 2>/dev/null; exec "$0"' USR1
_WAKE=0
trap '_WAKE=1' USR2

_start_animator() {
  local _sd="$STATE_DIR" _tb="$TMUXBIN" _pid="$PANE_ID"
  while true; do
    sleep 0.2
    [[ -f "${_sd}/animator_active" ]] && "$_tb" send-keys -t "$_pid" $'\x1e' 2>/dev/null
  done
}
_start_animator &
_ANIMATOR_PID=$!

_dpid_file="${STATE_DIR}/daemon.pid"
if [[ ! -f "$_dpid_file" ]] || ! kill -0 "$(<"$_dpid_file")" 2>/dev/null; then
  nohup bash "$PLUGIN_DIR/scripts/daemon.sh" >/dev/null 2>&1 &
  disown $! 2>/dev/null
  _i=0
  while [[ ! -f "$DATA_FILE" && $_i -lt 20 ]]; do sleep 0.1; (( _i++ )); done
fi

R=$'\033[0m';  G=$'\033[32m';  BG=$'\033[1;32m'
PU=$'\033[1;35m'; GR=$'\033[90m'; RD=$'\033[31m'; YL=$'\033[1;33m'; CY=$'\033[1;36m'; WH=$'\033[1;37m'

_SPIN_FRAME=0
_SPINNER=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
_HAS_WORKING=0
_CMD_BUF=""

SESSIONS_FLAT=()
ITEMS_FLAT=()
SELECTED=0
CURSOR_ITEM=""
_INITIAL_SELECT=1

file_mtime() { stat -f '%m' "$1" 2>/dev/null || stat -c '%Y' "$1" 2>/dev/null || echo 0; }

# ── Cursor sync (flat pane specific) ────────────────────────────────────────
# Write cursor to shared file so peer sidebar instances stay in sync.
_write_cursor() {
  printf '%d' "$SELECTED" > "$CURSOR_FILE"
}

# Read cursor from shared file — only apply if this instance didn't write it
# (avoids overwriting a mid-keypress cursor with a stale peer value).
_read_cursor() {
  [[ ! -f "$CURSOR_FILE" ]] && return
  local _c; _c=$(<"$CURSOR_FILE") 2>/dev/null
  [[ "$_c" =~ ^[0-9]+$ ]] && SELECTED="$_c"
}

jump_to() {
  local _srv _rest _sess _win _t
  _srv="${1%%|*}"; _rest="${1#*|}"
  _sess="${_rest%%|*}"; _win="${_rest#*|}"
  [[ "$_win" == "$_sess" ]] && _win=""
  _t="$_sess"; [[ -n "$_win" ]] && _t="${_sess}:${_win}"
  # Flat pane: always the same server
  "${OUTER_TMUX[@]}" switch-client -t "$_t" 2>/dev/null
}

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

move_window_up() {
  local _idx=$1
  local _item="${ITEMS_FLAT[$_idx]}"
  local _prev="${ITEMS_FLAT[$(( _idx - 1 ))]}"
  [[ $_idx -le 0 || "${_prev%%|*}" != "W" ]] && return
  local _crest="${_item#*|}"; local _csrv="${_crest%%|*}"
  local _cr2="${_crest#*|}"; local _csess="${_cr2%%|*}"; local _cwin="${_cr2#*|}"
  local _prest="${_prev#*|}"; local _pr2="${_prest#*|}"
  local _psess="${_pr2%%|*}"; local _pwin="${_pr2#*|}"
  "${OUTER_TMUX[@]}" swap-window -s "${_csess}:${_cwin}" -t "${_psess}:${_pwin}" 2>/dev/null
  ITEMS_FLAT[$(( _idx - 1 ))]="$_item"; ITEMS_FLAT[$_idx]="$_prev"
  SELECTED=$(( _idx - 1 )); touch "$DIRTY_FILE"
}

move_window_down() {
  local _idx=$1
  local _item="${ITEMS_FLAT[$_idx]}"
  local _last=$(( ${#ITEMS_FLAT[@]} - 1 ))
  local _next="${ITEMS_FLAT[$(( _idx + 1 ))]}"
  [[ $_idx -ge $_last || "${_next%%|*}" != "W" ]] && return
  local _crest="${_item#*|}"; local _csrv="${_crest%%|*}"
  local _cr2="${_crest#*|}"; local _csess="${_cr2%%|*}"; local _cwin="${_cr2#*|}"
  local _nrest="${_next#*|}"; local _nr2="${_nrest#*|}"
  local _nsess="${_nr2%%|*}"; local _nwin="${_nr2#*|}"
  "${OUTER_TMUX[@]}" swap-window -s "${_csess}:${_cwin}" -t "${_nsess}:${_nwin}" 2>/dev/null
  ITEMS_FLAT[$_idx]="$_next"; ITEMS_FLAT[$(( _idx + 1 ))]="$_item"
  SELECTED=$(( _idx + 1 )); touch "$DIRTY_FILE"
}

# ── Ensure sidebar pane in destination window (flat version) ─────────────────
# Flat approach: no server spawn. Just check for a live pane with title "Sessions".
# If none exists, open a new split running sidebar-flat.sh.
_ensure_sidebar() {
  local _dest="$1"
  local _sw; _sw=$(cat "${STATE_DIR}/sidebar_width" 2>/dev/null)
  [[ -z "$_sw" || ! "$_sw" =~ ^[0-9]+$ ]] && _sw=28

  local _live; _live=$("${OUTER_TMUX[@]}" list-panes -t "$_dest" \
    -F '#{pane_dead}|#{pane_id}|#{pane_title}' 2>/dev/null \
    | awk -F'|' '$1!="1" && $3=="Sessions"{print $2; exit}')
  if [[ -n "$_live" ]]; then
    "${OUTER_TMUX[@]}" select-pane -t "$_live" 2>/dev/null
    return
  fi

  local _lp; _lp=$("${OUTER_TMUX[@]}" list-panes -t "$_dest" \
    -F '#{pane_left}|#{pane_id}' 2>/dev/null \
    | sort -t'|' -k1 -n | head -1 | cut -d'|' -f2)
  local _tgt="${_dest}"; [[ -n "$_lp" ]] && _tgt="$_lp"
  "${OUTER_TMUX[@]}" split-window -hb -l "$_sw" -t "$_tgt" \
    "exec bash $PLUGIN_DIR/scripts/sidebar-flat.sh" 2>/dev/null
}

render() {
  [[ ! -f "$DATA_FILE" ]] && return

  (( _SPIN_FRAME = (_SPIN_FRAME + 1) % 10 ))

  # Sync cursor from peer instances (flat pane trade-off)
  _read_cursor

  if [[ -f "${STATE_DIR}/just_visited" ]]; then
    local _jv; _jv=$(<"${STATE_DIR}/just_visited"); rm -f "${STATE_DIR}/just_visited"
    local _jvk="${_jv//[^a-zA-Z0-9_-]/_}"
    rm -f "${STATE_DIR}/${_jvk}.unread"
    printf '💤' > "${STATE_DIR}/${_jvk}.prev_icon"
  fi

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
  local _sw; _sw=$(cat "${STATE_DIR}/sidebar_width" 2>/dev/null)
  [[ "$W" != "$_sw" ]] && printf '%s' "$W" > "${STATE_DIR}/sidebar_width"
  local max=$(( W - 6 )); [[ $max -lt 6 ]] && max=6
  local sep; sep=$(printf '─%.0s' $(seq 1 $W))

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

  local _old_items=("${ITEMS_FLAT[@]}")
  ITEMS_FLAT=()
  local _entry _srv _sess _k
  for _entry in "${SESSIONS_FLAT[@]}"; do
    _srv="${_entry%%|*}"; _sess="${_entry#*|}"
    ITEMS_FLAT+=("S|${_srv}|${_sess}")
    local _data_wins=()
    _k=0
    for _ws in "${_W_srv[@]}"; do
      [[ "$_ws" == "$_srv" && "${_W_sess[$_k]}" == "$_sess" ]] && \
        _data_wins+=("${_W_widx[$_k]}")
      (( _k++ ))
    done
    [[ ${#_data_wins[@]} -eq 0 ]] && continue
    local _old_wins=()
    local _oi _or _osrv _or2 _osess _owid
    for _oi in "${_old_items[@]}"; do
      [[ "${_oi%%|*}" != "W" ]] && continue
      _or="${_oi#*|}"; _osrv="${_or%%|*}"; _or2="${_or#*|}"
      _osess="${_or2%%|*}"; _owid="${_or2#*|}"
      [[ "$_osrv" == "$_srv" && "$_osess" == "$_sess" ]] && _old_wins+=("$_owid")
    done
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
    for _wid in "${_wins[@]}"; do ITEMS_FLAT+=("W|${_srv}|${_sess}|${_wid}"); done
  done

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

  local _wc=0 _uc=0 _ic_raw=0 _ec=0 _k2=0
  for _wi2 in "${_W_icon[@]}"; do
    case "$_wi2" in "⚡") (( _wc++ )) ;; "⏸") (( _ic_raw++ )) ;; "·") (( _ec++ )) ;; esac
    if [[ "$_wi2" != "·" ]]; then
      local _uk2="${_W_srv[$_k2]//[^a-zA-Z0-9_-]/_}_${_W_sess[$_k2]//[^a-zA-Z0-9_-]/_}_${_W_widx[$_k2]}"
      [[ -f "${STATE_DIR}/${_uk2}.unread" ]] && (( _uc++ ))
    fi
    (( _k2++ ))
  done

  local _cursor_parent_item=""
  if [[ "${ITEMS_FLAT[$SELECTED]%%|*}" == "W" ]]; then
    local _cpi=$SELECTED
    while (( _cpi > 0 )); do
      (( _cpi-- ))
      if [[ "${ITEMS_FLAT[$_cpi]%%|*}" == "S" ]]; then _cursor_parent_item="${ITEMS_FLAT[$_cpi]}"; break; fi
    done
  fi

  local buf="" mapbuf="" prev_server="" _sess_num=0 _ii=0

  if [[ -n "$_CMD_BUF" ]]; then
    buf+="${PU} ◈${R}  ${YL}${_CMD_BUF}${GR}▌${R}"$'\n'
  else
    buf+="${PU} ◈${R}  Claude${GR}[flat]${R}"$'\n'
  fi
  mapbuf+=$'\n'
  buf+="${GR}${sep}${R}"$'\n'; mapbuf+=$'\n'

  for _item in "${ITEMS_FLAT[@]}"; do
    local _itype="${_item%%|*}" _irest="${_item#*|}"

    if [[ "$_itype" == "S" ]]; then
      local _srv="${_irest%%|*}" _sess="${_irest#*|}"
      (( _sess_num++ ))

      if [[ "$_srv" != "$prev_server" ]]; then
        [[ -n "$prev_server" ]] && { buf+=$'\n'; mapbuf+=$'\n'; }
        local _is_cur=0; _k=0
        for _sn in "${_S_srv[@]}"; do
          [[ "$_sn" == "$_srv" ]] && { _is_cur="${_S_cur[$_k]}"; break; }; (( _k++ ))
        done
        local _sic="$GR"; [[ "$_is_cur" == "1" ]] && _sic="$CY"
        local _srvd="${_srv:0:$max}"; [[ ${#_srv} -gt $max ]] && _srvd="${_srv:0:$(( max-1 ))}…"
        buf+="${_sic}◎ ${_srvd}${R}"$'\n'; mapbuf+=$'\n'
        prev_server="$_srv"
      fi

      local _is_act=0
      _k=0
      for _en in "${_E_srv[@]}"; do
        [[ "$_en" == "$_srv" && "${_E_sess[$_k]}" == "$_sess" ]] && { _is_act="${_E_act[$_k]}"; break; }
        (( _k++ ))
      done

      local _cursor=" " _ic="$GR" _nc=""
      [[ $_ii -eq $SELECTED ]] && { _cursor="›"; _ic="$YL"; }
      if [[ "$_is_act" == "1" ]]; then
        _cursor="▶"; _nc="$BG"
        [[ $_ii -eq $SELECTED ]] && _ic="$YL" || _ic="$BG"
      fi
      [[ -n "$_cursor_parent_item" && "$_item" == "$_cursor_parent_item" ]] && _nc="$WH"
      local _sessd="${_sess:0:$max}"; [[ ${#_sess} -gt $max ]] && _sessd="${_sess:0:$(( max-1 ))}…"
      buf+="${_ic}${_cursor} ${_sess_num}${R}  ${_nc}${_sessd}${R}"$'\n'
      mapbuf+="${_srv}|${_sess}"$'\n'

    elif [[ "$_itype" == "W" ]]; then
      local _srv="${_irest%%|*}" _wrest="${_irest#*|}"
      local _sess="${_wrest%%|*}" _widx="${_wrest#*|}"

      local _wname="" _wicon="·" _islast="1"; _k=0
      for _ws in "${_W_srv[@]}"; do
        if [[ "$_ws" == "$_srv" && "${_W_sess[$_k]}" == "$_sess" && "${_W_widx[$_k]}" == "$_widx" ]]; then
          _wname="${_W_name[$_k]}"; _wicon="${_W_icon[$_k]}"; _islast="${_W_last[$_k]}"; break
        fi
        (( _k++ ))
      done

      local _key="${_srv//[^a-zA-Z0-9_-]/_}_${_sess//[^a-zA-Z0-9_-]/_}_${_widx}"
      local _flag_f="${STATE_DIR}/${_key}.unread" _prev_f="${STATE_DIR}/${_key}.prev_icon"
      local _state
      case "$_wicon" in "·") _state="empty" ;; "⚡") _state="working"; _HAS_WORKING=1 ;; *) _state="idle" ;; esac

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

      local _display_icon _icon_col _name_col
      case "$_state" in
        empty)   _display_icon="·";                         _icon_col="$GR"; _name_col="$GR" ;;
        idle)    _display_icon="○";                         _icon_col="$GR"; _name_col="$GR" ;;
        working) _display_icon="${_SPINNER[$_SPIN_FRAME]}"; _icon_col="$CY"; _name_col="$CY" ;;
        unread)  _display_icon="◉";                         _icon_col="$YL"; _name_col="$YL" ;;
      esac

      local _br='└─'; [[ "$_islast" != "1" ]] && _br='├─'
      local _wpfx
      _wpfx="  "; [[ $_ii -eq $SELECTED && -z "$_CMD_BUF" ]] && _wpfx=" ${YL}▸${R}"
      local _maxn=$(( max-3 )) _wdisp
      if [[ ${#_wname} -gt $_maxn ]]; then _wdisp="${_wname:0:$(( _maxn - 1 ))}…"
      else _wdisp="${_wname:0:$_maxn}"; fi

      if [[ "$_srv" == "$OUTER_SERVER" && "$_sess" == "$_outer_sess" && "$_widx" == "$_outer_win" ]]; then
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
  buf+="${GR} [jk]nav [JK]mv [↵]go${R}"$'\n'
  buf+="${GR} [hl]mode [r]↺ [q]✕${R}"$'\n'
  mapbuf+=$'\n\n\n'

  printf '%s' "$mapbuf" > "${STATE_DIR}/rowmap.tmp"
  mv "${STATE_DIR}/rowmap.tmp" "${STATE_DIR}/rowmap"
  printf '\033[H\033[J%s' "$buf"
}

handle_key() {
  local key="$1"
  local _total=${#ITEMS_FLAT[@]}

  if [[ "$key" == $'\033' ]]; then
    local _seq=""
    IFS= read -r -s -n2 -t 1 _seq 2>/dev/null
    case "$_seq" in
      "[A") key="UP" ;;   "[B") key="DOWN" ;;
      "[C") key="RIGHT" ;; "[D") key="LEFT" ;;
      *)    key="ESC" ;;
    esac
  fi

  if [[ -n "$_CMD_BUF" ]]; then
    case "$key" in
      $'\x1e') ;;
      ""|$'\n'|$'\r') _CMD_BUF="" ;;
      ESC)             _CMD_BUF="" ;;
      $'\x7f'|$'\x08') _CMD_BUF="${_CMD_BUF%?}" ;;
      *) _CMD_BUF+="$key" ;;
    esac
    return
  fi

  local _cur_item="${ITEMS_FLAT[$SELECTED]:-}"
  local _cur_type="${_cur_item%%|*}"
  local _cur_rest="${_cur_item#*|}"

  case "$key" in
    $'\x1e') ;;

    ":") _CMD_BUF=":" ;;

    r|R)
      kill "$_ANIMATOR_PID" 2>/dev/null
      rm -f "${STATE_DIR}/animator_active"
      ps aux 2>/dev/null | grep "[d]aemon.sh" | grep -v grep | awk '{print $2}' \
        | xargs kill -9 2>/dev/null
      rm -f "${STATE_DIR}/daemon.pid"; rm -rf "${STATE_DIR}/daemon.lock"
      _RELOADING=1; exec "$0" ;;

    j|DOWN)
      if [[ "$_cur_type" == "S" ]]; then
        local _i=$SELECTED
        while (( _i + 1 < _total )); do
          (( _i++ ))
          [[ "${ITEMS_FLAT[$_i]%%|*}" == "S" ]] && { SELECTED=$_i; break; }
        done
      else
        local _next=$(( SELECTED + 1 ))
        [[ $_next -lt $_total && "${ITEMS_FLAT[$_next]%%|*}" == "W" ]] && SELECTED=$_next
      fi
      _write_cursor ;;

    k|UP)
      if [[ "$_cur_type" == "S" ]]; then
        local _i=$SELECTED
        while (( _i > 0 )); do
          (( _i-- ))
          [[ "${ITEMS_FLAT[$_i]%%|*}" == "S" ]] && { SELECTED=$_i; break; }
        done
      else
        local _prev=$(( SELECTED - 1 ))
        [[ $_prev -ge 0 && "${ITEMS_FLAT[$_prev]%%|*}" == "W" ]] && SELECTED=$_prev
      fi
      _write_cursor ;;

    J)
      if [[ "$_cur_type" == "S" ]]; then
        local _sf_idx=0 _k=0
        for _e in "${SESSIONS_FLAT[@]}"; do
          [[ "$_e" == "$_cur_rest" ]] && { _sf_idx=$_k; break; }; (( _k++ ))
        done
        CURSOR_ITEM="$_cur_item"; move_session_down $_sf_idx
      elif [[ "$_cur_type" == "W" ]]; then
        move_window_down $SELECTED
      fi
      _write_cursor ;;

    K)
      if [[ "$_cur_type" == "S" ]]; then
        local _sf_idx=0 _k=0
        for _e in "${SESSIONS_FLAT[@]}"; do
          [[ "$_e" == "$_cur_rest" ]] && { _sf_idx=$_k; break; }; (( _k++ ))
        done
        CURSOR_ITEM="$_cur_item"; move_session_up $_sf_idx
      elif [[ "$_cur_type" == "W" ]]; then
        move_window_up $SELECTED
      fi
      _write_cursor ;;

    RIGHT|l)
      if [[ "$_cur_type" == "S" ]]; then
        local _next=$(( SELECTED + 1 ))
        [[ $_next -lt $_total && "${ITEMS_FLAT[$_next]%%|*}" == "W" ]] && SELECTED=$_next
      fi
      _write_cursor ;;

    LEFT|h|ESC)
      if [[ "$_cur_type" == "W" ]]; then
        local _si=$SELECTED
        while (( _si > 0 )); do
          (( _si-- ))
          [[ "${ITEMS_FLAT[$_si]%%|*}" == "S" ]] && { SELECTED=$_si; break; }
        done
      fi
      _write_cursor ;;

    $'\n'|$'\r')
      if [[ "$_cur_type" == "S" ]]; then
        local _srv="${_cur_rest%%|*}" _sess="${_cur_rest#*|}"
        jump_to "${_srv}|${_sess}"
        printf '%s' "$_sess" > "${STATE_DIR}/current_session"
        local _first_win="" _ii2=0
        for _it2 in "${ITEMS_FLAT[@]}"; do
          if [[ "${_it2%%|*}" == "W" ]]; then
            local _r2="${_it2#*|}"; local _s2="${_r2%%|*}" _r3="${_r2#*|}" _ss2="${_r3%%|*}"
            [[ "$_s2" == "$_srv" && "$_ss2" == "$_sess" ]] && { _first_win="${_s2}:${_r3#*|}"; break; }
          fi
          (( _ii2++ ))
        done
        [[ -n "$_first_win" ]] && printf '%s' "${_srv}|${_first_win}" > "${STATE_DIR}/just_visited"
        _ensure_sidebar "${_sess}:$(printf '%s' "$_first_win" | cut -d: -f2)"
      elif [[ "$_cur_type" == "W" ]]; then
        local _srv="${_cur_rest%%|*}" _wr="${_cur_rest#*|}"
        local _sess="${_wr%%|*}" _win="${_wr#*|}"
        jump_to "${_srv}|${_sess}|${_win}"
        printf '%s' "$_sess" > "${STATE_DIR}/current_session"
        printf '%s' "${_srv}|${_sess}:${_win}" > "${STATE_DIR}/just_visited"
        _ensure_sidebar "${_sess}:${_win}"
        $TMUXBIN send-keys -t "$PANE_ID" $'\x1e' 2>/dev/null
      fi ;;

    q|Q)
      $TMUXBIN kill-pane -t "$PANE_ID" 2>/dev/null; exit 0 ;;
  esac
}

render
LAST_RENDER=$SECONDS
DATA_MTIME=$(file_mtime "$DATA_FILE")
SESS_MTIME=$(file_mtime "${STATE_DIR}/current_session")
CURSOR_MTIME=$(file_mtime "$CURSOR_FILE")

while true; do
  _cur_mtime=$(file_mtime "$DATA_FILE")
  _cur_sess_mtime=$(file_mtime "${STATE_DIR}/current_session")
  _cur_cursor_mtime=$(file_mtime "$CURSOR_FILE")

  if [[ "$_cur_mtime" != "$DATA_MTIME" || "$_cur_sess_mtime" != "$SESS_MTIME" \
      || "$_cur_cursor_mtime" != "$CURSOR_MTIME" \
      || "$_WAKE" == "1" || "$_HAS_WORKING" == "1" ]] \
      || (( SECONDS - LAST_RENDER >= 2 )); then
    _WAKE=0; _HAS_WORKING=0
    DATA_MTIME="$_cur_mtime"; SESS_MTIME="$_cur_sess_mtime"; CURSOR_MTIME="$_cur_cursor_mtime"
    render
    LAST_RENDER=$SECONDS
    [[ "$_HAS_WORKING" == "1" ]] && touch "${STATE_DIR}/animator_active" \
                                 || rm -f "${STATE_DIR}/animator_active"
  fi

  if IFS= read -r -s -n1 -t 1 key 2>/dev/null; then
    handle_key "$key"
    _HAS_WORKING=0
    render
    DATA_MTIME=$(file_mtime "$DATA_FILE"); SESS_MTIME=$(file_mtime "${STATE_DIR}/current_session")
    CURSOR_MTIME=$(file_mtime "$CURSOR_FILE")
    LAST_RENDER=$SECONDS
    [[ "$_HAS_WORKING" == "1" ]] && touch "${STATE_DIR}/animator_active" \
                                 || rm -f "${STATE_DIR}/animator_active"
  fi
done
