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

# A worktree path containing a literal TAB cannot be represented in the
# <path><TAB><branch> output contract. csw-sweep must fail loudly (exit 2,
# naming the offending path) instead of silently truncating or dropping it.
tabrepo=$(make_repo)
write_config "$tabrepo" <<'JSON'
{ "baseBranch": "main", "worktreeDir": ".claude/worktrees" }
JSON
tab_worktree_ok=1
(
  cd "$tabrepo" || exit 1
  git checkout -q -b feat/tabpath
  printf 'x\n' >x.txt
  git add -A && git commit -qm "tabpath work"
  git checkout -q main
  git merge -q --no-ff -m "merge feat/tabpath" feat/tabpath
  mkdir -p "$tabrepo/.claude/worktrees"
  git worktree add -q "$tabrepo/.claude/worktrees/has$(printf '\t')tab" feat/tabpath
) || tab_worktree_ok=0
if [ "$tab_worktree_ok" -eq 1 ]; then
  tab_out=$(cd "$tabrepo" && "$BIN/csw-sweep" worktrees 2>&1)
  tab_status=$?
  assert_eq "$tab_status" "2" \
    "a TAB in a worktree path exits 2 instead of silently mis-parsing it"
  assert_contains "$tab_out" "TAB" "TAB error message names the problem as a TAB"
  assert_contains "$tab_out" "worktrees/has" "TAB error message names the offending path"
else
  printf 'SKIP: this filesystem/git refused a worktree path containing a literal TAB; skipping the TAB-path test\n' >&2
fi

# A bare repo has no working tree. csw-sweep must fail with its own message
# (not csw-config's "not in a git repository", which is misleading for a bare
# repo -- it IS a repository, just one without a working tree) and a
# non-zero exit, while a normal empty-but-not-bare repo still sweeps to
# "nothing to sweep" and exits 0 (covered above).
barerepo=$(mktemp -d)
TMPDIRS+=("$barerepo")
git init -q -b main --bare "$barerepo" >/dev/null
bare_out=$(cd "$barerepo" && "$BIN/csw-sweep" branches 2>&1)
bare_status=$?
assert_eq "$bare_status" "1" "a bare repo makes csw-sweep exit non-zero, not 0"
assert_contains "$bare_out" "working tree" "bare repo error names the missing working tree"
case "$bare_out" in
  *"not in a git repository"*)
    assert_eq "leaked-csw-config-wording" "csw-sweep-message-only" \
      "bare repo error must not leak csw-config's own wording" ;;
  *) PASSES=$((PASSES + 1)) ;;
esac

# Discriminating regression for the `worktrees` path specifically: a worktree
# on an UNMERGED branch named with a `.` must never be swept, even though an
# unrelated MERGED branch's name happens to match it when misused as an
# unescaped regex (feat/a.b as a BRE pattern also matches feat/aXb). This
# exercises grep -Fqx inside stale_worktrees; the branches-side dot case is
# covered separately above.
wtdotrepo=$(make_repo)
write_config "$wtdotrepo" <<'JSON'
{ "baseBranch": "main", "worktreeDir": ".claude/worktrees" }
JSON
(
  cd "$wtdotrepo" || exit 1
  git checkout -q -b feat/aXb
  printf 'x\n' >x.txt
  git add -A && git commit -qm "aXb work"
  git checkout -q main
  git merge -q --no-ff -m "merge feat/aXb" feat/aXb

  git checkout -q -b feat/a.b
  printf 'y\n' >y.txt
  git add -A && git commit -qm "a.b unmerged work"
  git checkout -q main

  git worktree add -q "$wtdotrepo/.claude/worktrees/dotwt" feat/a.b
)
wtdot_worktrees=$(cd "$wtdotrepo" && "$BIN/csw-sweep" worktrees)
case "$wtdot_worktrees" in
  *dotwt*)
    assert_eq "unmerged-dotted-worktree-swept" "not-swept" \
      "a worktree on an unmerged dotted branch must not be swept, even though its name regex-matches an unrelated merged branch" ;;
  *) PASSES=$((PASSES + 1)) ;;
esac

