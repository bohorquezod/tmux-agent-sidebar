# render-icons.sh — icon/character mapping for the sidebar
# shellcheck shell=bash
# Sourced by sidebar.sh (before render.sh). No shebang — not executed directly.
# Requires: _SPINNER and _SPIN_FRAME globals defined by sidebar.sh.
#           Color globals (GR, CY, RD, YL) defined by sidebar.sh.

# icon_display_attrs STATE
#   Outputs three tab-separated fields on a single line:
#     DISPLAY_ICON <tab> ICON_COL <tab> NAME_COL
#   STATE is one of: empty idle working blocked loop crashed unread
#   Caller captures with:
#     IFS=$'\t' read -r _display_icon _icon_col _name_col \
#       < <(icon_display_attrs "$_state")
icon_display_attrs() {
  local _st="$1"
  case "$_st" in
    empty)   printf '%s\t%s\t%s' "·"                         "$GR" "$GR" ;;
    idle)    printf '%s\t%s\t%s' "○"                         "$GR" "$GR" ;;
    working) printf '%s\t%s\t%s' "${_SPINNER[$_SPIN_FRAME]}" "$CY" "$CY" ;;
    blocked) printf '%s\t%s\t%s' "?"                         "$RD" "$RD" ;;
    loop)    printf '%s\t%s\t%s' "↺"                         "$YL" "$YL" ;;
    crashed) printf '%s\t%s\t%s' "✗"                         "$RD" "$GR" ;;
    unread)  printf '%s\t%s\t%s' "◉"                         "$YL" "$YL" ;;
    *)       printf '%s\t%s\t%s' "·"                         "$GR" "$GR" ;;
  esac
}

# icon_code_to_state ICON_CODE
#   Maps a raw data-file icon code (E/W/I/P/L/X) to a logical state name.
#   Outputs the state string on stdout.
#   Note: does NOT set _HAS_WORKING — that side-effect belongs to render().
icon_code_to_state() {
  case "$1" in
    E) printf 'empty'   ;;
    W) printf 'working' ;;
    P) printf 'blocked' ;;
    L) printf 'loop'    ;;
    X) printf 'crashed' ;;
    *) printf 'idle'    ;;
  esac
}
