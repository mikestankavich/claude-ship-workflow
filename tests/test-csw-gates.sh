#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/test-helpers.sh"

repo=$(make_repo)
write_config "$repo" <<'JSON'
{
  "gates": [
    { "when": "migrations/**",     "run": "just backend migrate-checksums" },
    { "when": "**/migrations/**",  "run": "just backend migrate-checksums" },
    { "when": "web/**/*.tsx",      "run": "just playwright-preview" },
    { "when": "*.sql",             "run": "just sql-lint" }
  ]
}
JSON
cd "$repo" || exit 1

gates() { printf '%s\n' "$@" | "$BIN/csw-gates" --files; }

assert_eq "$(gates migrations/0042_add_col.sql)" "just backend migrate-checksums" "top-level migrations dir"
assert_eq "$(gates migrations/sub/0043.sql)" "just backend migrate-checksums" "** crosses slashes"
assert_eq "$(gates backend/migrations/0044.sql)" "just backend migrate-checksums" "nested migrations dir"
assert_eq "$(gates src/migrations.ts)" "" "similarly named file does not match"
assert_eq "$(gates web/app/nav/Menu.tsx)" "just playwright-preview" "glob with an extension"
assert_eq "$(gates web/app/nav/Menu.ts)" "" "wrong extension does not match"
assert_eq "$(gates schema.sql)" "just sql-lint" "* stays within one segment"
assert_eq "$(gates db/schema.sql)" "" "* does not cross a slash"
assert_eq "$(gates README.md)" "" "no matches produces no output"
assert_status 0 "no matches still exits 0" -- sh -c "printf 'README.md\n' | '$BIN/csw-gates' --files"

# Two gates, same command: report it once.
assert_eq "$(gates migrations/0042.sql backend/migrations/0043.sql)" \
  "just backend migrate-checksums" "duplicate commands are deduped"

# Multiple distinct gates come out in config order.
both=$(gates migrations/0042.sql web/app/nav/Menu.tsx)
assert_eq "$both" "just backend migrate-checksums
just playwright-preview" "distinct gates in config order"

# Diff mode against a base ref.
git -C "$repo" checkout -q -b feat/probe
mkdir -p "$repo/migrations"
printf 'select 1;\n' >"$repo/migrations/0042.sql"
git -C "$repo" add -A
git -C "$repo" commit -qm "add migration"
assert_eq "$("$BIN/csw-gates" main)" "just backend migrate-checksums" "diff mode against a base ref"

# No gates configured at all.
empty=$(make_repo)
assert_eq "$(cd "$empty" && printf 'migrations/x.sql\n' | "$BIN/csw-gates" --files)" "" "no gates configured"

# Literal metacharacters and a literal backslash in `when`, plus dedup edge cases
# around `run` values that themselves contain a `|`, and true duplicate `run`
# strings. See fix round 1 in task-5-report.md for why these were added.
meta=$(make_repo)
write_config "$meta" <<'JSON'
{
  "gates": [
    { "when": "a+b/**",       "run": "cmd-plus" },
    { "when": "file(1).txt",  "run": "cmd-paren" },
    { "when": "x[0-9].sql",   "run": "cmd-bracket" },
    { "when": "back\\slash",  "run": "cmd-backslash" },
    { "when": "pipe/one",     "run": "echo foo|bar" },
    { "when": "pipe/two",     "run": "bar" },
    { "when": "dup/one",      "run": "cmd-dup" },
    { "when": "dup/two",      "run": "cmd-dup" }
  ]
}
JSON
cd "$meta" || exit 1
metagates() { printf '%s\n' "$@" | "$BIN/csw-gates" --files; }

assert_eq "$(metagates 'a+b/foo')" "cmd-plus" "literal + is matched literally"
assert_eq "$(metagates 'aXb/foo')" "" "+ is not a regex quantifier"
assert_eq "$(metagates 'file(1).txt')" "cmd-paren" "literal parens are matched literally"
assert_eq "$(metagates 'file1.txt')" "" "() is not a regex group"
assert_eq "$(metagates 'x[0-9].sql')" "cmd-bracket" "literal brackets are matched literally"
assert_eq "$(metagates 'x5.sql')" "" "[0-9] is not a regex character class"
assert_eq "$(metagates 'back\slash')" "cmd-backslash" "literal backslash in when matches a path with a backslash"
assert_eq "$(metagates 'backXslash')" "" "literal backslash in when does not match a path without one"

# Two gates whose run values are `echo foo|bar` and `bar`: the second must not
# be dropped as a false-positive substring match of the first.
assert_eq "$(metagates 'pipe/one' 'pipe/two')" \
  "echo foo|bar
bar" "run values containing | do not collide during dedup"

