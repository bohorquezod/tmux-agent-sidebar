# Contributing

## Opening an issue

Use issues to report bugs and propose features. For questions or general discussion, use [Discussions](https://github.com/bohorquezod/tmux-agent-sidebar/discussions) instead.

### Before opening

- Search open issues to avoid duplicates
- For bugs: press `prefix+M` to reload the plugin and confirm the issue persists
- For features: check the [roadmap issues](https://github.com/bohorquezod/tmux-agent-sidebar/issues) — your idea may already be tracked

### Which template to use

| Situation                              | Template           |
| -------------------------------------- | ------------------ |
| Something is broken                    | **Bug report**     |
| You want a new feature or improvement  | **Feature request**|
| Architectural or design decision       | Open a blank issue with label `type:design` |

### Labels

Issues are triaged with the following labels:

**Type**

| Label            | Meaning                                   |
| ---------------- | ----------------------------------------- |
| `type:bug`       | Something is not working as expected      |
| `type:feature`   | New feature or improvement                |
| `type:design`    | Architectural or UX design decision       |
| `type:docs`      | Documentation only                        |

**Priority**

| Label             | Meaning                                  |
| ----------------- | ---------------------------------------- |
| `priority:high`   | Blocks usage or causes data loss         |
| `priority:medium` | Noticeable friction, has a workaround    |
| `priority:low`    | Nice to have                             |

**Area**

| Label          | Meaning                                              |
| -------------- | ---------------------------------------------------- |
| `area:sidebar` | `sidebar.sh` — UI, rendering, key handling           |
| `area:daemon`  | `daemon.sh` — data collection, icon detection        |
| `area:server`  | `server-start.sh`, `toggle.sh`, `click.sh`           |
| `area:config`  | Plugin options, keybindings, `tmux-agent-sidebar.tmux` |

**Status**

| Label                | Meaning                              |
| -------------------- | ------------------------------------ |
| `status:needs-info`  | Waiting for more details from author |
| `status:in-progress` | Being actively worked on             |
| `status:blocked`     | Blocked on another issue or decision |

## What happens after you open an issue

1. The issue gets triaged: type, priority, and area labels are applied
2. For bugs: reproduction is confirmed
3. For features: scope and approach are discussed before any implementation starts
4. Issues that depend on a design decision are linked to the relevant `type:design` issue

## Submitting a pull request

### Branch naming

| Change type | Pattern                              | Example                       |
| ----------- | ------------------------------------ | ----------------------------- |
| Bug fix     | `fix/<issue-number>-short-desc`      | `fix/13-hide-cursor-cmd-mode` |
| Feature     | `feat/<issue-number>-short-desc`     | `feat/1-inline-search`        |
| Refactor    | `refactor/<issue-number>-short-desc` | `refactor/16-remove-daemon`   |
| Docs only   | `docs/<short-desc>`                  | `docs/contributing`           |

### Commit messages

Follow [Conventional Commits](https://www.conventionalcommits.org/): `<type>(<scope>): <description>`

```
fix(sidebar): hide cursor indicator when command buffer is active
feat(sidebar): inline session search with /
refactor(daemon): replace polling with reactive tmux hooks
```

Types: `fix`, `feat`, `refactor`, `docs`, `chore` — scopes: `sidebar`, `daemon`, `server`, `config`, `docs`

### PR checklist

- [ ] Linked to an issue with `Closes #N`
- [ ] Tested manually with `prefix+M` reload
- [ ] Scripts are compatible with bash 3.2 (no `mapfile`, no `declare -A`, no `[[ -v var ]]`)
- [ ] `CLAUDE.md` updated if architecture or data formats changed
- [ ] `README.md` updated if user-facing behavior changed

### Merge strategy

- **Squash and merge** for features and fixes
- **Merge commit** for refactors where the commit history is meaningful

See [docs/pr-process.md](./docs/pr-process.md) for the full PR lifecycle.

## Development workflow

See [CLAUDE.md](./CLAUDE.md) for architecture details and the development reload cycle.
