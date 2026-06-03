#!/usr/bin/env bash
# e2e-states.sh — Integration test: validates sidebar icon state transitions
#
# Lanza un agente Claude en una ventana tmux nueva, envía prompts diseñados
# para activar cada estado, y lee el data file del daemon para validar que
# el icono correcto aparece dentro del timeout esperado.
#
# Prerequisitos:
#   - Corriendo dentro de una sesión tmux (requiere $TMUX)
#   - Daemon de tmux-agent-sidebar activo (sidebar abierto o plugin cargado)
#   - CLI 'claude' en $PATH
#
# Uso:
#   bash tests/e2e-states.sh [--verbose]
#
# Variables de entorno:
#   E2E_PROMPT_W   Prompt que activa estado working (override del default)
#   E2E_PROMPT_P   Prompt que activa estado blocked (REQUERIDO para test de permiso)
#   E2E_SKIP_E     Si vale "1", saltea el test de estado empty
#   E2E_SKIP_W     Si vale "1", saltea el test de estado working/idle
#   E2E_SKIP_P     Si vale "1", saltea el test de estado blocked
#   E2E_SKIP_X     Si vale "1", saltea el test de estado crashed

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/lib/states.sh
source "$REPO_ROOT/scripts/lib/states.sh"

STATE_DIR="${TMPDIR:-/tmp}/agent-sidebar"
DATA_FILE="$STATE_DIR/data"
TMUXBIN="${TMUXBIN:-$(command -v tmux)}"
VERBOSE="${1:---quiet}"; [[ "$1" == "--verbose" ]] && VERBOSE=1 || VERBOSE=0

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
PASS_COUNT=0; FAIL_COUNT=0; SKIP_COUNT=0

pass()   { printf "${GREEN}  ✓${NC} %s\n"      "$1"; (( PASS_COUNT++ )); }
fail()   { printf "${RED}  ✗${NC} %s  ${RED}(esperado: %s  obtenido: %s)${NC}\n" "$1" "$2" "$3"; (( FAIL_COUNT++ )); }
skip()   { printf "${YELLOW}  ⊝${NC} %s\n"     "$1"; (( SKIP_COUNT++ )); }
info()   { (( VERBOSE )) && printf "    ${CYAN}→${NC} %s\n" "$1" || true; }
header() { printf "\n${CYAN}══${NC} %s\n" "$1"; }

# ── Helpers ───────────────────────────────────────────────────────────────────

# Mismo algoritmo que current_server_name() en daemon.sh
current_server() {
  local s="${TMUX%%,*}"
  printf '%s' "${s##*/}"
}

# Lee el icono del data file para server|session|win_idx
# Retorna string vacío si la ventana no aparece todavía
get_icon() {
  local server="$1" session="$2" win_idx="$3"
  grep "^W|${server}|${session}|${win_idx}|" "$DATA_FILE" 2>/dev/null \
    | cut -d'|' -f6 | head -1
}

# Espera hasta que el icono sea el esperado o expira el timeout
# Retorna 0 si coincide, 1 si expiró (y deja el icono actual en stdout)
wait_for_icon() {
  local server="$1" session="$2" win_idx="$3" expected="$4" timeout="${5:-30}"
  local tries=$(( timeout * 4 )) icon  # poll cada 250ms
  for (( i=0; i<tries; i++ )); do
    icon=$(get_icon "$server" "$session" "$win_idx")
    if [[ "$icon" == "$expected" ]]; then
      info "icono $expected confirmado tras $(( i / 4 ))s"
      return 0
    fi
    sleep 0.25
  done
  printf '%s' "$(get_icon "$server" "$session" "$win_idx")"
  return 1
}

# Espera a que el icono sea cualquiera de los esperados
wait_for_any_icon() {
  local server="$1" session="$2" win_idx="$3" timeout="$4"
  shift 4
  local expected=("$@")
  local tries=$(( timeout * 4 )) icon
  for (( i=0; i<tries; i++ )); do
    icon=$(get_icon "$server" "$session" "$win_idx")
    for e in "${expected[@]}"; do
      [[ "$icon" == "$e" ]] && { info "icono $icon confirmado tras $(( i / 4 ))s"; return 0; }
    done
    sleep 0.25
  done
  return 1
}

