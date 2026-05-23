# Release process

## Versioning

El plugin usa [Semantic Versioning](https://semver.org/) — `MAJOR.MINOR.PATCH`:

| Incremento | Cuándo usarlo                                                               |
| ---------- | --------------------------------------------------------------------------- |
| `MAJOR`    | Cambios que rompen compatibilidad: keybindings renombrados, formato del state file cambiado, opciones `@` eliminadas |
| `MINOR`    | Features nuevas compatibles hacia atrás: nueva acción de teclado, nuevo indicador de estado, nueva opción `@` |
| `PATCH`    | Bug fixes y ajustes visuales sin cambio de comportamiento                   |

## Crear un release

No hay build step. Un release es un tag git + GitHub Release con notas.

**1. Asegurarse de estar en `master` y con todo mergeado**

```bash
git checkout master
git pull origin master
```

**2. Crear el tag**

```bash
git tag v1.2.0
git push origin v1.2.0
```

**3. Crear el GitHub Release**

```bash
gh release create v1.2.0 --title "v1.2.0" --notes "$(cat <<'EOF'
## What's new

- Feature A
- Feature B

## Bug fixes

- Fix C

## Breaking changes

_None_
EOF
)"
```

O desde la UI de GitHub en **Releases → Draft a new release**.

## Instalar una versión específica con TPM

TPM soporta pinear a un tag:

```tmux
set -g @plugin 'bohorquezod/tmux-agent-sidebar'
set -g @plugin_version_bohorquezod/tmux-agent-sidebar 'v1.2.0'
```

Sin la opción de versión, TPM siempre instala el HEAD de la rama principal.

## Backlog y changelog

- Las features pendientes y deudas técnicas se gestionan en `BACKLOG.md`
- Antes de cada release, mover los items completados a un `CHANGELOG.md` (crearlo cuando haya al menos un release)
