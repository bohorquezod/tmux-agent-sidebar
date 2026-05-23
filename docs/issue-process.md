# Issue process

This document describes the full lifecycle of an issue in this repository, from submission to resolution.

## 1. Submission

All issues are submitted via GitHub using one of two templates:

- **Bug report** — for anything that is broken or behaves unexpectedly
- **Feature request** — for new functionality or improvements

Blank issues are disabled. Questions go to [Discussions](https://github.com/bohorquezod/tmux-agent-sidebar/discussions).

See [CONTRIBUTING.md](../CONTRIBUTING.md) for the full label taxonomy and submission guidelines.

## 2. Triage

After submission, the issue is triaged:

- **Type label** is confirmed or corrected (`type:bug`, `type:feature`, `type:design`, `type:docs`)
- **Priority label** is set (`priority:high`, `priority:medium`, `priority:low`)
- **Area label** is added (`area:sidebar`, `area:daemon`, `area:server`, `area:config`)
- If more information is needed, `status:needs-info` is applied and a comment is left asking for it

Triage happens within a few days of submission.

## 3. Design (features and architectural changes only)

Features that affect keybindings, mode behavior, or cross-script architecture require a `type:design` issue to be resolved first. Implementation issues are blocked on the design decision and linked via GitHub's "blocked by" reference.

Example flow:

```
#14 design: command catalog  ←─ blocks ─┬─ #1  feat: search with /
                                         ├─ #2  feat: kill with x
                                         └─ #3  feat: rename with r
```

## 4. Implementation

Once triaged (and unblocked for features), the issue moves to implementation:

1. `status:in-progress` is applied
2. A branch is created: `fix/<issue-number>-short-description` or `feat/<issue-number>-short-description`
3. Changes are tested manually by reloading the plugin with `prefix+M`
4. A PR is opened referencing the issue (`Closes #N`)

## 5. Resolution

- **Bugs**: closed when the fix is merged to `master`
- **Features**: closed when the feature is merged and the acceptance criteria in the issue are met
- **Design issues**: closed when the decision is documented in the issue and the dependent implementation issues are unblocked
- Issues that won't be fixed are closed with `status:wont-fix` and a comment explaining why
