#!/usr/bin/env bash
# Entry point del plugin tmux-agent-sidebar

PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="${TMPDIR:-/tmp}/agent-sidebar"
DIRTY_FILE="$STATE_DIR/dirty"
mkdir -p "$STATE_DIR"

# Registrar hooks solo una vez por servidor tmux (evita duplicados al hacer source-file)
if [ "$(tmux show-option -gqv @claude_sidebar_hooks)" != "1" ]; then
  tmux set-option -g @claude_sidebar_hooks "1"
  for hook in after-new-session session-closed after-new-window window-unlinked after-rename-window; do
    tmux set-hook -ga "$hook" "run-shell 'touch \"$DIRTY_FILE\" 2>/dev/null'"
  done
  # Rastrear sesión activa del cliente para el indicador ▶ en el sidebar
  tmux set-hook -ga client-session-changed "run-shell '$PLUGIN_DIR/scripts/track-session.sh'"
  # Limpiar sidebar server cuando el último outer session cierre
  tmux set-hook -ga session-closed \
    "run-shell 'tmux list-sessions 2>/dev/null | grep -q . || tmux -L tmux-agent-sidebar kill-server 2>/dev/null'"
fi

# prefix + m — alterna el sidebar
# prefix + M — recarga todos los sidebars activos (útil después de cambios en el plugin)
tmux bind-key m run-shell "$PLUGIN_DIR/scripts/toggle.sh"
tmux bind-key M run-shell "$PLUGIN_DIR/scripts/reload-all.sh"

# prefix + p (configurable) — sidebar como popup flotante (opt-in, tmux 3.3+)
_POPUP_KEY=$(tmux show-option -gqv @agent-sidebar-popup-key 2>/dev/null)
[[ -z "$_POPUP_KEY" ]] && _POPUP_KEY="p"
tmux bind-key "$_POPUP_KEY" run-shell "$PLUGIN_DIR/scripts/popup.sh"

# Click en el sidebar → dar foco + navegar; en otros panes → comportamiento normal
# select-pane -t= primero para que j/k funcionen si el click cae en una fila no navegable
tmux bind-key -n MouseDown1Pane if-shell -F "#{==:#{pane_title},Sessions}" \
  "select-pane -t=; run-shell '$PLUGIN_DIR/scripts/click.sh #{mouse_y}'" \
  "select-pane -t=; send-keys -M"
