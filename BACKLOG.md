# Technical Backlog — tmux-claude-sidebar

> Ideas y mejoras pendientes del plugin. Usar `/meli.backlog` para gestionar.

**Last Updated**: 2026-05-22
**Total Items**: 4 (2 TODO, 0 DEBT, 2 IDEA)

---

## 📋 TODOs

### TODO-001: Limpieza visual del drilldown al salir
- **Priority**: Medium
- **Status**: pending
- **Created**: 2026-05-22
- **Context**: Cuando el usuario ejecuta un comando `N.M` y navega, la transición de vuelta al modo normal puede verse abrupta. Evaluar animación de transición, clear progresivo o fade al volver a la vista completa.
- **Affected Files**: scripts/sidebar.sh (render, _exec_cmd)
- **Complexity**: S

---

### TODO-002: Quitar indicador de selección al entrar en modo comando
- **Priority**: Medium
- **Status**: pending
- **Created**: 2026-05-22
- **Context**: Cuando el usuario empieza a escribir un comando (entra en _CMD_BUF mode), el cursor `›` o `▸` del modo selector sigue visible. En modo comando ese indicador es irrelevante y puede confundir. Debe ocultarse o cambiar de forma al activar el command buffer.
- **Affected Files**: scripts/sidebar.sh (render, handle_key)
- **Complexity**: S

---

## 💡 Ideas

### IDEA-001: Inventario de comandos útiles para el command buffer
- **Priority**: Medium
- **Status**: pending
- **Created**: 2026-05-22
- **Context**: El command buffer (`◈  N.M▌`) solo soporta navegación numérica. Identificar qué otros comandos valdría agregar — posibles candidatos: búsqueda por nombre de sesión (`/brain`), `r` para reload, `q` para cerrar, `:new` para nueva sesión, `:kill` para matar sesión. Definir el catálogo antes de implementar.
- **Potential Impact**: UX, Productividad
- **Notes**: Ver patrones de comandos en tmux nativo (`:`) y vim (`:` / `/`) como referencia.

---

### IDEA-002: Separar modo comando de modo selector con tecla activadora
- **Priority**: High
- **Status**: pending
- **Created**: 2026-05-22
- **Context**: Actualmente los dígitos activan automáticamente el command buffer, lo que hace que `j`, `k`, `r`, etc. funcionen como navegación solo cuando el buffer está vacío. Conflicto potencial al querer teclas de navegación habituales. Evaluar usar `:` (estilo vim/tmux) o `/` para ENTRAR en modo comando explícitamente — así `j/k/r/q` siempre navegan y `:2.1 Enter` navega a sesión 2 ventana 1.
- **Potential Impact**: UX, Consistencia, Extensibilidad
- **Notes**: Decisión arquitectural importante — afecta todos los bindings. Alternativa: mantener dígitos como atajo rápido Y agregar `:` como modo comando completo con más comandos disponibles.

---
