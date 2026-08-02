# CSW Reboot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Claude *Spec* Workflow v0.4.0 with Claude **Ship** Workflow 1.0.0 — a Claude Code plugin that dispatches a tracker ticket into a worktree, lands the PR, and cleans up after it.

**Architecture:** The repo becomes a single-plugin marketplace. Four skills (`work`, `merge`, `cleanup`, `batch`) carry the policy — what to do, when to stop, what to ask. Four small executables in `bin/` carry the deterministic parts — config reading, ticket/branch derivation, gate matching, stale-branch sweeping, batch selection — so the fiddly logic is unit-testable instead of buried in prose. Everything project-specific lives in a `.claude/csw.json` read from the target repo; the plugin ships zero Trakrf values.

**Tech Stack:** Bash (skills + `bin/`), `jq` for config, Python 3 stdlib for the one algorithm bash can't carry cleanly (batch selection), `git` + `gh` for the git half, Linear MCP for the tracker, GitHub Actions + a bash test harness for CI.

## Global Constraints

- **Plugin name is `csw`** — verbatim, kebab-case. It sets the command namespace, so `skills/work/SKILL.md` becomes `/csw:work`. The *repo* renames to `claude-ship-workflow`; the *plugin* does not.
- **Version is `1.0.0`** everywhere it appears: `VERSION`, `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `CHANGELOG.md`. A test enforces that they agree.
- **CSW now expands to "Claude Ship Workflow."** Never "Claude Spec Workflow" in any new or rewritten file except the CHANGELOG's historical entries.
- **No Trakrf values in the plugin.** `TRA`, `just validate`, `just backend migrate-checksums`, `.claude/worktrees` appear only in `examples/csw.json` and in documentation clearly labelled as an example.
- **Merges are always `--merge`.** Never `--squash`, never `--rebase`. `csw-sweep` relies on `git branch --merged` working, which squash-merging breaks.
- **Hold-for-review is a hard stop.** The `work` skill ends at an open PR. It never merges, regardless of what the invoking message said.
- **Draft PR is the state for unfinished work.** Any ticket that does not reach merge-ready autonomously gets a draft PR, not a ready one — `sync-preview`-style automation filters drafts out.
- **Branch/worktree cleanup never asks. Ticket closing always asks.**
- **Runtime requirements:** `bash` 4+, `git` 2.30+, `gh` 2.x, `jq` 1.6+ for phases 1–3. `python3` 3.9+ additionally for phase 4. Document this; do not add other dependencies.
- **Template tokens are `<type>`, `<ticket>`, `<slug>`.** The design doc's `<type>/tra-NNNN-slug` is prose describing the *result*; the literal config value that produces it is `"<type>/<ticket>-<slug>"`.
- **`plugin.json` declares no `dependencies`.** Superpowers is a documented soft requirement checked at runtime, not a hard install-time dependency that breaks installs when superpowers is not in a known marketplace.
- **All `bin/` scripts are `set -euo pipefail`** and portable to macOS bash 3.2 where cheap — no GNU-only `sed` escapes (`\x01`), no `mapfile`.
- **Never write `cmd && other` as a bare statement** in these scripts. Under `set -e` a false left side exits the script. Use `if`/`fi`.

**Working directory:** all paths are relative to the worktree at
`/home/mike/claude-spec-workflow/.claude/worktrees/v2-reboot` on branch
`feat/csw-reboot-superpowers`.

---

### Task 1: Archive tag, teardown, and test harness

Tags the pre-reboot tree for archaeology, deletes every v0.x artifact, and stands up the
bash test harness plus CI that every later task builds on. The test that proves the teardown
is the harness's first test, so the red→green cycle lives inside this task.

**Files:**
- Create: `tests/run-tests.sh`
- Create: `tests/test-helpers.sh`
- Create: `tests/test-no-legacy-paths.sh`
- Create: `.github/workflows/tests.yml`
- Delete: `commands/` (6 files), `skills/`, `scripts/`, `presets/`, `templates/`, `spec/`, `csw`, `TESTING.md`, `issues-for-review.md`, `examples/profile-feature/`, `.envrc`
- Keep untouched: `LICENSE`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `CHANGELOG.md`, `README.md`, `VERSION`, `docs/design.md`

- [ ] **Step 1: Tag the pre-reboot tree as archaeology**

`5abad73` is the last commit of v0.4.0 — the merge commit on `main` before the design
commits. Tag it, do not tag HEAD.

```bash
git tag -a v0.4.0 5abad73 -m "v0.4.0 — final Claude Spec Workflow release (unmaintained, superseded by 1.0.0)"
git push origin v0.4.0
git tag -l
```

Expected: `v0.1.0` and `v0.4.0` listed.

- [ ] **Step 2: Write the test harness**

`tests/run-tests.sh`:

```bash
#!/usr/bin/env bash
# Run every tests/test-*.sh and summarise. Exit non-zero if any file fails.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

for tool in git jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'run-tests: required tool not found: %s\n' "$tool" >&2
    exit 1
  fi
done

failed=0
for t in tests/test-*.sh; do
  [ -f "$t" ] || continue
  printf '\n=== %s ===\n' "$t"
  if bash "$t"; then
    printf 'ok   %s\n' "$t"
  else
    printf 'FAIL %s\n' "$t"
    failed=$((failed + 1))
  fi
done

printf '\n'
if [ "$failed" -gt 0 ]; then
  printf '%d test file(s) failed\n' "$failed"
  exit 1
fi
printf 'all test files passed\n'
```

`tests/test-helpers.sh`:

```bash
#!/usr/bin/env bash
# Shared assertions and fixtures. Source this at the top of every test file.

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
BIN="$REPO_ROOT/bin"
PASSES=0
FAILURES=0
TMPDIRS=()

cleanup_tmpdirs() {
  local d
  for d in "${TMPDIRS[@]:-}"; do
    [ -n "$d" ] || continue
    chmod -R u+w "$d" 2>/dev/null
    rm -rf "$d"
  done
}
trap cleanup_tmpdirs EXIT

assert_eq() { # actual expected label
  if [ "$1" = "$2" ]; then
    PASSES=$((PASSES + 1))
  else
    FAILURES=$((FAILURES + 1))
    printf 'FAIL %s\n  expected: [%s]\n  actual:   [%s]\n' "$3" "$2" "$1" >&2
  fi
}

assert_contains() { # haystack needle label
  case "$1" in
    *"$2"*) PASSES=$((PASSES + 1)) ;;
    *)
      FAILURES=$((FAILURES + 1))
      printf 'FAIL %s\n  expected to contain: [%s]\n  actual: [%s]\n' "$3" "$2" "$1" >&2
      ;;
  esac
}

assert_status() { # expected-code label -- command...
  local expected=$1 label=$2 actual
  shift 3 # drop expected, label, and the literal --
  "$@" >/dev/null 2>&1
  actual=$?
  assert_eq "$actual" "$expected" "$label"
}

# Run a command in a directory, in a subshell. `env -C` would be shorter but is
# GNU-only — BSD env on macOS does not have it.
in_dir() { # dir command...
  local dir=$1
  shift
  (cd "$dir" && "$@")
}

report() {
  printf '%d passed, %d failed\n' "$PASSES" "$FAILURES"
  [ "$FAILURES" -eq 0 ]
}

# Create a throwaway git repo with one commit on main. Prints its path.
make_repo() {
  local dir
  dir=$(mktemp -d)
  TMPDIRS+=("$dir")
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email test@example.com
  git -C "$dir" config user.name "CSW Test"
  git -C "$dir" config commit.gpgsign false
  printf 'seed\n' >"$dir/README.md"
  git -C "$dir" add -A
  git -C "$dir" commit -qm seed
  printf '%s\n' "$dir"
}

# write_config <repo-dir>  — reads the JSON body from stdin
write_config() {
  mkdir -p "$1/.claude"
  cat >"$1/.claude/csw.json"
}
```

- [ ] **Step 3: Write the failing test**

`tests/test-no-legacy-paths.sh`:

```bash
#!/usr/bin/env bash
# The v0.x tree must be gone. Old and new must not coexist.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/test-helpers.sh"

LEGACY="commands scripts presets templates spec csw TESTING.md issues-for-review.md .envrc"

for path in $LEGACY; do
  if [ -e "$REPO_ROOT/$path" ]; then
    FAILURES=$((FAILURES + 1))
    printf 'FAIL legacy path still present: %s\n' "$path" >&2
  else
    PASSES=$((PASSES + 1))
  fi
done

# skills/ itself is legitimate again: the reboot's plugin skills live at
# skills/work/, skills/merge/, skills/cleanup/, skills/batch/. Only the v0.x
# shape — the single flat skills/csw/SKILL.md — must stay gone.
if [ -e "$REPO_ROOT/skills/csw" ]; then
  FAILURES=$((FAILURES + 1))
  printf 'FAIL legacy path still present: skills/csw\n' >&2
else
  PASSES=$((PASSES + 1))
fi

tracked=$(git -C "$REPO_ROOT" ls-files | grep -E '^(commands|scripts|presets|templates|spec|examples/profile-feature)/' || true)
assert_eq "$tracked" "" "no legacy paths tracked in git"

tracked_skills_csw=$(git -C "$REPO_ROOT" ls-files | grep -E '^skills/csw/' || true)
assert_eq "$tracked_skills_csw" "" "no v0.x skills/csw files tracked in git"

kept="LICENSE CONTRIBUTING.md CODE_OF_CONDUCT.md CHANGELOG.md README.md VERSION docs/design.md"
for path in $kept; do
  if [ -e "$REPO_ROOT/$path" ]; then
    PASSES=$((PASSES + 1))
  else
    FAILURES=$((FAILURES + 1))
    printf 'FAIL kept file missing: %s\n' "$path" >&2
  fi
done

report
```

- [ ] **Step 4: Run it and watch it fail**

```bash
chmod +x tests/run-tests.sh
bash tests/run-tests.sh
```

Expected: FAIL — `legacy path still present: commands`, `skills/csw`, `scripts`, `presets`,
`templates`, `spec`, `csw`, `TESTING.md`, `issues-for-review.md`, `.envrc`.

- [ ] **Step 5: Tear down v0.x**

`skills/` and `.envrc` are new-purpose names that will not come back in this shape, and
`examples/` gets rebuilt in Task 12. Remove them all now.

```bash
git rm -r -q commands skills scripts presets templates spec examples
git rm -q csw TESTING.md issues-for-review.md .envrc
ls -A
```

Expected remaining: `.git`, `.gitignore`, `CHANGELOG.md`, `CODE_OF_CONDUCT.md`,
`CONTRIBUTING.md`, `LICENSE`, `README.md`, `VERSION`, `docs/`, `tests/`, `.github/`.

- [ ] **Step 6: Add CI**

`.github/workflows/tests.yml`:

```yaml
name: tests

