# render-row.sh — per-row formatting helpers for the sidebar
# shellcheck shell=bash
# Sourced by sidebar.sh (before render.sh). No shebang — not executed directly.
# Requires: render-icons.sh sourced first (icon_display_attrs, icon_code_to_state).
#           All sidebar globals (STATE_DIR, OUTER_SERVER, color vars, etc.) defined
#           by sidebar.sh before sourcing.

# Note: individual session-row and window-row rendering logic lives inline in
# render() in render.sh because it depends heavily on the render-loop's local
# state (buf, mapbuf, _ii, SELECTED, _CMD_BUF, drill-down flags, filter state,
# etc.). Extracting those blocks into standalone functions would require passing
# many dozens of parameters or using global state, both of which introduce more
# risk than benefit for a pure refactor.
#
# This file is reserved for future extraction of render_session_row() and
# render_window_row() once the render loop is refactored to pass context
# explicitly.
