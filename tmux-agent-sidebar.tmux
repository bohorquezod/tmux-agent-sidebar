#!/usr/bin/env bash
# Entry point del plugin tmux-agent-sidebar

# Si corremos bajo bash 3 (macOS system default), buscar bash 4+ y re-ejecutar
_bash_ver="${BASH_VERSINFO[0]:-0}"
if (( _bash_ver < 4 )); then
  _b4=""
  for _b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "$_b" && "$("$_b" -c 'echo ${BASH_VERSINFO[0]}')" -ge 4 ]]; then
      _b4="$_b"; break
    fi
  done
  if [[ -z "$_b4" ]]; then
    tmux display-message "tmux-agent-sidebar requires bash 4+. Install: brew install bash"
    exit 1
  fi
  exec "$_b4" "$0" "$@"
fi

PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="${TMPDIR:-/tmp}/agent-sidebar"
DIRTY_FILE="$STATE_DIR/dirty"
mkdir -p "$STATE_DIR"

# Leer opciones @agent-sidebar-* con fallback a defaults
_toggle_key=$(tmux show-option -gqv @agent-sidebar-toggle-key   2>/dev/null)
_reload_key=$(tmux show-option  -gqv @agent-sidebar-reload-key  2>/dev/null)
_width=$(tmux show-option       -gqv @agent-sidebar-width       2>/dev/null)
_hidden=$(tmux show-option      -gqv @agent-sidebar-hidden-sessions 2>/dev/null)
_interval=$(tmux show-option    -gqv @agent-sidebar-refresh-interval 2>/dev/null)

[[ -z "$_toggle_key" ]] && _toggle_key="m"
[[ -z "$_reload_key"  ]] && _reload_key="M"
[[ "$_width" =~ ^[0-9]+$ ]]    || _width="28"
[[ "$_interval" =~ ^[0-9]+$ ]] || _interval="2"

# Persistir en state dir para que daemon, sidebar y scripts los lean sin acceso al outer server
printf '%s' "$_width"    > "${STATE_DIR}/sidebar_width"
printf '%s' "$_hidden"   > "${STATE_DIR}/hidden_sessions"
printf '%s' "$_interval" > "${STATE_DIR}/refresh_interval"

# Registrar hooks solo una vez por servidor tmux (evita duplicados al hacer source-file)
if [ "$(tmux show-option -gqv @claude_sidebar_hooks)" != "3" ]; then
  tmux set-option -g @claude_sidebar_hooks "3"
  for hook in session-created session-closed after-rename-session after-new-window window-unlinked after-rename-window; do
    tmux set-hook -ga "$hook" "run-shell 'touch \"$DIRTY_FILE\" 2>/dev/null'"
  done
  # Rastrear sesión activa del cliente para el indicador ▶ en el sidebar
  tmux set-hook -ga client-session-changed "run-shell '$PLUGIN_DIR/scripts/track-session.sh'"
  # Recuperar sidebar muerto al cambiar de ventana o sesión
  tmux set-hook -ga after-select-window    "run-shell '$PLUGIN_DIR/scripts/recover-sidebar.sh'"
  tmux set-hook -ga client-session-changed "run-shell '$PLUGIN_DIR/scripts/recover-sidebar.sh'"
  # Cuando el pane sidebar es resizeado, actualizar el sidebar server con el nuevo ancho.
  # Necesario porque window-size manual impide que los clientes cambien el tamaño solos.
  # Resize del pane sidebar → actualizar sidebar server con el nuevo ancho.
  # sidebar.sh detecta el cambio vía stty size al inicio de cada iteración del loop.
  tmux set-hook -ga after-resize-pane "if -F '#{==:#{pane_title},Sessions}' 'run-shell \"tmux -L tmux-agent-sidebar resize-window -t sidebar -x #{pane_width} -y #{pane_height} 2>/dev/null\"'"
  # Limpiar sidebar server cuando el último outer session cierre
  tmux set-hook -ga session-closed \
    "run-shell 'tmux list-sessions 2>/dev/null | grep -q . || tmux -L tmux-agent-sidebar kill-server 2>/dev/null'"
fi

# Bind teclas solo si no están vacías (vacío = el usuario deshabilita ese atajo)
[[ -n "$_toggle_key" ]] && tmux bind-key "$_toggle_key" run-shell "$PLUGIN_DIR/scripts/toggle.sh"
[[ -n "$_reload_key"  ]] && tmux bind-key "$_reload_key"  run-shell "$PLUGIN_DIR/scripts/reload-all.sh"

# prefix + p (configurable) — sidebar como popup flotante (opt-in, tmux 3.3+)
_POPUP_KEY=$(tmux show-option -gqv @agent-sidebar-popup-key 2>/dev/null)
[[ -z "$_POPUP_KEY" ]] && _POPUP_KEY="p"
tmux bind-key "$_POPUP_KEY" run-shell "$PLUGIN_DIR/scripts/popup.sh"

# Click en el sidebar → dar foco + navegar; en otros panes → comportamiento normal
# select-pane -t= primero para que j/k funcionen si el click cae en una fila no navegable
tmux bind-key -n MouseDown1Pane if-shell -F "#{==:#{pane_title},Sessions}" \
  "select-pane -t=; run-shell '$PLUGIN_DIR/scripts/click.sh #{mouse_y}'" \
  "select-pane -t=; send-keys -M"