on:
  push:
    branches: [main]
  pull_request:

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run test suite
        run: bash tests/run-tests.sh
      - name: Shellcheck
        run: |
          sudo apt-get update -qq
          sudo apt-get install -y -qq shellcheck
          shellcheck --severity=warning tests/*.sh $(ls bin/* 2>/dev/null | grep -v batch-filter || true)
```

- [ ] **Step 7: Run the test to verify it passes**

```bash
bash tests/run-tests.sh
```

Expected: PASS — `all test files passed`.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "chore!: tear down v0.x and stand up the test harness

Tags v0.4.0 as archaeology, removes commands/, skills/, scripts/,
presets/, templates/, spec/, examples/ and the csw script. Adds a bash
test harness and CI. Old and new must not coexist.

BREAKING CHANGE: /csw:spec, /csw:plan, /csw:build, /csw:check, /csw:ship
and the csw binary are gone. Superpowers owns that workflow now."
```

---

### Task 2: Plugin manifests

Turns the repo into an installable single-plugin marketplace. Nothing else can be tested
end-to-end until Claude Code can load the plugin.

**Files:**
- Create: `.claude-plugin/plugin.json`
- Create: `.claude-plugin/marketplace.json`
- Create: `tests/test-plugin-manifest.sh`
- Modify: `VERSION`

**Interfaces:**
- Produces: plugin name `csw` — every later skill's command is `/csw:<skill-dir-name>`.
- Produces: `bin/` on the Bash tool's `PATH` when the plugin is enabled, so skills call
  `csw-config`, `csw-ticket`, `csw-gates`, `csw-sweep`, `csw-batch-filter` as bare commands.

- [ ] **Step 1: Write the failing test**

`tests/test-plugin-manifest.sh`:

```bash
#!/usr/bin/env bash
# Manifests must be valid JSON, name the plugin csw, and agree on the version.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/test-helpers.sh"

PLUGIN="$REPO_ROOT/.claude-plugin/plugin.json"
MARKET="$REPO_ROOT/.claude-plugin/marketplace.json"

for f in "$PLUGIN" "$MARKET"; do
  if [ -f "$f" ]; then
    PASSES=$((PASSES + 1))
  else
    FAILURES=$((FAILURES + 1))
    printf 'FAIL missing manifest: %s\n' "$f" >&2
    report
    exit 1
  fi
  if jq -e . "$f" >/dev/null 2>&1; then
    PASSES=$((PASSES + 1))
  else
    FAILURES=$((FAILURES + 1))
    printf 'FAIL invalid JSON: %s\n' "$f" >&2
  fi
done

assert_eq "$(jq -r .name "$PLUGIN")" "csw" "plugin name is csw"
assert_eq "$(jq -r .license "$PLUGIN")" "MIT" "plugin license is MIT"
assert_eq "$(jq -r '.dependencies // "absent"' "$PLUGIN")" "absent" "no hard dependencies declared"

version_file=$(tr -d '[:space:]' <"$REPO_ROOT/VERSION")
assert_eq "$version_file" "1.0.0" "VERSION is 1.0.0"
assert_eq "$(jq -r .version "$PLUGIN")" "$version_file" "plugin.json version matches VERSION"

assert_eq "$(jq -r '.plugins | length' "$MARKET")" "1" "marketplace lists exactly one plugin"
assert_eq "$(jq -r '.plugins[0].name' "$MARKET")" "csw" "marketplace entry is named csw"
assert_eq "$(jq -r '.plugins[0].source' "$MARKET")" "./" "marketplace entry sources the repo root"
assert_eq "$(jq -r '.plugins[0].version' "$MARKET")" "$version_file" "marketplace version matches VERSION"

# The reboot's meaning of CSW must be consistent.
assert_contains "$(jq -r .description "$PLUGIN")" "Ship" "plugin description says Ship"
spec_leak=$(grep -rl "Claude Spec Workflow" "$REPO_ROOT/.claude-plugin" 2>/dev/null || true)
assert_eq "$spec_leak" "" "manifests do not say Claude Spec Workflow"

report
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bash tests/test-plugin-manifest.sh
```

Expected: FAIL — `missing manifest: .../.claude-plugin/plugin.json`.

- [ ] **Step 3: Write the manifests**

`.claude-plugin/plugin.json`:

```json
{
  "$schema": "https://json.schemastore.org/claude-code-plugin-manifest.json",
  "name": "csw",
  "displayName": "Claude Ship Workflow",
  "version": "1.0.0",
  "description": "Ship a tracker ticket: dispatch it into a worktree, drive it to a pull request, merge it after review, and clean up after itself.",
  "author": {
    "name": "Mike Stankavich",
    "email": "miks2u@gmail.com"
  },
  "homepage": "https://github.com/mikestankavich/claude-ship-workflow",
  "repository": "https://github.com/mikestankavich/claude-ship-workflow",
  "license": "MIT",
  "keywords": [
    "workflow",
    "worktree",
    "pull-request",
    "cleanup",
    "linear",
    "github"
  ]
}
```

`.claude-plugin/marketplace.json`:

```json
{
  "name": "claude-ship-workflow",
  "description": "Claude Ship Workflow — one person's ticket-to-merged-PR workflow, packaged.",
  "owner": {
    "name": "Mike Stankavich",
    "email": "miks2u@gmail.com"
  },
  "plugins": [
    {
      "name": "csw",
      "description": "Ship a tracker ticket: dispatch it into a worktree, drive it to a pull request, merge it after review, and clean up after itself.",
      "version": "1.0.0",
      "source": "./",
      "author": {
        "name": "Mike Stankavich",
        "email": "miks2u@gmail.com"
      }
    }
  ]
}
```

- [ ] **Step 4: Bump VERSION**

Replace the contents of `VERSION` with exactly:

```
1.0.0
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
bash tests/run-tests.sh
```

Expected: PASS, both test files.

- [ ] **Step 6: Verify with the plugin validator if available**

```bash
claude plugin validate . --strict || echo "validator unavailable — skipping"
```

Expected: passes, or the skip message. A validator failure is a real failure — fix it before
committing.

- [ ] **Step 7: Commit**

```bash
git add .claude-plugin VERSION tests/test-plugin-manifest.sh
git commit -m "feat: add csw plugin and marketplace manifests at 1.0.0"
```

---

### Task 3: `bin/csw-config`

The config layer. Every other executable and every skill reads project settings through
this one entry point, so defaults and lookup order are defined in exactly one place.

**Files:**
- Create: `bin/csw-config`
- Create: `tests/test-csw-config.sh`

**Interfaces:**
- Produces: `csw-config json` → effective config on stdout (defaults deep-merged with the
  repo's file). `csw-config get <dotted.key>` → one value; strings bare, objects/arrays as
  compact JSON. `csw-config path` → path of the config file, or empty output if absent.
- Produces exit codes: `0` ok, `2` unknown key or bad usage, `3` not a git repository,
  `4` config file is not valid JSON.
- Produces these effective keys, consumed by every later task: `ticketPrefix`, `tracker`,
  `baseBranch`, `defaultType`, `validate`, `worktreeDir`, `branchPattern`, `gates`
  (array of `{when, run}`), `batch.maxTickets`, `batch.singleWriterLabels`.

- [ ] **Step 1: Write the failing test**

`tests/test-csw-config.sh`:

```bash
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
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bash tests/test-csw-config.sh
```

Expected: FAIL on every assertion — `csw-config: No such file or directory`.

- [ ] **Step 3: Write the implementation**

`bin/csw-config`:

```bash
#!/usr/bin/env bash
# csw-config — read the effective CSW config for the current repository.
#
# Looks for .claude/csw.json in the current worktree root first, then in the
# main worktree root. The fallback matters because .claude/worktrees/ is
# usually gitignored, so a linked worktree does not carry the config file.
set -euo pipefail

DEFAULTS='{
  "ticketPrefix": "",
  "tracker": "none",
  "baseBranch": "main",
  "defaultType": "feat",
  "validate": "",
  "worktreeDir": ".worktrees",
  "branchPattern": "<type>/<ticket>-<slug>",
  "gates": [],
  "batch": { "maxTickets": 3, "singleWriterLabels": ["migration"] }
}'

die() { printf 'csw-config: %s\n' "$1" >&2; exit "$2"; }

usage() {
  cat <<'EOF'
Usage:
  csw-config json           Print the effective config (defaults merged with the repo's)
  csw-config get <key>      Print one value; dotted keys index into objects
  csw-config path           Print the config file path, or nothing if there is none
EOF
}

config_path() {
  local root common main
  root=$(git rev-parse --show-toplevel 2>/dev/null) || die "not in a git repository" 3
  if [ -f "$root/.claude/csw.json" ]; then
    printf '%s\n' "$root/.claude/csw.json"
    return 0
  fi
  common=$(git rev-parse --git-common-dir 2>/dev/null) || return 0
  case "$common" in
    /*) ;;
    *) common="$root/$common" ;;
  esac
  main=$(cd "$common/.." 2>/dev/null && pwd -P) || return 0
  if [ -f "$main/.claude/csw.json" ]; then
    printf '%s\n' "$main/.claude/csw.json"
  fi
  return 0
}

effective() {
  local p status
  status=0
  # Capture config_path's exit status explicitly rather than relying on
  # `set -e` to abort here: when `effective` itself is invoked inside a
  # command substitution (as `get` below does), bash runs it in a subshell
  # where -e is off by default (there is no portable `inherit_errexit` on
  # bash 3.2), so a bare `p=$(config_path)` would silently swallow a
  # not-a-git-repo (3) failure and fall through to "no config, use defaults".
  p=$(config_path) || status=$?
  if [ "$status" -ne 0 ]; then
    exit "$status"
  fi
  if [ -z "$p" ]; then
    printf '%s' "$DEFAULTS" | jq '.'
    return 0
  fi
  if ! jq -e . "$p" >/dev/null 2>&1; then
    die "invalid JSON in $p" 4
  fi
  if ! jq -e 'type == "object"' "$p" >/dev/null 2>&1; then
    die "config must be a JSON object, not $(jq -r 'type' "$p") — $p" 4
  fi
  # jq's `*` deep-merges objects and replaces arrays, which is what we want:
  # a repo listing two gates should get exactly those two, not those plus ours.
  jq -n --argjson d "$DEFAULTS" --slurpfile u "$p" '$d * $u[0]'
}

cmd=${1:-}
case "$cmd" in
  json)
    effective
    ;;
  path)
    config_path
    ;;
  get)
    if [ $# -ne 2 ]; then die "usage: csw-config get <key>" 2; fi
    # `effective` now checks config_path's exit status itself and calls
    # `exit` directly on failure (see its definition above), so this
    # `|| exit $?` is a second line of defence rather than the only one —
    # either way, exit 3 (not a git repo) and exit 4 (malformed config)
    # must reach the caller unchanged, not collapse into "unknown key".
    json=$(effective) || exit $?
    # Test path *existence* rather than inferring it from the value, so a key
    # explicitly set to null is distinguishable from a key that is absent.
    exists=$(printf '%s' "$json" | jq -r --arg k "$2" '
      ($k | split(".")) as $p
      | if (getpath($p[0:-1]) | type) == "object" and (getpath($p[0:-1]) | has($p[-1]))
        then "yes" else "no" end' 2>/dev/null) || exists=no
    if [ "$exists" != "yes" ]; then
      die "unknown key: $2" 2
    fi
    value=$(printf '%s' "$json" | jq -c --arg k "$2" 'getpath($k | split("."))')
    printf '%s' "$value" | jq -r 'if type == "string" then . else tojson end'
    ;;
  ''|-h|--help)
    usage
    ;;
  *)
    die "unknown subcommand: $cmd" 2
    ;;
esac
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
chmod +x bin/csw-config
bash tests/test-csw-config.sh
```

Expected: PASS — `27 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add bin/csw-config tests/test-csw-config.sh
git commit -m "feat(bin): add csw-config, the per-repo config layer"
```

---

### Task 4: `bin/csw-ticket`

Ticket-reference normalisation and branch naming. This is where `1088`, `tra-1088`, and
`TRA-1088` all become one thing, and where the branch pattern gets rendered.

**Files:**
- Create: `bin/csw-ticket`
- Create: `tests/test-csw-ticket.sh`

**Interfaces:**
- Consumes: `csw-config get ticketPrefix`, `csw-config get branchPattern` (Task 3).
- Produces: `csw-ticket normalize <ref>` → `TRA-1088`. `csw-ticket number <ref>` → `1088`.
  `csw-ticket slug <words...>` → `add-nav-vocabulary`. `csw-ticket branch <type> <ref>
  <title...>` → `feat/tra-1088-add-nav-vocabulary`.
- Produces exit codes: `0` ok, `2` unparseable reference, empty slug, or bad usage.

- [ ] **Step 1: Write the failing test**

`tests/test-csw-ticket.sh`:

```bash
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
# reference normalize can't parse back.
write_config "$repo" <<'JSON'
{ "ticketPrefix": "1AB", "branchPattern": "<type>/<ticket>-<slug>" }
JSON
assert_status 2 "ticketPrefix starting with a digit exits 2" -- "$BIN/csw-ticket" normalize 42
write_config "$repo" <<'JSON'
{ "ticketPrefix": "TRA-X", "branchPattern": "<type>/<ticket>-<slug>" }
JSON
assert_status 2 "ticketPrefix containing a dash exits 2" -- "$BIN/csw-ticket" normalize 42

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
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bash tests/test-csw-ticket.sh
```

Expected: FAIL — `csw-ticket: No such file or directory` on every assertion.

- [ ] **Step 3: Write the implementation**

`bin/csw-ticket`:

```bash
#!/usr/bin/env bash
# csw-ticket — normalise ticket references and derive branch names.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

die() { printf 'csw-ticket: %s\n' "$1" >&2; exit "$2"; }
config() { "$HERE/csw-config" "$@"; }

usage() {
  cat <<'EOF'
Usage:
  csw-ticket normalize <ref>                 1088 | tra-1088 | TRA-1088  ->  TRA-1088
  csw-ticket number <ref>                    TRA-1088                    ->  1088
  csw-ticket slug <words...>                 "Add nav vocabulary"        ->  add-nav-vocabulary
  csw-ticket branch <type> <ref> <title...>  feat TRA-1088 "Add nav ..." ->  feat/tra-1088-add-nav-vocabulary
EOF
}

slugify() {
  local s
  s=$(printf '%s' "$*" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-\{1,\}//' -e 's/-\{1,\}$//')
  # Truncate to 40 characters, then drop a dash the cut may have left dangling.
  s=$(printf '%s' "$s" | cut -c1-40 | sed -e 's/-\{1,\}$//')
  printf '%s' "$s"
}

# A configured ticketPrefix must itself be parseable back out of a normalised
# reference (letter, then letters/digits, no dash). Reject anything else here
# rather than silently minting references normalize() cannot round-trip.
validate_prefix() {
  local p=$1
  if [ -n "$p" ] && ! printf '%s' "$p" | grep -q '^[A-Za-z][A-Za-z0-9]*$'; then
    die "invalid ticketPrefix in config: '$p' (must start with a letter, then letters or digits only)" 2
  fi
}

normalize() {
  local raw prefix letters digits
  raw=$(printf '%s' "${1-}" | tr -d '[:space:]')
  if [ -z "$raw" ]; then die "empty ticket reference" 2; fi

  if printf '%s' "$raw" | grep -q '^[0-9][0-9]*$'; then
    prefix=$(config get ticketPrefix)
    validate_prefix "$prefix"
    if [ -z "$prefix" ]; then
      die "bare number '$raw' needs \"ticketPrefix\" in .claude/csw.json" 2
    fi
    printf '%s-%s\n' "$prefix" "$raw"
    return 0
  fi

  # Dashed: a prefix (which may itself contain digits, e.g. a "K8S" team key)
  # followed by exactly one separating dash and a run of digits. Split on the
  # LAST dash so a digit-bearing prefix is not mistaken for a malformed
  # multi-segment reference.
  if printf '%s' "$raw" | grep -q '^[A-Za-z][A-Za-z0-9]*-[0-9][0-9]*$'; then
    letters=${raw%-*}
    digits=${raw##*-}
    letters=$(printf '%s' "$letters" | tr '[:lower:]' '[:upper:]')
    printf '%s-%s\n' "$letters" "$digits"
    return 0
  fi

  # Undashed: only unambiguous when the prefix is pure alphabetic (tra1088 ->
  # TRA-1088). An undashed alphanumeric prefix like K8S42 is genuinely
  # ambiguous about where the prefix ends and the ticket number begins, so it
  # falls through to the rejection below.
  if printf '%s' "$raw" | grep -q '^[A-Za-z][A-Za-z]*[0-9][0-9]*$'; then
    letters=$(printf '%s' "$raw" | sed -e 's/[0-9].*$//' | tr '[:lower:]' '[:upper:]')
    digits=$(printf '%s' "$raw" | sed -e 's/^[A-Za-z]*//')
    printf '%s-%s\n' "$letters" "$digits"
    return 0
  fi

  die "not a ticket reference: ${1-}" 2
}

