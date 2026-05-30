#!/usr/bin/env bash
# run_tests.sh — runner that executes all .bats test files

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BATS="${REPO_ROOT}/tests/bats/bin/bats"
[[ ! -x "$BATS" ]] && BATS="$(command -v bats 2>/dev/null)"
if [[ -z "$BATS" ]]; then
  printf 'ERROR: bats not found. Run: brew install bats-core\n' >&2
  exit 1
fi

if command -v shellcheck &>/dev/null; then
  shellcheck "$REPO_ROOT"/scripts/*.sh "$REPO_ROOT"/scripts/lib/*.sh
fi

"$BATS" "$REPO_ROOT/tests/"*.bats