# Two gates with genuinely identical run strings still collapse to one line.
assert_eq "$(metagates 'dup/one' 'dup/two')" "cmd-dup" "true duplicate run strings still dedup"

# A malformed "gates" config must not leak a raw jq trace or an undocumented
# exit code — it gets the same exit 4 as csw-config's own malformed-config
# check. See fix round 2 in task-5-report.md.
bad_object=$(make_repo)
write_config "$bad_object" <<'JSON'
{ "gates": {} }
JSON
assert_status 4 "gates as an object (not an array) exits 4" -- \
  sh -c "cd '$bad_object' && printf 'foo/x\n' | '$BIN/csw-gates' --files"

bad_string=$(make_repo)
write_config "$bad_string" <<'JSON'
{ "gates": "just validate" }
JSON
assert_status 4 "gates as a bare string (not an array) exits 4" -- \
  sh -c "cd '$bad_string' && printf 'foo/x\n' | '$BIN/csw-gates' --files"

bad_entry=$(make_repo)
write_config "$bad_entry" <<'JSON'
{ "gates": ["not-an-object"] }
JSON
assert_status 4 "a gates entry that is not an object exits 4" -- \
  sh -c "cd '$bad_entry' && printf 'foo/x\n' | '$BIN/csw-gates' --files"

bad_missing=$(make_repo)
write_config "$bad_missing" <<'JSON'
{ "gates": [ { "when": "foo/**" } ] }
JSON
assert_status 4 "a gates entry missing run exits 4 rather than silently skipping" -- \
  sh -c "cd '$bad_missing' && printf 'foo/x\n' | '$BIN/csw-gates' --files"

bad_missing_when=$(make_repo)
write_config "$bad_missing_when" <<'JSON'
{ "gates": [ { "run": "just foo" } ] }
JSON
assert_status 4 "a gates entry missing when exits 4 rather than silently skipping" -- \
  sh -c "cd '$bad_missing_when' && printf 'foo/x\n' | '$BIN/csw-gates' --files"

# A valid gates array still behaves exactly as before.
good=$(make_repo)
write_config "$good" <<'JSON'
{ "gates": [ { "when": "foo/**", "run": "just foo" } ] }
JSON
assert_eq "$(cd "$good" && printf 'foo/x\n' | "$BIN/csw-gates" --files)" "just foo" \
  "a valid gates array still matches as before"

# An empty file list must never match a catch-all glob (fix round 3):
# `printf '%s\n' "$files"` turns a truly empty `$files` into one blank line,
# and `grep -Eq` would otherwise happily match that blank line against any
# glob that can match the empty string, like `**` or `*`.
catchall_star=$(make_repo)
write_config "$catchall_star" <<'JSON'
{ "gates": [{ "when": "**", "run": "cmd-catchall" }] }
JSON
assert_eq "$(cd "$catchall_star" && printf '' | "$BIN/csw-gates" --files)" "" \
  "empty stdin with when ** produces no output"
assert_status 0 "empty stdin with when ** still exits 0" -- \
  sh -c "cd '$catchall_star' && printf '' | '$BIN/csw-gates' --files"

catchall_single=$(make_repo)
write_config "$catchall_single" <<'JSON'
{ "gates": [{ "when": "*", "run": "cmd-catchall" }] }
JSON
assert_eq "$(cd "$catchall_single" && printf '' | "$BIN/csw-gates" --files)" "" \
  "empty stdin with when * produces no output"
assert_status 0 "empty stdin with when * still exits 0" -- \
  sh -c "cd '$catchall_single' && printf '' | '$BIN/csw-gates' --files"

# Same bug, diff mode: a branch with zero changed files must not fire a
# catch-all gate either.
nochange=$(make_repo)
write_config "$nochange" <<'JSON'
{ "gates": [{ "when": "**", "run": "cmd-catchall" }] }
JSON
git -C "$nochange" checkout -q -b feat/nochange
assert_eq "$(cd "$nochange" && "$BIN/csw-gates" main)" "" \
  "diff mode with zero changed files produces no output"
assert_status 0 "diff mode with zero changed files still exits 0" -- \
  sh -c "cd '$nochange' && '$BIN/csw-gates' main"

# Non-empty diff still fires a catch-all glob — the fix must not swing the
# other way and break `**`/`*` entirely.
assert_eq "$(cd "$catchall_star" && printf 'anything.txt\n' | "$BIN/csw-gates" --files)" \
  "cmd-catchall" "a real change still fires a catch-all when **"

