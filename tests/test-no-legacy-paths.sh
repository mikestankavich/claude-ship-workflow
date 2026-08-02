#!/usr/bin/env bash
# The v0.x tree must be gone. Old and new must not coexist.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/test-helpers.sh"

LEGACY="commands scripts presets templates spec csw TESTING.md issues-for-review.md .envrc"

for path in $LEGACY; do
  if [ -e "$REPO_ROOT/$path" ]; then
    FAILURES=$((FAILURES + 1))
    printf 'FAIL legacy path still present: %s\n' "$path" >&2
  else
    PASSES=$((PASSES + 1))
  fi
done

tracked=$(git -C "$REPO_ROOT" ls-files | grep -E '^(commands|scripts|presets|templates|spec|examples/profile-feature)/' || true)
assert_eq "$tracked" "" "no legacy paths tracked in git"

kept="LICENSE CONTRIBUTING.md CODE_OF_CONDUCT.md CHANGELOG.md README.md VERSION docs/design.md"
for path in $kept; do
  if [ -e "$REPO_ROOT/$path" ]; then
    PASSES=$((PASSES + 1))
  else
    FAILURES=$((FAILURES + 1))
    printf 'FAIL kept file missing: %s\n' "$path" >&2
  fi
done

report
