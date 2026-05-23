# tmux-agent-sidebar

Sidebar para tmux que muestra todas las sesiones y ventanas de todos los servidores tmux activos, con indicadores de estado de Claude Code en cada ventana.

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

## Status bar token

El plugin expone un token compacto con conteos de actividad de agentes para
integrar en el `status-right` (u otro componente) del status bar de tmux.

**Formato**: `⚡N ⏸N ◉N` — los conteos de cero se omiten.

| Símbolo | Significado        |
| ------- | ------------------ |
| `⚡N`   | N agentes working  |
| `⏸N`   | N agentes idle     |
| `◉N`   | N ventanas unread  |

Ejemplos de output: `⚡2 ⏸1`, `⏸3 ◉1`, `⚡1` (vacío cuando no hay agentes activos).

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

Útil si se quiere usar el token sin tener el sidebar abierto:

```tmux
set -g status-right "#(~/path/to/tmux-agent-sidebar/scripts/summary.sh) %H:%M"
```

`scripts/summary.sh` lee el data file del daemon directamente y no requiere
conexión con ningún proceso adicional.

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