# Captura el pane del sidebar server y devuelve el icono visible para una sesión dada.
# Busca la línea de la ventana que sigue al nombre de sesión en el sidebar.
# Retorna el primer carácter no-espacio de esa línea (el icono de display).
get_sidebar_icon() {
  local session="$1"
  local sidebar_output
  sidebar_output=$(/opt/homebrew/bin/tmux -L tmux-agent-sidebar \
    capture-pane -t sidebar:0.0 -p 2>/dev/null)
  # La línea de la ventana sigue al nombre de sesión en el sidebar.
  # Extraer la línea inmediatamente posterior al nombre de sesión.
  local win_line
  win_line=$(printf '%s' "$sidebar_output" \
    | grep -A1 "$session" | tail -1)
  # El icono sigue al decorador de árbol (└─ o ├─) y un espacio
  printf '%s' "$win_line" | sed 's/^[[:space:]]*//' | sed 's/^[└├]─ //' | cut -c1
}

# Espera hasta que el sidebar muestre el icono esperado para la sesión
wait_for_sidebar_icon() {
  local session="$1" expected_state="$2" timeout="${3:-30}"
  local tries=$(( timeout * 4 )) icon
  # Mapear estado → caracter(es) esperados en el sidebar
  local expected_chars
  case "$expected_state" in
    "$STATE_EMPTY")   expected_chars="·" ;;
    "$STATE_WORKING") expected_chars=$'⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' ;;  # cualquier Braille del spinner
    "$STATE_IDLE")    expected_chars="○◉" ;;  # ◉ = unread (idle con notificación pendiente)
    "$STATE_BLOCKED") expected_chars="?◉" ;;  # ◉ = unread (blocked mientras usuario no miraba)
    "$STATE_CRASHED") expected_chars="✗◉" ;;  # ◉ = unread si el crash fue mientras no miraba
    "$STATE_LOOP")    expected_chars="↺" ;;
    *) expected_chars="$expected_state" ;;
  esac
  for (( i=0; i<tries; i++ )); do
    icon=$(get_sidebar_icon "$session")
    if [[ "$expected_state" == "$STATE_WORKING" ]]; then
      # Para working, verificar que el icono es uno de los Braille del spinner
      if printf '%s' "$icon" | grep -qP '[\x{2800}-\x{28FF}]' 2>/dev/null \
         || [[ "$expected_chars" == *"$icon"* ]]; then
        info "sidebar muestra $expected_state (icono: $icon) tras $(( i / 4 ))s"
        return 0
      fi
    else
      if [[ "$expected_chars" == *"$icon"* && -n "$icon" ]]; then
        info "sidebar muestra $expected_state (icono: $icon) tras $(( i / 4 ))s"
        return 0
      fi
    fi
    sleep 0.25
  done
  info "sidebar mostraba al timeout: '$icon'"
  return 1
}

# Envía teclas a la ventana de prueba
send() {
  $TMUXBIN send-keys -t "${TEST_SESSION}:${WIN_IDX}" "$1" "${2:-Enter}"
}

# Captura contenido visible del pane
capture_pane() {
  $TMUXBIN capture-pane -t "${TEST_SESSION}:${WIN_IDX}" -p 2>/dev/null
}

# ── Prerequisitos ─────────────────────────────────────────────────────────────

header "Prerequisitos"

if [[ -z "${TMUX:-}" ]]; then
  printf "${RED}ERROR${NC}: Debe ejecutarse dentro de una sesión tmux\n"; exit 1
fi
pass "Corriendo dentro de tmux"

if [[ ! -f "$DATA_FILE" ]]; then
  printf "${RED}ERROR${NC}: %s no existe — abre el sidebar primero (prefix+m)\n" "$DATA_FILE"; exit 1
fi
pass "Daemon activo (data file presente)"

if ! command -v claude &>/dev/null; then
  printf "${RED}ERROR${NC}: 'claude' no encontrado en PATH\n"; exit 1
fi
pass "claude CLI disponible"

# ── Setup ─────────────────────────────────────────────────────────────────────

SERVER=$(current_server)
TEST_SESSION="sidebar-e2e-$$"

header "Setup"
info "Servidor tmux: $SERVER"
info "Sesión de prueba: $TEST_SESSION"

$TMUXBIN new-session -d -s "$TEST_SESSION" -x 220 -y 50 2>/dev/null
WIN_IDX=$($TMUXBIN list-windows -t "$TEST_SESSION" -F "#{window_index}" | head -1)
info "Sesión creada (window index: $WIN_IDX)"

