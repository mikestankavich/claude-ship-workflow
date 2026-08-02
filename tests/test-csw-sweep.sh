#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/test-helpers.sh"

repo=$(make_repo)
write_config "$repo" <<'JSON'
{ "baseBranch": "main", "worktreeDir": ".claude/worktrees" }
JSON
cd "$repo" || exit 1

# A merged branch and an unmerged one.
git checkout -q -b feat/merged
printf 'merged\n' >merged.txt
git add -A && git commit -qm "merged work"
git checkout -q main
git merge -q --no-ff -m "merge feat/merged" feat/merged

git checkout -q -b feat/unmerged
printf 'wip\n' >wip.txt
git add -A && git commit -qm "work in progress"
git checkout -q main

branches=$("$BIN/csw-sweep" branches)
assert_contains "$branches" "feat/merged" "merged branch is swept"
case "$branches" in
  *feat/unmerged*) assert_eq "unmerged-listed" "not-listed" "unmerged branch must not be swept" ;;
  *) PASSES=$((PASSES + 1)) ;;
esac
case "$branches" in
  *main*) assert_eq "base-listed" "not-listed" "base branch must not be swept" ;;
  *) PASSES=$((PASSES + 1)) ;;
esac

# The current branch is never swept, even when it is merged.
git checkout -q feat/merged
assert_eq "$("$BIN/csw-sweep" branches | grep -c 'feat/merged' || true)" "0" \
  "current branch is never swept"
git checkout -q main

# A worktree holding a merged branch shows up; one holding unmerged work does not.
git worktree add -q "$repo/.claude/worktrees/merged" feat/merged
git worktree add -q "$repo/.claude/worktrees/unmerged" feat/unmerged
worktrees=$("$BIN/csw-sweep" worktrees)
assert_contains "$worktrees" "worktrees/merged" "worktree on a merged branch is swept"
# Exactly one line: not the unmerged worktree, and not the main worktree.
assert_eq "$(printf '%s' "$worktrees" | grep -c . || true)" "1" \
  "only the merged worktree is swept"

# A clean repo sweeps to nothing, and still exits 0.
clean=$(make_repo)
assert_eq "$(cd "$clean" && "$BIN/csw-sweep" branches)" "" "clean repo has no branches to sweep"
assert_contains "$(cd "$clean" && "$BIN/csw-sweep")" "nothing to sweep" "clean repo reports nothing to sweep"
assert_status 0 "clean sweep exits 0" -- in_dir "$clean" "$BIN/csw-sweep"

# A `.` in the current branch name must not act as a regex wildcard and
# swallow an unrelated merged branch (feat/a.b as current used to hide
# feat/aXb, because grep -vx treated the current branch as a pattern).
dotrepo=$(make_repo)
write_config "$dotrepo" <<'JSON'
{ "baseBranch": "main", "worktreeDir": ".claude/worktrees" }
JSON
(
  cd "$dotrepo" || exit 1
  git checkout -q -b feat/a.b
  printf 'ab\n' >ab.txt
  git add -A && git commit -qm "a.b work"
  git checkout -q main
  git merge -q --no-ff -m "merge feat/a.b" feat/a.b

  git checkout -q -b feat/aXb
  printf 'axb\n' >axb.txt
  git add -A && git commit -qm "aXb work"
  git checkout -q main
  git merge -q --no-ff -m "merge feat/aXb" feat/aXb

  git checkout -q feat/a.b
)
dot_branches=$(cd "$dotrepo" && "$BIN/csw-sweep" branches)
assert_contains "$dot_branches" "feat/aXb" \
  "a dot in the current branch name does not swallow an unrelated merged branch"

# A branch name with a `+` (also special to regexes) round-trips correctly
# through both `branches` and `worktrees`.
plusrepo=$(make_repo)
write_config "$plusrepo" <<'JSON'
{ "baseBranch": "main", "worktreeDir": ".claude/worktrees" }
JSON
(
  cd "$plusrepo" || exit 1
  git checkout -q -b "feat/a+b"
  printf 'plus\n' >plus.txt
  git add -A && git commit -qm "a+b work"
  git checkout -q main
  git merge -q --no-ff -m "merge feat/a+b" "feat/a+b"
  git worktree add -q "$plusrepo/.claude/worktrees/plus" "feat/a+b"
)
plus_branches=$(cd "$plusrepo" && "$BIN/csw-sweep" branches)
assert_contains "$plus_branches" "feat/a+b" "a + in a branch name round-trips through branches"
plus_worktrees=$(cd "$plusrepo" && "$BIN/csw-sweep" worktrees)
assert_contains "$plus_worktrees" "worktrees/plus" "a + in a branch name round-trips through worktrees (path)"
assert_contains "$plus_worktrees" "feat/a+b" "a + in a branch name round-trips through worktrees (branch)"

# HEAD detached in the main worktree must not leak the synthetic
# "(HEAD detached at ...)" pseudo-entry into `branches` output, and
# `worktrees` output must still parse as exactly <path><TAB><branch>.
detrepo=$(make_repo)
write_config "$detrepo" <<'JSON'
{ "baseBranch": "main", "worktreeDir": ".claude/worktrees" }
JSON
(
  cd "$detrepo" || exit 1
  git checkout -q -b feat/detected
  printf 'd\n' >d.txt
  git add -A && git commit -qm "detected work"
  git checkout -q main
  git merge -q --no-ff -m "merge feat/detected" feat/detected
  git worktree add -q "$detrepo/.claude/worktrees/detected" feat/detected
  git checkout -q --detach main
)
det_branches=$(cd "$detrepo" && "$BIN/csw-sweep" branches)
assert_contains "$det_branches" "feat/detected" \
  "detached HEAD in the main worktree still sweeps real merged branches"
case "$det_branches" in
  *"HEAD detached"*)
    assert_eq "leaked-pseudo-entry" "no-pseudo-entry" \
      "detached HEAD must not leak a pseudo branch-name line into branches" ;;
  *) PASSES=$((PASSES + 1)) ;;
esac

det_worktrees=$(cd "$detrepo" && "$BIN/csw-sweep" worktrees)
assert_contains "$det_worktrees" "worktrees/detected" \
  "worktree on a merged branch is still swept when main HEAD is detached"
case "$det_worktrees" in
  *"HEAD detached"*)
    assert_eq "leaked-pseudo-entry-worktrees" "no-pseudo-entry" \
      "worktrees output must not contain a HEAD-detached pseudo-entry" ;;
  *) PASSES=$((PASSES + 1)) ;;
esac
badfields=$(printf '%s\n' "$det_worktrees" | awk -F'\t' 'NF && NF != 2 { c++ } END { print c + 0 }')
assert_eq "$badfields" "0" \
  "worktrees output parses as exactly <path><TAB><branch> when main HEAD is detached"

report
