#!/usr/bin/env bash
# Shared assertions and fixtures. Source this at the top of every test file.

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# Used by the test files that source this library; shellcheck cannot see across `source`.
# shellcheck disable=SC2034
BIN="$REPO_ROOT/bin"
PASSES=0
FAILURES=0
TMPDIRS=()

cleanup_tmpdirs() {
  local d
  for d in "${TMPDIRS[@]:-}"; do
    [ -n "$d" ] || continue
    chmod -R u+w "$d" 2>/dev/null
    rm -rf "$d"
  done
}
trap cleanup_tmpdirs EXIT

assert_eq() { # actual expected label
  if [ "$1" = "$2" ]; then
    PASSES=$((PASSES + 1))
  else
    FAILURES=$((FAILURES + 1))
    printf 'FAIL %s\n  expected: [%s]\n  actual:   [%s]\n' "$3" "$2" "$1" >&2
  fi
}

assert_contains() { # haystack needle label
  case "$1" in
    *"$2"*) PASSES=$((PASSES + 1)) ;;
    *)
      FAILURES=$((FAILURES + 1))
      printf 'FAIL %s\n  expected to contain: [%s]\n  actual: [%s]\n' "$3" "$2" "$1" >&2
      ;;
  esac
}

# assert_guards <file> <region-start> <region-end> <needle> <label>
#
# A *guard* claims to protect a specific documented behaviour, and its whole
# job is to go red when that behaviour is removed. `assert_contains` against a
# whole file does not do that on its own: if the needle also occurs somewhere
# the behaviour does not live, reverting the behaviour leaves the needle behind
# and the assertion stays green. That is #69 — `already gone` was asserted
# against all of skills/cleanup/SKILL.md, and the file's unrelated "The remote
# branch is already gone…" sentence kept it passing with the fix reverted.
#
# assert_guards scopes the needle to the region of the file that documents the
# behaviour. Revert the behaviour and the region goes with it, so the
# extraction comes back empty and the assertion fails.
#
# `<region-start>` and `<region-end>` are sed address regexes, matched against
# whole lines of <file>. They are deliberately free-form rather than heading
# names: on skills/cleanup/SKILL.md the unrelated sentence sits *inside* Step
# 3's own section, so a region at heading granularity still contains it. A
# region has to be able to name a single bullet.
#
# Use this for assertions that guard a behaviour. A presence check — "the
# README mentions X at all" — has no fix to revert and no region to scope to,
# so plain assert_contains remains the right tool there.
assert_guards() {
  local file=$1 start=$2 end=$3 needle=$4 label=$5 region

  if [ ! -f "$file" ]; then
    FAILURES=$((FAILURES + 1))
    printf 'FAIL %s\n  no such file: [%s]\n' "$label" "$file" >&2
    return
  fi

  region=$(sed -n "/$start/,/$end/p" "$file")

  # An empty extraction means the region start never matched — which is exactly
  # what a revert of the guarded behaviour looks like.
  if [ -z "$region" ]; then
    FAILURES=$((FAILURES + 1))
    printf 'FAIL %s\n  region start never matched: [%s] in %s\n' "$label" "$start" "$file" >&2
    return
  fi

  # If the start matches but the end never does, sed runs the range to EOF and
  # the "region" quietly becomes the rest of the file — the scoping is gone and
  # the assertion is a whole-file check again, without looking like one. Require
  # the extraction to actually terminate on <region-end>. (test-skills.sh guards
  # its frontmatter extraction against the same run-to-EOF failure.)
  if ! printf '%s\n' "$region" | tail -1 | grep -qE "$end"; then
    FAILURES=$((FAILURES + 1))
    printf 'FAIL %s\n  region end never matched: [%s] in %s — extraction ran to EOF\n' \
      "$label" "$end" "$file" >&2
    return
  fi

  assert_contains "$region" "$needle" "$label"
}

assert_status() { # expected-code label -- command...
  local expected=$1 label=$2 actual
  shift 3 # drop expected, label, and the literal --
  "$@" >/dev/null 2>&1
  actual=$?
  assert_eq "$actual" "$expected" "$label"
}

# Run a command in a directory, in a subshell. `env -C` would be shorter but is
# GNU-only — BSD env on macOS does not have it.
in_dir() { # dir command...
  local dir=$1
  shift
  (cd "$dir" && "$@")
}

report() {
  printf '%d passed, %d failed\n' "$PASSES" "$FAILURES"
  [ "$FAILURES" -eq 0 ]
}

# Create a throwaway git repo with one commit on main. Prints its path.
make_repo() {
  local dir
  dir=$(mktemp -d)
  TMPDIRS+=("$dir")
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email test@example.com
  git -C "$dir" config user.name "CSW Test"
  git -C "$dir" config commit.gpgsign false
  printf 'seed\n' >"$dir/README.md"
  git -C "$dir" add -A
  git -C "$dir" commit -qm seed
  printf '%s\n' "$dir"
}

# write_config <repo-dir>  — reads the JSON body from stdin
write_config() {
  mkdir -p "$1/.claude"
  cat >"$1/.claude/csw.json"
}
