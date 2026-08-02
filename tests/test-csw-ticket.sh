#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/test-helpers.sh"

repo=$(make_repo)
write_config "$repo" <<'JSON'
{ "ticketPrefix": "TRA", "branchPattern": "<type>/<ticket>-<slug>" }
JSON
cd "$repo" || exit 1

assert_eq "$("$BIN/csw-ticket" normalize 1088)" "TRA-1088" "bare number gets the prefix"
assert_eq "$("$BIN/csw-ticket" normalize tra-1088)" "TRA-1088" "lowercase prefixed"
assert_eq "$("$BIN/csw-ticket" normalize TRA-1088)" "TRA-1088" "already normalised"
assert_eq "$("$BIN/csw-ticket" normalize tra1088)" "TRA-1088" "missing dash"
assert_eq "$("$BIN/csw-ticket" normalize ' TRA-1088 ')" "TRA-1088" "surrounding whitespace"
assert_eq "$("$BIN/csw-ticket" number tra-1088)" "1088" "number strips the prefix"

assert_status 2 "unparseable reference exits 2" -- "$BIN/csw-ticket" normalize "not a ticket"
assert_status 2 "empty reference exits 2" -- "$BIN/csw-ticket" normalize ""

assert_eq "$("$BIN/csw-ticket" slug 'Add nav vocabulary')" "add-nav-vocabulary" "basic slug"
assert_eq "$("$BIN/csw-ticket" slug 'Fix: the "Named Instance" audit!')" "fix-the-named-instance-audit" "punctuation collapses"
assert_eq "$("$BIN/csw-ticket" slug '  Leading and trailing  ')" "leading-and-trailing" "trims to no stray dashes"
long=$("$BIN/csw-ticket" slug 'replace the deprecated dsn setting rather than deleting it outright')
assert_eq "${#long}" "40" "long slug truncates to 40 characters"
case "$long" in *-) assert_eq "trailing-dash" "none" "truncated slug has no trailing dash" ;; *) PASSES=$((PASSES + 1)) ;; esac

assert_eq "$("$BIN/csw-ticket" branch feat TRA-1088 Add nav vocabulary)" \
  "feat/tra-1088-add-nav-vocabulary" "branch renders the pattern"
assert_eq "$("$BIN/csw-ticket" branch fix 1076 'Replace the DSN setting')" \
  "fix/tra-1076-replace-the-dsn-setting" "branch normalises a bare number"

# A different pattern must be honoured, not hardcoded around.
write_config "$repo" <<'JSON'
{ "ticketPrefix": "ENG", "branchPattern": "<ticket>/<type>-<slug>" }
JSON
assert_eq "$("$BIN/csw-ticket" branch chore 42 'Bump deps')" "eng-42/chore-bump-deps" "custom pattern"

# No prefix configured: a bare number is ambiguous and must fail loudly.
bare=$(make_repo)
assert_status 2 "bare number without ticketPrefix exits 2" -- in_dir "$bare" "$BIN/csw-ticket" normalize 1088
assert_eq "$(cd "$bare" && "$BIN/csw-ticket" normalize ENG-7)" "ENG-7" "explicit prefix works without config"

report
