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

# Team keys that contain digits (Linear/Jira style) must round-trip: normalize's
# own output must be re-parseable by normalize, and number must strip only the
# prefix, not everything up to the first dash.
write_config "$repo" <<'JSON'
{ "ticketPrefix": "K8S", "branchPattern": "<type>/<ticket>-<slug>" }
JSON
assert_eq "$("$BIN/csw-ticket" normalize 42)" "K8S-42" "digit-bearing prefix from a bare number"
assert_eq "$("$BIN/csw-ticket" normalize K8S-42)" "K8S-42" "digit-bearing prefix round-trips"
assert_eq "$("$BIN/csw-ticket" number K8S-42)" "42" "number strips a digit-bearing prefix, not up to the first dash"

# An invalid configured ticketPrefix must fail loudly rather than mint a
# reference normalize can't parse back. Exit 4, not 2: this is a broken
# config, the same class of failure as csw-config's own malformed-config
# checks, not a bad invocation of csw-ticket.
write_config "$repo" <<'JSON'
{ "ticketPrefix": "1AB", "branchPattern": "<type>/<ticket>-<slug>" }
JSON
assert_status 4 "ticketPrefix starting with a digit exits 4" -- "$BIN/csw-ticket" normalize 42
write_config "$repo" <<'JSON'
{ "ticketPrefix": "TRA-X", "branchPattern": "<type>/<ticket>-<slug>" }
JSON
assert_status 4 "ticketPrefix containing a dash exits 4" -- "$BIN/csw-ticket" normalize 42

# A malformed config file must propagate csw-config's real exit code (4)
# through `branch` and `number`, not collapse into the misleading "needs
# ticketPrefix" usage error (2) that fires when normalize's internal
# `config get ticketPrefix` failure is silently swallowed by a nested command
# substitution lacking `inherit_errexit`.
badcfg=$(make_repo)
mkdir -p "$badcfg/.claude"
printf '{ not json\n' >"$badcfg/.claude/csw.json"
assert_status 4 "branch propagates a malformed-config exit 4 through a bare-number ticket ref" -- \
  in_dir "$badcfg" "$BIN/csw-ticket" branch feat 5 title
assert_status 4 "number propagates a malformed-config exit 4 through a bare-number ticket ref" -- \
  in_dir "$badcfg" "$BIN/csw-ticket" number 5

# branchPattern is free text, unlike the strictly validated ticketPrefix. Left
# unvalidated it can render every ticket to the same branch ("wip"), a
# literal "null", or an illegal ref — silent collisions in /csw:batch. It
# must contain a placeholder and render to a legal git branch name, or exit 4.
write_config "$repo" <<'JSON'
{ "ticketPrefix": "TRA", "branchPattern": "wip" }
JSON
assert_status 4 "branchPattern with no <ticket>/<slug> placeholder exits 4" -- \
  "$BIN/csw-ticket" branch feat 1088 'Add nav vocabulary'

write_config "$repo" <<'JSON'
{ "ticketPrefix": "TRA", "branchPattern": null }
JSON
assert_status 4 "branchPattern of null exits 4" -- \
  "$BIN/csw-ticket" branch feat 1088 'Add nav vocabulary'

write_config "$repo" <<'JSON'
{ "ticketPrefix": "TRA", "branchPattern": {"a": 1} }
JSON
assert_status 4 "branchPattern as an object exits 4" -- \
  "$BIN/csw-ticket" branch feat 1088 'Add nav vocabulary'

write_config "$repo" <<'JSON'
{ "ticketPrefix": "TRA", "branchPattern": "<ticket>:<slug>" }
JSON
assert_status 4 "branchPattern with a placeholder that still renders an illegal git ref (colon) exits 4" -- \
  "$BIN/csw-ticket" branch feat 1088 'Add nav vocabulary'

write_config "$repo" <<'JSON'
{ "ticketPrefix": "TRA", "branchPattern": "<ticket>" }
JSON
assert_eq "$("$BIN/csw-ticket" branch feat 1088 'Add nav vocabulary')" "tra-1088" \
  "branchPattern with only <ticket> is still a legal single-placeholder pattern"

# Reject every unparseable / ambiguous shape.
write_config "$repo" <<'JSON'
{ "ticketPrefix": "TRA", "branchPattern": "<type>/<ticket>-<slug>" }
JSON
assert_status 2 "prefix with no digits exits 2" -- "$BIN/csw-ticket" normalize "TRA-"
assert_status 2 "leading dash exits 2" -- "$BIN/csw-ticket" normalize "-1088"
assert_status 2 "double dash exits 2" -- "$BIN/csw-ticket" normalize "TRA--1088"
assert_status 2 "leading digits exits 2" -- "$BIN/csw-ticket" normalize "12AB34"
assert_status 2 "trailing extra segment exits 2" -- "$BIN/csw-ticket" normalize "TRA-1088-extra"
assert_status 2 "unparseable words exit 2" -- "$BIN/csw-ticket" normalize "not a ticket"

report