# Insertar la sesión al principio del ORDER file para que aparezca visible en el sidebar
ORDER_FILE="${HOME}/.tmux-sidebar-order"
ORDER_BACKUP="${STATE_DIR}/e2e_order_backup_$$"
cp "$ORDER_FILE" "$ORDER_BACKUP" 2>/dev/null || true
printf '%s|%s\n' "$SERVER" "$TEST_SESSION" | cat - "$ORDER_FILE" > "${ORDER_FILE}.tmp" && mv "${ORDER_FILE}.tmp" "$ORDER_FILE"
# Forzar reconstrucción inmediata del daemon y esperar que el sidebar muestre la sesión
touch "${STATE_DIR}/dirty"
info "Sesión insertada en ORDER file (posición 1) — esperando que el sidebar la muestre..."
for _i in $(seq 1 20); do
  sleep 0.5
  _sb=$(/opt/homebrew/bin/tmux -L tmux-agent-sidebar capture-pane -t sidebar:0.0 -p 2>/dev/null)
  if printf '%s' "$_sb" | grep -q "$TEST_SESSION"; then
    info "Sesión visible en sidebar tras $(( _i / 2 ))s"
    break
  fi
done

# Registrar este proceso como cliente activo para que el daemon no salga por has_clients.
# El daemon envía SIGUSR2 a los PIDs en clients/ — ignorarlo para que no mate el test.
trap '' USR2
E2E_CLIENT_KEY="e2e-$$"
printf '%d' "$$" > "${STATE_DIR}/clients/${E2E_CLIENT_KEY}"
info "Cliente registrado (PID: $$)"

cleanup() {
  # Restaurar ORDER file
  if [[ -f "$ORDER_BACKUP" ]]; then
    mv "$ORDER_BACKUP" "$ORDER_FILE"
  fi
  if [[ "${E2E_KEEP:-}" == "1" ]]; then
    info "Sesión $TEST_SESSION conservada (E2E_KEEP=1) — elimínala manualmente con: tmux kill-session -t $TEST_SESSION"
    rm -f "${STATE_DIR}/clients/${E2E_CLIENT_KEY}"
    return
  fi
  info "Limpiando sesión de prueba..."
  $TMUXBIN send-keys -t "${TEST_SESSION}:${WIN_IDX}" "" Enter 2>/dev/null || true
  sleep 0.2
  $TMUXBIN kill-session -t "$TEST_SESSION" 2>/dev/null || true
  rm -f "${STATE_DIR}/clients/${E2E_CLIENT_KEY}"
}
trap cleanup EXIT INT TERM

# ── Test 1: Estado E (Empty) ──────────────────────────────────────────────────

header "Test 1 — empty: shell sin agente"

if [[ "${E2E_SKIP_E:-}" == "1" ]]; then
  skip "Test $STATE_EMPTY saltado (E2E_SKIP_E=1)"
elif wait_for_icon "$SERVER" "$TEST_SESSION" "$WIN_IDX" "$STATE_EMPTY" 10 >/dev/null; then
  pass "Daemon detectó $STATE_EMPTY en data file"
else
  actual_icon=$(get_icon "$SERVER" "$TEST_SESSION" "$WIN_IDX")
  fail "Estado $STATE_EMPTY esperado en ventana vacía" "$STATE_EMPTY" "${actual_icon:-<no detectado>}"
fi

if [[ "${E2E_SKIP_E:-}" != "1" ]]; then
  info "Verificando icono $STATE_EMPTY en sidebar..."
  if wait_for_sidebar_icon "$TEST_SESSION" "$STATE_EMPTY" 10; then
    pass "Sidebar renderizó $STATE_EMPTY correctamente"
  else
    fail "Sidebar no mostró $STATE_EMPTY" "$STATE_EMPTY" "$(get_sidebar_icon "$TEST_SESSION")"
  fi
fi

# ── Test 2: W → I (Claude procesando → idle) ──────────────────────────────────

header "Test 2 — working → idle: Claude procesa y queda idle"

# Prompt que encadena 4 lecturas seguidas para mantener el estado working
# al menos 2-3 s — suficiente para ser visible en el sidebar a ojo humano
PROMPT_W="${E2E_PROMPT_W:-"Necesito que cuentes hasta 10, haz un sleep de 1 segundo entre cada numero"}"

if [[ "${E2E_SKIP_W:-}" == "1" ]]; then
  skip "Test $STATE_WORKING/$STATE_IDLE saltado (E2E_SKIP_W=1)"
else

info "Prompt: ${PROMPT_W:0:80}..."
send "claude \"$PROMPT_W\""

# Esperar working
info "Esperando estado $STATE_WORKING..."
if wait_for_icon "$SERVER" "$TEST_SESSION" "$WIN_IDX" "$STATE_WORKING" 25 >/dev/null; then
  pass "Daemon detectó $STATE_WORKING en data file"
