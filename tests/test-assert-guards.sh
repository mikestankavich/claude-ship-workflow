#!/usr/bin/env bash
# Tests for assert_guards, the region-scoped assertion in test-helpers.sh.
#
# assert_guards exists because a whole-file `assert_contains` does not
# necessarily guard anything. If the needle also occurs somewhere the guarded
# behaviour does not live, reverting that behaviour leaves the needle behind and
# the assertion stays green — a guard that cannot go red. That is #69.
#
# The property assert_guards adds is: the needle must be found *inside the
# region of the file that documents the behaviour*. Revert the behaviour and the
# region goes with it, the extraction comes back empty, and the assertion fails.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/test-helpers.sh"

# Run assert_guards in a subshell and report only whether it passed, so its
# effect on the counters stays inside the subshell and does not pollute this
# file's own tally. The subshell prints the FAILURES it ended with; comparing
# that to ours tells us which way it went.
guard_result() { # file start end needle label -> "pass" | "fail"
  local ended_at
  ended_at=$(
    assert_guards "$@" 2>/dev/null
    printf '%s' "$FAILURES"
  )
  if [ "$ended_at" = "$FAILURES" ]; then printf 'pass\n'; else printf 'fail\n'; fi
}

fixture=$(mktemp -d)
TMPDIRS+=("$fixture")
doc="$fixture/doc.md"
cat >"$doc" <<'EOF'
## Step 3: Remove it

- **The native tool already removed it.** Running the command again fails with
  `is not a working tree` — that is success, not a problem to report.

- **The manual path was used.** The thing is still there, so remove it first.

The remote branch is already gone if the merge used `--delete-branch`.
EOF

start='^- \*\*The native tool already removed it\.\*\*'
end='^- \*\*The manual path was used\.\*\*'

# The needle lives inside the region: the ordinary passing case.
assert_eq "$(guard_result "$doc" "$start" "$end" 'is not a working tree' l)" "pass" \
  "assert_guards: passes when the needle is inside the region"

# Absent from the file entirely — no different from assert_contains.
assert_eq "$(guard_result "$doc" "$start" "$end" 'nowhere in this file' l)" "fail" \
  "assert_guards: fails when the needle is absent from the file"

# The #69 case in miniature. `already gone` is in the file, but in the unrelated
# remote-branch sentence, not in the region the guard claims to protect. A
# whole-file assert_contains passes here; assert_guards must not.
assert_eq "$(guard_result "$doc" "$start" "$end" 'already gone' l)" "fail" \
  "assert_guards: fails when the needle is in the file but outside the region"

# The revert. The bullet the guard protects is gone, so the region start no
# longer matches and the extraction is empty. This is the property that makes
# the guard bite, checked on every run rather than proved once by hand.
reverted="$fixture/reverted.md"
grep -v 'is not a working tree' "$doc" | grep -v '^- \*\*The native tool already removed it' >"$reverted"
assert_eq "$(guard_result "$reverted" "$start" "$end" 'is not a working tree' l)" "fail" \
  "assert_guards: fails when the region it scopes to no longer exists"

# A start that matches with no end that does makes sed run the range to EOF, so
# the "region" silently becomes the rest of the file and the scoping is lost.
# That is the same failure mode test-skills.sh guards against when it requires a
# closing `---` before trusting a frontmatter extraction. Fail loudly instead.
assert_eq "$(guard_result "$doc" "$start" '^## Step 4' 'already gone' l)" "fail" \
  "assert_guards: fails when the region end never matches rather than running to EOF"

report