# A file list with blank lines interleaved among real paths must match
# exactly as if the blank lines were absent.
blanks=$(make_repo)
write_config "$blanks" <<'JSON'
{ "gates": [{ "when": "a.txt", "run": "cmd-a" }, { "when": "b.txt", "run": "cmd-b" }] }
JSON
assert_eq "$(cd "$blanks" && printf 'a.txt\n\nb.txt\n' | "$BIN/csw-gates" --files)" \
  "cmd-a
cmd-b" "blank lines interleaved among real paths do not change matching"

# A bad base ref exits 2, and only this script's own message reaches
# stderr — git's own ~50-line usage dump must not leak through.
badref=$(make_repo)
assert_status 2 "bad base ref exits 2" -- \
  sh -c "cd '$badref' && '$BIN/csw-gates' totally-bogus-ref-xyz"
badref_stderr=$(cd "$badref" && "$BIN/csw-gates" totally-bogus-ref-xyz 2>&1 >/dev/null)
assert_eq "$badref_stderr" 'csw-gates: cannot diff totally-bogus-ref-xyz...HEAD' \
  "bad base ref stderr is only the csw-gates message, no git usage block"

# --- --worktree mode -------------------------------------------------------
#
# The set of paths that will exist once the current work is committed: the
# committed diff against <base-ref>, unioned with the working tree. Every case
# below is one the old `git status --porcelain | cut -c4- | sed 's/.* -> //'`
# pipeline in csw:work Step 6 got wrong, silently dropping a gate.

MIGRATE="just backend migrate-checksums"

# A repo on main with the two gates these cases exercise. Callers seed and
# commit whatever main should already contain, then branch themselves.
wt_repo() {
  local d
  d=$(make_repo)
  write_config "$d" <<'JSON'
{
  "gates": [
    { "when": "**/migrations/**", "run": "just backend migrate-checksums" },
    { "when": "*.sql",            "run": "just sql-lint" }
  ]
}
JSON
  printf '%s\n' "$d"
}

# Commit a five-line .sql at <repo>/<path> on the current branch.
wt_seed_sql() { # repo path
  mkdir -p "$(dirname "$1/$2")"
  printf 'select 1;\nselect 2;\nselect 3;\nselect 4;\nselect 5;\n' >"$1/$2"
  git -C "$1" add -A
  git -C "$1" commit -qm "seed $2"
}

# 1. An untracked file inside a brand-new untracked directory. The common miss:
#    without `-uall` git collapses this to `?? newdir/` and `**/migrations/**`
#    never fires. No unusual filename required.
r=$(wt_repo)
git -C "$r" checkout -q -b feat/probe
mkdir -p "$r/backend/migrations"
printf 'select 1;\n' >"$r/backend/migrations/0002.sql"
assert_eq "$(in_dir "$r" "$BIN/csw-gates" --worktree main)" "$MIGRATE" \
  "--worktree: untracked file in a brand-new untracked directory fires its gate"

# 2. An untracked path containing a space. git C-style-quotes any path with a
#    space or a non-ASCII byte, and the quotes match no glob.
r=$(wt_repo)
git -C "$r" checkout -q -b feat/probe
printf 'select 1;\n' >"$r/plain space.sql"
assert_eq "$(in_dir "$r" "$BIN/csw-gates" --worktree main)" "just sql-lint" \
  "--worktree: an untracked path containing a space fires its gate"

# 3. A staged rename whose destination contains a literal ' -> ' — the repro on
#    the ticket. Under -z the record order is new path first, old path second.
r=$(wt_repo)
git -C "$r" checkout -q -b feat/probe
wt_seed_sql "$r" m/a.sql
mkdir -p "$r/backend/migrations"
git -C "$r" mv m/a.sql "backend/migrations/weird -> evil.sql"
assert_eq "$(in_dir "$r" "$BIN/csw-gates" --worktree main)" "$MIGRATE" \
  "--worktree: staged rename to a path containing ' -> ' fires its gate"

# 4. The same rename left unstaged. Nothing has run `git add` at Step 6, so this
#    is the shape that actually shows up: ' D old' plus '?? new', no R record.
r=$(wt_repo)
git -C "$r" checkout -q -b feat/probe
wt_seed_sql "$r" m/a.sql
mkdir -p "$r/backend/migrations"
mv "$r/m/a.sql" "$r/backend/migrations/weird -> evil.sql"
assert_eq "$(in_dir "$r" "$BIN/csw-gates" --worktree main)" "$MIGRATE" \
  "--worktree: unstaged rename to a path containing ' -> ' fires its gate"

