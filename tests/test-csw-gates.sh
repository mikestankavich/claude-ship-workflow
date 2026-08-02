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

report
