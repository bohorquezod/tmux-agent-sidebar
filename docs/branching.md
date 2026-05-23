# Branching — Git Flow

Este repo sigue el modelo [Git Flow](https://nvie.com/posts/a-successful-git-branching-model/).

## Ramas permanentes

| Rama      | Propósito                                                   |
| --------- | ----------------------------------------------------------- |
| `master`  | Código en producción. Solo recibe merges de `release/*` y `hotfix/*`. Siempre tiene un tag de versión. |
| `develop` | Rama de integración. Las features se mergean acá antes de ir a producción. |

## Ramas temporales

| Tipo             | Nomenclatura              | Sale de   | Se mergea en              |
| ---------------- | ------------------------- | --------- | ------------------------- |
| Feature          | `feature/descripcion`     | `develop` | `develop`                 |
| Release          | `release/x.x.x`           | `develop` | `master` + `develop`      |
| Hotfix           | `hotfix/descripcion`      | `master`  | `master` + `develop`      |

## Flujo típico

### Feature nueva

```bash
git checkout develop
git checkout -b feature/search-inline
# ... trabajo ...
git checkout develop
git merge --no-ff feature/search-inline
git branch -d feature/search-inline
```

### Release

```bash
git checkout develop
git checkout -b release/1.1.0
# ajustes finales, bump de versión en docs si aplica
git checkout master
git merge --no-ff release/1.1.0
git tag v1.1.0
git push origin master v1.1.0
git checkout develop
git merge --no-ff release/1.1.0
git branch -d release/1.1.0
```

### Hotfix

```bash
git checkout master
git checkout -b hotfix/fix-daemon-lock
# ... fix ...
git checkout master
git merge --no-ff hotfix/fix-daemon-lock
git tag v1.0.1
git push origin master v1.0.1
git checkout develop
git merge --no-ff hotfix/fix-daemon-lock
git branch -d hotfix/fix-daemon-lock
```

## Reglas

- Nunca hacer commits directos en `master` ni en `develop`
- Usar `--no-ff` al mergear para preservar el historial de la rama
- Todo tag va en `master` y sigue el formato `vMAJOR.MINOR.PATCH`
- Las ramas temporales se eliminan después del merge