cmd=${1:-}
case "$cmd" in
  normalize)
    if [ $# -ne 2 ]; then die "usage: csw-ticket normalize <ref>" 2; fi
    normalize "$2"
    ;;
  number)
    if [ $# -ne 2 ]; then die "usage: csw-ticket number <ref>" 2; fi
    # Strip everything up to and including the LAST dash (not a leading
    # `[A-Z]*-`), so a prefix containing digits (K8S-42) still yields 42
    # instead of being left untouched.
    normalized=$(normalize "$2")
    printf '%s\n' "${normalized##*-}"
    ;;
  slug)
    shift
    if [ $# -eq 0 ]; then die "usage: csw-ticket slug <words...>" 2; fi
    slug=$(slugify "$@")
    if [ -z "$slug" ]; then die "title produced an empty slug" 2; fi
    printf '%s\n' "$slug"
    ;;
  branch)
    if [ $# -lt 4 ]; then die "usage: csw-ticket branch <type> <ref> <title...>" 2; fi
    type=$2
    ticket=$(normalize "$3")
    shift 3
    slug=$(slugify "$@")
    if [ -z "$slug" ]; then die "title produced an empty slug" 2; fi
    pattern=$(config get branchPattern)
    lower=$(printf '%s' "$ticket" | tr '[:upper:]' '[:lower:]')
    out=${pattern//<type>/$type}
    out=${out//<ticket>/$lower}
    out=${out//<slug>/$slug}
    printf '%s\n' "$out"
    ;;
  ''|-h|--help)
    usage
    ;;
  *)
    die "unknown subcommand: $cmd" 2
    ;;
esac
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
chmod +x bin/csw-ticket
bash tests/test-csw-ticket.sh
```

Expected: PASS — `29 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add bin/csw-ticket tests/test-csw-ticket.sh
git commit -m "feat(bin): add csw-ticket for reference normalisation and branch naming"
```

---

### Task 5: `bin/csw-gates`

Turns "which files did this branch touch" into "which extra validation commands must run."
Encodes the design's migration-checksums and Playwright-on-preview gates as config, not as
prose the assistant has to remember.

**Files:**
- Create: `bin/csw-gates`
- Create: `tests/test-csw-gates.sh`

**Interfaces:**
- Consumes: `csw-config get gates` (Task 3) — an array of `{"when": <glob>, "run": <command>}`.
- Produces: `csw-gates <base-ref>` → one shell command per line, in config order, deduped by
  command. `csw-gates --files` reads a newline-separated file list from stdin instead of
  diffing. Exit `0` even when nothing matches (empty output is the answer).
- Glob semantics: `**` matches across `/`, `*` matches within one segment, `?` matches one
  non-`/` character, and the pattern is anchored to the whole path.
- Exit codes: `0` success (including "no gates matched"), `2` cannot diff the given base ref,
  `4` malformed config — `gates` is not an array, a `gates` entry is not an object, or an
  object entry is missing `when` or `run`. `3` (not in a git repository) propagates unchanged
  from `csw-config`.
- Blank lines in the file list (from either source) are stripped before any matching happens.
  An empty file list — a zero-file diff, or empty `--files` stdin — prints nothing and exits 0
  without evaluating any gate or fetching the config, so a catch-all `when` like `**` or `*`
  can never false-match a no-op diff.

- [ ] **Step 1: Write the failing test**

`tests/test-csw-gates.sh`:

```bash
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

bad_missing_when=$(make_repo)
write_config "$bad_missing_when" <<'JSON'
{ "gates": [ { "run": "just foo" } ] }
JSON
assert_status 4 "a gates entry missing when exits 4 rather than silently skipping" -- \
  sh -c "cd '$bad_missing_when' && printf 'foo/x\n' | '$BIN/csw-gates' --files"

# A valid gates array still behaves exactly as before.
good=$(make_repo)
write_config "$good" <<'JSON'
{ "gates": [ { "when": "foo/**", "run": "just foo" } ] }
JSON
assert_eq "$(cd "$good" && printf 'foo/x\n' | "$BIN/csw-gates" --files)" "just foo" \
  "a valid gates array still matches as before"

# An empty file list must never match a catch-all glob (fix round 3):
# `printf '%s\n' "$files"` turns a truly empty `$files` into one blank line,
# and `grep -Eq` would otherwise happily match that blank line against any
# glob that can match the empty string, like `**` or `*`.
catchall_star=$(make_repo)
write_config "$catchall_star" <<'JSON'
{ "gates": [{ "when": "**", "run": "cmd-catchall" }] }
JSON
assert_eq "$(cd "$catchall_star" && printf '' | "$BIN/csw-gates" --files)" "" \
  "empty stdin with when ** produces no output"
assert_status 0 "empty stdin with when ** still exits 0" -- \
  sh -c "cd '$catchall_star' && printf '' | '$BIN/csw-gates' --files"

catchall_single=$(make_repo)
write_config "$catchall_single" <<'JSON'
{ "gates": [{ "when": "*", "run": "cmd-catchall" }] }
JSON
assert_eq "$(cd "$catchall_single" && printf '' | "$BIN/csw-gates" --files)" "" \
  "empty stdin with when * produces no output"
assert_status 0 "empty stdin with when * still exits 0" -- \
  sh -c "cd '$catchall_single' && printf '' | '$BIN/csw-gates' --files"

# Same bug, diff mode: a branch with zero changed files must not fire a
# catch-all gate either.
nochange=$(make_repo)
write_config "$nochange" <<'JSON'
{ "gates": [{ "when": "**", "run": "cmd-catchall" }] }
JSON
git -C "$nochange" checkout -q -b feat/nochange
assert_eq "$(cd "$nochange" && "$BIN/csw-gates" main)" "" \
  "diff mode with zero changed files produces no output"
assert_status 0 "diff mode with zero changed files still exits 0" -- \
  sh -c "cd '$nochange' && '$BIN/csw-gates' main"

# Non-empty diff still fires a catch-all glob — the fix must not swing the
# other way and break `**`/`*` entirely.
assert_eq "$(cd "$catchall_star" && printf 'anything.txt\n' | "$BIN/csw-gates" --files)" \
  "cmd-catchall" "a real change still fires a catch-all when **"

# A file list with blank lines interleaved among real paths must match
# exactly as if the blank lines were absent.
blanks=$(make_repo)
write_config "$blanks" <<'JSON'
{ "gates": [{ "when": "a.txt", "run": "cmd-a" }, { "when": "b.txt", "run": "cmd-b" }] }
JSON
assert_eq "$(cd "$blanks" && printf 'a.txt\n\nb.txt\n' | "$BIN/csw-gates" --files)" \
  "cmd-a
cmd-b" "blank lines interleaved among real paths do not change matching"

# A bad base ref exits 2, and only this script's own message reaches
# stderr — git's own ~50-line usage dump must not leak through.
badref=$(make_repo)
assert_status 2 "bad base ref exits 2" -- \
  sh -c "cd '$badref' && '$BIN/csw-gates' totally-bogus-ref-xyz"
badref_stderr=$(cd "$badref" && "$BIN/csw-gates" totally-bogus-ref-xyz 2>&1 >/dev/null)
assert_eq "$badref_stderr" 'csw-gates: cannot diff totally-bogus-ref-xyz...HEAD' \
  "bad base ref stderr is only the csw-gates message, no git usage block"

report
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bash tests/test-csw-gates.sh
```

Expected: FAIL — `csw-gates: No such file or directory`.

- [ ] **Step 3: Write the implementation**

`bin/csw-gates`:

```bash
#!/usr/bin/env bash
# csw-gates — print the extra validation commands this diff triggers.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

die() { printf 'csw-gates: %s\n' "$1" >&2; exit "$2"; }

usage() {
  cat <<'EOF'
Usage:
  csw-gates <base-ref>   Diff <base-ref>...HEAD and print the gates it triggers
  csw-gates --files      Read a newline-separated file list from stdin instead
EOF
}

# Convert a config glob to an anchored POSIX extended regex.
# ** crosses slashes, * does not, ? matches one non-slash character.
glob_to_regex() {
  local g=$1 out='' c i
  i=0
  while [ "$i" -lt "${#g}" ]; do
    c=${g:i:1}
    # A literal backslash must become the two-character ERE `\\`. Handled here,
    # ahead of the case, because case-pattern quoting can't match it: a
    # single-quoted '\\' pattern requires the tested value to contain two
    # backslash characters, but $c is always exactly one — that arm can never
    # fire, so a lone backslash used to fall through unescaped into the regex.
    if [ "$c" = '\' ]; then
      out="${out}\\\\"
      i=$((i + 1))
      continue
    fi
    case $c in
      '*')
        if [ "${g:i+1:1}" = '*' ]; then
          out="${out}.*"
          i=$((i + 1))
        else
          out="${out}[^/]*"
        fi
        ;;
      '?')
        out="${out}[^/]"
        ;;
      '.'|'['|']'|'('|')'|'{'|'}'|'+'|'^'|'$'|'|') out="${out}\\$c" ;;
      *) out="${out}$c" ;;
    esac
    i=$((i + 1))
  done
  printf '^%s$' "$out"
}

case "${1:-}" in
  ''|-h|--help)
    usage
    exit 0
    ;;
  --files)
    files=$(cat)
    ;;
  *)
    # Silence git's own error output (a ~50-line usage dump on a bad ref, or
    # a "not a git repository" warning outside one) so only this script's own
    # die() message reaches the user.
    files=$(git diff --name-only "$1...HEAD" 2>/dev/null) || die "cannot diff $1...HEAD" 2
    ;;
esac

# Blank lines are never real paths. Strip them before anything tries to match
# against them: `printf '%s\n' "$files"` turns an empty `$files` (a zero-file
# diff, or empty stdin) into exactly one blank line, and `grep -Eq` happily
# matches that blank line against any glob that can match the empty string —
# `**`, `*`, `*.sql`, etc. — so a catch-all gate would otherwise fire on a
# no-op diff. Filtering here also means a file list with blank lines
# interleaved among real paths (`a.txt`, ``, `b.txt`) matches exactly as if
# the blank lines were absent, since every match below reads this same
# already-filtered `$files`.
files=$(printf '%s\n' "$files" | grep -v '^$') || files=''

# Nothing to match against: print nothing and exit 0 without evaluating any
# gate — not even a malformed-config check, since there is nothing a gate
# could have fired on either way.
if [ -z "$files" ]; then
  exit 0
fi

gates=$("$HERE/csw-config" get gates)

# The "gates" config key must be a JSON array — {} or a bare string would
# otherwise leak a raw jq trace and an undocumented exit code the first time
# something below tries to index or iterate it. Same failure class as
# csw-config's "config must be a JSON object" check, so it gets the same
# exit code: 4, malformed config.
#
# `csw-config get` unwraps a top-level JSON string to raw unquoted text (so
# scalar keys like ticketPrefix print without quotes), which means a
# string-valued "gates" arrives here as text that isn't valid JSON at all —
# a second, unguarded `jq -r 'type'` on it would itself fail to parse and
# print its own trace to stderr. Suppress that and fall back to a plain
# description instead, so only this script's own die() message reaches the
# user, in every case.
gates_type=$(printf '%s' "$gates" | jq -r 'type' 2>/dev/null) || gates_type='valid JSON'
if [ "$gates_type" != array ]; then
  die "config key \"gates\" must be an array, not $gates_type" 4
fi

count=$(printf '%s' "$gates" | jq 'length')

emitted=''
i=0
while [ "$i" -lt "$count" ]; do
  entry_type=$(printf '%s' "$gates" | jq -r ".[$i] | type")
  if [ "$entry_type" != object ]; then
    die "gates[$i] must be an object, not $entry_type" 4
  fi
  when=$(printf '%s' "$gates" | jq -r ".[$i].when // empty")
  run=$(printf '%s' "$gates" | jq -r ".[$i].run // empty")
  # Silently skipping a configured gate is a wrong answer, not a safe
  # default — a migration-checksum gate that quietly never runs is the exact
  # failure this program exists to prevent. Reject it instead.
  if [ -z "$when" ] || [ -z "$run" ]; then
    die "gates[$i] is missing \"when\" or \"run\"" 4
  fi
  i=$((i + 1))
  regex=$(glob_to_regex "$when")
  if printf '%s\n' "$files" | grep -Eq "$regex"; then
    if ! printf '%s' "$emitted" | grep -Fxq -- "$run"; then
      printf '%s\n' "$run"
      emitted="${emitted}${run}
"
    fi
  fi
done
```

Note: the `emitted` dedup accumulator is newline-delimited and checked with
`grep -Fxq` (fixed-string, whole-line), not the earlier `|`-delimited
substring check — a `run` value containing an embedded literal newline could
still confuse it, but `run` values are expected to be single command lines.

A gates entry that is an object but missing `when` or `run` now `die`s with
exit 4 instead of being silently skipped — see fix round 2 in
task-5-report.md for why (the brief's own shipped test never asserted the
skip behavior, and silently not running a configured gate is the exact
failure this program exists to prevent).

The blank-line normalization and empty-file-list short circuit (fix round 3
in task-5-report.md) close a Critical: an empty diff used to false-match any
`when` glob that can match the empty string (`**`, `*`, ...), silently
firing a catch-all gate — e.g. a Playwright-against-preview run — on a no-op
diff. The fix strips blank lines from the file list before any matching
happens (in both `--files` and diff mode) and exits 0 with no output as soon
as the filtered list is empty, before fetching config or evaluating any
gate.

- [ ] **Step 4: Run the test to verify it passes**

```bash
chmod +x bin/csw-gates
bash tests/test-csw-gates.sh
```

Expected: PASS — `40 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add bin/csw-gates tests/test-csw-gates.sh
git commit -m "feat(bin): add csw-gates to map a diff onto extra validation commands"
```

---

### Task 6: `bin/csw-sweep`

The answer to *"wait, why are we on a TRA-1079 worktree?"* — finds merged-but-undeleted
branches and the worktrees still holding them, so cleanup can report them unprompted.

**Files:**
- Create: `bin/csw-sweep`
- Create: `tests/test-csw-sweep.sh`

**Interfaces:**
- Consumes: `csw-config get baseBranch`, `csw-config get worktreeDir` (Task 3).
- Produces: `csw-sweep branches` → one local branch name per line, merged into the base or
  whose upstream is gone, never including the base or the current branch.
  `csw-sweep worktrees` → `<path>\t<branch>` per line for worktrees holding such a branch.
  `csw-sweep` with no argument → a human-readable report, or `nothing to sweep`.
- **Narrowed exit contract:** exit `0` applies to sweep *results* — finding nothing is
  information, not an error, in every subcommand. It does **not** apply to environment
  failures. A `csw-config` lookup failing (not a git repository, malformed config) surfaces
  as `csw-sweep`'s own message naming which config lookup failed, propagating the
  underlying exit code rather than leaking the other tool's wording. A bare repository
  (no working tree) is its own case: `csw-config`'s generic "not in a git repository" is
  actively misleading there — a bare repo *is* a repository — so `csw-sweep` detects it
  directly and exits non-zero with a message saying it needs a working tree. A worktree
  path that cannot be represented in the `<path><TAB><branch>` output contract (it
  contains a literal TAB or newline) is also an environment failure, not a sweep result:
  `csw-sweep worktrees` exits `2` naming the offending path rather than silently
  mis-parsing or dropping it.
- **Depends on `--merge` merges.** `git branch --merged` cannot see a squash-merged branch;
  the `--delete-branch` upstream-gone check is the backstop when it does not.

- [ ] **Step 1: Write the failing test**

`tests/test-csw-sweep.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/test-helpers.sh"

repo=$(make_repo)
write_config "$repo" <<'JSON'
{ "baseBranch": "main", "worktreeDir": ".claude/worktrees" }
JSON
cd "$repo" || exit 1

# A merged branch and an unmerged one.
git checkout -q -b feat/merged
printf 'merged\n' >merged.txt
git add -A && git commit -qm "merged work"
git checkout -q main
git merge -q --no-ff -m "merge feat/merged" feat/merged

git checkout -q -b feat/unmerged
printf 'wip\n' >wip.txt
git add -A && git commit -qm "work in progress"
git checkout -q main

branches=$("$BIN/csw-sweep" branches)
assert_contains "$branches" "feat/merged" "merged branch is swept"
case "$branches" in
  *feat/unmerged*) assert_eq "unmerged-listed" "not-listed" "unmerged branch must not be swept" ;;
  *) PASSES=$((PASSES + 1)) ;;
esac
case "$branches" in
  *main*) assert_eq "base-listed" "not-listed" "base branch must not be swept" ;;
  *) PASSES=$((PASSES + 1)) ;;
esac

# The current branch is never swept, even when it is merged.
git checkout -q feat/merged
assert_eq "$("$BIN/csw-sweep" branches | grep -c 'feat/merged' || true)" "0" \
  "current branch is never swept"
git checkout -q main

# A worktree holding a merged branch shows up; one holding unmerged work does not.
git worktree add -q "$repo/.claude/worktrees/merged" feat/merged
git worktree add -q "$repo/.claude/worktrees/unmerged" feat/unmerged
worktrees=$("$BIN/csw-sweep" worktrees)
assert_contains "$worktrees" "worktrees/merged" "worktree on a merged branch is swept"
# Exactly one line: not the unmerged worktree, and not the main worktree.
assert_eq "$(printf '%s' "$worktrees" | grep -c . || true)" "1" \
  "only the merged worktree is swept"

# A clean repo sweeps to nothing, and still exits 0.
clean=$(make_repo)
assert_eq "$(cd "$clean" && "$BIN/csw-sweep" branches)" "" "clean repo has no branches to sweep"
assert_contains "$(cd "$clean" && "$BIN/csw-sweep")" "nothing to sweep" "clean repo reports nothing to sweep"
assert_status 0 "clean sweep exits 0" -- in_dir "$clean" "$BIN/csw-sweep"

# A `.` in the current branch name must not act as a regex wildcard and
# swallow an unrelated merged branch (feat/a.b as current used to hide
# feat/aXb, because grep -vx treated the current branch as a pattern).
dotrepo=$(make_repo)
write_config "$dotrepo" <<'JSON'
{ "baseBranch": "main", "worktreeDir": ".claude/worktrees" }
JSON
(
  cd "$dotrepo" || exit 1
  git checkout -q -b feat/a.b
  printf 'ab\n' >ab.txt
  git add -A && git commit -qm "a.b work"
  git checkout -q main
  git merge -q --no-ff -m "merge feat/a.b" feat/a.b

  git checkout -q -b feat/aXb
  printf 'axb\n' >axb.txt
  git add -A && git commit -qm "aXb work"
  git checkout -q main
  git merge -q --no-ff -m "merge feat/aXb" feat/aXb

  git checkout -q feat/a.b
)
dot_branches=$(cd "$dotrepo" && "$BIN/csw-sweep" branches)
assert_contains "$dot_branches" "feat/aXb" \
  "a dot in the current branch name does not swallow an unrelated merged branch"

