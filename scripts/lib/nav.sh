# nav.sh — navigation helpers
# Sourced by sidebar.sh. Assumes all sidebar globals are already set.
# No shebang — not executed directly.

# ── Jump multi-servidor ───────────────────────────────────────────────────────
jump_to() {
  local _srv _rest _sess _win _t
  _srv="${1%%|*}"; _rest="${1#*|}"
  _sess="${_rest%%|*}"; _win="${_rest#*|}"
  [[ "$_win" == "$_sess" ]] && _win=""
  _t="$_sess"; [[ -n "$_win" ]] && _t="${_sess}:${_win}"
  if [[ "$_srv" == "$OUTER_SERVER" ]]; then
    "${OUTER_TMUX[@]}" switch-client -t "$_t" 2>/dev/null
  else
    "$TMUXBIN" -S "$SOCKET_DIR/$_srv" switch-client -t "$_t" 2>/dev/null
  fi
}

# ── Salto rápido: siguiente working (w) / siguiente unread (u) ────────────────
jump_next_working() {
  local _total=${#ITEMS_FLAT[@]}
  [[ $_total -eq 0 ]] && return
  local _start=$(( SELECTED + 1 )) _tries _i _item _type _irest _srv _wrest _sess _widx _icon
  for (( _tries=0; _tries<_total; _tries++ )); do
    _i=$(( (_start + _tries) % _total ))
    _item="${ITEMS_FLAT[$_i]}"; _type="${_item%%|*}"
    [[ "$_type" != "W" ]] && continue
    _irest="${_item#*|}"; _srv="${_irest%%|*}"; _wrest="${_irest#*|}"
    _sess="${_wrest%%|*}"; _widx="${_wrest#*|}"
    _icon=$(awk -F'|' -v s="$_srv" -v e="$_sess" -v w="$_widx" \
      '$1=="W"&&$2==s&&$3==e&&$4==w{print $6;exit}' "$DATA_FILE" 2>/dev/null)
    if [[ "$_icon" == "W" || "$_icon" == "L" ]]; then
      SELECTED=$_i
      [[ "$_srv" == "$OUTER_SERVER" ]] && _ensure_sidebar "${_sess}:${_widx}"
      jump_to "${_srv}|${_sess}|${_widx}"
      [[ "$_srv" == "$OUTER_SERVER" ]] && printf '%s' "$_sess" > "${STATE_DIR}/current_session"
      return
    fi
  done
}

jump_next_unread() {
  local _total=${#ITEMS_FLAT[@]}
  [[ $_total -eq 0 ]] && return
  local _start=$(( SELECTED + 1 )) _tries _i _item _type _irest _srv _wrest _sess _widx _key
  for (( _tries=0; _tries<_total; _tries++ )); do
    _i=$(( (_start + _tries) % _total ))
    _item="${ITEMS_FLAT[$_i]}"; _type="${_item%%|*}"
    [[ "$_type" != "W" ]] && continue
    _irest="${_item#*|}"; _srv="${_irest%%|*}"; _wrest="${_irest#*|}"
    _sess="${_wrest%%|*}"; _widx="${_wrest#*|}"
    _key="${_srv//[^a-zA-Z0-9_-]/_}_${_sess//[^a-zA-Z0-9_-]/_}_${_widx}"
    if [[ -f "${STATE_DIR}/${_key}.unread" ]]; then
      SELECTED=$_i
      [[ "$_srv" == "$OUTER_SERVER" ]] && _ensure_sidebar "${_sess}:${_widx}"
      jump_to "${_srv}|${_sess}|${_widx}"
      [[ "$_srv" == "$OUTER_SERVER" ]] && printf '%s' "$_sess" > "${STATE_DIR}/current_session"
      printf '%s' "${_srv}|${_sess}:${_widx}" > "${STATE_DIR}/just_visited"
      return
    fi
  done
}

# ── Resolver item por ordinal (N o N.M) desde ITEMS_FLAT ─────────────────────
# Salida: escribe en las variables globales _ri_ci, _ri_ct, _ri_cr
# Retorna 1 si no encuentra el item.
_resolve_ordinal() {
  local _snum="$1" _wnum="${2:-}"
  _ri_ci=""; _ri_ct=""; _ri_cr=""
  local _n=0 _ii=0 _si=-1
  for _it in "${ITEMS_FLAT[@]}"; do
    [[ "${_it%%|*}" == "S" ]] && { (( _n++ )) || true; [[ $_n -eq $_snum ]] && { _si=$_ii; break; }; }
    (( _ii++ )) || true
  done
  [[ $_si -lt 0 ]] && return 1
  if [[ -z "$_wnum" ]]; then
    _ri_ci="${ITEMS_FLAT[$_si]}"; _ri_ct="S"; _ri_cr="${_ri_ci#*|}"; return 0
  fi
  local _wn=0 _wi=$(( _si + 1 )) _wfound=-1
  while [[ $_wi -lt ${#ITEMS_FLAT[@]} ]]; do
    local _wit="${ITEMS_FLAT[$_wi]}"
    [[ "${_wit%%|*}" == "S" ]] && break
    [[ "${_wit%%|*}" == "W" ]] && { (( _wn++ )) || true; [[ $_wn -eq $_wnum ]] && { _wfound=$_wi; break; }; }
    (( _wi++ )) || true
  done
  [[ $_wfound -lt 0 ]] && return 1
  _ri_ci="${ITEMS_FLAT[$_wfound]}"; _ri_ct="W"; _ri_cr="${_ri_ci#*|}"; return 0
}
_ri_ci="" _ri_ct="" _ri_cr=""
