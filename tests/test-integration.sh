#!/usr/bin/env bash
# End-to-end: a fresh repo, the real example config, and the full derivation
# chain, proving the pieces work together rather than only in isolation.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/test-helpers.sh"

repo=$(make_repo)
mkdir -p "$repo/.claude"
cp "$REPO_ROOT/examples/csw.json" "$repo/.claude/csw.json"

# --- The example config must actually drive the tools it claims to. ---
assert_eq "$(in_dir "$repo" "$BIN/csw-config" get ticketPrefix)" "TRA" \
  "example config loads"
assert_eq "$(in_dir "$repo" "$BIN/csw-ticket" normalize 1088)" "TRA-1088" \
  "example config normalises a bare number"
assert_eq "$(in_dir "$repo" "$BIN/csw-ticket" branch feat 1088 'Add nav vocabulary')" \
  "feat/tra-1088-add-nav-vocabulary" "example config produces the documented branch name"
assert_eq "$(printf 'backend/migrations/0042.sql\n' | in_dir "$repo" "$BIN/csw-gates" --files)" \
  "just backend migrate-checksums" "example config's migration gate fires"
assert_eq "$(printf 'README.md\n' | in_dir "$repo" "$BIN/csw-gates" --files)" "" \
  "unrelated change triggers no gate"
assert_eq "$(printf 'web/Menu.tsx\n' | in_dir "$repo" "$BIN/csw-gates" --files)" \
  "just playwright-preview" "example config's playwright gate fires on a top-level web/*.tsx file"
assert_eq "$(printf 'web/app/nav/Menu.tsx\n' | in_dir "$repo" "$BIN/csw-gates" --files)" \
  "just playwright-preview" "example config's playwright gate fires on a nested web/**/*.tsx file"

# --- Every executable in bin/ is executable and starts with a #!/usr/bin/env shebang. ---
for f in "$REPO_ROOT"/bin/*; do
  name=$(basename "$f")
  if [ -x "$f" ]; then
    PASSES=$((PASSES + 1))
  else
    FAILURES=$((FAILURES + 1))
    printf 'FAIL bin/%s is not executable\n' "$name" >&2
  fi
  assert_contains "$(head -1 "$f")" "#!/usr/bin/env" "bin/$name has a shebang"
done

# --- Every skill the README advertises exists. ---
for s in work merge cleanup batch; do
  if [ -f "$REPO_ROOT/skills/$s/SKILL.md" ]; then
    PASSES=$((PASSES + 1))
  else
    FAILURES=$((FAILURES + 1))
    printf 'FAIL skills/%s/SKILL.md missing\n' "$s" >&2
  fi
done

# --- The plugin name alone puts the commands under the csw: prefix. ---
assert_eq "$(jq -r '.name' "$REPO_ROOT/.claude-plugin/plugin.json")" "csw" \
  "plugin.json name is csw, which namespaces /csw:work and friends"

# --- Both manifests and VERSION agree. ---
version=$(tr -d '[:space:]' <"$REPO_ROOT/VERSION")
assert_eq "$version" "1.0.1" "VERSION is 1.0.1"
assert_eq "$(jq -r '.version' "$REPO_ROOT/.claude-plugin/plugin.json")" "$version" \
  "plugin.json version matches VERSION"
assert_eq "$(jq -r '.plugins[0].version' "$REPO_ROOT/.claude-plugin/marketplace.json")" "$version" \
  "marketplace.json version matches VERSION"

# --- csw-batch-filter end-to-end against the example config: blocked, cluster, ---
# --- single-writer, and cap filters all firing together on one realistic input, ---
# --- rather than each exercised in isolation. maxTickets is 3, singleWriterLabels ---
# --- is ["migration"], per examples/csw.json. ---
tickets='[
  {"id":"A-1","state":"Todo","priority":2,"blockedBy":["A-9"]},
  {"id":"A-2","state":"Todo","priority":1},
  {"id":"A-3","state":"Todo","priority":2,"relatedTo":["A-9"]},
  {"id":"A-4","state":"Todo","priority":3,"relatedTo":["A-9"]},
  {"id":"A-5","state":"Todo","priority":1,"labels":["migration"]},
  {"id":"A-6","state":"Todo","priority":4,"labels":["migration"]},
  {"id":"A-7","state":"Todo","priority":4}
]'
batch_out=$(printf '%s' "$tickets" | in_dir "$repo" "$BIN/csw-batch-filter")
assert_eq "$(printf '%s' "$batch_out" | jq -c '.selected')" '["A-2","A-5","A-3"]' \
  "example config's cap and priority order pick the winners"
reason() { printf '%s' "$batch_out" | jq -r --arg id "$1" '.skipped[] | select(.id == $id) | .reason'; }
assert_contains "$(reason A-1)" "blocked by A-9" "blocked filter fires"
assert_contains "$(reason A-4)" "cluster" "cluster filter fires"
assert_contains "$(reason A-4)" "A-3" "cluster reason names the winner it lost to"
assert_contains "$(reason A-6)" "single-writer" "single-writer filter fires"
assert_contains "$(reason A-6)" "A-5" "single-writer reason names the holder"
assert_contains "$(reason A-7)" "batch cap" "cap filter fires"

# --- Cross-tool flow: derive a branch name, create and merge it, and confirm ---
# --- the sweep reports it. ---
branch=$(in_dir "$repo" "$BIN/csw-ticket" branch feat 1088 'Add nav vocabulary')
in_dir "$repo" git checkout -q -b "$branch"
printf 'nav work\n' >"$repo/nav.txt"
in_dir "$repo" git add -A
in_dir "$repo" git commit -qm "nav work on $branch"
in_dir "$repo" git checkout -q main
in_dir "$repo" git merge -q --no-ff -m "merge $branch" "$branch"
swept=$(in_dir "$repo" "$BIN/csw-sweep" branches)
assert_contains "$swept" "$branch" \
  "csw-sweep reports the branch csw-ticket derived, once it is merged"

report
