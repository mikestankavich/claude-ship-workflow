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
below_cap() { run "$1" | jq -c '.belowCap'; }
skipped_ids() { run "$1" | jq -c '[.skipped[].id]'; }
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

# The cap is the last cut applied, and it is not an exclusion: what it leaves out is
# reported in belowCap, not skipped.
t='[
  {"id":"G-1","state":"Todo","priority":1},
  {"id":"G-2","state":"Todo","priority":1},
  {"id":"G-3","state":"Todo","priority":2},
  {"id":"G-4","state":"Todo","priority":3}
]'
assert_eq "$(selected "$t")" '["G-1","G-2","G-3"]' "batch cap of 3"
assert_eq "$(below_cap "$t")" '["G-4"]' "the ticket over the cap lands in belowCap"
assert_eq "$(skipped_ids "$t")" '[]' "the ticket over the cap is not skipped"

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

# maxTickets: 0 is valid and meaningful — it selects nothing, and every candidate falls
# below the cap. None of them was excluded, so none of them is skipped.
write_config "$repo" <<'JSON'
{ "tracker": "linear", "batch": { "maxTickets": 0, "singleWriterLabels": ["migration"] } }
JSON
t='[{"id":"Z-1","state":"Todo","priority":1},{"id":"Z-2","state":"Todo","priority":2}]'
assert_eq "$(selected "$t")" '[]' "maxTickets 0 selects nothing"
assert_eq "$(below_cap "$t")" '["Z-1","Z-2"]' \
  "maxTickets 0 puts every candidate below the cap, in dispatch order"
assert_eq "$(skipped_ids "$t")" '[]' "maxTickets 0 skips nothing"

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
# once across selected plus belowCap plus skipped. This is a permanent guard, not
# just a probe.
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
out_ids=$(printf '%s' "$out" | jq -c '(.selected + .belowCap + [.skipped[].id]) | sort')
assert_eq "$out_ids" "$in_ids" \
  "every ticket appears across selected+belowCap+skipped, same set as the input"
dupe_count=$(printf '%s' "$out" | jq '(.selected + .belowCap + [.skipped[].id]) | (length - (unique | length))')
assert_eq "$dupe_count" "0" "no ticket appears in more than one of the three groups"

# --- Fix round 2: per-field type validation instead of crashing or silently ---
# --- misreading a malformed field. ---

# String priority previously tracebacked with a TypeError on the sort comparison.
t='[{"id":"S-1","state":"Todo","priority":"high"},{"id":"S-2","state":"Todo","priority":2}]'
assert_eq "$(status_of "$t")" "2" "string priority exits 2"
err=$(stderr_of "$t")
assert_contains "$err" "S-1" "string priority error names the ticket id"
assert_contains "$err" "priority" "string priority error names the field"
assert_no_traceback "$err" "string priority must not traceback"

# Float priority is rejected too — priority must be an integer.
t='[{"id":"FL-1","state":"Todo","priority":2.5}]'
assert_eq "$(status_of "$t")" "2" "float priority exits 2"
assert_contains "$(stderr_of "$t")" "FL-1" "float priority error names the ticket id"

# Boolean priority is rejected — bool is an int subclass in Python and must not
# slip through a bare isinstance(x, int) check.
t='[{"id":"BP-1","state":"Todo","priority":true}]'
assert_eq "$(status_of "$t")" "2" "boolean priority exits 2"
assert_contains "$(stderr_of "$t")" "BP-1" "boolean priority error names the ticket id"

# Non-string state is rejected.
t='[{"id":"ST-1","state":5,"priority":1}]'
assert_eq "$(status_of "$t")" "2" "non-string state exits 2"
err=$(stderr_of "$t")
assert_contains "$err" "ST-1" "non-string state error names the ticket id"
assert_contains "$err" "state" "non-string state error names the field"

# String labels previously let `"migration" in "has-migrationXYZ-in-it"` fall
# through as True, silently claiming a single-writer slot it never earned.
t='[{"id":"L-1","state":"Todo","priority":1,"labels":"has-migrationXYZ-in-it"}]'
assert_eq "$(status_of "$t")" "2" "string labels exits 2"
err=$(stderr_of "$t")
assert_contains "$err" "L-1" "string labels error names the ticket id"
assert_contains "$err" "labels" "string labels error names the field"
assert_no_traceback "$err" "string labels must not traceback"