else
  actual_icon=$(get_icon "$SERVER" "$TEST_SESSION" "$WIN_IDX")
  fail "Estado $STATE_WORKING no detectado" "$STATE_WORKING" "${actual_icon:-<vacío>}"
  info "Contenido del pane:\n$(capture_pane | tail -5)"
fi

info "Verificando icono $STATE_WORKING en sidebar..."
if wait_for_sidebar_icon "$TEST_SESSION" "$STATE_WORKING" 25; then
  pass "Sidebar renderizó $STATE_WORKING correctamente"
else
  fail "Sidebar no mostró $STATE_WORKING" "$STATE_WORKING" "$(get_sidebar_icon "$TEST_SESSION")"
fi

# Esperar idle
info "Esperando estado $STATE_IDLE..."
if wait_for_icon "$SERVER" "$TEST_SESSION" "$WIN_IDX" "$STATE_IDLE" 90 >/dev/null; then
  pass "Daemon detectó $STATE_IDLE en data file"
else
  actual_icon=$(get_icon "$SERVER" "$TEST_SESSION" "$WIN_IDX")
  fail "Estado $STATE_IDLE no detectado tras respuesta" "$STATE_IDLE" "${actual_icon:-<vacío>}"
fi

info "Verificando icono $STATE_IDLE en sidebar..."
if wait_for_sidebar_icon "$TEST_SESSION" "$STATE_IDLE" 10; then
  pass "Sidebar renderizó $STATE_IDLE correctamente"
else
  fail "Sidebar no mostró $STATE_IDLE" "$STATE_IDLE" "$(get_sidebar_icon "$TEST_SESSION")"
fi

# ── Test 2b: unread ───────────────────────────────────────────────────────────

header "Test 2b — unread: ◉ aparece cuando working→idle ocurre sin que el usuario mire"

if [[ "${E2E_SKIP_W:-}" == "1" ]]; then
  skip "Test unread saltado (E2E_SKIP_W=1)"
else
  # El flag .unread debe existir porque la transición working→idle ocurrió
  # en una ventana que el usuario no estaba mirando (ventana de prueba)
  _UNREAD_KEY="${SERVER//[^a-zA-Z0-9_-]/_}_${TEST_SESSION//[^a-zA-Z0-9_-]/_}_${WIN_IDX}"
  if [[ -f "${STATE_DIR}/${_UNREAD_KEY}.unread" ]]; then
    pass "Flag .unread existe — transición working→idle no vista"
  else
    fail "Flag .unread no existe" ".unread" "<ausente>"
  fi

  info "Verificando icono unread (◉) en sidebar..."
  _sidebar_icon=$(get_sidebar_icon "$TEST_SESSION")
  if [[ "$_sidebar_icon" == "◉" ]]; then
    pass "Sidebar muestra ◉ (unread) — notificación de idle pendiente"
  else
    fail "Sidebar no muestra unread" "◉" "${_sidebar_icon:-<vacío>}"
  fi
fi

fi  # fin E2E_SKIP_W

# ── Test 3: P (diálogo de permiso) ────────────────────────────────────────────

header "Test 3 — blocked: diálogo de permiso [Yes]/[No]/[Always]"

# AskUserQuestion muestra "Enter to select" en el pane → detectado como blocked
PROMPT_P="${E2E_PROMPT_P:-"Hazme una pregunta con AskUserQuestion"}"

if [[ "${E2E_SKIP_P:-}" == "1" ]]; then
  skip "Test $STATE_BLOCKED saltado (E2E_SKIP_P=1)"
else
  info "Prompt blocked: ${PROMPT_P:0:80}..."
  send "claude \"$PROMPT_P\""

  # Esperar blocked en data file
  info "Esperando estado $STATE_BLOCKED..."
  if wait_for_icon "$SERVER" "$TEST_SESSION" "$WIN_IDX" "$STATE_BLOCKED" 30 >/dev/null; then
    pass "Daemon detectó $STATE_BLOCKED en data file"
  else
    actual_icon=$(get_icon "$SERVER" "$TEST_SESSION" "$WIN_IDX")
    fail "Estado $STATE_BLOCKED no detectado" "$STATE_BLOCKED" "${actual_icon:-<vacío>}"
  fi

  # Verificar icono blocked en sidebar
  info "Verificando icono $STATE_BLOCKED en sidebar..."
  if wait_for_sidebar_icon "$TEST_SESSION" "$STATE_BLOCKED" 10; then
    pass "Sidebar renderizó $STATE_BLOCKED correctamente"
  else
    fail "Sidebar no mostró $STATE_BLOCKED" "$STATE_BLOCKED" "$(get_sidebar_icon "$TEST_SESSION")"
  fi

  # Desbloquear — Enter selecciona la primera opción del diálogo
  send "" Enter
  sleep 0.5

  # Esperar que vuelva a idle o working
  wait_for_any_icon "$SERVER" "$TEST_SESSION" "$WIN_IDX" 15 "$STATE_IDLE" "$STATE_WORKING" >/dev/null || true
  info "Estado post-permiso: $(get_icon "$SERVER" "$TEST_SESSION" "$WIN_IDX")"
