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

# --- Fix round 1: input and config validation instead of crashing on it ---

status_of() { printf '%s' "$1" | "$BIN/csw-batch-filter" >/dev/null 2>/dev/null; printf '%d' "$?"; }
stderr_of() { { printf '%s' "$1" | "$BIN/csw-batch-filter" >/dev/null; } 2>&1; }
assert_no_traceback() { # stderr-text label
  case "$1" in
    *Traceback*)
      FAILURES=$((FAILURES + 1))
      printf 'FAIL %s\n  must not contain a Python traceback\n  actual: [%s]\n' "$2" "$1" >&2
      ;;
    *) PASSES=$((PASSES + 1)) ;;
  esac
}

# Missing id: exit 2, names the offending index, no traceback.
t='[{"priority":1,"state":"Todo"}]'
assert_eq "$(status_of "$t")" "2" "missing id exits 2"
err=$(stderr_of "$t")
assert_contains "$err" "csw-batch-filter:" "missing id error uses the house prefix"
assert_contains "$err" "index 0" "missing id error names the offending index"
assert_no_traceback "$err" "missing id must not traceback"

# Duplicate id: exit 2, names it.
t='[{"id":"DUP","state":"Todo","priority":1},{"id":"DUP","state":"Todo","priority":2}]'
assert_eq "$(status_of "$t")" "2" "duplicate id exits 2"
assert_contains "$(stderr_of "$t")" "DUP" "duplicate id error names the id"

# Top-level object instead of array: exit 2, names what arrived, no traceback.
t='{"id":"X-1"}'
assert_eq "$(status_of "$t")" "2" "top-level object exits 2"
err=$(stderr_of "$t")
assert_contains "$err" "object" "top-level object error names the type"
assert_no_traceback "$err" "top-level object must not traceback"

# Bare string: exit 2, no traceback.
t='"hello"'
assert_eq "$(status_of "$t")" "2" "bare string exits 2"
err=$(stderr_of "$t")
assert_contains "$err" "string" "bare string error names the type"
assert_no_traceback "$err" "bare string must not traceback"

# Malformed JSON: exit 2, no traceback.
t='[{"id":'
assert_eq "$(status_of "$t")" "2" "malformed JSON exits 2"
err=$(stderr_of "$t")
assert_contains "$err" "csw-batch-filter:" "malformed JSON error uses the house prefix"
assert_no_traceback "$err" "malformed JSON must not traceback"

# Empty stdin: exit 2, its own wording (distinct from generic malformed-JSON text),
# no traceback.
assert_eq "$(printf '' | "$BIN/csw-batch-filter" >/dev/null 2>/dev/null; printf '%d' "$?")" "2" \
  "empty stdin exits 2"
err=$( { printf '' | "$BIN/csw-batch-filter" >/dev/null; } 2>&1)
assert_contains "$err" "no input" "empty stdin gets its own wording"
assert_no_traceback "$err" "empty stdin must not traceback"

# Negative maxTickets: rejected outright rather than silently slicing "all but the
# last N" — a typo must not produce a plausible-looking wrong batch.
write_config "$repo" <<'JSON'
{ "tracker": "linear", "batch": { "maxTickets": -1, "singleWriterLabels": ["migration"] } }
JSON
t='[{"id":"NEG-1","state":"Todo","priority":1}]'
assert_eq "$(status_of "$t")" "2" "negative maxTickets exits 2"
assert_contains "$(stderr_of "$t")" "maxTickets" "negative maxTickets error names the key"

# maxTickets: 0 is valid and meaningful — it selects nothing, and every candidate is
# skipped with the batch-cap reason.
write_config "$repo" <<'JSON'
{ "tracker": "linear", "batch": { "maxTickets": 0, "singleWriterLabels": ["migration"] } }
JSON
t='[{"id":"Z-1","state":"Todo","priority":1},{"id":"Z-2","state":"Todo","priority":2}]'
assert_eq "$(selected "$t")" '[]' "maxTickets 0 selects nothing"
assert_contains "$(reason_for "$t" Z-1)" "batch cap" "maxTickets 0 skips the first with the cap reason"
assert_contains "$(reason_for "$t" Z-2)" "batch cap" "maxTickets 0 skips the second with the cap reason"

# Non-list singleWriterLabels: exit 2, names the key.
write_config "$repo" <<'JSON'
{ "tracker": "linear", "batch": { "maxTickets": 3, "singleWriterLabels": "migration" } }
JSON
t='[{"id":"SW-1","state":"Todo","priority":1}]'
assert_eq "$(status_of "$t")" "2" "non-list singleWriterLabels exits 2"
assert_contains "$(stderr_of "$t")" "singleWriterLabels" "non-list singleWriterLabels error names the key"

# Restore the standard config for the accounting-invariant check below.
write_config "$repo" <<'JSON'
{
  "tracker": "linear",
  "batch": { "maxTickets": 3, "singleWriterLabels": ["migration"] }
}
JSON

# The invariant every filter above depends on: every input ticket appears exactly
# once across selected plus skipped. This is a permanent guard, not just a probe.
t='[
  {"id":"INV-1","state":"Todo","priority":1,"labels":["migration"]},
  {"id":"INV-2","state":"Todo","priority":2,"labels":["migration"]},
  {"id":"INV-3","state":"Todo","priority":1,"relatedTo":["INV-9"]},
  {"id":"INV-4","state":"Todo","priority":2,"relatedTo":["INV-9"]},
  {"id":"INV-5","state":"Todo","priority":3,"blockedBy":["INV-8"]},
  {"id":"INV-6","state":"In Progress","priority":1},
  {"id":"INV-7","state":"Todo","priority":4}
]'
out=$(run "$t")
in_ids=$(printf '%s' "$t" | jq -c '[.[].id] | sort')
out_ids=$(printf '%s' "$out" | jq -c '(.selected + [.skipped[].id]) | sort')
assert_eq "$out_ids" "$in_ids" "every ticket appears across selected+skipped, same set as the input"
dupe_count=$(printf '%s' "$out" | jq '(.selected + [.skipped[].id]) | (length - (unique | length))')
assert_eq "$dupe_count" "0" "no ticket appears in both selected and skipped"

report
