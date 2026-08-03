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
assert_eq "$version_file" "1.0.2" "VERSION is 1.0.2"
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
