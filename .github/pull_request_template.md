## Summary

<!-- What does this PR do? One or two sentences. -->

## Type of change

- [ ] Bug fix
- [ ] New feature
- [ ] Refactor / cleanup
- [ ] Documentation only

## Related issues

Closes #<!-- issue number -->

## Testing

<!-- How did you verify this works? The test suite is manual — describe what you did. -->

- [ ] Reloaded the plugin with `prefix+M` and confirmed the change works
- [ ] Tested the affected keybindings / interactions
- [ ] Verified no regressions in adjacent behavior (navigation, unread tracking, multi-server display)

## Checklist

- [ ] Scripts are compatible with bash 3.2 (no `mapfile`, no `declare -A`, no `[[ -v var ]]`)
- [ ] State files in `$STATE_DIR` are cleaned up on exit if created by this change
- [ ] CLAUDE.md or docs updated if the architecture or data formats changed
