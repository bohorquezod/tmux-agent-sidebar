#!/usr/bin/env bash
# sidebar.sh — cliente del sidebar: cursor plano sobre sesiones y ventanas

# Require bash 4+
_bash_ver="${BASH_VERSINFO[0]:-0}"
if (( _bash_ver < 4 )); then
  printf 'tmux-agent-sidebar requires bash 4+. Current: %s\n' "$BASH_VERSION" >&2
  exit 1
fi

# Deshabilitar echo y asegurar que \n produzca \r\n (ONLCR) en la pty.
stty -echo onlcr 2>/dev/null
printf '\033[?7l\033[?25l'  # deshabilitar auto-wrap y ocultar cursor
shopt -s checkwinsize 2>/dev/null

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
  OUTER_TMUX=("$TMUXBIN" -S "$OUTER_TMUX_SOCKET")
  OUTER_SERVER="${OUTER_TMUX_SOCKET##*/}"
  if [[ -n "$POPUP_MODE" ]]; then
    CLIENT_KEY="popup-$$"
    STATE_FILE="${STATE_DIR}/popup_$$"
  else
    CLIENT_KEY="sidebar-server"
    STATE_FILE="${STATE_DIR}/sidebar_server"
  fi
else
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

# Source all lib modules (defines render, nav, ops, cmd, sidebar-utils functions)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/log.sh"
source "${SCRIPT_DIR}/lib/states.sh"
source "${SCRIPT_DIR}/lib/sidebar-utils.sh"
source "${SCRIPT_DIR}/lib/nav.sh"
source "${SCRIPT_DIR}/lib/ops.sh"
source "${SCRIPT_DIR}/lib/cmd.sh"
source "${SCRIPT_DIR}/lib/render-icons.sh"
source "${SCRIPT_DIR}/lib/render-row.sh"
source "${SCRIPT_DIR}/lib/render.sh"

_RELOADING=0
_ANIMATOR_PID=0
trap '_sidebar_cleanup' EXIT INT TERM
trap '_RELOADING=1; kill "$_ANIMATOR_PID" 2>/dev/null; exec "$0"' USR1
_WAKE=0
trap '_WAKE=1' USR2
_WINCH=0
_RESIZE=0
trap '_WINCH=1; _RESIZE=1' WINCH

_start_animator &
_ANIMATOR_PID=$!

# Arrancar daemon si no está corriendo
_dpid_file="${STATE_DIR}/daemon.pid"
if [[ ! -f "$_dpid_file" ]] || ! kill -0 "$(<"$_dpid_file")" 2>/dev/null; then
  if [[ -n "$OUTER_TMUX_SOCKET" ]]; then
    TMUX="${OUTER_TMUX_SOCKET},0,0" nohup "$BASH" "$PLUGIN_DIR/scripts/daemon.sh" >/dev/null 2>&1 &
  else
    nohup "$BASH" "$PLUGIN_DIR/scripts/daemon.sh" >/dev/null 2>&1 &
  fi
  disown $! 2>/dev/null
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

_CURRENT_W=0
_CURRENT_H=0

_SPIN_FRAME=0
_SPINNER=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
_HAS_WORKING=0
_CMD_BUF=""
_KILL_PENDING=""
_SEARCH_MODE=0
_SEARCH_QUERY=""
_SEARCH_SEL=0
_SEARCH_ITEMS=()
_RENAME_ITEM=""
_RENAME_BUF=""
_RENAME_TYPE=""
_FILTER_STATUS=""
_HELP_MODE=0

# Data arrays — global cache repopulado solo cuando DATA_FILE cambia
# bash 4: associative arrays replace parallel indexed arrays
declare -A _srv_cur    # server → is_current (0|1)
declare -A _sess_act   # "srv|sess" → is_active (0|1)
declare -A _win_meta   # "srv|sess|widx" → "name|icon|agent|last"
_win_keys=()           # lista ordenada de claves para renderizar
_RENDER_DATA_MTIME=""

