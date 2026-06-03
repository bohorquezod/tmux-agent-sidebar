#!/bin/bash
# track-session.sh — escribe la sesión activa del cliente al STATE_DIR
# Invocado por el hook after-switch-client en el entry point del plugin

TMUXBIN="$(command -v tmux 2>/dev/null)"
[[ -z "$TMUXBIN" ]] && TMUXBIN="tmux"
STATE_DIR="${TMPDIR:-/tmp}/agent-sidebar"

_sess=$($TMUXBIN display-message -p '#{client_session}' 2>/dev/null)
[[ -n "$_sess" ]] && printf '%s' "$_sess" >"$STATE_DIR/current_session"