# --- The local base branch is behind its upstream -----------------------------
#
# The normal state on a machine where PRs are merged on the forge rather than
# locally: `main` is stale, so a branch that genuinely shipped is not merged
# into the *local* base and used to be invisible to the sweep entirely.
#
# make_upstream_clone prints the path of a fresh clone of an origin whose
# `main` carries a `--no-ff` merge of `feat/already-merged` plus a later
# commit. In the clone: `feat/already-merged` exists as a local branch with no
# upstream of its own (so the `[gone]` path cannot be what reports it), an
# unrelated `feat/never-merged` exists, and local `main` is reset back to the
# pre-merge commit — three commits behind `origin/main`.
make_upstream_clone() {
  local origin base0 parent clone
  origin=$(make_repo)
  base0=$(git -C "$origin" rev-parse HEAD)
  (
    cd "$origin" || exit 1
    git checkout -q -b feat/already-merged
    printf 'm\n' >m.txt
    git add -A && git commit -qm "work that shipped via a PR"
    git checkout -q main
    git merge -q --no-ff -m "merge feat/already-merged" feat/already-merged
    printf 'more\n' >more.txt
    git add -A && git commit -qm "later work on main"
  ) || return 1
  parent=$(mktemp -d)
  TMPDIRS+=("$parent")
  clone="$parent/work"
  git clone -q "$origin" "$clone" || return 1
  write_config "$clone" <<'JSON'
{ "baseBranch": "main", "worktreeDir": ".claude/worktrees" }
JSON
  (
    cd "$clone" || exit 1
    git config user.email test@example.com
    git config user.name "CSW Test"
    git config commit.gpgsign false
    # --no-track: this branch must have no upstream, so `[gone]` cannot be the
    # reason it gets swept. Only the upstream-merged union can report it.
    git branch --no-track feat/already-merged origin/feat/already-merged
    git checkout -q -b feat/never-merged
    printf 'n\n' >n.txt
    git add -A && git commit -qm "work still in flight"
    git checkout -q main
    git reset -q --hard "$base0"
  ) || return 1
  printf '%s\n' "$clone"
}

behind=$(make_upstream_clone) || behind=""
if [ -z "$behind" ]; then
  FAILURES=$((FAILURES + 1))
  printf 'FAIL could not build the behind-upstream fixture\n' >&2
else
  git -C "$behind" worktree add -q "$behind/.claude/worktrees/shipped" feat/already-merged

  behind_branches=$(cd "$behind" && "$BIN/csw-sweep" branches)
  assert_contains "$behind_branches" "feat/already-merged" \
    "a branch merged into origin/<base> but not local <base> is swept"
  case "$behind_branches" in
    *feat/never-merged*)
      assert_eq "unmerged-listed" "not-listed" \
        "a branch merged into neither local nor upstream base is not swept" ;;
    *) PASSES=$((PASSES + 1)) ;;
  esac
  case "$behind_branches" in
    *main*)
      assert_eq "base-listed" "not-listed" \
        "the base branch is not swept just because it is an ancestor of its upstream" ;;
    *) PASSES=$((PASSES + 1)) ;;
  esac

  behind_worktrees=$(cd "$behind" && "$BIN/csw-sweep" worktrees)
  assert_contains "$behind_worktrees" "worktrees/shipped" \
    "a worktree holding a branch merged only upstream is swept too"

  # A stale local base must be visible in the report, so a silent answer is
  # distinguishable from a stale one.
  behind_report=$(cd "$behind" && "$BIN/csw-sweep")
  assert_contains "$behind_report" "behind" "the report says the local base is behind"
  assert_contains "$behind_report" "origin/main" "the report names the upstream it is behind"

  # Read-only: reporting must not fetch, move refs, or touch the working tree.
  before=$(cd "$behind" && git for-each-ref --format='%(refname) %(objectname)' | sort)
  (cd "$behind" && "$BIN/csw-sweep" >/dev/null)
  after=$(cd "$behind" && git for-each-ref --format='%(refname) %(objectname)' | sort)
  assert_eq "$after" "$before" "the sweep does not move any ref"
fi

# No upstream configured on the base: behave exactly as before the fix — the
# upstream-merged branch is invisible, and no staleness note is emitted.
noup=$(make_upstream_clone) || noup=""
if [ -z "$noup" ]; then
  FAILURES=$((FAILURES + 1))
  printf 'FAIL could not build the no-upstream fixture\n' >&2
else
  git -C "$noup" branch --unset-upstream main
  noup_branches=$(cd "$noup" && "$BIN/csw-sweep" branches)
  case "$noup_branches" in
    *feat/already-merged*)
      assert_eq "swept-without-upstream" "not-swept" \
        "with no upstream on the base, the upstream-merged branch stays invisible" ;;
    *) PASSES=$((PASSES + 1)) ;;
  esac
  noup_report=$(cd "$noup" && "$BIN/csw-sweep")
  assert_contains "$noup_report" "nothing to sweep" \
    "with no upstream on the base, the report is unchanged"
  case "$noup_report" in
    *behind*)
      assert_eq "note-without-upstream" "no-note" \
        "no upstream means no staleness note" ;;
    *) PASSES=$((PASSES + 1)) ;;
  esac
fi

# Base level with its upstream: the branch is swept via the local base as it
# always was, and the staleness note must not fire spuriously.
level=$(make_upstream_clone) || level=""
if [ -z "$level" ]; then
  FAILURES=$((FAILURES + 1))
  printf 'FAIL could not build the level-with-upstream fixture\n' >&2
else
  git -C "$level" merge -q --ff-only origin/main
  level_report=$(cd "$level" && "$BIN/csw-sweep")
  assert_contains "$level_report" "feat/already-merged" \
    "an up-to-date base still sweeps its merged branches"
  case "$level_report" in
    *behind*)
      assert_eq "note-when-level" "no-note" \
        "a base level with its upstream produces no staleness note" ;;
    *) PASSES=$((PASSES + 1)) ;;
  esac
fi

report
