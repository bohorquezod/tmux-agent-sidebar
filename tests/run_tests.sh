#!/usr/bin/env bash
# run_tests.sh — runner that executes all .bats test files

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BATS="${REPO_ROOT}/tests/bats/bin/bats"
[[ ! -x "$BATS" ]] && BATS="$(command -v bats 2>/dev/null)"
if [[ -z "$BATS" ]]; then
  printf 'ERROR: bats not found. Run: brew install bats-core\n' >&2
  exit 1
fi

SHFMT="$(command -v shfmt 2>/dev/null)"
if [[ -n "$SHFMT" ]]; then
  printf 'shfmt check...\n'
  if ! "$SHFMT" -i 2 -ci -bn -d "${REPO_ROOT}/scripts/" 2>&1; then
    printf 'ERROR: shfmt check failed. Run: shfmt -i 2 -ci -bn -w scripts/\n' >&2
    exit 1
  fi
  printf 'shfmt ok\n'
fi

if command -v shellcheck &>/dev/null; then
  shellcheck "$REPO_ROOT"/scripts/*.sh "$REPO_ROOT"/scripts/lib/*.sh
fi

"$BATS" "$REPO_ROOT/tests/"*.bats
