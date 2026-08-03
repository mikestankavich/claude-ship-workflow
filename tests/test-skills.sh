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

  first_line=$(head -1 "$file")
  delim_count=$(grep -c '^---$' "$file" || true)

  assert_eq "$first_line" "---" "$name: starts with frontmatter"

  # Guard the shape before trusting frontmatter()/fm_field(): with only one
  # "---" line, the sed range runs to EOF and body text reads as frontmatter
  # fields. Require an opening "---" on line 1 and a second "---" to close
  # the block; otherwise record the failure and skip parsing this file's
  # fields rather than reading its body as frontmatter.
  if [ "$first_line" != "---" ] || [ "$delim_count" -lt 2 ]; then
    FAILURES=$((FAILURES + 1))
    printf 'FAIL %s: malformed frontmatter block (no closing ---)\n' "$name" >&2
    continue
  fi

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
assert_contains "$(cat "$work")" "No PR means Step 9, not Step 8" "work: Step 7 failures route to Step 9"
assert_contains "$(cat "$work")" "csw-gates --files" \
  "work: Step 6 gates the working tree via --files, not a bare baseBranch diff"
assert_contains "$(cat "$work")" "git status --porcelain" \
  "work: Step 6 feeds uncommitted changes into the gate check, not just the committed diff"
assert_contains "$(cat "$work")" "returning control to the" \
  "work: Step 8's hard stop acknowledges being dispatched from csw:batch"
if grep -q "gh pr merge" "$work"; then
  FAILURES=$((FAILURES + 1))
  printf 'FAIL work: must never merge\n' >&2
else
  PASSES=$((PASSES + 1))
fi

# --- merge: never squash, always check CI, always chain into cleanup ---
merge="$SKILLS/merge/SKILL.md"
assert_contains "$(cat "$merge")" "gh pr checks" "merge: checks CI"
assert_contains "$(cat "$merge")" "gh pr merge" "merge: merges the PR"
assert_contains "$(cat "$merge")" "--merge --delete-branch" "merge: merge commit, delete the branch (local and remote)"
assert_contains "$(cat "$merge")" "csw:cleanup" "merge: chains into cleanup"
assert_contains "$(cat "$merge")" "gh pr view <number> --json state,mergedAt" \
  "merge: re-establishes ground truth on a non-zero gh pr merge exit instead of assuming it failed"
assert_contains "$(cat "$merge")" "git for-each-ref --merged" \
  "merge: cites the mechanism cleanup actually uses to find stale branches"
# The skill may *mention* --squash to forbid it; it must never *use* it.
bad_flags=$(grep "gh pr merge" "$merge" | grep -E -- "--squash|--rebase" || true)
assert_eq "$bad_flags" "" "merge: no gh pr merge line uses --squash or --rebase"
assert_eq "$(fm_field "$merge" 'disable-model-invocation')" "" "merge: stays model-invocable"
assert_contains "$(cat "$merge")" "only ever entered after a confirmed merge" "merge: cleanup gated on a confirmed merge"
assert_contains "$(cat "$merge")" "BLOCKED" "merge: covers mergeStateStatus BLOCKED"

# --- cleanup: sweeps unprompted, asks only about the tracker ---
cleanup="$SKILLS/cleanup/SKILL.md"
assert_contains "$(cat "$cleanup")" "csw-sweep" "cleanup: runs the sweep"
assert_contains "$(cat "$cleanup")" "ExitWorktree" "cleanup: prefers the native worktree exit"
assert_contains "$(cat "$cleanup")" "git worktree remove" "cleanup: removes the worktree"
assert_contains "$(cat "$cleanup")" "git worktree prune" "cleanup: prunes stale registrations"
# The pull must bind both paths, not just the manual fallback — an ExitWorktree cleanup
# that skips it leaves the local base branch behind the merge it just landed.
assert_contains "$(cat "$cleanup")" "on either path" "cleanup: pulls the base branch on both paths"
assert_contains "$(cat "$cleanup")" "not only for the manual path" "cleanup: says the pull is not optional"
assert_contains "$(cat "$cleanup")" "Always ask before closing" "cleanup: never closes a ticket unasked"
assert_contains "$(cat "$cleanup")" "sibling" "cleanup: checks for sibling PRs in other repos"
assert_contains "$(cat "$cleanup")" "never require a separate instruction" "cleanup: branch cleanup is unconditional"
assert_contains "$(cat "$cleanup")" "gh pr view --json state,mergedAt" "cleanup: verifies the PR is merged before removing anything"
assert_contains "$(cat "$cleanup")" "unknown, not absent" "cleanup: a failed sweep is reported distinctly from an empty one"
assert_contains "$(cat "$cleanup")" "the command failing for any reason" "cleanup: any gh pr view failure is a stop, not just a non-merged state"
assert_contains "$(cat "$cleanup")" "already gone" \
  "cleanup: Step 3 treats a worktree ExitWorktree already removed as success, not failure"
