#!/usr/bin/env bash
# Every skill must have parseable frontmatter, a description, and must not
# leak project-specific values or contradict the plan's hard rules.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/test-helpers.sh"

SKILLS="$REPO_ROOT/skills"

frontmatter() { sed -n '/^---$/,/^---$/p' "$1" | sed -e '1d' -e '$d'; }
fm_field() { frontmatter "$1" | sed -n "s/^$2: *//p" | head -1; }

# A test file that asserts nothing must never report success: fail loudly if
# skills/ is missing, and fail if it exists but contains zero skill
# directories, rather than letting the loop below iterate zero times and
# report a silent green.
if [ ! -d "$SKILLS" ]; then
  FAILURES=$((FAILURES + 1))
  printf 'FAIL skills/ directory does not exist\n' >&2
fi

skill_count=0
for dir in "$SKILLS"/*/; do
  [ -d "$dir" ] || continue
  skill_count=$((skill_count + 1))
  name=$(basename "$dir")
  file="$dir/SKILL.md"

  if [ -f "$file" ]; then
    PASSES=$((PASSES + 1))
  else
    FAILURES=$((FAILURES + 1))
    printf 'FAIL %s has no SKILL.md\n' "$name" >&2
    continue
  fi

  assert_eq "$(head -1 "$file")" "---" "$name: starts with frontmatter"
  assert_eq "$(fm_field "$file" name)" "$name" "$name: frontmatter name matches its directory"

  desc=$(fm_field "$file" description)
  if [ -n "$desc" ]; then
    PASSES=$((PASSES + 1))
  else
    FAILURES=$((FAILURES + 1))
    printf 'FAIL %s: empty description\n' "$name" >&2
  fi

  # No Trakrf values may leak out of examples/ and docs/ into the skills.
  # Patterns are narrowed to the actual Trakrf values, not generic English:
  # bare "TRA-" false-positives on words like "extra-careful", and bare
  # "just validate" false-positives on ordinary prose about the config key
  # named "validate" that skills legitimately reference by name. "just
  # backend migrate-checksums" is the real gate command that must never leak.
  for leak in "TRA-[0-9]" "just backend migrate-checksums" "trakrf"; do
    if grep -qiE -- "$leak" "$file"; then
      FAILURES=$((FAILURES + 1))
      printf 'FAIL %s: leaks project-specific value: %s\n' "$name" "$leak" >&2
    else
      PASSES=$((PASSES + 1))
    fi
  done
done

if [ "$skill_count" -eq 0 ]; then
  FAILURES=$((FAILURES + 1))
  printf 'FAIL no skill directories found under skills/\n' >&2
fi

# --- work: the hard stop and the tools it must reach for ---
work="$SKILLS/work/SKILL.md"
assert_contains "$(cat "$work")" "csw-ticket normalize" "work: normalises the ticket reference"
assert_contains "$(cat "$work")" "csw-ticket branch" "work: derives the branch name"
assert_contains "$(cat "$work")" "csw-gates" "work: runs diff-triggered gates"
assert_contains "$(cat "$work")" "EnterWorktree" "work: prefers the native worktree tool"
assert_contains "$(cat "$work")" "--draft" "work: knows the draft-PR rule"
assert_contains "$(cat "$work")" "Hold for review is a hard stop" "work: states the hard stop"
if grep -q "gh pr merge" "$work"; then
  FAILURES=$((FAILURES + 1))
  printf 'FAIL work: must never merge\n' >&2
else
  PASSES=$((PASSES + 1))
fi

report