fi

# ── Test 4: X (proceso crashed) ───────────────────────────────────────────────

header "Test 4 — crashed: Claude muere mientras procesa"

if [[ "${E2E_SKIP_X:-}" == "1" ]]; then
  skip "Test $STATE_CRASHED saltado (E2E_SKIP_X=1)"
else
  # Necesitamos que Claude esté en working para luego matarlo
  # Usamos un prompt largo para tener ventana de tiempo
  PROMPT_X="${E2E_PROMPT_X:-"Read $REPO_ROOT/scripts/daemon.sh then read $REPO_ROOT/scripts/sidebar.sh and compare them, listing every function that exists in one but not the other."}"

  info "Enviando prompt para tener Claude en $STATE_WORKING..."
  # Matar claude previo si quedó idle
  send "" C-c
  sleep 0.5

  send "claude \"$PROMPT_X\""

  info "Esperando $STATE_WORKING antes de matar el proceso..."
  if ! wait_for_icon "$SERVER" "$TEST_SESSION" "$WIN_IDX" "$STATE_WORKING" 25 >/dev/null; then
    skip "Test $STATE_CRASHED saltado — no se pudo confirmar estado $STATE_WORKING para el kill"
  else
    # Obtener el PID de claude en ese pane
    PANE_PID=$($TMUXBIN display-message -t "${TEST_SESSION}:${WIN_IDX}" -p '#{pane_pid}' 2>/dev/null)
    CLAUDE_PID=""
    if [[ -n "$PANE_PID" ]]; then
      # Buscar hijo que tenga session file
      while IFS= read -r child; do
        [[ -f "${HOME}/.claude/sessions/${child}.json" ]] && { CLAUDE_PID="$child"; break; }
      done < <(pgrep -P "$PANE_PID" 2>/dev/null)
      # Si no hay hijo, intentar con el pane_pid mismo
      [[ -z "$CLAUDE_PID" && -f "${HOME}/.claude/sessions/${PANE_PID}.json" ]] && CLAUDE_PID="$PANE_PID"
    fi

    if [[ -z "$CLAUDE_PID" ]]; then
      skip "Test $STATE_CRASHED saltado — no se encontró PID de claude en el pane"
    else
      info "Matando claude PID $CLAUDE_PID..."
      kill -9 "$CLAUDE_PID" 2>/dev/null || true

      info "Esperando estado $STATE_CRASHED (hasta 15s)..."
      if wait_for_icon "$SERVER" "$TEST_SESSION" "$WIN_IDX" "$STATE_CRASHED" 15 >/dev/null; then
        pass "Daemon detectó $STATE_CRASHED — crash con session file en busy"
      else
        actual_icon=$(get_icon "$SERVER" "$TEST_SESSION" "$WIN_IDX")
        fail "Estado $STATE_CRASHED no detectado tras kill -9" "$STATE_CRASHED" "${actual_icon:-<vacío>}"
        info "El daemon puede tardar hasta 2s en detectar muerte del proceso"
      fi

      info "Verificando icono $STATE_CRASHED en sidebar..."
      if wait_for_sidebar_icon "$TEST_SESSION" "$STATE_CRASHED" 15; then
        pass "Sidebar renderizó $STATE_CRASHED correctamente"
      else
        fail "Sidebar no mostró $STATE_CRASHED" "$STATE_CRASHED" "$(get_sidebar_icon "$TEST_SESSION")"
      fi
    fi
  fi
fi

# ── Resumen ───────────────────────────────────────────────────────────────────

printf "\n${CYAN}══ Resumen ══${NC}\n"
printf "  ${GREEN}Pasaron${NC}: %d  ${RED}Fallaron${NC}: %d  ${YELLOW}Saltados${NC}: %d\n" \
  "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"

printf "\n${YELLOW}Nota${NC}: El estado $STATE_LOOP no se prueba aquí.\n"
printf "  $STATE_LOOP requiere ≥3 transiciones $STATE_WORKING→$STATE_IDLE con ≥60s de separación — ver tests unitarios en tests/detect.bats.\n\n"

(( FAIL_COUNT == 0 ))