# A branch name with a `+` (also special to regexes) round-trips correctly
# through both `branches` and `worktrees`.
plusrepo=$(make_repo)
write_config "$plusrepo" <<'JSON'
{ "baseBranch": "main", "worktreeDir": ".claude/worktrees" }
JSON
(
  cd "$plusrepo" || exit 1
  git checkout -q -b "feat/a+b"
  printf 'plus\n' >plus.txt
  git add -A && git commit -qm "a+b work"
  git checkout -q main
  git merge -q --no-ff -m "merge feat/a+b" "feat/a+b"
  git worktree add -q "$plusrepo/.claude/worktrees/plus" "feat/a+b"
)
plus_branches=$(cd "$plusrepo" && "$BIN/csw-sweep" branches)
assert_contains "$plus_branches" "feat/a+b" "a + in a branch name round-trips through branches"
plus_worktrees=$(cd "$plusrepo" && "$BIN/csw-sweep" worktrees)
assert_contains "$plus_worktrees" "worktrees/plus" "a + in a branch name round-trips through worktrees (path)"
assert_contains "$plus_worktrees" "feat/a+b" "a + in a branch name round-trips through worktrees (branch)"

# HEAD detached in the main worktree must not leak the synthetic
# "(HEAD detached at ...)" pseudo-entry into `branches` output, and
# `worktrees` output must still parse as exactly <path><TAB><branch>.
detrepo=$(make_repo)
write_config "$detrepo" <<'JSON'
{ "baseBranch": "main", "worktreeDir": ".claude/worktrees" }
JSON
(
  cd "$detrepo" || exit 1
  git checkout -q -b feat/detected
  printf 'd\n' >d.txt
  git add -A && git commit -qm "detected work"
  git checkout -q main
  git merge -q --no-ff -m "merge feat/detected" feat/detected
  git worktree add -q "$detrepo/.claude/worktrees/detected" feat/detected
  git checkout -q --detach main
)
det_branches=$(cd "$detrepo" && "$BIN/csw-sweep" branches)
assert_contains "$det_branches" "feat/detected" \
  "detached HEAD in the main worktree still sweeps real merged branches"
case "$det_branches" in
  *"HEAD detached"*)
    assert_eq "leaked-pseudo-entry" "no-pseudo-entry" \
      "detached HEAD must not leak a pseudo branch-name line into branches" ;;
  *) PASSES=$((PASSES + 1)) ;;
esac

det_worktrees=$(cd "$detrepo" && "$BIN/csw-sweep" worktrees)
assert_contains "$det_worktrees" "worktrees/detected" \
  "worktree on a merged branch is still swept when main HEAD is detached"
case "$det_worktrees" in
  *"HEAD detached"*)
    assert_eq "leaked-pseudo-entry-worktrees" "no-pseudo-entry" \
      "worktrees output must not contain a HEAD-detached pseudo-entry" ;;
  *) PASSES=$((PASSES + 1)) ;;
esac
badfields=$(printf '%s\n' "$det_worktrees" | awk -F'\t' 'NF && NF != 2 { c++ } END { print c + 0 }')
assert_eq "$badfields" "0" \
  "worktrees output parses as exactly <path><TAB><branch> when main HEAD is detached"

# A worktree path containing a literal TAB cannot be represented in the
# <path><TAB><branch> output contract. csw-sweep must fail loudly (exit 2,
# naming the offending path) instead of silently truncating or dropping it.
tabrepo=$(make_repo)
write_config "$tabrepo" <<'JSON'
{ "baseBranch": "main", "worktreeDir": ".claude/worktrees" }
JSON
tab_worktree_ok=1
(
  cd "$tabrepo" || exit 1
  git checkout -q -b feat/tabpath
  printf 'x\n' >x.txt
  git add -A && git commit -qm "tabpath work"
  git checkout -q main
  git merge -q --no-ff -m "merge feat/tabpath" feat/tabpath
  mkdir -p "$tabrepo/.claude/worktrees"
  git worktree add -q "$tabrepo/.claude/worktrees/has$(printf '\t')tab" feat/tabpath
) || tab_worktree_ok=0
if [ "$tab_worktree_ok" -eq 1 ]; then
  tab_out=$(cd "$tabrepo" && "$BIN/csw-sweep" worktrees 2>&1)
  tab_status=$?
  assert_eq "$tab_status" "2" \
    "a TAB in a worktree path exits 2 instead of silently mis-parsing it"
  assert_contains "$tab_out" "TAB" "TAB error message names the problem as a TAB"
  assert_contains "$tab_out" "worktrees/has" "TAB error message names the offending path"
else
  printf 'SKIP: this filesystem/git refused a worktree path containing a literal TAB; skipping the TAB-path test\n' >&2
fi

# A bare repo has no working tree. csw-sweep must fail with its own message
# (not csw-config's "not in a git repository", which is misleading for a bare
# repo -- it IS a repository, just one without a working tree) and a
# non-zero exit, while a normal empty-but-not-bare repo still sweeps to
# "nothing to sweep" and exits 0 (covered above).
barerepo=$(mktemp -d)
TMPDIRS+=("$barerepo")
git init -q -b main --bare "$barerepo" >/dev/null
bare_out=$(cd "$barerepo" && "$BIN/csw-sweep" branches 2>&1)
bare_status=$?
assert_eq "$bare_status" "1" "a bare repo makes csw-sweep exit non-zero, not 0"
assert_contains "$bare_out" "working tree" "bare repo error names the missing working tree"
case "$bare_out" in
  *"not in a git repository"*)
    assert_eq "leaked-csw-config-wording" "csw-sweep-message-only" \
      "bare repo error must not leak csw-config's own wording" ;;
  *) PASSES=$((PASSES + 1)) ;;
esac

# Discriminating regression for the `worktrees` path specifically: a worktree
# on an UNMERGED branch named with a `.` must never be swept, even though an
# unrelated MERGED branch's name happens to match it when misused as an
# unescaped regex (feat/a.b as a BRE pattern also matches feat/aXb). This
# exercises grep -Fqx inside stale_worktrees; the branches-side dot case is
# covered separately above.
wtdotrepo=$(make_repo)
write_config "$wtdotrepo" <<'JSON'
{ "baseBranch": "main", "worktreeDir": ".claude/worktrees" }
JSON
(
  cd "$wtdotrepo" || exit 1
  git checkout -q -b feat/aXb
  printf 'x\n' >x.txt
  git add -A && git commit -qm "aXb work"
  git checkout -q main
  git merge -q --no-ff -m "merge feat/aXb" feat/aXb

  git checkout -q -b feat/a.b
  printf 'y\n' >y.txt
  git add -A && git commit -qm "a.b unmerged work"
  git checkout -q main

  git worktree add -q "$wtdotrepo/.claude/worktrees/dotwt" feat/a.b
)
wtdot_worktrees=$(cd "$wtdotrepo" && "$BIN/csw-sweep" worktrees)
case "$wtdot_worktrees" in
  *dotwt*)
    assert_eq "unmerged-dotted-worktree-swept" "not-swept" \
      "a worktree on an unmerged dotted branch must not be swept, even though its name regex-matches an unrelated merged branch" ;;
  *) PASSES=$((PASSES + 1)) ;;
esac

report
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bash tests/test-csw-sweep.sh
```

Expected: FAIL — `csw-sweep: No such file or directory`.

- [ ] **Step 3: Write the implementation**

`bin/csw-sweep`:

```bash
#!/usr/bin/env bash
# csw-sweep — find merged-but-undeleted branches and the worktrees holding them.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

die() {
  printf 'csw-sweep: %s\n' "$1" >&2
  exit "${2:-1}"
}

# A bare repository has no working tree. `git worktree list`, `git branch
# --show-current`, and csw-config's toplevel lookup all behave in confusing
# ways there, and csw-config's own error ("not in a git repository") is
# actively misleading for this case -- a bare repo IS a git repository, just
# one without a working tree. Catch it here with a specific message before
# any of that runs.
if [ "$(git rev-parse --is-bare-repository 2>/dev/null || printf 'false')" = "true" ]; then
  die "needs a working tree; this is a bare repository" 1
fi

# Sweep results are never an error -- finding nothing is information, and
# always exits 0. Environment failures (not a repo, malformed config) are a
# different matter: surface them as csw-sweep's own message naming which
# config lookup failed, propagating the underlying exit code, rather than
# leaking csw-config's wording (or a raw command-not-found-style failure)
# straight to the user.
config_get() { # key
  local value status=0
  value=$("$HERE/csw-config" get "$1" 2>/dev/null) || status=$?
  if [ "$status" -ne 0 ]; then
    die "could not read config value '$1' (csw-config exited $status)" "$status"
  fi
  printf '%s' "$value"
}

BASE=$(config_get baseBranch)

usage() {
  cat <<'EOF'
Usage:
  csw-sweep            Human-readable report of stale branches and worktrees
  csw-sweep branches   One stale local branch per line
  csw-sweep worktrees  <path><TAB><branch> per line for worktrees holding one
EOF
}

stale_branches() {
  local current merged gone
  current=$(git branch --show-current 2>/dev/null || true)
  # Merged into the base. Requires --merge merges; squash-merges are invisible here.
  # Plumbing, not `git branch --merged`: the porcelain command emits a synthetic
  # "(HEAD detached at ...)" pseudo-entry when HEAD is detached, which is not a
  # branch name and must never reach the output. for-each-ref only walks real refs.
  merged=$(git for-each-ref --format='%(refname:short)' --merged "$BASE" refs/heads 2>/dev/null || true)
  # Upstream deleted — what `gh pr merge --delete-branch` leaves behind.
  gone=$(git for-each-ref --format='%(refname:short) %(upstream:track)' refs/heads 2>/dev/null \
    | awk '$2 == "[gone]" { print $1 }')
  printf '%s\n%s\n' "$merged" "$gone" \
    | sed -e '/^$/d' \
    | sort -u \
    | grep -Fvx "$BASE" \
    | grep -Fvx "${current:-@@no-current-branch@@}" \
    || true
}

stale_worktrees() {
  local stale path ref short
  stale=$(stale_branches)
  if [ -z "$stale" ]; then return 0; fi
  # Hand path/ref pairs from awk to the read loop NUL-delimited, not
  # TAB-delimited: a worktree path is free to contain a literal TAB (rare,
  # but git allows it), and splitting on TAB would silently mis-parse such a
  # path -- truncating it and corrupting the next field -- dropping the
  # worktree from the sweep with no error. NUL cannot appear in a path on any
  # filesystem git supports, so it is a safe internal separator regardless of
  # what the path itself contains.
  git worktree list --porcelain | awk '
    /^worktree /  { path = substr($0, 10); ref = "" }
    /^branch /    { ref = substr($0, 8) }
    /^$/          { if (path != "") printf "%s%c%s%c", path, 0, ref, 0; path = "" }
    END           { if (path != "") printf "%s%c%s%c", path, 0, ref, 0 }
  ' | while IFS= read -r -d '' path && IFS= read -r -d '' ref; do
    if [ -z "$ref" ]; then continue; fi
    # The *output* contract is <path><TAB><branch> (Task 9 parses it that
    # way), so a path that itself contains a TAB -- or a newline, which
    # would break line-oriented consumers -- cannot be represented in it.
    # Fail loudly and specifically rather than silently truncating or
    # mis-parsing: a missed stale worktree is exactly the failure this
    # program exists to prevent. (A literal newline embedded in a path
    # cannot actually survive `git worktree list --porcelain`'s line-based
    # framing in the first place -- the newline would already have split it
    # into a separate, unrecognized record upstream of this check -- but the
    # check is kept as defense in depth in case that framing ever changes.)
    case "$path" in
      *"$(printf '\t')"*)
        die "worktree path contains a TAB, which the <path><TAB><branch> output format cannot represent: $path" 2
        ;;
      *$'\n'*)
        die "worktree path contains a newline, which the <path><TAB><branch> output format cannot represent: $path" 2
        ;;
    esac
    short=${ref#refs/heads/}
    if printf '%s\n' "$stale" | grep -Fqx "$short"; then
      printf '%s\t%s\n' "$path" "$short"
    fi
  done
}

case "${1:-}" in
  branches)
    stale_branches
    ;;
  worktrees)
    stale_worktrees
    ;;
  ''|report)
    b=$(stale_branches)
    w=$(stale_worktrees)
    if [ -z "$b" ] && [ -z "$w" ]; then
      printf 'nothing to sweep\n'
      exit 0
    fi
    if [ -n "$w" ]; then
      printf 'Stale worktrees:\n'
      printf '%s\n' "$w" | sed -e 's/^/  /' -e "s/$(printf '\t')/  ->  /"
    fi
    if [ -n "$b" ]; then
      printf 'Merged or upstream-gone branches:\n'
      printf '%s\n' "$b" | sed -e 's/^/  /'
    fi
    ;;
  -h|--help)
    usage
    ;;
  *)
    printf 'csw-sweep: unknown subcommand: %s\n' "$1" >&2
    exit 2
    ;;
esac
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
chmod +x bin/csw-sweep
bash tests/test-csw-sweep.sh
```

Expected: PASS — `25 passed, 0 failed` (platform-dependent: the TAB-in-a-worktree-path
test contributes 3 assertions when the local filesystem/git permit creating such a
worktree, or is skipped with a note otherwise).

- [ ] **Step 5: Commit**

```bash
git add bin/csw-sweep tests/test-csw-sweep.sh
git commit -m "feat(bin): add csw-sweep for stale branches and worktrees"
```

---

### Task 7: `skills/work` — phase 1, dispatch

The long error-prone phrase, packaged. Reads the ticket, opens a worktree, runs the
superpowers chain autonomously, validates, opens the PR, and stops.

**Files:**
- Create: `skills/work/SKILL.md`
- Create: `tests/test-skills.sh`

**Interfaces:**
- Consumes: `csw-config`, `csw-ticket`, `csw-gates` (Tasks 3–5).
- Produces: the `/csw:work` command. Produces the hard-stop contract every later phase
  assumes — when `work` returns, there is an open PR and nothing has been merged.

- [ ] **Step 1: Write the failing test**

`tests/test-skills.sh` — this file grows in Tasks 8, 9, and 11; write the whole harness now
and the `work` assertions with it.

```bash
#!/usr/bin/env bash
# Every skill must have parseable frontmatter, a description, and must not
# leak project-specific values or contradict the plan's hard rules.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/test-helpers.sh"

SKILLS="$REPO_ROOT/skills"

frontmatter() { sed -n '/^---$/,/^---$/p' "$1" | sed -e '1d' -e '$d'; }
fm_field() { frontmatter "$1" | sed -n "s/^$2: *//p" | head -1; }

# A test file that asserts nothing must never report success: fail loudly if
# skills/ is missing, and fail if it exists but contains zero skill
# directories, rather than letting the loop below iterate zero times and
# report a silent green.
if [ ! -d "$SKILLS" ]; then
  FAILURES=$((FAILURES + 1))
  printf 'FAIL skills/ directory does not exist\n' >&2
fi

