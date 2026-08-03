#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/test-helpers.sh"

readme="$REPO_ROOT/README.md"
config_doc="$REPO_ROOT/docs/configuration.md"
example="$REPO_ROOT/examples/csw.json"

assert_contains "$(cat "$readme")" "Claude Ship Workflow" "README uses the new name"
if grep -q "Claude Spec Workflow" "$readme"; then
  FAILURES=$((FAILURES + 1)); printf 'FAIL README still says Claude Spec Workflow\n' >&2
else
  PASSES=$((PASSES + 1))
fi
for phrase in "not yours" "unmaintained" "/csw:work" "/csw:merge" "/csw:cleanup" "/csw:batch"; do
  assert_contains "$(cat "$readme")" "$phrase" "README mentions $phrase"
done
for gone in "/csw:spec" "/csw:plan" "/csw:build" "/csw:ship"; do
  if grep -q -- "$gone" "$readme"; then
    FAILURES=$((FAILURES + 1)); printf 'FAIL README still advertises %s\n' "$gone" >&2
  else
    PASSES=$((PASSES + 1))
  fi
done

# Every default key must be documented, including the nested batch keys.
repo=$(make_repo)
top_keys=$(in_dir "$repo" "$BIN/csw-config" json | jq -r 'keys[]')
batch_keys=$(in_dir "$repo" "$BIN/csw-config" json | jq -r '.batch | keys[] | "batch." + .')
for key in $top_keys $batch_keys; do
  assert_contains "$(cat "$config_doc")" "$key" "configuration.md documents $key"
done

if jq -e . "$example" >/dev/null 2>&1; then
  PASSES=$((PASSES + 1))
else
  FAILURES=$((FAILURES + 1)); printf 'FAIL examples/csw.json is not valid JSON\n' >&2
fi

# This repo dogfoods its own config, and it must be committed.
own="$REPO_ROOT/.claude/csw.json"
if jq -e . "$own" >/dev/null 2>&1; then
  PASSES=$((PASSES + 1))
else
  FAILURES=$((FAILURES + 1)); printf 'FAIL .claude/csw.json is missing or invalid\n' >&2
fi
tracked=$(git -C "$REPO_ROOT" ls-files --error-unmatch .claude/csw.json 2>/dev/null || true)
assert_eq "$tracked" ".claude/csw.json" ".claude/csw.json is tracked, not gitignored"
ignored=$(git -C "$REPO_ROOT" check-ignore .claude/worktrees 2>/dev/null || true)
assert_eq "$ignored" ".claude/worktrees" ".claude/worktrees stays ignored"

assert_contains "$(cat "$REPO_ROOT/CHANGELOG.md")" "1.0.0" "CHANGELOG has a 1.0.0 entry"

report