# String relatedTo previously iterated per character, colliding a ticket id
# ("9") with one character of the string ("R-9") into a spurious cluster.
t='[{"id":"9","state":"Todo","priority":1},{"id":"R-1","state":"Todo","priority":2,"relatedTo":"R-9"}]'
assert_eq "$(status_of "$t")" "2" "string relatedTo exits 2"
err=$(stderr_of "$t")
assert_contains "$err" "R-1" "string relatedTo error names the ticket id"
assert_contains "$err" "relatedTo" "string relatedTo error names the field"

# String blockedBy previously garbled the skip reason via ", ".join over characters.
t='[{"id":"K-1","state":"Todo","priority":1,"blockedBy":"K-9"}]'
assert_eq "$(status_of "$t")" "2" "string blockedBy exits 2"
err=$(stderr_of "$t")
assert_contains "$err" "K-1" "string blockedBy error names the ticket id"
assert_contains "$err" "blockedBy" "string blockedBy error names the field"

# A non-string element inside an otherwise-list field is rejected too.
t='[{"id":"LX-1","state":"Todo","priority":1,"labels":["ok",7]}]'
assert_eq "$(status_of "$t")" "2" "non-string element inside labels exits 2"
assert_contains "$(stderr_of "$t")" "LX-1" "non-string list element error names the ticket id"

# --- Cap overflow is reported separately from genuine exclusions ---

# belowCap carries everything that passed every filter and still fell outside the cap, in
# the order it would have been dispatched. That is the difference between "must not run
# tonight" and "would have run with a bigger cap", which nothing downstream could tell
# apart while both shared one `skipped` array.
t='[
  {"id":"CAP-1","state":"Todo","priority":4},
  {"id":"CAP-2","state":"Todo","priority":1},
  {"id":"CAP-3","state":"Todo","priority":3},
  {"id":"CAP-4","state":"Todo","priority":2},
  {"id":"CAP-5","state":"Todo","priority":3,"blockedBy":["CAP-9"]}
]'
assert_eq "$(selected "$t")" '["CAP-2","CAP-4","CAP-3"]' "the cap keeps the top three, in priority order"
assert_eq "$(below_cap "$t")" '["CAP-1"]' "belowCap carries the overflow in dispatch order"
assert_eq "$(skipped_ids "$t")" '["CAP-5"]' "skipped carries only the genuine exclusion"
assert_contains "$(reason_for "$t" CAP-5)" "blocked by CAP-9" "the genuine exclusion keeps its reason"

# No skip reason blames the cap any more. A reader scanning `skipped` has to be able to
# trust that every entry there is a real exclusion.
assert_eq "$(run "$t" | jq '[.skipped[] | select(.reason | test("cap"))] | length')" "0" \
  "no skipped entry blames the cap"

# belowCap is always present, so a consumer never has to tell "absent" from "empty".
assert_eq "$(below_cap '[{"id":"UN-1","state":"Todo","priority":1}]')" '[]' \
  "belowCap is an empty array when nothing overflows"
assert_eq "$(below_cap '[]')" '[]' "belowCap is an empty array for empty input"

# belowCap is strictly the cap's overflow: a ticket a filter genuinely rejected never
# appears there, however far down the priority order it sits.
t='[
  {"id":"BC-1","state":"Todo","priority":1,"labels":["migration"]},
  {"id":"BC-2","state":"Todo","priority":2,"labels":["migration"]},
  {"id":"BC-3","state":"In Progress","priority":1},
  {"id":"BC-4","state":"Todo","priority":3,"blockedBy":["BC-9"]}
]'
assert_eq "$(below_cap "$t")" '[]' "genuine exclusions never land in belowCap"
assert_eq "$(run "$t" | jq -c '[.skipped[].id] | sort')" '["BC-2","BC-3","BC-4"]' \
  "every genuine exclusion is still reported, with its reason"

report