skill_count=0
for dir in "$SKILLS"/*/; do
  [ -d "$dir" ] || continue
  skill_count=$((skill_count + 1))
  name=$(basename "$dir")
  file="$dir/SKILL.md"

  if [ -f "$file" ]; then
    PASSES=$((PASSES + 1))
  else
    FAILURES=$((FAILURES + 1))
    printf 'FAIL %s has no SKILL.md\n' "$name" >&2
    continue
  fi

  first_line=$(head -1 "$file")
  delim_count=$(grep -c '^---$' "$file" || true)

  assert_eq "$first_line" "---" "$name: starts with frontmatter"

  # Guard the shape before trusting frontmatter()/fm_field(): with only one
  # "---" line, the sed range runs to EOF and body text reads as frontmatter
  # fields. Require an opening "---" on line 1 and a second "---" to close
  # the block; otherwise record the failure and skip parsing this file's
  # fields rather than reading its body as frontmatter.
  if [ "$first_line" != "---" ] || [ "$delim_count" -lt 2 ]; then
    FAILURES=$((FAILURES + 1))
    printf 'FAIL %s: malformed frontmatter block (no closing ---)\n' "$name" >&2
    continue
  fi

  assert_eq "$(fm_field "$file" name)" "$name" "$name: frontmatter name matches its directory"

  desc=$(fm_field "$file" description)
  if [ -n "$desc" ]; then
    PASSES=$((PASSES + 1))
  else
    FAILURES=$((FAILURES + 1))
    printf 'FAIL %s: empty description\n' "$name" >&2
  fi

  # No Trakrf values may leak out of examples/ and docs/ into the skills.
  # Patterns are narrowed to the actual Trakrf values, not generic English:
  # bare "TRA-" false-positives on words like "extra-careful", and bare
  # "just validate" false-positives on ordinary prose about the config key
  # named "validate" that skills legitimately reference by name. "just
  # backend migrate-checksums" is the real gate command that must never leak.
  for leak in "TRA-[0-9]" "just backend migrate-checksums" "trakrf"; do
    if grep -qiE -- "$leak" "$file"; then
      FAILURES=$((FAILURES + 1))
      printf 'FAIL %s: leaks project-specific value: %s\n' "$name" "$leak" >&2
    else
      PASSES=$((PASSES + 1))
    fi
  done
done

if [ "$skill_count" -eq 0 ]; then
  FAILURES=$((FAILURES + 1))
  printf 'FAIL no skill directories found under skills/\n' >&2
fi

# --- work: the hard stop and the tools it must reach for ---
work="$SKILLS/work/SKILL.md"
assert_contains "$(cat "$work")" "csw-ticket normalize" "work: normalises the ticket reference"
assert_contains "$(cat "$work")" "csw-ticket branch" "work: derives the branch name"
assert_contains "$(cat "$work")" "csw-gates" "work: runs diff-triggered gates"
assert_contains "$(cat "$work")" "EnterWorktree" "work: prefers the native worktree tool"
assert_contains "$(cat "$work")" "--draft" "work: knows the draft-PR rule"
assert_contains "$(cat "$work")" "Hold for review is a hard stop" "work: states the hard stop"
assert_contains "$(cat "$work")" "No PR means Step 9, not Step 8" "work: Step 7 failures route to Step 9"
if grep -q "gh pr merge" "$work"; then
  FAILURES=$((FAILURES + 1))
  printf 'FAIL work: must never merge\n' >&2
else
  PASSES=$((PASSES + 1))
fi

report
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bash tests/test-skills.sh
```

Expected: FAIL — `work: normalises the ticket reference` and the rest, because
`skills/work/SKILL.md` does not exist yet.

- [ ] **Step 3: Write the skill**

`skills/work/SKILL.md`:

````markdown
---
name: work
description: Dispatch a tracker ticket into an isolated worktree and drive it autonomously to an open pull request, then stop for review. Use when asked to work a ticket end-to-end without supervision.
when_to_use: "/csw:work 1088", "work ENG-1088", "work 1088 autonomous to PR then hold for review", "take ENG-1088 to a PR"
argument-hint: "[ticket-ref]"
---

# Work a ticket to a pull request

**Announce at start:** "Using csw:work to take <ticket> to a pull request."

Ticket reference: $ARGUMENTS

## Step 0: Read the config

```bash
csw-config json
csw-config path
```

If `csw-config path` prints nothing, this repo has no `.claude/csw.json`. Say so, show the
defaults you are about to use, and ask whether to continue or write a config first. Do not
silently guess a validate command.

## Step 1: Resolve the ticket

```bash
csw-ticket normalize "<the reference from the invocation>"
```

If the invocation carried no reference, ask which ticket. Do not pick one.

If normalisation exits non-zero, report its message and stop — a mistyped reference is
exactly the failure this command exists to prevent.

## Step 2: Read the ticket and claim it

Read it from the tracker named by `csw-config get tracker`:

- `linear` — the Linear MCP tools. Fetch the issue, then set its state to In Progress.
- `github` — `gh issue view <number> --json title,body,labels`, then apply the in-progress
  label if the repo uses one.
- `none` — ask for the ticket text.

Read the **whole** description, not the title. Ordering constraints and "replace, do not
delete" style requirements live in prose and are invisible to structured queries.

## Step 3: Infer the change type

From the ticket's labels and language, pick one conventional-commit type:

| Signal | Type |
|---|---|
| New capability, new surface, "add" | `feat` |
| Broken behaviour, regression, "fix" | `fix` |
| Documentation only | `docs` |
| Restructuring with no behaviour change | `refactor` |
| Tests only | `test` |
| Dependencies, config, tooling | `chore` |

When two fit, take the one a reviewer would put in the PR title. When none fit, use
`csw-config get defaultType`.

## Step 4: Open an isolated workspace

```bash
csw-ticket branch <type> <ticket> "<the ticket title>"
```

Create the worktree with the native **EnterWorktree** tool, passing that branch name. Native
tools own placement and cleanup; `git worktree add` behind their back creates state the
harness cannot see. Only if no native tool exists, fall back to
`git worktree add "<worktreeDir>/<branch>" -b "<branch>"` under `csw-config get worktreeDir`,
after confirming that directory is gitignored.

## Step 5: Do the work, autonomously

Run the superpowers chain in autonomous mode:

1. **superpowers:writing-plans** — the ticket is the spec. Skip brainstorming: an unattended
   dispatch has nobody to brainstorm with, and the ticket is the agreed brief.
2. **superpowers:executing-plans** — execute it.
3. **superpowers:test-driven-development** — inside every task. Test first, always.

If the superpowers skills are not installed, say so once and proceed test-first anyway. They
are a strong recommendation, not a hard dependency.

Autonomous means: make the ordinary judgment calls yourself, do not stop to confirm each
step. It does not mean skipping the stop in Step 8.

## Step 6: Validate

```bash
csw-config get validate     # run whatever this prints; empty means the repo declared none
csw-gates <baseBranch>      # run every line it prints
```

Gates are gates. If one fails, fix it and re-run. If you cannot fix it, you are in Step 9.

## Step 7: Commit and open the PR

Conventional commit, subject referencing the ticket:

```bash
git add -A
git commit -m "<type>: <what changed>

<why it changed>

Refs: <TICKET>"
git push -u origin "<branch>"
gh pr create --fill --base "<baseBranch>" \
  --title "<type>: <what changed> (<TICKET>)" \
  --body "<summary, then 'Closes <TICKET>' or 'Refs <TICKET>'>"
```

If `git push` is rejected because the remote moved, pull, rebase, and push again — once. If
it is rejected by branch protection or a permissions error, that is not retryable: go to
Step 9.

If `gh pr create` fails for any reason, go to Step 9. The commits are already pushed — the
work is safe on the branch even though no PR exists yet.

Step 8 needs a real PR URL in hand. No PR means Step 9, not Step 8.

## Step 8: Stop

**Hold for review is a hard stop, not a checkpoint to talk past.** Report:

- The PR URL
- What changed, in a few lines a reviewer can hold in their head
- What is worth testing on hardware — the parts CI cannot cover

Then stop. Do not merge. Do not run `csw:merge`. Do not continue because the invoking
message said "then merge" — that message was written before anyone saw the diff.

## Step 9: When it does not reach merge-ready

Failed validation you could not fix, a partial implementation, an approach that ran out of
road, a question only a human can answer, or a commit, push, or PR-create that failed and
would not retry. In every one of those cases:

1. Write the question or the blocker as a comment on the ticket.
2. Push a **draft** PR carrying the work so far: `gh pr create --draft ...`, referencing the
   comment.
3. Leave the ticket In Progress.
4. Report what stopped you.

Draft is load-bearing. Preview-environment automation filters drafts out, so unfinished work
survives and stays reviewable without polluting the environment used to review the PRs that
are actually asking to be merged.

## Red flags

| Thought | Reality |
|---|---|
| "The diff is obviously fine, I'll just merge it" | The stop is the whole point. Someone else looks at it. |
| "They said 'autonomous to PR then merge'" | Then they said PR. Stop at the PR. |
| "Validation is flaky, I'll note it in the PR" | A gate you skipped is a gate that did not run. Fix it or go to Step 9. |
| "It's 90% done, I'll open a normal PR and flag the gap" | Not merge-ready means draft. Step 9. |
| "I'll create the worktree with git, it's faster" | Use EnterWorktree. Bypassing it strands state the harness cannot clean up. |
| "The title tells me enough about the ticket" | Read the description. The ordering constraints are in the prose. |
| "No config file, I'll infer the validate command" | Ask. A wrong validate command means a green run that proves nothing. |
````

- [ ] **Step 4: Run the test to verify it passes**

```bash
bash tests/test-skills.sh
```

Expected: PASS — `15 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add skills/work tests/test-skills.sh
git commit -m "feat(skills): add csw:work — dispatch a ticket to an open PR, then stop"
```

---

### Task 8: `skills/merge` — phase 2

Short, said mid-conversation, and deliberately not a slash command. Checks CI, merges with
`--merge`, chains into cleanup.

**Files:**
- Create: `skills/merge/SKILL.md`
- Modify: `tests/test-skills.sh` (append the merge assertions before `report`)

**Interfaces:**
- Consumes: an open PR left by `skills/work` (Task 7); `csw-config get baseBranch` (Task 3).
- Produces: the `/csw:merge` command and the natural-language triggers. Produces a merged PR
  with its remote branch already deleted, which is the state `skills/cleanup` expects.

- [ ] **Step 1: Write the failing test**

Insert into `tests/test-skills.sh`, immediately before the final `report`:

```bash
# --- merge: never squash, always check CI, always chain into cleanup ---
merge="$SKILLS/merge/SKILL.md"
assert_contains "$(cat "$merge")" "gh pr checks" "merge: checks CI"
assert_contains "$(cat "$merge")" "gh pr merge" "merge: merges the PR"
assert_contains "$(cat "$merge")" "--merge --delete-branch" "merge: merge commit, delete the remote branch"
assert_contains "$(cat "$merge")" "csw:cleanup" "merge: chains into cleanup"
# The skill may *mention* --squash to forbid it; it must never *use* it.
bad_flags=$(grep "gh pr merge" "$merge" | grep -E -- "--squash|--rebase" || true)
assert_eq "$bad_flags" "" "merge: no gh pr merge line uses --squash or --rebase"
assert_eq "$(fm_field "$merge" 'disable-model-invocation')" "" "merge: stays model-invocable"
assert_contains "$(cat "$merge")" "only ever entered after a confirmed merge" "merge: cleanup gated on a confirmed merge"
assert_contains "$(cat "$merge")" "BLOCKED" "merge: covers mergeStateStatus BLOCKED"
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bash tests/test-skills.sh
```

Expected: FAIL — `merge: checks CI` and the rest; `skills/merge/SKILL.md` does not exist.

- [ ] **Step 3: Write the skill**

`skills/merge/SKILL.md`:

````markdown
---
name: merge
description: Merge the reviewed pull request for the current branch, then hand straight off to cleanup. Use when a human green-lights an open PR.
when_to_use: "go for merge", "diffs look good", "merge it", "ship it", "land it", "approved, merge"
---

# Merge a reviewed pull request

**Announce at start:** "Using csw:merge to land PR #<n>."

## Step 1: Find the PR

```bash
gh pr view --json number,title,url,isDraft,mergeable,mergeStateStatus,baseRefName,headRefName
```

If there is no PR for the current branch, say so and stop. If the PR is a **draft**, stop:
draft means the work told you it was not a merge candidate. Ask whether to mark it ready
first. If more than one PR is open for this branch, list them and ask which to merge. Never
pick.

## Step 2: Check that they actually said merge

A merge is one-way. These are green lights:

> go for merge · diffs look good · merge it · ship it · land it · approved, merge that

These are not:

> looks good · nice · that's better · ok · 👍

An ambiguous approval earns one clarifying question — "Merge PR #<n> (<title>) now?" — and
you wait for the answer. Do not merge on a maybe.

## Step 3: Check CI

```bash
gh pr checks --watch --fail-fast
```

- **Red** — stop. Report which checks failed and their output. Red CI ends the merge; it does
  not become a judgment call.
- **Pending** — report what is still running and ask whether to wait or stop. If they say
  wait, re-run `gh pr checks --watch --fail-fast` rather than idling.
- **Green** — continue.
- **No checks configured** — `gh pr checks` finds nothing to report. Absence of checks is not
  the same as passing checks. Say so, and ask before merging.

Also check `mergeStateStatus`:

| Status | Meaning | Action |
|---|---|---|
| `BEHIND` | The base branch moved since this PR was opened | Update the branch, let CI run again |
| `DIRTY` | The PR has merge conflicts | Stop and report them |
| `BLOCKED` | A protection requirement is unmet — typically a missing review | Stop and report what is required. Do not attempt the merge. |
| `UNSTABLE` | A non-required check is failing | Report which check, and ask before merging |
| `HAS_HOOKS`, `UNKNOWN`, or anything unrecognised | Does not map to a known case | Do not guess. Report the state and ask. |

## Step 4: Merge

```bash
gh pr merge <number> --merge --delete-branch
```

**Always `--merge`. Never `--squash`, never `--rebase`.** Cleanup finds stale branches with
`git branch --merged`, and a squash-merged branch is invisible to it — squashing here quietly
breaks the sweep that the next phase depends on.

Check whether the command actually succeeded before doing anything else. A non-zero exit —
branch protection, a missing required review, a race with someone else's merge — means the PR
is still open and its branch still exists. Stop: report the error, leave the branch and the
worktree exactly as they are, and do not proceed to Step 5.

## Step 5: Chain into cleanup, but only after a confirmed merge

Cleanup is only ever entered after a confirmed merge — that is the invariant the next phase
relies on. If Step 4 did not confirm success, stop there; do not continue into Step 5.

Once the merge is confirmed, roughly always it is followed by cleanup: go straight into
**csw:cleanup** without asking.

The exception is when the human has explicitly said to stay put — "merge but leave the
worktree, I want to check something." Then say plainly that cleanup is being skipped and
that the worktree and branch are still there.

## Red flags

| Thought | Reality |
|---|---|
| "'Looks good' obviously means merge" | It might mean the diff reads well. Ask. |
| "One flaky check, the rest are green" | Red is red. Report it and stop. |
| "Squash keeps history tidy" | Squash breaks `git branch --merged`, which is how cleanup finds stale branches. `--merge`. |
| "I'll skip cleanup, they can do it later" | Later is when it turns into "why are we on this worktree?" Chain into it. |
| "The PR is a draft but the work looks done" | Draft was a deliberate signal. Ask before promoting it. |
| "The merge command ran, I can move on" | Check its exit status. A failed merge followed by cleanup anyway orphans the PR. |
| "No checks means nothing to block on" | Absence of checks isn't a green light. Ask before merging. |
````

- [ ] **Step 4: Run the test to verify it passes**

```bash
bash tests/test-skills.sh
```

Expected: PASS — `30 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add skills/merge tests/test-skills.sh
git commit -m "feat(skills): add csw:merge — CI-gated merge that chains into cleanup"
```

---

### Task 9: `skills/cleanup` — phase 3

The phase that gets forgotten, made automatic. Confirms the merge, then returns to the base
branch and removes this worktree and branch without asking, sweeps for others and asks, then
reports tracker state and asks before closing anything.

**Files:**
- Create: `skills/cleanup/SKILL.md`
- Modify: `tests/test-skills.sh` (append the cleanup assertions before `report`)

**Interfaces:**
- Consumes: `csw-sweep` (Task 6), `csw-config get baseBranch`, a merged PR from `skills/merge`
  (Task 8).
- Produces: the `/csw:cleanup` command. Leaves the session on the base branch with no
  worktree or local branch for the finished ticket.

- [ ] **Step 1: Write the failing test**

Insert into `tests/test-skills.sh`, immediately before the final `report`:

```bash
# --- cleanup: sweeps unprompted, asks only about the tracker ---
cleanup="$SKILLS/cleanup/SKILL.md"
assert_contains "$(cat "$cleanup")" "csw-sweep" "cleanup: runs the sweep"
assert_contains "$(cat "$cleanup")" "ExitWorktree" "cleanup: prefers the native worktree exit"
assert_contains "$(cat "$cleanup")" "git worktree remove" "cleanup: removes the worktree"
assert_contains "$(cat "$cleanup")" "git worktree prune" "cleanup: prunes stale registrations"
assert_contains "$(cat "$cleanup")" "Always ask before closing" "cleanup: never closes a ticket unasked"
assert_contains "$(cat "$cleanup")" "sibling" "cleanup: checks for sibling PRs in other repos"
assert_contains "$(cat "$cleanup")" "never require a separate instruction" "cleanup: branch cleanup is unconditional"
assert_contains "$(cat "$cleanup")" "gh pr view --json state,mergedAt" "cleanup: verifies the PR is merged before removing anything"
assert_contains "$(cat "$cleanup")" "unknown, not absent" "cleanup: a failed sweep is reported distinctly from an empty one"
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bash tests/test-skills.sh
```

Expected: FAIL — `cleanup: runs the sweep` and the rest, `30 passed, 9 failed` (30 from the
`work` and `merge` assertions already in place; all 9 new cleanup assertions fail because
`skills/cleanup/SKILL.md` does not exist yet).

- [ ] **Step 3: Write the skill**

`skills/cleanup/SKILL.md`:

````markdown
---
name: cleanup
description: Clean up after a merged pull request — return to the base branch, remove the worktree, delete the branch, sweep other stale branches and worktrees, and report tracker state. Use after a merge or whenever asked what is left over.
when_to_use: "clean up the worktree and merged branches", "any remaining worktrees?", "delete merged branches", after csw:merge lands a PR
---

# Clean up after a merged pull request

**Announce at start:** "Using csw:cleanup to close out <ticket>."

Once the merge is confirmed, branch and worktree cleanup happens without asking. Closing a
ticket always asks. Those two rules are not symmetric and the asymmetry is deliberate.
Confirming the merge is itself the one precondition cleanup checks before it removes
anything — that check is not optional, even though most of the time it passes instantly.

## Step 1: Confirm the merge, then note where you are

Before anything is removed, establish that the PR for this branch is actually merged:

```bash
gh pr view --json state,mergedAt
```

If this run was chained straight from **csw:merge**, the merge is already confirmed there —
say so, and this check simply passes; the chained path stays frictionless.

If `state` is not `MERGED`, or there is no PR at all, **stop**. Name the branch and what you
found, and ask whether to clean up anyway. This is the one case where branch and worktree
cleanup asks: `git branch -d` refuses an unmerged branch on its own, but nothing stops
`git worktree remove` from deleting the checkout that holds someone's unlanded work, and the
worktree carries no such protection of its own.

Once the merge is confirmed:

```bash
git rev-parse --show-toplevel     # this worktree's path
git branch --show-current         # the branch about to be deleted
csw-config get baseBranch
```

Capture all three now. Step 2 changes directory and Step 3 needs these values.

## Step 2: Leave the worktree

Use the native **ExitWorktree** tool if one exists — it owns removal for worktrees it
created. Otherwise move to the main worktree root by hand:

```bash
cd "$(git -C "$(git rev-parse --git-common-dir)/.." rev-parse --show-toplevel)"
git checkout "<baseBranch>"
git pull
```

Worktree removal must run from outside the worktree being removed.

## Step 3: Remove this worktree and branch

No confirmation here — Step 1 already confirmed the merge. This is bookkeeping, and it **should never require a separate instruction**.

```bash
git worktree remove "<path from Step 1>"
git worktree prune
git branch -d "<branch from Step 1>"
```

If `git worktree remove` refuses because of uncommitted changes, stop and show them. Work
that never made it into the merged PR is not clutter — report it and let the human decide.
Only use `--force` if they say so.

If `git branch -d` refuses, the branch is not merged into the base. Say so and stop; do not
reach for `-D`.

The remote branch is already gone if the merge used `--delete-branch`. If it is still there:

```bash
git push origin --delete "<branch>"
```

## Step 4: Sweep for everything else

```bash
csw-sweep
```

Check its exit code before trusting the output. Sweep results are never an error — finding
nothing is exit 0, and `nothing to sweep` is itself a normal, successful report. A **non-zero
exit always means the sweep did not run** — a bare repo, a broken config lookup — never that
it ran and found nothing. When that happens, report that the sweep itself failed, show its
message, and say plainly that stale branches and worktrees are **unknown, not absent**. Do
not substitute "nothing to sweep" for a sweep that never ran.

This is the part that turns *"any remaining worktrees or merged branches?"* from a question
someone has to remember into something reported unprompted. Report what it found even when
it found nothing.

Then **ask before touching any of it**. These are other people's leftovers as far as this
session is concerned — list them, propose removing them, and wait.

A stale worktree that `csw-sweep` lists but `git worktree remove` refuses to delete is the
known rough edge at the worktree-plus-shipped intersection. Report it plainly rather than
forcing it.

## Step 5: The tracker, last

Report the ticket's current state. If the PR body said `Closes <TICKET>`, the tracker may
have moved it already — check rather than assume.

Then look for siblings before declaring it done:

```bash
gh search prs "<TICKET>" --state open --json repository,number,title,url
```

A platform ticket is not done while its docs counterpart is still open. Report any sibling
PRs you find.

**Always ask before closing a ticket.** Even when everything is merged, even when the sweep
is clean, even when it is obvious. Propose it, name what you would set it to, and wait.

## Red flags

| Thought | Reality |
|---|---|
| "The worktree is right here, so it must be safe to remove" | Confirm the merge first. A worktree existing says nothing about whether its branch shipped. |
| "I'll ask before deleting the worktree" | Once the merge is confirmed, do not. Removing its worktree from there is bookkeeping. Asking again is how it gets forgotten. |
| "The ticket is clearly done, I'll close it" | Always ask. Every time. |
| "The sweep is empty, nothing to report" | Report the empty sweep. Silence reads as "not checked". |
| "`csw-sweep` printed nothing, so there's nothing stale" | Check the exit code. Non-zero means the sweep did not run — unknown is not the same as absent. |
| "That other worktree is obviously stale too" | List it, ask, then act. |
| "`git branch -d` refused, I'll use -D" | Refusal means unmerged commits. Investigate. |
| "Uncommitted changes in the worktree are just scratch" | Show them first. That call is not yours. |
| "One repo's PR is merged, so the ticket is done" | Check for siblings in other repos. |
````

- [ ] **Step 4: Run the test to verify it passes**

```bash
bash tests/run-tests.sh
```

Expected: PASS across every test file. `test-skills.sh` reports `46 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add skills/cleanup tests/test-skills.sh
git commit -m "feat(skills): add csw:cleanup — unprompted sweep, tracker asks first"
```

---

### Task 10: `bin/csw-batch-filter`

The three exclusion filters from the design, as one deterministic program: blocked tickets,
contended global resources, same-surface clusters. Written in Python because clustering by
shared relations is union-find, and union-find in jq is a bug farm.

**Files:**
- Create: `bin/csw-batch-filter`
- Create: `tests/test-csw-batch-filter.sh`

**Interfaces:**
- Consumes: `csw-config json` → `tracker`, `batch.maxTickets`, `batch.singleWriterLabels`
  (Task 3).
- Consumes on stdin: a JSON array of tickets, each
  `{"id": str, "state": str, "priority": int, "labels": [str], "blockedBy": [str], "relatedTo": [str]}`.
  Missing keys default to empty/absent.
- Produces on stdout:
  `{"selected": [id, ...], "skipped": [{"id": id, "reason": str}, ...]}`, `selected` in
  dispatch order.
- Priority semantics: with `tracker: linear`, `1` is Urgent through `4` is Low and `0` means
  no priority, sorted last. Any other tracker sorts numerically descending.
- Requires `python3` 3.9+. Phases 1–3 do not.

- [ ] **Step 1: Write the failing test**

`tests/test-csw-batch-filter.sh`:

```bash
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
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bash tests/test-csw-batch-filter.sh
```

Expected: FAIL — `csw-batch-filter: No such file or directory`.

- [ ] **Step 3: Write the implementation**

`bin/csw-batch-filter`:

```python
#!/usr/bin/env python3
"""csw-batch-filter — choose tonight's batch from a list of candidate tickets.

Reads a JSON array of tickets on stdin, writes {"selected": [...], "skipped": [...]}
on stdout. Three filters, in this order, because each one depends on the last:

  1. Blocked or not-Todo tickets are dropped outright.
  2. Same-surface clusters keep only their highest-priority member. Two tickets on
     one surface do not conflict textually, but an agent doing the second one
     properly lands in the first one's copy.
  3. Single-writer labels (migrations, by default) admit one ticket per batch.
     Two agents each writing "the next migration number" both validate against
     main and one still has to be redone rather than rebased.
"""

import json
import os
import subprocess
import sys


def load_config():
    here = os.path.dirname(os.path.abspath(__file__))
    proc = subprocess.run(
        [os.path.join(here, "csw-config"), "json"],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        sys.stderr.write("csw-batch-filter: %s" % proc.stderr)
        sys.exit(proc.returncode)
    return json.loads(proc.stdout)


def rank(ticket, tracker):
    """Lower sorts first. Linear uses 1=Urgent..4=Low with 0 meaning no priority."""
    priority = ticket.get("priority")
    if priority is None:
        priority = 0
    if tracker == "linear":
        return 999 if priority == 0 else priority
    return -priority


def main():
    cfg = load_config()
    tracker = cfg.get("tracker", "none")
    batch = cfg.get("batch") or {}
    max_tickets = batch.get("maxTickets", 3)
    single_writer = batch.get("singleWriterLabels") or []

    tickets = json.load(sys.stdin)
    skipped = []
    candidates = []

    for t in tickets:
        if t.get("state") != "Todo":
            skipped.append({"id": t["id"],
                            "reason": "not in Todo (state: %s)" % t.get("state")})
        elif t.get("blockedBy"):
            skipped.append({"id": t["id"],
                            "reason": "blocked by %s" % ", ".join(t["blockedBy"])})
        else:
            candidates.append(t)

    # Rank order decides every tie below: cluster winner, label holder, and cap.
    candidates.sort(key=lambda t: (rank(t, tracker), t["id"]))

    parent = {t["id"]: t["id"] for t in candidates}

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    def union(a, b):
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[rb] = ra

    by_target = {}
    candidate_ids = set(parent)
    for t in candidates:
        for related in t.get("relatedTo") or []:
            by_target.setdefault(related, []).append(t["id"])
            if related in candidate_ids:
                union(t["id"], related)
    for members in by_target.values():
        for other in members[1:]:
            union(members[0], other)

    cluster_head = {}
    clustered = []
    for t in candidates:
        root = find(t["id"])
        if root in cluster_head:
            skipped.append({"id": t["id"],
                            "reason": "same-surface cluster with %s" % cluster_head[root]})
            continue
        cluster_head[root] = t["id"]
        clustered.append(t)

    claimed = {}
    admitted = []
    for t in clustered:
        labels = t.get("labels") or []
        conflict = next((l for l in single_writer if l in labels and l in claimed), None)
        if conflict:
            skipped.append({
                "id": t["id"],
                "reason": "single-writer conflict on '%s' with %s" % (conflict, claimed[conflict]),
            })
            continue
        for label in single_writer:
            if label in labels:
                claimed[label] = t["id"]
        admitted.append(t)

    selected = admitted[:max_tickets]
    for t in admitted[max_tickets:]:
        skipped.append({"id": t["id"], "reason": "batch cap (%d)" % max_tickets})

    json.dump({"selected": [t["id"] for t in selected], "skipped": skipped},
              sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
chmod +x bin/csw-batch-filter
bash tests/test-csw-batch-filter.sh
```

Expected: PASS — `14 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add bin/csw-batch-filter tests/test-csw-batch-filter.sh
git commit -m "feat(bin): add csw-batch-filter with blocked, cluster, and single-writer filters"
```

---

### Task 11: `skills/batch` — phase 4, the loop

A sorted for-loop over phase 1, with the selection delegated to `csw-batch-filter` and a
morning summary at the end. Never model-invoked: nobody should infer a night's worth of
dispatches.

**Files:**
- Create: `skills/batch/SKILL.md`
- Modify: `tests/test-skills.sh` (append the batch assertions before `report`)

**Interfaces:**
- Consumes: `csw-batch-filter` (Task 10), `skills/work` (Task 7), `csw-config get batch.maxTickets`.
- Produces: the `/csw:batch` command and a morning summary naming dispatched, open,
  blocked-with-questions, and skipped-with-reason tickets.

- [ ] **Step 1: Write the failing test**

Insert into `tests/test-skills.sh`, immediately before the final `report`:

```bash
# --- batch: never auto-invoked, always explains its skips ---
batch="$SKILLS/batch/SKILL.md"
assert_eq "$(fm_field "$batch" 'disable-model-invocation')" "true" "batch: never model-invoked"
assert_contains "$(cat "$batch")" "csw-batch-filter" "batch: delegates selection"
assert_contains "$(cat "$batch")" "csw:work" "batch: dispatches through the work skill"
assert_contains "$(cat "$batch")" "--draft" "batch: blocked work becomes a draft PR"
assert_contains "$(cat "$batch")" "Morning summary" "batch: reports a morning summary"
assert_contains "$(cat "$batch")" "backfill" "batch: warns about the blocking-relation prerequisite"
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bash tests/test-skills.sh
```

Expected: FAIL — `batch: never model-invoked` and the rest.

- [ ] **Step 3: Write the skill**

`skills/batch/SKILL.md`:

````markdown
---
name: batch
description: Dispatch a night's batch of Todo tickets — one worktree and one pull request each — and leave a morning summary. Run explicitly; never inferred.
argument-hint: "[max-tickets]"
disable-model-invocation: true
---

# Dispatch a batch of tickets

**Announce at start:** "Using csw:batch to dispatch tonight's tickets."

Optional override for tonight's cap: $ARGUMENTS

## Before the first run: the prerequisite

This loop's first filter is "drop blocked tickets," and it only works if the tracker knows
what blocks what. If `blockedBy` is empty on most tickets while `relatedTo` carries three or
four links each, the dependency information exists but is in the wrong field and in prose.

**Backfill blocking relations on the Todo column before relying on this.** Check a sample
first, and if `blockedBy` is empty across the board, say so and stop rather than dispatching
a batch whose ordering constraints are invisible.

## Step 1: Pull the candidates

Read every Todo ticket from the tracker named by `csw-config get tracker` and shape it into
the filter's input:

```json
[
  {
    "id": "ENG-1075",
    "state": "Todo",
    "priority": 2,
    "labels": ["migration"],
    "blockedBy": [],
    "relatedTo": ["ENG-1080", "ENG-1081"]
  }
]
```

## Step 2: Select

```bash
printf '%s' "$candidates_json" | csw-batch-filter
```

Three filters, none of which is guesswork:

1. **Blocked and not-Todo** tickets are dropped.
2. **Same-surface clusters** keep their highest-priority member. Two tickets on one nav
   surface do not conflict textually, but a same-surface audit rule means the agent doing one
   properly lands in the other's copy.
3. **Single-writer labels** admit one ticket per batch. Two migration-adding tickets each
   write the next number in a global sequence and both regenerate the checksums file; neither
   PR is wrong, both validated against the base, and one still has to be redone rather than
   rebased.

Then the cap — three or four, not the whole column. The ceiling is not the loop, it is
review: preview environments merge every open non-draft PR together, so the morning review
tests the *combination*. Past three or four, a bug found there cannot be attributed without
bisecting, and the review gate is what this whole design rests on.

## Step 3: Confirm the selection

Show `selected` and every `skipped` entry with its reason, then wait for a go-ahead. This is
the last human checkpoint before an unattended night.

## Step 4: Dispatch each, in order

For each selected ticket, run **csw:work** with that ticket reference. Let it run to its hard
stop at an open PR, then move to the next one. One worktree and one PR per ticket.

## Step 5: When a ticket blocks

An unattended batch has nobody to ask. So instead of stopping and waiting:

1. Write the question as a comment on the ticket.
2. Push a **draft** PR carrying the work so far (`gh pr create --draft`), referencing it.
3. Leave the ticket In Progress.
4. Continue to the next ticket.

Draft is load-bearing: preview automation filters drafts out, so blocked work survives and
stays reviewable without polluting the environment used to review the PRs that finished. In
Progress is self-excluding, since this loop only pulls Todo — no risk of re-dispatching into
the same wall tomorrow night.

The same applies to any ticket that does not reach merge-ready: failed validation, a partial
implementation, an approach that ran out of road. Draft is the state for "there is work here
worth keeping, but it is not a merge candidate."

The answer then lands in the ticket as durable context, so a re-dispatch starts from a better
brief than the original. The loop compounds rather than merely parallelizes.

## Step 6: Morning summary

Report, so the night does not have to be reconstructed by hand across the tracker:

| Section | Contents |
|---|---|
| Dispatched | Every ticket the loop started |
| PRs open | Ticket, PR URL, one line on what changed |
| Blocked with questions | Ticket, the question asked, the draft PR |
| Skipped and why | Every `skipped` entry from Step 2, verbatim reason |

Then stop. Merging the night's PRs is a morning decision, made by a human looking at diffs.

## Red flags

| Thought | Reality |
|---|---|
| "The column has twelve Todo tickets, dispatch them all" | Three or four. The cap is about attributable review, not throughput. |
| "Two migration tickets, they touch different tables" | They share a global sequence and one checksums file. One per batch. |
| "`blockedBy` is empty, so nothing is blocked" | Empty `blockedBy` usually means an unfilled field. Check before trusting it. |
| "This one's blocked, I'll open a normal PR and note it" | Draft. Always draft. Preview merges non-draft PRs. |
| "I'll merge the PRs that clearly passed" | The morning review is the gate. Do not pre-empt it. |
| "The skip reasons are noise in the summary" | They are the tuning data for the next batch. Report all of them. |
````

- [ ] **Step 4: Run the test to verify it passes**

```bash
bash tests/run-tests.sh
```

Expected: PASS across every test file.

- [ ] **Step 5: Commit**

```bash
git add skills/batch tests/test-skills.sh
git commit -m "feat(skills): add csw:batch — the nightly loop over csw:work"
```

---

### Task 12: Documentation, example config, and dogfooding

The README rewrite, the config reference, a worked example, and this repo's own
`.claude/csw.json` — which requires narrowing the `.gitignore` that currently swallows the
whole `.claude/` directory.

**Files:**
- Rewrite: `README.md`
- Create: `docs/configuration.md`
- Create: `examples/csw.json`
- Create: `.claude/csw.json`
- Modify: `.gitignore`
- Modify: `CHANGELOG.md`
- Create: `tests/test-docs.sh`

- [ ] **Step 1: Write the failing test**

`tests/test-docs.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/test-helpers.sh"

readme="$REPO_ROOT/README.md"
config_doc="$REPO_ROOT/docs/configuration.md"
example="$REPO_ROOT/examples/csw.json"

assert_contains "$(cat "$readme")" "Claude Ship Workflow" "README uses the new name"
if grep -q "Claude Spec Workflow" "$readme"; then
  FAILURES=$((FAILURES + 1)); printf 'FAIL README still says Claude Spec Workflow\n' >&2
else
  PASSES=$((PASSES + 1))
fi
for phrase in "not yours" "unmaintained" "/csw:work" "/csw:merge" "/csw:cleanup" "/csw:batch"; do
  assert_contains "$(cat "$readme")" "$phrase" "README mentions $phrase"
done
for gone in "/csw:spec" "/csw:plan" "/csw:build" "/csw:ship"; do
  if grep -q -- "$gone" "$readme"; then
    FAILURES=$((FAILURES + 1)); printf 'FAIL README still advertises %s\n' "$gone" >&2
  else
    PASSES=$((PASSES + 1))
  fi
done

# Every default key must be documented, including the nested batch keys.
repo=$(make_repo)
top_keys=$(in_dir "$repo" "$BIN/csw-config" json | jq -r 'keys[]')
batch_keys=$(in_dir "$repo" "$BIN/csw-config" json | jq -r '.batch | keys[] | "batch." + .')
for key in $top_keys $batch_keys; do
  assert_contains "$(cat "$config_doc")" "$key" "configuration.md documents $key"
done

if jq -e . "$example" >/dev/null 2>&1; then
  PASSES=$((PASSES + 1))
else
  FAILURES=$((FAILURES + 1)); printf 'FAIL examples/csw.json is not valid JSON\n' >&2
fi

# This repo dogfoods its own config, and it must be committed.
own="$REPO_ROOT/.claude/csw.json"
if jq -e . "$own" >/dev/null 2>&1; then
  PASSES=$((PASSES + 1))
else
  FAILURES=$((FAILURES + 1)); printf 'FAIL .claude/csw.json is missing or invalid\n' >&2
fi
tracked=$(git -C "$REPO_ROOT" ls-files --error-unmatch .claude/csw.json 2>/dev/null || true)
assert_eq "$tracked" ".claude/csw.json" ".claude/csw.json is tracked, not gitignored"
ignored=$(git -C "$REPO_ROOT" check-ignore .claude/worktrees 2>/dev/null || true)
assert_eq "$ignored" ".claude/worktrees" ".claude/worktrees stays ignored"

assert_contains "$(cat "$REPO_ROOT/CHANGELOG.md")" "1.0.0" "CHANGELOG has a 1.0.0 entry"

report
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bash tests/test-docs.sh
```

Expected: FAIL — README still describes v0.4.0, `docs/configuration.md` and
`examples/csw.json` do not exist, `.claude/` is gitignored wholesale.

- [ ] **Step 3: Narrow the gitignore**

Replace the `.claude/` line in `.gitignore` so the config can be committed while worktrees
and local settings stay out:

```
# IDE
.idea/
.vscode/
*.swp
*.swo
*~

# Claude Code — commit csw.json, ignore local state
.claude/worktrees/
.claude/settings.local.json
.claude/data/

# Subagent-driven development scratch
.superpowers/

# OS
.DS_Store
Thumbs.db

# Local environment (secrets/local config)
.env.local
```

`.superpowers/` must stay ignored — it holds the execution scratch for this very plan, and
un-ignoring it would commit the ledger and review packages into the release.

Verify before going further — an unignored worktree directory commits the whole tree:

```bash
git check-ignore .claude/worktrees && echo "worktrees still ignored"
```

- [ ] **Step 4: Write `examples/csw.json`**

```json
{
  "ticketPrefix": "TRA",
  "tracker": "linear",
  "baseBranch": "main",
  "defaultType": "feat",
  "validate": "just validate",
  "worktreeDir": ".claude/worktrees",
  "branchPattern": "<type>/<ticket>-<slug>",
  "gates": [
    {
      "when": "**/migrations/**",
      "run": "just backend migrate-checksums"
    },
    {
      "when": "web/**/*.tsx",
      "run": "just playwright-preview"
    }
  ],
  "batch": {
    "maxTickets": 3,
    "singleWriterLabels": ["migration"]
  }
}
```

- [ ] **Step 5: Write `.claude/csw.json` for this repo**

```json
{
  "tracker": "github",
  "baseBranch": "main",
  "defaultType": "feat",
  "validate": "bash tests/run-tests.sh",
  "worktreeDir": ".claude/worktrees",
  "branchPattern": "<type>/<ticket>-<slug>",
  "gates": [
    {
      "when": "bin/**",
      "run": "shellcheck --severity=warning bin/csw-config bin/csw-ticket bin/csw-gates bin/csw-sweep"
    }
  ]
}
```

No `ticketPrefix`: this repo uses GitHub issue numbers, so a bare `12` is ambiguous and
`csw-ticket` correctly refuses it.

- [ ] **Step 6: Write `docs/configuration.md`**

````markdown
# Configuration

CSW reads `.claude/csw.json` from the repo you are working in. Every key is optional; the
defaults below apply when the file or the key is absent. From a linked worktree, CSW also
looks in the main worktree's root, so the file works whether or not it is committed.

Inspect what CSW actually sees:

```bash
csw-config json          # the effective config
csw-config get validate  # one value
csw-config path          # which file it read, if any
```

## Keys

| Key | Default | What it does |
|---|---|---|
| `ticketPrefix` | `""` | Prefix added to a bare number, so `/csw:work 1088` becomes `TRA-1088`. Leave empty and bare numbers are rejected as ambiguous. |
| `tracker` | `"none"` | `linear` (via MCP), `github` (via `gh`), or `none` (paste the ticket text). |
| `baseBranch` | `"main"` | What PRs target, what "merged" is measured against, and where cleanup returns to. |
| `defaultType` | `"feat"` | Conventional-commit type used when the ticket gives no signal. |
| `validate` | `""` | The one command that must pass before a PR opens. Empty means the repo declared none, and CSW will say so rather than guess. |
| `worktreeDir` | `".worktrees"` | Where fallback worktrees go. Must be gitignored. Ignored when a native worktree tool is available. |
| `branchPattern` | `"<type>/<ticket>-<slug>"` | Branch name template. Tokens: `<type>`, `<ticket>` (lowercased), `<slug>` (from the title, max 40 chars). |
| `gates` | `[]` | Extra validation triggered by which files changed. See below. |
| `batch.maxTickets` | `3` | Cap on a single `/csw:batch` run. |
| `batch.singleWriterLabels` | `["migration"]` | Labels admitting at most one ticket per batch. |

## Gates

A gate is a glob and a command. When a changed file matches the glob, the command joins the
validation run:

```json
"gates": [
  { "when": "**/migrations/**", "run": "just backend migrate-checksums" },
  { "when": "web/**/*.tsx",     "run": "just playwright-preview" }
]
```

Glob semantics:

| Pattern | Matches |
|---|---|
| `**` | Any characters, including `/` |
| `*` | Any characters except `/` |
| `?` | One character except `/` |

Patterns are anchored to the whole path, so `migrations/**` matches `migrations/0042.sql`
but not `backend/migrations/0042.sql`. Use `**/migrations/**` for the nested case.

Gates exist for the checks CI cannot or does not run — a checksum regeneration that only
matters when a migration lands, or a browser suite that only runs against a preview
deployment.

Preview the gates a branch triggers:

```bash
csw-gates main
```

## Priority ordering

`/csw:batch` sorts by priority. With `tracker: linear`, Linear's own scale applies — `1` is
Urgent through `4` is Low, and `0` (no priority) sorts last. Any other tracker sorts
numerically descending.

## Example

A full config, from the project this workflow grew out of:

```json
{
  "ticketPrefix": "TRA",
  "tracker": "linear",
  "validate": "just validate",
  "worktreeDir": ".claude/worktrees",
  "gates": [
    { "when": "**/migrations/**", "run": "just backend migrate-checksums" }
  ],
  "batch": { "maxTickets": 3, "singleWriterLabels": ["migration"] }
}
```
````

- [ ] **Step 7: Rewrite `README.md`**

````markdown
# Claude Ship Workflow

**CSW** takes a ticket from your tracker to a merged pull request, then cleans up after
itself. Superpowers owns *how the work gets done*. CSW owns *how it gets shipped and closed
out*.

> **This is one person's idiosyncratic workflow, and it is probably not yours.** It assumes
> worktrees, merge commits, conventional commits, a review step that a human actually
> performs, and a tracker that holds the brief. It is MIT-licensed and public because the
> shape is reusable even when the details are not. Fork it, or lift the parts you want.

## The three phases

```
/csw:work ENG-1088          # dispatch: worktree, autonomous implementation, PR, stop
  ... you review the diff ...
go for merge                # merge: CI gate, merge commit, chains into cleanup
                            # cleanup: worktree gone, branches gone, sweep reported
```

**Dispatch** reads the ticket, sets it In Progress, opens a worktree, runs the work
autonomously test-first, validates, and opens a PR. Then it stops. Hold-for-review is a hard
stop, not a checkpoint to talk past.

**Merge** is natural language, not a command — `go for merge`, `diffs look good`, `merge it`
— because it is said mid-conversation where a slash command is friction. An ambiguous "looks
good" earns a clarifying question rather than a merge. CI red stops it.

**Cleanup** returns to the base branch, removes the worktree, deletes the branches, and then
sweeps: it reports *other* merged-but-undeleted branches and stale worktrees without being
asked. That turns "any remaining worktrees?" from a question you have to remember into
something reported unprompted. Branch cleanup never asks. Closing a ticket always asks.

## The nightly loop

```
/csw:batch
```

Pulls Todo tickets, excludes what cannot safely run tonight, and dispatches the rest — one
worktree and one PR each — then leaves a morning summary. Three filters, because one is not
enough:

- **Blocked tickets**, which only works if your tracker actually records blocking relations.
- **Contended global resources.** Two migration-adding tickets each write the next number in
  a global sequence. Neither PR is wrong; one still has to be redone rather than rebased. At
  most one per batch.
- **Same-surface clusters.** Tickets that share related-issue links tend to land in each
  other's copy even when they touch different files. Highest priority per cluster.

Three or four tickets a night, not the whole column — the cap comes from review, not from the
loop. Anything that does not reach merge-ready is left as a **draft** PR with a question on
the ticket, so preview automation filters it out and the morning review only sees PRs that
are genuinely asking to be merged.

## Install

```
/plugin marketplace add mikestankavich/claude-ship-workflow
/plugin install csw@claude-ship-workflow
```

**Requires:** `git` 2.30+, `gh` 2.x authenticated, `jq` 1.6+. `/csw:batch` also needs
`python3` 3.9+. [Superpowers](https://github.com/obra/superpowers) is a strong
recommendation, not a hard dependency — `/csw:work` uses its planning, execution, and TDD
skills when they are installed and proceeds test-first when they are not.

## Configure

Drop a `.claude/csw.json` in the repo you work in:

```json
{
  "ticketPrefix": "ENG",
  "tracker": "linear",
  "validate": "just validate",
  "worktreeDir": ".claude/worktrees",
  "gates": [
    { "when": "**/migrations/**", "run": "just backend migrate-checksums" }
  ]
}
```

A different project is a config file, not a fork. Full reference:
[docs/configuration.md](docs/configuration.md). Design rationale:
[docs/design.md](docs/design.md).

## Commands

| Command | Phase | Invocation |
|---|---|---|
| `/csw:work <ticket>` | Dispatch | Command, or "work ENG-1088" |
| `/csw:merge` | Merge | Usually natural language: "go for merge" |
| `/csw:cleanup` | Cleanup | Usually automatic, chained from merge |
| `/csw:batch` | Nightly loop | Command only — never inferred |

## What happened to v0.x

Versions through **v0.4.0** were *Claude **Spec** Workflow*: a bespoke
`/csw:spec` → `/csw:plan` → `/csw:build` → `/csw:ship` framework with a bash CLI and a
`spec/` tree checked into every target repo. Superpowers now does that job better, and
running both produced two overlapping vocabularies and one half-retired framework.

**v0.4.0 is unmaintained, superseded, and wrong in places. Do not install it.** The tag
exists as archaeology, not as an offer. There is no migration path: if you were using it,
move to [superpowers](https://github.com/obra/superpowers) for the spec-and-build half and
use this for the ship half.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Tests: `bash tests/run-tests.sh`.

## License

MIT — see [LICENSE](LICENSE).
````

- [ ] **Step 8: Add the CHANGELOG entry**

Insert directly beneath the CHANGELOG's top heading, above the existing `0.4.0` entry:

```markdown
## [1.0.0] - 2026-08-02

CSW is now Claude **Ship** Workflow. Complete rewrite: superpowers owns how the work gets
done, CSW owns how it gets shipped and closed out.

### Added
- `/csw:work <ticket>` — dispatch a ticket into a worktree, drive it autonomously to an open
  pull request, then hard-stop for review.
- `/csw:merge` — CI-gated merge on natural-language approval, chaining into cleanup.
- `/csw:cleanup` — worktree and branch removal plus an unprompted sweep for other stale
  branches and worktrees. Always asks before closing a ticket.
- `/csw:batch` — nightly loop with blocked, same-surface-cluster, and single-writer filters
  and a morning summary.
- `.claude/csw.json` config layer, so a different project is a config file rather than a fork.
- `bin/csw-config`, `bin/csw-ticket`, `bin/csw-gates`, `bin/csw-sweep`, `bin/csw-batch-filter`.
- Bash test suite and CI.

### Removed
- **BREAKING:** `/csw:spec`, `/csw:plan`, `/csw:build`, `/csw:check`, `/csw:ship`, the `csw`
  binary, `spec/` trees, presets, and templates. Old and new must not coexist. Use
  [superpowers](https://github.com/obra/superpowers) for that half of the workflow.

### Changed
- Ships as a Claude Code plugin marketplace instead of a shell installer.
- Repository renamed to `claude-ship-workflow`.
```

- [ ] **Step 9: Run the tests to verify they pass**

```bash
bash tests/run-tests.sh
```

Expected: PASS across every test file.

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "docs: rewrite README for the reboot, add configuration reference and example config"
```

---

### Task 13: End-to-end verification and pull request

Everything above is unit-tested. This task proves the plugin actually loads and the
executables work through the plugin's `PATH`, then opens the PR.

**Files:**
- Create: `tests/test-integration.sh`

- [ ] **Step 1: Write the integration test**

`tests/test-integration.sh`:

```bash
#!/usr/bin/env bash
# End-to-end: a fresh repo, a real config, and the full derivation chain.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/test-helpers.sh"

repo=$(make_repo)
cp "$REPO_ROOT/examples/csw.json" "$repo/.claude-tmp.json" 2>/dev/null
mkdir -p "$repo/.claude"
cp "$REPO_ROOT/examples/csw.json" "$repo/.claude/csw.json"
rm -f "$repo/.claude-tmp.json"
cd "$repo" || exit 1

# The example config must actually drive the tools it claims to.
assert_eq "$("$BIN/csw-config" get ticketPrefix)" "TRA" "example config loads"
assert_eq "$("$BIN/csw-ticket" normalize 1088)" "TRA-1088" "example config normalises a bare number"
assert_eq "$("$BIN/csw-ticket" branch feat 1088 'Add nav vocabulary')" \
  "feat/tra-1088-add-nav-vocabulary" "example config produces the documented branch name"
assert_eq "$(printf 'backend/migrations/0042.sql\n' | "$BIN/csw-gates" --files)" \
  "just backend migrate-checksums" "example config's migration gate fires"
assert_eq "$(printf 'README.md\n' | "$BIN/csw-gates" --files)" "" "unrelated change triggers no gate"

# Every executable is executable and has a shebang.
for f in "$REPO_ROOT"/bin/*; do
  name=$(basename "$f")
  if [ -x "$f" ]; then PASSES=$((PASSES + 1)); else
    FAILURES=$((FAILURES + 1)); printf 'FAIL bin/%s is not executable\n' "$name" >&2
  fi
  assert_contains "$(head -1 "$f")" "#!/usr/bin/env" "bin/$name has a shebang"
done

# Every skill the README advertises exists.
for s in work merge cleanup batch; do
  if [ -f "$REPO_ROOT/skills/$s/SKILL.md" ]; then PASSES=$((PASSES + 1)); else
    FAILURES=$((FAILURES + 1)); printf 'FAIL skills/%s/SKILL.md missing\n' "$s" >&2
  fi
done

report
```

- [ ] **Step 2: Run the full suite**

```bash
bash tests/run-tests.sh
```

Expected: PASS across all eight test files. Fix anything red before continuing — do not open
a PR on a red suite.

- [ ] **Step 3: Validate the plugin and install it locally**

```bash
claude plugin validate . --strict || echo "validator unavailable"
```

Then, in a Claude Code session, add the local marketplace and confirm `/csw:work`,
`/csw:merge`, `/csw:cleanup`, and `/csw:batch` appear in the `/` menu and that
`csw-config json` runs as a bare command in a Bash tool call.

Record the result. If the commands do not appear under the `csw:` prefix, the plugin name in
`.claude-plugin/plugin.json` is wrong — that is the only thing that sets the namespace.

- [ ] **Step 4: Commit**

```bash
git add tests/test-integration.sh
git commit -m "test: add end-to-end verification of the example config and plugin layout"
```

- [ ] **Step 5: Hand off — the branch owner opens the PR**

Do not push or open the PR from inside this task. The branch is finished as a whole, after
the final whole-branch review, using superpowers:finishing-a-development-branch. Report that
the integration test is green and the branch is ready.

For reference, the PR the branch owner will open:

```bash
git push -u origin feat/csw-reboot-superpowers
gh pr create --base main \
  --title "feat!: reboot CSW as Claude Ship Workflow 1.0.0" \
  --body "$(cat <<'BODY'
Replaces Claude *Spec* Workflow v0.4.0 with Claude **Ship** Workflow 1.0.0.

Superpowers owns how the work gets done. CSW now owns how it gets shipped and
closed out: dispatch a ticket into a worktree, land the PR, clean up, close the loop.

## What's here

- `/csw:work` — dispatch to an open PR, then hard-stop for review
- `/csw:merge` — CI-gated merge on natural-language approval, chains into cleanup
- `/csw:cleanup` — worktree and branch removal plus an unprompted sweep
- `/csw:batch` — nightly loop with blocked, cluster, and single-writer filters
- `.claude/csw.json` config layer, so a different project is a config file, not a fork
- Five executables in `bin/`, each unit-tested
- Bash test suite and CI

## Breaking

`/csw:spec`, `/csw:plan`, `/csw:build`, `/csw:check`, `/csw:ship`, the `csw` binary,
`spec/` trees, presets, and templates are all gone. v0.4.0 is tagged as archaeology.

## Worth checking by hand

- The four commands appear under the `csw:` prefix after `/plugin install`
- `bin/` executables run as bare commands in a Bash tool call
- `/csw:work` against a real ticket, all the way to an open PR

Design: `docs/design.md`. Plan: `docs/superpowers/plans/2026-08-02-csw-reboot.md`.
BODY
)"
```

Once it is open, report the PR URL and what is worth testing by hand. Do not merge.

---

### Task 14: Repo rename and 1.0.0 release

**Runs only after the PR from Task 13 is merged to `main`.** These are outward-facing and
partly irreversible; confirm each one before running it.

- [ ] **Step 1: Confirm the merge landed**

```bash
git checkout main && git pull
git log --oneline -3
test -f .claude-plugin/plugin.json && echo "reboot is on main"
```

- [ ] **Step 2: Confirm the rename with the user, then rename**

The GitHub redirect keeps old clone URLs and links working, but this changes a public URL.
Ask before running it.

```bash
gh repo rename claude-ship-workflow --repo mikestankavich/claude-spec-workflow
git remote set-url origin git@github.com:mikestankavich/claude-ship-workflow.git
git remote -v
git fetch origin
```

- [ ] **Step 3: Update the repository description and topics**

```bash
gh repo edit mikestankavich/claude-ship-workflow \
  --description "Ship a tracker ticket: dispatch it into a worktree, drive it to a pull request, merge it after review, and clean up after itself." \
  --add-topic claude-code --add-topic claude-code-plugin --add-topic worktree --add-topic workflow
```

- [ ] **Step 4: Confirm the release with the user, then cut it**

```bash
git tag -a v1.0.0 -m "1.0.0 — Claude Ship Workflow"
git push origin v1.0.0
gh release create v1.0.0 \
  --title "1.0.0 — Claude Ship Workflow" \
  --notes "$(sed -n '/^## \[1.0.0\]/,/^## \[0.4.0\]/p' CHANGELOG.md | sed -e '$d')"
```

- [ ] **Step 5: Mark v0.4.0 as archaeology on the release page**

Only if a GitHub release exists for `v0.4.0` — a bare tag needs nothing. If one does:

```bash
gh release edit v0.4.0 --prerelease \
  --notes "Final Claude *Spec* Workflow release. Unmaintained, superseded by 1.0.0, and wrong in places. Kept as archaeology — do not install."
```

- [ ] **Step 6: Verify the install path end-to-end**

In a fresh Claude Code session:

```
/plugin marketplace add mikestankavich/claude-ship-workflow
/plugin install csw@claude-ship-workflow
```

Confirm all four commands appear. Report the result.

---

### Task 15: Leftovers outside this repo

Three cleanups the design names, each in someone else's tree. **Confirm before each one** —
these touch machines and repos outside the reboot.

- [ ] **Step 1: Remove the v0.4.0 binary from PATH**

```bash
ls -l ~/.local/bin/csw && which csw
```

Confirm with the user, then:

```bash
rm ~/.local/bin/csw
```

- [ ] **Step 2: Remove the user-level v0.x commands and skill**

These are what makes old and new coexist — the plugin cannot replace them while they sit in
`~/.claude/`.

```bash
ls ~/.claude/commands/csw:*.md ~/.claude/skills/csw
```

Confirm, then:

```bash
rm ~/.claude/commands/csw:build.md ~/.claude/commands/csw:check.md \
   ~/.claude/commands/csw:cleanup.md ~/.claude/commands/csw:plan.md \
   ~/.claude/commands/csw:ship.md ~/.claude/commands/csw:spec.md
rm -rf ~/.claude/skills/csw
```

Verify in a fresh session that `/csw:` now resolves only to the plugin's four commands.

- [ ] **Step 3: Open a PR removing `spec/` from `trakrf/platform`**

Nine checked-in v0.4.0 feature directories. Its own small PR in that repo, not this one.

```bash
gh repo view trakrf/platform --json name >/dev/null
```

Confirm with the user, then in a worktree of that repo:

```bash
git rm -r spec
git commit -m "chore: remove checked-in CSW v0.4.0 spec tree

Superseded by superpowers plus Claude Ship Workflow 1.0.0."
```

Push and open the PR. Do not merge it — that repo has its own review.

- [ ] **Step 4: Update the "do not use CSW" memory files**

Three projects carry memory files instructing the assistant not to use CSW. That instruction
was written when CSW meant the spec framework, and it is now wrong in a way that will quietly
suppress the reboot.

Find them:

```bash
grep -rl -i "csw" ~/.claude/projects/*/memory/ 2>/dev/null
```

For each hit, read the file first, then rewrite it to say what is now true: superpowers owns
spec-and-build; CSW means Claude Ship Workflow and owns dispatch, merge, and cleanup. Show
each rewrite before saving it.

- [ ] **Step 5: Report**

List every leftover handled, every one skipped, and why.

---

## Self-review

**Spec coverage** — every section of `docs/design.md` maps to a task:

| Design section | Task |
|---|---|
| What changed / Why it exists | 12 (README), 12 (CHANGELOG) |
| Shape — marketplace repo, MIT, public, disclaimer | 2, 12 |
| Shape — config layer, not a fork | 3, 12 |
| Phase 1 — Dispatch | 7, with 3–5 underneath |
| Phase 2 — Merge | 8 |
| Phase 3 — Cleanup | 9, with 6 underneath |
| Phase 4 — Batch loop, three filters, preview cap | 10, 11 |
| Blocked-on-a-question / generalized draft rule | 7 (Step 9), 11 (Step 5) |
| Morning summary | 11 (Step 6) |
| Migration — tag v0.4.0 as archaeology | 1 (Step 1), 14 (Step 5) |
| Migration — README states v0.x unmaintained | 12 (Step 7), tested |
| Migration — ships as 1.0.0 | 2, 14 |
| Migration — repo rename, history carries over | 14 |
| Migration — what is removed, what is kept | 1, tested |
| Old and new must not coexist | 1 (in-repo), 15 (user-level) |
| Leftovers outside this repo | 15 |
| Prior art — worktree-plus-shipped rough edges | 9 (Step 4, uncommitted changes and refusal-to-remove paths) |

Two design lines are deliberately not implemented as code: the *interactive* dispatch flavor
is out of scope by the design's own statement, and the hour of prior-art reading is research
whose output is already folded into Task 9's edge-case handling.

**Placeholder scan** — no TBDs, no "add error handling", no "similar to Task N". Every code
step carries its actual content. Exit codes, glob semantics, and priority ordering are
specified where they are produced and re-stated where they are consumed.

**Type consistency** — the config keys named in Task 3's `DEFAULTS` are the same keys read in
Tasks 4, 5, 6, 10, and 12, and `tests/test-docs.sh` enforces that every one of them is
documented. Branch-pattern tokens are `<type>`, `<ticket>`, `<slug>` in the implementation,
the tests, the example config, and the configuration reference. `csw-batch-filter`'s output
keys `selected`/`skipped` match what `skills/batch` reports.

**One correction to the design doc's wording:** it shows the branch pattern as
`<type>/tra-NNNN-slug`, which describes the *output*. The literal config value that produces
it is `"<type>/<ticket>-<slug>"`. The plan uses the literal form throughout.
