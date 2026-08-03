#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/test-helpers.sh"

if ! command -v python3 >/dev/null 2>&1; then
  printf 'skip: python3 not available\n'
  exit 0
fi

repo=$(make_repo)
write_config "$repo" <<'JSON'
{
  "tracker": "linear",
  "batch": { "maxTickets": 3, "singleWriterLabels": ["migration"] }
}
JSON
cd "$repo" || exit 1

run() { printf '%s' "$1" | "$BIN/csw-batch-filter"; }
selected() { run "$1" | jq -c '.selected'; }
reason_for() { run "$1" | jq -r --arg id "$2" '.skipped[] | select(.id == $id) | .reason'; }

# Blocked tickets are excluded.
t='[
  {"id":"A-1","state":"Todo","priority":2,"blockedBy":["A-9"]},
  {"id":"A-2","state":"Todo","priority":2}
]'
assert_eq "$(selected "$t")" '["A-2"]' "blocked ticket is excluded"
assert_contains "$(reason_for "$t" A-1)" "blocked by A-9" "blocked reason names the blocker"

# Non-Todo tickets are excluded.
t='[
  {"id":"B-1","state":"In Progress","priority":1},
  {"id":"B-2","state":"Todo","priority":1}
]'
assert_eq "$(selected "$t")" '["B-2"]' "only Todo tickets are dispatched"

# Linear priority: 1 is Urgent, 0 is none and sorts last.
t='[
  {"id":"C-1","state":"Todo","priority":3},
  {"id":"C-2","state":"Todo","priority":1},
  {"id":"C-3","state":"Todo","priority":0}
]'
assert_eq "$(selected "$t")" '["C-2","C-1","C-3"]' "linear priority order, none last"

# At most one migration-adding ticket per batch; the higher priority keeps it.
t='[
  {"id":"D-1","state":"Todo","priority":3,"labels":["migration"]},
  {"id":"D-2","state":"Todo","priority":1,"labels":["migration"]},
  {"id":"D-3","state":"Todo","priority":4}
]'
assert_eq "$(selected "$t")" '["D-2","D-3"]' "single writer on the migration label"
assert_contains "$(reason_for "$t" D-1)" "single-writer" "single-writer reason is explicit"
assert_contains "$(reason_for "$t" D-1)" "D-2" "single-writer reason names the holder"

# Same-surface clustering via a shared relatedTo target.
t='[
  {"id":"E-1","state":"Todo","priority":3,"relatedTo":["E-9"]},
  {"id":"E-2","state":"Todo","priority":1,"relatedTo":["E-9"]},
  {"id":"E-3","state":"Todo","priority":2,"relatedTo":["E-8"]}
]'
assert_eq "$(selected "$t")" '["E-2","E-3"]' "one ticket per shared-relation cluster"
assert_contains "$(reason_for "$t" E-1)" "cluster" "cluster reason is explicit"

# A direct relation between two candidates clusters them too.
t='[
  {"id":"F-1","state":"Todo","priority":2,"relatedTo":["F-2"]},
  {"id":"F-2","state":"Todo","priority":1}
]'
assert_eq "$(selected "$t")" '["F-2"]' "direct relation clusters two candidates"

# The cap is the last filter applied, and it explains itself.
t='[
  {"id":"G-1","state":"Todo","priority":1},
  {"id":"G-2","state":"Todo","priority":1},
  {"id":"G-3","state":"Todo","priority":2},
  {"id":"G-4","state":"Todo","priority":3}
]'
assert_eq "$(selected "$t")" '["G-1","G-2","G-3"]' "batch cap of 3"
assert_contains "$(reason_for "$t" G-4)" "batch cap" "cap reason is explicit"

# Empty input is valid.
assert_eq "$(selected '[]')" '[]' "empty input selects nothing"

report
