#!/bin/bash
# summary.sh — imprime el token de resumen de estado de agentes para status-right de tmux
# Formato: ⚡N (working) ⏸N (idle) ◉N (unread); conteos de cero se omiten.
# Uso directo: set -g status-right "#($PLUGIN_DIR/scripts/summary.sh)"

export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

STATE_DIR="${TMPDIR:-/tmp}/agent-sidebar"
DATA_FILE="${STATE_DIR}/data"

working=0
idle=0
unread=0

if [[ -f "$DATA_FILE" ]]; then
  while IFS='|' read -r _type _server _sess _widx _wname _icon _islast; do
    [[ "$_type" == "W" ]] || continue
    [[ "$_icon" == "⚡" ]] && (( working++ ))
    [[ "$_icon" == "⏸" ]] && (( idle++ ))
  done < "$DATA_FILE"
fi

for _f in "$STATE_DIR"/*.unread; do
  [[ -f "$_f" ]] && (( unread++ ))
done

token=""
[[ $working -gt 0 ]] && token+="⚡${working} "
[[ $idle    -gt 0 ]] && token+="⏸${idle} "
[[ $unread  -gt 0 ]] && token+="◉${unread} "
token="${token% }"

printf '%s' "$token"
