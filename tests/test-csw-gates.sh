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

# A valid gates array still behaves exactly as before.
good=$(make_repo)
write_config "$good" <<'JSON'
{ "gates": [ { "when": "foo/**", "run": "just foo" } ] }
JSON
assert_eq "$(cd "$good" && printf 'foo/x\n' | "$BIN/csw-gates" --files)" "just foo" \
  "a valid gates array still matches as before"

report
