# Pull request process

This document describes the full lifecycle of a pull request in this repository.

## 1. Branch

Create a branch from `master` following this naming convention:

| Change type   | Pattern                              | Example                          |
| ------------- | ------------------------------------ | -------------------------------- |
| Bug fix       | `fix/<issue-number>-short-desc`      | `fix/13-hide-cursor-cmd-mode`    |
| New feature   | `feat/<issue-number>-short-desc`     | `feat/1-inline-search`           |
| Refactor      | `refactor/<issue-number>-short-desc` | `refactor/16-remove-daemon`      |
| Docs only     | `docs/<short-desc>`                  | `docs/contributing`              |

## 2. Commits

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <short description>

[optional body]
```

**Types**: `fix`, `feat`, `refactor`, `docs`, `chore`

**Scopes**: `sidebar`, `daemon`, `server`, `config`, `docs`

```bash
# Examples
fix(sidebar): hide cursor indicator when command buffer is active
feat(sidebar): inline session search with /
refactor(daemon): replace polling with reactive tmux hooks
docs: add contributing guide and issue templates
```

- One logical change per commit
- Present tense, lowercase, no trailing period

## 3. Opening the PR

- Title follows the same Conventional Commits format as the commit message
- Fill in the PR template: summary, type of change, related issue, and testing notes
- Link the issue with `Closes #N` so it closes automatically on merge
- Open as **Draft** if the change is not ready for review yet

## 4. Review

This is a personal project — review is self-directed. Before merging, confirm:

- The PR template checklist is fully checked
- The change has been tested manually with `prefix+M` reload
- Bash 3.2 compatibility is maintained (no `mapfile`, no `declare -A`, no `[[ -v var ]]`)
- No unrelated changes are included

For architectural changes (`type:design` issues), the design decision must be documented in the issue before the implementation PR is opened.

## 5. Merge

- **Squash and merge** for features and bug fixes — keeps `master` history clean, one commit per issue
- **Merge commit** for refactors that span many logical steps and where the commit history is meaningful
- Delete the branch after merge

## 6. After merge

- The linked issue closes automatically via `Closes #N`
- If the change affects architecture, data formats, or state files: update `CLAUDE.md`
- If the change adds or removes user-facing behavior: update `README.md`