# 5. A staged copy whose destination contains ' -> '. Under -z a copy is the
#    same two-record shape as a rename, so it must take the same branch.
r=$(wt_repo)
wt_seed_sql "$r" m/a.sql
git -C "$r" config status.renames copies
git -C "$r" checkout -q -b feat/probe
mkdir -p "$r/backend/migrations"
cp "$r/m/a.sql" "$r/backend/migrations/weird -> evil.sql"
printf 'select 6;\n' >>"$r/m/a.sql"   # -C only finds copies of files the same change touches
git -C "$r" add -A
assert_eq "$(in_dir "$r" "$BIN/csw-gates" --worktree main)" "$MIGRATE" \
  "--worktree: staged copy to a path containing ' -> ' fires its gate"

# 6. A deleted path contributes nothing: it will not exist once this commits,
#    so there is nothing left for a gate to validate against it.
r=$(wt_repo)
wt_seed_sql "$r" backend/migrations/0001.sql
git -C "$r" checkout -q -b feat/probe
git -C "$r" rm -q backend/migrations/0001.sql
assert_eq "$(in_dir "$r" "$BIN/csw-gates" --worktree main)" "" \
  "--worktree: a deleted path does not fire its gate"

# ...including a deletion that is only committed on the branch, which the
# committed half must drop too.
r=$(wt_repo)
wt_seed_sql "$r" backend/migrations/0001.sql
git -C "$r" checkout -q -b feat/probe
git -C "$r" rm -q backend/migrations/0001.sql
git -C "$r" commit -qm "drop migration"
assert_eq "$(in_dir "$r" "$BIN/csw-gates" --worktree main)" "" \
  "--worktree: a path deleted in a commit on the branch does not fire its gate"

# 7. A literal newline in a path cannot be represented in the line-based
#    matching csw-gates does, and silently skipping a gate is the failure this
#    program exists to prevent. Fail loudly, exit 2.
r=$(wt_repo)
git -C "$r" checkout -q -b feat/probe
printf 'select 1;\n' >"$r/$(printf 'we\nird').sql"
assert_status 2 "--worktree: a path containing a newline exits 2" -- \
  sh -c "cd '$r' && '$BIN/csw-gates' --worktree main"
newline_stderr=$(in_dir "$r" "$BIN/csw-gates" --worktree main 2>&1 >/dev/null)
assert_contains "$newline_stderr" \
  'csw-gates: path contains a newline, which the line-based gate matching cannot represent:' \
  "--worktree: the newline failure names itself"

# The committed half is still there: a change committed on the branch and then
# left alone fires its gate with a clean working tree.
r=$(wt_repo)
git -C "$r" checkout -q -b feat/probe
wt_seed_sql "$r" backend/migrations/0003.sql
assert_eq "$(in_dir "$r" "$BIN/csw-gates" --worktree main)" "$MIGRATE" \
  "--worktree: a change committed on the branch fires its gate"

# Both halves at once, deduped down to the single command they share.
r=$(wt_repo)
git -C "$r" checkout -q -b feat/probe
wt_seed_sql "$r" backend/migrations/0003.sql
printf 'select 1;\n' >"$r/backend/migrations/0004.sql"
assert_eq "$(in_dir "$r" "$BIN/csw-gates" --worktree main)" "$MIGRATE" \
  "--worktree: committed and uncommitted halves are unioned"

# A clean tree with nothing on the branch fires nothing, and still exits 0.
r=$(wt_repo)
git -C "$r" checkout -q -b feat/probe
assert_eq "$(in_dir "$r" "$BIN/csw-gates" --worktree main)" "" \
  "--worktree: a clean tree with no branch commits produces no output"
assert_status 0 "--worktree: a clean tree still exits 0" -- \
  sh -c "cd '$r' && '$BIN/csw-gates' --worktree main"

# A bad base ref fails the same way it does in diff mode, and a missing base ref
# is a usage error rather than a diff against the empty string.
r=$(wt_repo)
assert_status 2 "--worktree: a bad base ref exits 2" -- \
  sh -c "cd '$r' && '$BIN/csw-gates' --worktree totally-bogus-ref-xyz"
wt_badref_stderr=$(in_dir "$r" "$BIN/csw-gates" --worktree totally-bogus-ref-xyz 2>&1 >/dev/null)
assert_eq "$wt_badref_stderr" 'csw-gates: cannot diff totally-bogus-ref-xyz...HEAD' \
  "--worktree: a bad base ref reports only the csw-gates message"
assert_status 2 "--worktree without a base ref exits 2" -- \
  sh -c "cd '$r' && '$BIN/csw-gates' --worktree"

# --files keeps its stdin contract exactly as it was: it is the escape hatch and
# the test seam, not something --worktree replaced.
assert_eq "$(printf 'backend/migrations/0002.sql\n' | in_dir "$r" "$BIN/csw-gates" --files)" \
  "$MIGRATE" "--files still reads a newline-separated list from stdin"

report
