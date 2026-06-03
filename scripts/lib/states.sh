# shellcheck shell=bash
# shellcheck disable=SC2034  # all STATE_* constants used in sourced modules
# states.sh — State name constants for icon detection
# Sourced before all other lib modules. No shebang — not executed directly.
# Globals: STATE_EMPTY STATE_WORKING STATE_IDLE STATE_BLOCKED STATE_LOOP STATE_CRASHED

readonly STATE_EMPTY="empty"
readonly STATE_WORKING="working"
readonly STATE_IDLE="idle"
readonly STATE_BLOCKED="blocked"
readonly STATE_LOOP="loop"
readonly STATE_CRASHED="crashed"
