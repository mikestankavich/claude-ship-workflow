#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/test-helpers.sh"

# --- defaults when no config file exists ---
repo=$(make_repo)
assert_eq "$(cd "$repo" && "$BIN/csw-config" get worktreeDir)" ".worktrees" "default worktreeDir"
assert_eq "$(cd "$repo" && "$BIN/csw-config" get baseBranch)" "main" "default baseBranch"
assert_eq "$(cd "$repo" && "$BIN/csw-config" get defaultType)" "feat" "default defaultType"
assert_eq "$(cd "$repo" && "$BIN/csw-config" get ticketPrefix)" "" "default ticketPrefix is empty"
# Empty means "ask the tracker named by `tracker`", which is the behaviour every existing
# config already has. A non-empty default would silently shell out on someone else's repo.
# The exit-status assertion is the load-bearing half: an absent key exits 2 and its command
# substitution is also the empty string, so assert_eq alone would pass without the default.
assert_eq "$(cd "$repo" && "$BIN/csw-config" get trackerCommand)" "" "default trackerCommand is empty"
assert_status 0 "trackerCommand is a known key, not an absent one" -- in_dir "$repo" "$BIN/csw-config" get trackerCommand
assert_eq "$(cd "$repo" && "$BIN/csw-config" get branchPattern)" "<type>/<ticket>-<slug>" "default branchPattern"
# Empty means "this repo keeps no ADRs", and `/csw:work` never asks the question. The
# exit-status assertion carries the same weight as trackerCommand's above: an absent key also
# substitutes to the empty string, so assert_eq alone would pass with the default missing.
assert_eq "$(cd "$repo" && "$BIN/csw-config" get adrDir)" "" "default adrDir is empty"
assert_status 0 "adrDir is a known key, not an absent one" -- in_dir "$repo" "$BIN/csw-config" get adrDir
assert_eq "$(cd "$repo" && "$BIN/csw-config" get gates)" "[]" "default gates is an empty array"
assert_eq "$(cd "$repo" && "$BIN/csw-config" get batch.maxTickets)" "3" "default batch.maxTickets"
assert_eq "$(cd "$repo" && "$BIN/csw-config" path)" "" "path is empty with no config file"

# --- repo config overrides, and partial config keeps other defaults ---
repo=$(make_repo)
write_config "$repo" <<'JSON'
{
  "ticketPrefix": "TRA",
  "tracker": "linear",
  "trackerCommand": "linear-cli todo --json",
  "validate": "just validate",
  "worktreeDir": ".claude/worktrees",
  "adrDir": "docs/adr",
  "batch": { "maxTickets": 4 }
}
JSON
assert_eq "$(cd "$repo" && "$BIN/csw-config" get adrDir)" "docs/adr" "override adrDir"
assert_eq "$(cd "$repo" && "$BIN/csw-config" get ticketPrefix)" "TRA" "override ticketPrefix"
assert_eq "$(cd "$repo" && "$BIN/csw-config" get validate)" "just validate" "override validate"
# trackerCommand replaces only the fetch, so a repo setting it keeps `tracker` too — the
# filter's own priority ranking still reads `tracker`.
assert_eq "$(cd "$repo" && "$BIN/csw-config" get trackerCommand)" "linear-cli todo --json" "override trackerCommand"
assert_eq "$(cd "$repo" && "$BIN/csw-config" get tracker)" "linear" "trackerCommand does not displace tracker"
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
assert_status 3 "get outside a git repo exits 3, not a default value" -- in_dir "$outside" "$BIN/csw-config" get branchPattern

repo=$(make_repo)
mkdir -p "$repo/.claude"
printf '{ not json\n' >"$repo/.claude/csw.json"
assert_status 4 "malformed config exits 4" -- in_dir "$repo" "$BIN/csw-config" json
assert_status 4 "get with malformed config exits 4, not unknown key" -- in_dir "$repo" "$BIN/csw-config" get branchPattern

# --- syntactically valid JSON that is not an object is also a config error ---
repo=$(make_repo)
write_config "$repo" <<'JSON'
[1, 2, 3]
JSON
assert_status 4 "top-level array config exits 4" -- in_dir "$repo" "$BIN/csw-config" json

repo=$(make_repo)
write_config "$repo" <<'JSON'
"hello"
JSON
assert_status 4 "top-level bare-string config exits 4" -- in_dir "$repo" "$BIN/csw-config" json

# --- a key explicitly set to null is present, not unknown ---
repo=$(make_repo)
write_config "$repo" <<'JSON'
{ "ticketPrefix": null }
JSON
assert_eq "$(cd "$repo" && "$BIN/csw-config" get ticketPrefix)" "null" "explicit null value prints as null"
assert_status 0 "explicit null value exits 0" -- in_dir "$repo" "$BIN/csw-config" get ticketPrefix

# --- a genuinely absent key still exits 2, even with a valid config file present ---
assert_status 2 "absent key exits 2 alongside a valid config" -- in_dir "$repo" "$BIN/csw-config" get nope

report
