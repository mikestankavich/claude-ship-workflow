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
