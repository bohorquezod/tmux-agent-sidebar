# shellcheck shell=bash
# render-icons.sh — icon/spinner pure-mapping functions
# Sourced by sidebar.sh. No shebang — not executed directly.
# Requires: _SPINNER array, R GR CY RD YL color globals.
# No tmux calls, no file I/O — pure lookup tables.

# spinner_frame <index>
# Prints the Braille spinner character at the given frame index (wraps at array length).
spinner_frame() {
  printf '%s' "${_SPINNER[$(( $1 % ${#_SPINNER[@]} ))]}"
}

# icon_to_char <state> <spin_frame>
# Prints the display character for the given window state.
# state: empty | idle | working | blocked | loop | crashed | unread
icon_to_char() {
  local _ic_state="$1" _ic_frame="${2:-0}"
  case "$_ic_state" in
    empty)   printf '·' ;;
    idle)    printf '○' ;;
    working) printf '%s' "${_SPINNER[$_ic_frame]}" ;;
    blocked) printf '?' ;;
    loop)    printf '↺' ;;
    crashed) printf '✗' ;;
    unread)  printf '◉' ;;
    *)       printf '·' ;;
  esac
}

# icon_to_color <state>
# Sets _icon_col and _name_col ANSI color globals for the given window state.
# Caller reads _icon_col and _name_col immediately after.
icon_to_color() {
  local _ic_state="$1"
  case "$_ic_state" in
    empty)   _icon_col="$GR"; _name_col="$GR" ;;
    idle)    _icon_col="$GR"; _name_col="$GR" ;;
    working) _icon_col="$CY"; _name_col="$CY" ;;
    blocked) _icon_col="$RD"; _name_col="$RD" ;;
    loop)    _icon_col="$YL"; _name_col="$YL" ;;
    crashed) _icon_col="$RD"; _name_col="$GR" ;;
    unread)  _icon_col="$YL"; _name_col="$YL" ;;
    *)       _icon_col="$GR"; _name_col="$GR" ;;
  esac
}
