#!/usr/bin/env bash
# Run every tests/test-*.sh and summarise. Exit non-zero if any file fails.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

for tool in git jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'run-tests: required tool not found: %s\n' "$tool" >&2
    exit 1
  fi
done

failed=0
for t in tests/test-*.sh; do
  [ -f "$t" ] || continue
  printf '\n=== %s ===\n' "$t"
  if bash "$t"; then
    printf 'ok   %s\n' "$t"
  else
    printf 'FAIL %s\n' "$t"
    failed=$((failed + 1))
  fi
done

printf '\n'
if [ "$failed" -gt 0 ]; then
  printf '%d test file(s) failed\n' "$failed"
  exit 1
fi
printf 'all test files passed\n'
