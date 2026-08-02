#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/test-helpers.sh"

# --- defaults when no config file exists ---
repo=$(make_repo)
assert_eq "$(cd "$repo" && "$BIN/csw-config" get worktreeDir)" ".worktrees" "default worktreeDir"
assert_eq "$(cd "$repo" && "$BIN/csw-config" get baseBranch)" "main" "default baseBranch"
assert_eq "$(cd "$repo" && "$BIN/csw-config" get defaultType)" "feat" "default defaultType"
assert_eq "$(cd "$repo" && "$BIN/csw-config" get ticketPrefix)" "" "default ticketPrefix is empty"
assert_eq "$(cd "$repo" && "$BIN/csw-config" get branchPattern)" "<type>/<ticket>-<slug>" "default branchPattern"
assert_eq "$(cd "$repo" && "$BIN/csw-config" get gates)" "[]" "default gates is an empty array"
assert_eq "$(cd "$repo" && "$BIN/csw-config" get batch.maxTickets)" "3" "default batch.maxTickets"
assert_eq "$(cd "$repo" && "$BIN/csw-config" path)" "" "path is empty with no config file"

# --- repo config overrides, and partial config keeps other defaults ---
repo=$(make_repo)
write_config "$repo" <<'JSON'
{
  "ticketPrefix": "TRA",
  "tracker": "linear",
  "validate": "just validate",
  "worktreeDir": ".claude/worktrees",
  "batch": { "maxTickets": 4 }
}
JSON
assert_eq "$(cd "$repo" && "$BIN/csw-config" get ticketPrefix)" "TRA" "override ticketPrefix"
assert_eq "$(cd "$repo" && "$BIN/csw-config" get validate)" "just validate" "override validate"
assert_eq "$(cd "$repo" && "$BIN/csw-config" get worktreeDir)" ".claude/worktrees" "override worktreeDir"
assert_eq "$(cd "$repo" && "$BIN/csw-config" get baseBranch)" "main" "untouched key keeps its default"
assert_eq "$(cd "$repo" && "$BIN/csw-config" get batch.maxTickets)" "4" "nested override"
assert_eq "$(cd "$repo" && "$BIN/csw-config" get batch.singleWriterLabels)" '["migration"]' "nested sibling keeps default"
assert_eq "$(cd "$repo" && "$BIN/csw-config" path)" "$repo/.claude/csw.json" "path reports the config file"

# --- a linked worktree finds a config that lives only in the main worktree ---
repo=$(make_repo)
write_config "$repo" <<'JSON'
{ "ticketPrefix": "TRA", "worktreeDir": ".claude/worktrees" }
JSON
git -C "$repo" worktree add -q -b feat/probe "$repo/.claude/worktrees/probe" >/dev/null 2>&1
assert_eq "$(cd "$repo/.claude/worktrees/probe" && "$BIN/csw-config" get ticketPrefix)" "TRA" \
  "linked worktree falls back to the main worktree config"

# --- error paths ---
repo=$(make_repo)
assert_status 2 "unknown key exits 2" -- in_dir "$repo" "$BIN/csw-config" get nope
assert_status 2 "bad subcommand exits 2" -- in_dir "$repo" "$BIN/csw-config" frobnicate

outside=$(mktemp -d)
TMPDIRS+=("$outside")
assert_status 3 "outside a git repo exits 3" -- in_dir "$outside" "$BIN/csw-config" json

repo=$(make_repo)
mkdir -p "$repo/.claude"
printf '{ not json\n' >"$repo/.claude/csw.json"
assert_status 4 "malformed config exits 4" -- in_dir "$repo" "$BIN/csw-config" json

report
