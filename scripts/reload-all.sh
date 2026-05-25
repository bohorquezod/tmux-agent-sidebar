#!/bin/bash
# reload-all.sh — hard reload nuclear: mata todo y recrea desde cero (prefix + M)

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMUXBIN="$(command -v tmux 2>/dev/null)"; [[ -z "$TMUXBIN" ]] && TMUXBIN="tmux"
STATE_DIR="${TMPDIR:-/tmp}/agent-sidebar"
SERVER="tmux-agent-sidebar"

# 1. Matar servidor sidebar completo (incluye sidebar.sh y animator)
$TMUXBIN -L "$SERVER" kill-server 2>/dev/null
sleep 0.2

# 2. Matar todos los daemons con SIGKILL (no depender del EXIT trap)
ps aux 2>/dev/null | grep "[d]aemon.sh" | grep -v grep | awk '{print $2}' \
  | xargs kill -9 2>/dev/null

# 3. Limpiar todo el estado
rm -f "${STATE_DIR}/daemon.pid"
rm -rf "${STATE_DIR}/daemon.lock"
rm -f "${STATE_DIR}/animator_active"
rm -f "${STATE_DIR}/clients/sidebar-server"
sleep 0.2

# 4. Resetear guard de hooks y re-registrar (necesario para que nuevos hooks se apliquen)
tmux set-option -gu @claude_sidebar_hooks 2>/dev/null
bash "$PLUGIN_DIR/tmux-agent-sidebar.tmux"

# 5. Recrear servidor sidebar limpio
bash "$PLUGIN_DIR/scripts/server-start.sh"