# The sweep now reports a merged branch even when it is checked out, which
# `git branch -d` refuses. Cleanup has to know to land on the base first.
assert_contains "$(cat "$cleanup")" "The branch you are standing on" \
  "cleanup: handles a swept branch that is the current branch"
assert_contains "$(cat "$cleanup")" "refuses the checked-out branch" \
  "cleanup: names why the current branch needs landing first, not -D"
# Cleanup exists to leave a clean checkout behind for the next session.
assert_contains "$(cat "$cleanup")" "End on the base branch" \
  "cleanup: states its end state explicitly"
assert_contains "$(cat "$cleanup")" "git branch --show-current      # must be" \
  "cleanup: verifies where it landed rather than assuming"
# ExitWorktree's "will discard N commits" warning fires on essentially every cleanup,
# because cleanup always runs right after a forge-side merge. It must be proven false
# against the remote, never waved through and never stalled on.
assert_contains "$(cat "$cleanup")" "git merge-base --is-ancestor" \
  "cleanup: proves the discard warning false against the remote instead of trusting it"
assert_contains "$(cat "$cleanup")" "Non-zero means the warning is real" \
  "cleanup: a non-zero merge-base check stops the cleanup"
assert_contains "$(cat "$cleanup")" "discard_changes: true" \
  "cleanup: names the flag that must never be passed unverified"
assert_contains "$(cat "$cleanup")" "display only" \
  "cleanup: says the stale branch name in the warning is cosmetic, not a reason to dismiss the count"
# Red flags are where an agent looks when it is about to rationalise. The verification
# rule has to appear there too, not only in the step prose.
red_flags=$(sed -n '/^## Red flags/,$p' "$cleanup")
assert_contains "$red_flags" "merge-base" \
  "cleanup: red flags forbid waving the discard warning through"

# The base pull has to happen *before* ExitWorktree runs, so the tool compares against a
# base branch that already carries the merge. Ordering is the whole point of the change,
# and a needle-anywhere assertion cannot see ordering.
pull_line=$(grep -n 'main_checkout" pull' "$cleanup" | head -1 | cut -d: -f1)
leave_line=$(grep -n '^### Leave the worktree' "$cleanup" | head -1 | cut -d: -f1)
if [ -n "$pull_line" ] && [ -n "$leave_line" ] && [ "$pull_line" -lt "$leave_line" ]; then
  PASSES=$((PASSES + 1))
else
  FAILURES=$((FAILURES + 1))
  printf 'FAIL cleanup: the base pull must precede leaving the worktree (pull at line [%s], exit at line [%s])\n' \
    "${pull_line:-none}" "${leave_line:-none}" >&2
fi
# A dirty main checkout makes the pull fail or conflict; it must be skipped, not forced,
# and its failure must never block a cleanup that Step 1 already verified is safe.
assert_contains "$(cat "$cleanup")" 'git -C "$main_checkout" status --porcelain' \
  "cleanup: guards the pre-exit pull against a dirty main checkout"
assert_contains "$(cat "$cleanup")" "must not block the cleanup" \
  "cleanup: a failed pre-exit pull is reported, not fatal"

# --- batch: never auto-invoked, always explains its skips ---
batch="$SKILLS/batch/SKILL.md"
assert_eq "$(fm_field "$batch" 'disable-model-invocation')" "true" "batch: never model-invoked"
assert_contains "$(cat "$batch")" "csw-batch-filter" "batch: delegates selection"
assert_contains "$(cat "$batch")" "csw:work" "batch: dispatches through the work skill"
assert_contains "$(cat "$batch")" "--draft" "batch: blocked work becomes a draft PR"
assert_contains "$(cat "$batch")" "Morning summary" "batch: reports a morning summary"
# Case-insensitive: the prerequisite reads naturally as a sentence-initial "Backfill", and a
# case-sensitive check here is exactly the kind of assertion that breaks the day someone
# "corrects" the capitalisation back to what reads naturally in prose.
if grep -qi "backfill" "$batch"; then
  PASSES=$((PASSES + 1))
else
  FAILURES=$((FAILURES + 1))
  printf 'FAIL batch: warns about the blocking-relation prerequisite\n' >&2
fi
assert_contains "$(cat "$batch")" "A failed selection is never an empty selection" \
  "batch: a filter failure is reported distinctly from an empty batch"
assert_contains "$(cat "$batch")" "can only lower tonight's cap, never raise it" \
  "batch: the cap override is documented as lower-only"
assert_contains "$(cat "$batch")" "csw-config get batch.maxTickets" \
  "batch: reads the configured cap before evaluating an override"

report
