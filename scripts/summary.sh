#!/bin/bash
# summary.sh — imprime el token de resumen escrito por el daemon.
# Uso: set -g status-right "#($PLUGIN_DIR/scripts/summary.sh) %H:%M"

STATE_DIR="${TMPDIR:-/tmp}/agent-sidebar"

cat "${STATE_DIR}/summary" 2>/dev/null
