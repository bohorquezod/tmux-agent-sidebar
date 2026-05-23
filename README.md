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
