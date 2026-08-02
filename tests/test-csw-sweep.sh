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

report
