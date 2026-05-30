# tmux-agent-sidebar

Sidebar para tmux que muestra todas las sesiones y ventanas de todos los servidores tmux activos, con indicadores de estado de Claude Code en cada ventana.

## Prerequisitos

- **tmux 3.0+**
- **bash 4+** — macOS incluye bash 3.2 por default, que no es compatible.

  ```bash
  brew install bash
  ```

## Instalación

### Via TPM (desde GitHub)

```tmux
set -g @plugin 'tu-usuario/tmux-agent-sidebar'
```

Después `prefix+I` para instalar.

### Local (sin GitHub)

Carga directa en `~/.tmux.conf`:

```tmux
run-shell '~/ruta/a/tmux-agent-sidebar/tmux-agent-sidebar.tmux'
```

### Via TPM desde un directorio local

```tmux
set -g @plugin 'file:///ruta/absoluta/a/tmux-agent-sidebar'
```

Después `prefix+I`.

## Uso

| Atajo        | Acción                              |
| ------------ | ----------------------------------- |
| `prefix+m`   | Abrir / cerrar / enfocar el sidebar |
| `prefix+M`   | Recargar el sidebar completamente   |
| `j` / `k`    | Navegar entre sesiones              |
| `l` / `h`    | Entrar / salir de ventanas          |
| `J` / `K`    | Reordenar sesión o ventana          |
| `Enter`      | Ir al item seleccionado             |
| `r`          | Recargar                            |
| `q`          | Cerrar                              |

Los números ordinales (`1`, `2.3`, etc.) activan el command buffer para navegar directamente a una sesión o ventana.

## Window states

Each window displays an icon indicating the state of the Claude Code agent running in it.

| Icon | State   | Meaning                                                          |
| ---- | ------- | ---------------------------------------------------------------- |
| `·`  | Empty   | No Claude agent running (shell or blank pane)                    |
| `⠿`  | Working | Claude is actively executing tools or processing                 |
| `○`  | Idle    | Claude is waiting for the next user message                      |
| `?`  | Blocked | Claude is waiting for a permission decision (`[Yes]` / `[No]`)  |
| `↺`  | Loop    | Claude appears stuck in a repetitive cycle                       |
| `✗`  | Crashed | Claude process died unexpectedly while it was working            |
| `◉`  | Unread  | Claude finished working while you were in another window         |

## Configuración

Todas las opciones son opcionales. Agregalas en `~/.tmux.conf` antes de cargar el plugin.

| Opción                             | Default | Descripción                                                                          |
| ---------------------------------- | ------- | ------------------------------------------------------------------------------------ |
| `@agent-sidebar-toggle-key`        | `m`     | Tecla para abrir/cerrar/enfocar el sidebar (`prefix + <key>`). Vacío = deshabilitar. |
| `@agent-sidebar-reload-key`        | `M`     | Tecla para recargar el sidebar (`prefix + <key>`). Vacío = deshabilitar.             |
| `@agent-sidebar-width`             | `28`    | Ancho inicial del sidebar en columnas.                                               |
| `@agent-sidebar-hidden-sessions`   | `""`    | Sesiones a ocultar del sidebar (separadas por espacios).                             |
| `@agent-sidebar-refresh-interval`  | `2`     | Intervalo en segundos entre actualizaciones del daemon.                              |

### Ejemplo

```tmux
set -g @agent-sidebar-toggle-key    "s"
set -g @agent-sidebar-reload-key    "S"
set -g @agent-sidebar-width         "35"
set -g @agent-sidebar-hidden-sessions "scratch temp"
set -g @agent-sidebar-refresh-interval "3"

run-shell '~/ruta/a/tmux-agent-sidebar/tmux-agent-sidebar.tmux'
```

## Status bar token

El plugin expone un token compacto con conteos de actividad de agentes para
integrar en el `status-right` (u otro componente) del status bar de tmux.

**Formato**: `⚡N ?N ↺N ✗N ⏸N ◉N` — los conteos de cero se omiten.

| Símbolo | Significado             |
| ------- | ----------------------- |
| `⚡N`   | N agentes working       |
| `?N`    | N agentes blocked       |
| `↺N`    | N agentes en loop       |
| `✗N`    | N agentes crashed       |
| `⏸N`   | N agentes idle          |
| `◉N`   | N ventanas unread       |

Ejemplos de output: `⚡2 ⏸1`, `⏸3 ◉1`, `⚡1 ?1` (vacío cuando no hay agentes activos).

### Opción 1 — `#{@agent_sidebar_summary}` (recomendada)

El daemon actualiza automáticamente la user-option `@agent_sidebar_summary` en
el servidor tmux principal cada vez que refresca los datos (~0.3 s). Agregar al
`~/.tmux.conf`:

```tmux
set -g status-right "#{@agent_sidebar_summary} %H:%M"
```

No requiere ningún subshell; tmux lee la opción directamente.

### Opción 2 — archivo de estado

El daemon escribe `${TMPDIR:-/tmp}/agent-sidebar/summary` en cada ciclo.
Cualquier componente puede leerlo:

```tmux
set -g status-right "#(cat ${TMPDIR:-/tmp}/agent-sidebar/summary) %H:%M"
```

### Opción 3 — script standalone

Alternativa a leer el archivo directamente:

```tmux
set -g status-right "#(~/path/to/tmux-agent-sidebar/scripts/summary.sh) %H:%M"
```

`scripts/summary.sh` lee el archivo `summary` escrito por el daemon. Equivalente
a la opción 2 pero útil cuando se prefiere delegar la ruta al script.

## Debugging

Set `AGENT_SIDEBAR_LOG=2` to enable verbose logging to `${TMPDIR:-/tmp}/agent-sidebar/debug.log`:

```tmux
# In tmux.conf (persistent):
set-environment -g AGENT_SIDEBAR_LOG 2

# Or for a single session:
AGENT_SIDEBAR_LOG=2 tmux source-file tmux-agent-sidebar.tmux
```

Then tail the log:

```bash
tail -f "${TMPDIR:-/tmp}/agent-sidebar/debug.log"
```

Log levels:

| Level | Meaning                    |
| ----- | -------------------------- |
| `0`   | Off (default)              |
| `1`   | Info and warnings          |
| `2`   | Debug (verbose)            |

The log is automatically rotated when it exceeds 1 MB (previous log saved as `debug.log.1`).

## Actualizaciones

Los plugins no se actualizan automáticamente.

- **Via TPM**: `prefix+U` para actualizar (TPM hace `git pull` en `~/.tmux/plugins/tmux-agent-sidebar/`)
- **Local**: `git pull` en el directorio del repo, luego `prefix+M` para recargar

## Probar un branch específico

Si tenés el repo clonado localmente, hacé checkout del branch y el plugin lo toma directamente:

```bash
cd ~/ruta/a/tmux-agent-sidebar
git checkout nombre-del-branch
```

La entrada en `~/.tmux.conf` no cambia.