# ── Estado de navegación ──────────────────────────────────────────────────────
SESSIONS_FLAT=()
ITEMS_FLAT=()
SELECTED=0
CURSOR_ITEM=""
_INITIAL_SELECT=1
PREVIEW_MODE=0

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
      *) [[ "$key" > $'\x1f' && "$key" != $'\x7f' ]] && _RENAME_BUF+="$key" ;;
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
      *) [[ "$key" > $'\x1f' && "$key" != $'\x7f' ]] && _CMD_BUF+="$key" ;;
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
        if [[ ${#key} -eq 1 && "$key" > $'\x1f' && "$key" != $'\x7f' ]]; then _SEARCH_QUERY+="$key"; _SEARCH_SEL=0; fi ;;
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

    "?") _HELP_MODE=1 ;;

    ":") _CMD_BUF=":" ;;
    "/") _SEARCH_MODE=1; _SEARCH_QUERY=""; _SEARCH_SEL=0; _SEARCH_ITEMS=() ;;
    [0-9]) _CMD_BUF="$key" ;;

    R)
      # Nuclear reload: equivalente a prefix+M pero sin matar el pane del sidebar.
      # El servidor tmux-agent-sidebar y la sesión se preservan; solo se reinicia
      # sidebar.sh (exec $0) con estado limpio y daemon fresco.
      kill "$_ANIMATOR_PID" 2>/dev/null
      rm -f "${STATE_DIR}/animator_active"
      ps aux 2>/dev/null | grep "[d]aemon.sh" | grep -v grep | awk '{print $2}' \
        | xargs kill -9 2>/dev/null
      rm -f "${STATE_DIR}/daemon.pid"
      rm -rf "${STATE_DIR}/daemon.lock"
      rm -f "${STATE_DIR}/data"
      rm -f "${STATE_DIR}/rowmap"
      rm -f "${STATE_DIR}/clients/"*
      "${OUTER_TMUX[@]}" set-option -gu @claude_sidebar_hooks 2>/dev/null
      "${OUTER_TMUX[@]}" run-shell "bash \"$PLUGIN_DIR/tmux-agent-sidebar.tmux\"" 2>/dev/null
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
        local _i=$SELECTED
        while (( _i + 1 < _total )); do
          (( _i++ ))
          [[ "${ITEMS_FLAT[$_i]%%|*}" == "S" ]] && { SELECTED=$_i; break; }
        done
      else
        local _next=$(( SELECTED + 1 ))
        [[ $_next -lt $_total && "${ITEMS_FLAT[$_next]%%|*}" == "W" ]] && SELECTED=$_next
      fi ;;

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

    RIGHT|l)
      if [[ "$_cur_type" == "S" ]]; then
        local _next=$(( SELECTED + 1 ))
        [[ $_next -lt $_total && "${ITEMS_FLAT[$_next]%%|*}" == "W" ]] && SELECTED=$_next
      fi ;;

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

    $'\n'|$'\r')
      if [[ "$_cur_type" == "S" ]]; then
        local _srv="${_cur_rest%%|*}" _sess="${_cur_rest#*|}"
        jump_to "${_srv}|${_sess}"
        [[ "$_srv" == "$OUTER_SERVER" ]] && printf '%s' "$_sess" > "${STATE_DIR}/current_session"
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

    w) jump_next_working ;;
    u) jump_next_unread ;;

    q|Q)
      if [[ -n "$POPUP_MODE" ]]; then
        exit 0
      elif [[ -n "$OUTER_TMUX_SOCKET" ]]; then
        $TMUXBIN detach-client 2>/dev/null
      else
        $TMUXBIN kill-pane -t "$PANE_ID" 2>/dev/null; exit 0
      fi ;;
  esac
}

# ── Loop principal ────────────────────────────────────────────────────────────

# Render inicial inmediato
render
LAST_RENDER=$SECONDS
DATA_MTIME=$(file_mtime "$DATA_FILE")
SESS_MTIME=$(file_mtime "${STATE_DIR}/current_session")
LAST_SZ=$(stty size 2>/dev/null)
while true; do
  # Heartbeat: re-registrar en clients/ por si el directorio fue limpiado
  printf '%d' "$$" > "$CLIENTS_DIR/$CLIENT_KEY" 2>/dev/null || true

  _cur_sz=$(stty size 2>/dev/null)
  if [[ "$_cur_sz" != "$LAST_SZ" ]]; then
    LAST_SZ="$_cur_sz"; _WINCH=1; _RESIZE=1
    _CURRENT_W="${_cur_sz##* }"; _CURRENT_H="${_cur_sz%% *}"
  fi

  # Con window-size manual, stty puede estar desactualizado mientras el hook after-resize-pane
  # aún no completó su resize-window. Consultamos el pane externo directamente y, si hay
  # mismatch, llamamos resize-window de forma síncrona y actualizamos _CURRENT_W/_CURRENT_H
  # antes de que render() los use. Sin flags, sin continue: render ocurre normalmente pero con
  # los valores correctos.
  if [[ -n "$OUTER_TMUX_SOCKET" ]]; then
    _opw=$("${OUTER_TMUX[@]}" list-panes -a \
      -F '#{pane_title}|#{pane_width}|#{pane_height}' 2>/dev/null \
      | awk -F'|' '$1=="Sessions"{print $2"|"$3; exit}')
    if [[ -n "$_opw" ]]; then
      _opw_x="${_opw%%|*}"; _opw_y="${_opw##*|}"
      if [[ "$_opw_x" =~ ^[0-9]+$ && "$_opw_y" =~ ^[0-9]+$ && \
            ( "$_opw_x" != "$_CURRENT_W" || "$_opw_y" != "$_CURRENT_H" ) ]]; then
        "$TMUXBIN" -L "tmux-agent-sidebar" resize-window -t sidebar \
          -x "$_opw_x" -y "$_opw_y" 2>/dev/null
        _CURRENT_W="$_opw_x"; _CURRENT_H="$_opw_y"
        _DIFF_LINES=()
        _WINCH=1
      fi
    fi
  fi

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

  if IFS= read -r -s -n1 -t 1 key 2>/dev/null; then
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
