# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.3] - 2026-08-03

### Fixed
- **`csw-sweep`'s upstream-gone detection had never fired.** It finds branches deleted on the
  forge through `%(upstream:track)` reporting `[gone]`, which only happens once
  `refs/remotes/origin/<name>` is missing *locally*. `gh pr merge --delete-branch` deletes the
  branch on the forge; only a prune removes the local mirror, and nothing in the workflow pruned
  — `/csw:cleanup`'s `git pull` does not, absent `fetch.prune`. Every leftover the sweep ever
  found came from the merged-into-base arm instead, which is exactly the arm that cannot see a
  branch that shipped without becoming an ancestor of the base. `/csw:cleanup` Step 2 now runs
  `git pull --prune` before the sweep, with the reason recorded so the flag is not tidied away
  later. The sweep cannot fix this itself: never fetching is a deliberate invariant, and pruning
  mutates refs.
- `/csw:cleanup`'s sibling-PR search ran unscoped across all of GitHub. With `tracker: github`
  the ticket is a bare number, so searching for `81` returned thirty strangers' PRs and not one
  sibling — thirty false positives being precisely the output an agent skims past. The query is
  now scoped with `--owner`, with a title search and a `--match title,body` form for numeric
  tickets, and the skill says plainly that a long result list means the query was too broad
  rather than that there are many siblings.

### Changed
- `csw-sweep`'s report carries a second `note:` line when upstream-gone detection may be stale,
  for standalone invocations that have no skill wrapped around them to prune first. It fires
  only when it could change the answer — when some branch that is not the base and is not
  already reported still resolves an upstream, which is precisely the set a prune could add to
  the report. Unconditional would be noise that teaches the reader to skip `note:` lines,
  costing the base-behind note its audience too.

## [1.0.2] - 2026-08-03

### Fixed
- `/csw:cleanup` now **verifies** `ExitWorktree`'s "will discard N commits" warning instead of
  trusting it. Before passing `discard_changes: true` it captures the branch head and runs
  `git merge-base --is-ancestor "$head_sha" origin/<base>`: exit 0 proves the commits are already
  on the remote and nothing is lost, non-zero means the warning is real — stop and report, do not
  discard. The skill previously said nothing about this warning, leaving an agent to either stall
  on something it could not evaluate or wave it through reflexively, and the second habit
  eventually deletes work that really was unmerged.

### Changed
- **The discard warning is documented as unavoidable.** `ExitWorktree` compares the branch against
  the worktree's *creation point*, so the warning fires on every cleanup and **cannot be suppressed
  by anything cleanup does**. This was measured, not assumed: the local base branch was moved
  *ahead* of the branch head before exiting and the warning fired anyway. Because it always fires
  it carries no information on its own, which is precisely why the `merge-base` check is the only
  defence. The skill records the null result so the experiment is not run a third time.
- The branch name shown in the warning is the pre-rename `worktree-<slug>`, which makes
  `/csw:work` Step 4's rename look causal. It is not — the commit *count* is correct, and the
  stale name is display only. `/csw:cleanup` now says so, and says not to "fix" this by
  abandoning the rename that ties a branch to its ticket.

## [1.0.1] - 2026-08-03

### Fixed
- `csw-sweep` missed branches merged into the base branch's **upstream** when the local base
  was behind it — the normal state on a machine where PRs are merged on the forge rather than
  locally, and precisely the staleness the sweep exists to catch. The merged set is now the
  union of `<base>` and `<base>@{upstream}`. No fetch: it reads only the remote-tracking ref
  already on disk.
- `csw-sweep` hid a merged branch when it was the one checked out, which silenced it about the
  single branch a human is most likely to care about. It is now reported like any other,
  annotated with the base branch to land on first — `git branch -d` refuses the checked-out
  branch.

### Changed
- `csw-sweep`'s report leads with a note when the local base is behind its upstream, so a
  quiet sweep is distinguishable from a stale one.
- **`csw-sweep branches` output contract:** a listed branch is no longer guaranteed deletable
  with `git branch -d` from where the caller stands. Git refuses loudly and harmlessly, which
  beats the previous silent omission.
- `csw-sweep worktrees` no longer lists the main working tree. `git worktree remove` refuses
  it outright, so offering it as a removable leftover was an action that could not succeed.
  Its branch still appears in `csw-sweep branches`.
- `/csw:cleanup` handles a swept branch that is the current branch — land on the base, pull,
  then delete — and states its end condition explicitly: it finishes on the base branch,
  current with its remote.

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
- Repository rename to `claude-ship-workflow` is planned to follow this release, once this
  branch merges.

## [0.4.0] - 2026-03-23

> **Skill Framework Migration**: Native Claude Code integration with colon-namespaced commands

### Breaking Changes

- Commands renamed to colon namespace: `/spec` → `/csw:spec`, `/plan` → `/csw:plan`, etc.
- `/cleanup` deprecated — cleanup now runs automatically at start of `/csw:spec`
- `cleanup/merged` branch pattern removed
- Requires `csw migrate && csw install` for existing users

### Added

- SKILL.md for Claude Code autonomous discovery (`skills/csw/SKILL.md`)
- `csw migrate` subcommand for removing old command files
- Dirty-tree guard at start of `/csw:spec`
- Automatic cleanup of completed specs at start of each new spec cycle
- `cleanup_completed_specs()` function in `scripts/lib/cleanup.sh`
- `csw --version` now reads from VERSION file

### Changed

- `csw install` now installs skill + namespaced commands, detects old files
- `csw init` now installs `.claude/skills/` and `.claude/commands/` at project scope
- `csw uninstall` removes both skill and namespaced commands + old files
- All command markdowns updated with `csw:` prefix references
- `spec/active/` path references updated to `spec/` throughout

### Removed

- Standalone `/cleanup` command (prints deprecation notice)
- `cleanup/merged` branch detection in `/csw:plan`
- Old un-namespaced command file installation
- SHIPPED.md references (already retired in previous cycle)

### Fixed

- `csw --version` was hardcoded to 0.2.2, now reads VERSION file
- Stale `spec/active/` path references in command docs (#48)

## [0.3.2] - 2025-10-23

> **Bug Fix**: Cleanup script branch detection

### Fixed

- **`/cleanup` branch detection exit code handling**
  - Fixed critical bug where ls-remote exit codes were captured incorrectly
  - Root cause: `local ls_exit=$?` inside else block captured exit code of if evaluation (0), not ls-remote command (2)
  - Impact: Branches with deleted remotes (squash/rebase merges) weren't being cleaned up
  - Solution: Capture exit code before conditional logic, use elif chain for clarity
  - Now correctly deletes branches merged via GitHub squash/rebase strategies
  - Changed in: `scripts/lib/cleanup.sh:127-145`

## [0.3.1] - 2025-10-23

> **Critical Bug Fix**: Prevents data loss from cleanup script

### Fixed

- **CRITICAL: `/cleanup` spec deletion logic** (Issue #35)
  - Fixed false positive deletions where specs mentioned in SHIPPED.md descriptions were incorrectly deleted
  - Root cause: `grep -q "$feature_name"` matched feature names anywhere in SHIPPED.md, not just section headers
  - Example: Spec `3.3.2/` was deleted because a different feature's entry contained "Foundation for: Phase 3.3.2"
  - **Solution**: Use `log.md` filesystem existence as definitive proof of completion instead of text parsing
  - `log.md` on main proves: `/build` ran → committed → PR merged → feature complete
  - Eliminates all text-matching edge cases and simplifies cleanup logic
  - Backward compatible: all shipped specs have log.md; unshipped specs are preserved
  - **Impact**: Prevents data loss for work-in-progress specs referenced in shipped feature descriptions
  - Changed in: `scripts/cleanup.sh:59-83`

- **`/cleanup` command**: Fixed branch detection to handle squash-merged and rebase-merged PRs (Issues #20, #30)
  - Added `git fetch --prune origin` to sync remote state before detection (fixes timing issues)
  - Implemented dual detection: traditional `--merged` check + remote tracking verification
  - Now reliably detects branches merged via any GitHub strategy (merge commit, squash, rebase)
  - Eliminates manual cleanup for orphaned local branches after merging PRs

- Fix output formatting across all workflow commands (/plan, /check, /build, /ship)
  - Added explicit OUTPUT FORMATTING RULES sections to prevent list item concatenation
  - Each command now includes visual examples (✅ correct vs ❌ wrong) for clear guidance
  - Resolves issue where multiple choice options, checkmarks, and bullet points were rendered as walls of text

- Fix `csw install` failing to create CLI symlink due to arithmetic operator bug with `set -e`
- Fix similar counter increment bugs in `csw uninstall`, validation suite, and cleanup workflow
- All bash scripts now use `var=$((var + 1))` instead of `((var++))` for `set -e` compatibility

### Migration Notes

**If you have been using v0.3.0**:
- No action required - the fix is backward compatible
- All existing shipped specs already have `log.md` on main branch
- Update immediately to prevent potential data loss from cleanup operations

**Recommended**: Pull and reinstall:
```bash
cd claude-spec-workflow
git pull
./csw install
```

## [0.3.0] - 2025-10-15

> **Bootstrap & Workflow Consolidation**: Unified CLI + workflow automation + infrastructure refactoring

This release consolidates 10 shipped features since v0.2.2, including major bootstrap improvements, new workflow commands, bug fixes, and internal refactoring. All changes have been dogfooded and validated.

### Added

#### Bootstrap & Installation (PR #15, #10, #5)
- **`csw install` subcommand** - Replaces `install.sh` with idempotent installation
  - Installs commands to `~/.claude/commands/`
  - Creates `~/.local/bin/csw` symlink
  - Checks PATH and provides setup guidance
- **`csw init` subcommand** - Replaces `init-project.sh` with enhanced project initialization
  - Fuzzy preset matching (exact → case-insensitive → substring): "shell" → "shell-scripts"
  - Bootstrap spec generation by default for all users (teaches workflow + monorepo customization)
  - `--no-bootstrap-spec` flag to opt out
  - Interactive prompts for directory creation and reinit confirmation
  - Creates `spec/csw` symlink for project-local usage
- **`csw uninstall` subcommand** - Replaces `uninstall.sh` with clean removal
  - Removes commands from `~/.claude/commands/`
  - Removes `~/.local/bin/csw` symlink
  - Preserves project `spec/` directories
- **Bootstrap validation spec template** (`templates/bootstrap-spec.md`)
  - Auto-generated during `csw init` to guide first workflow experience
  - Variable substitution: {{STACK_NAME}}, {{PRESET_NAME}}, {{INSTALL_DATE}}
  - Validates installation and teaches /plan → /build → /check → /ship cycle

#### Workflow Automation (PR #12, #11)
- **`/cleanup` command** - Post-ship workflow automation for solo developers
  - One-shot cleanup: sync main, delete merged branches, delete shipped specs
  - Creates `cleanup/merged` staging branch for seamless handoff to `/plan`
  - Aggressive and opinionated (no confirmations), trusts git history as backup
  - Optional for teams (can use manual cleanup per conventions)
- **`/plan` auto-cleanup** - Pre-flight cleanup of shipped features
  - Detects shipped branches via SHIPPED.md
  - Automatic branch deletion with safety checks
  - Prompts for each shipped feature found

#### Script Library Infrastructure (PR #6, #7, #9)
- **scripts/lib/** modules: common.sh, git.sh, validation.sh, cleanup.sh (456 lines, 29 functions)
- **bin/csw** CLI wrapper with command routing
- Three access methods work identically: `/command`, `csw command`, `./spec/csw command`

### Changed

#### Breaking Changes
- **BREAKING**: Moved `bin/csw` to project root as `csw` (PR #15)
  - Simpler bootstrap: `./csw install` vs `./bin/csw install`
  - Maximum discoverability: visible immediately after clone
  - Follows industry patterns (gradlew, mvnw, configure)
- **BREAKING**: Removed `bin/` directory (empty after csw move)
- **BREAKING**: Deleted `install.sh`, `init-project.sh`, `uninstall.sh` (replaced by csw subcommands)
- **BREAKING**: EOL PowerShell installation scripts (PR #5)
  - Removed install.ps1, init-project.ps1, uninstall.ps1
  - Windows users must use Git Bash or WSL2
  - Reduces installer codebase by 50%

#### Workflow Improvements
- **`/ship` workflow** - Single-commit SHIPPED.md update (PR #14)
  - Reordered steps: push → PR → SHIPPED.md (eliminates "PR: pending" states)
  - Updated template: short commit hash, full PR URL on separate line
  - Commit format: `docs: ship {feature} (#{pr-number})`
  - Method 4 (manual fallback) now fails fast
- **Commands simplified** - From ~100 lines to ~15 lines each (PR #9)
  - Replaced 28 embedded bash blocks with 5 clean csw calls
  - All instructional prompt text preserved
- **Paths simplified** - `spec/active/` → `spec/` throughout codebase (PR #7)
- **Documentation updates** (13 files across all PRs)
  - README.md: Installation, troubleshooting, Feature Lifecycle diagram
  - CONTRIBUTING.md: Development setup
  - TESTING.md: All test procedures
  - commands/*.md: All command references
  - templates/: stack-template.md, bootstrap-spec.md

### Fixed

- **CSW symlink resolution** (PR #13)
  - Fixed critical bug where commands failed when invoked via `~/.local/bin/csw` symlink
  - Implemented industry-standard symlink resolution (Node.js/Homebrew pattern)
  - Handles absolute/relative symlinks, multi-level chains
  - POSIX compliant (Linux, macOS, WSL, Git Bash)

### Internal

- **Script library refactoring** (PR #6, #7, #9)
  - Extracted ~400 lines from commands into standalone scripts
  - Created 6 executable scripts: spec.sh, plan.sh, build.sh, check.sh, ship.sh, cleanup.sh
  - Zero duplication: all use Phase 1 library functions
  - All scripts pass shellcheck with zero errors/warnings
- **Terminology shift**: "archive" → "cleanup" throughout codebase (PR #11)

### Migration Guide

If upgrading from v0.2.x:

1. **Reinstall globally**:
   ```bash
   cd claude-spec-workflow
   git pull
   ./csw install  # New command location and syntax
   ```

2. **Update existing projects** (optional):
   - Projects with `spec/` already initialized will continue to work
   - To update project-local wrapper: `cd your-project && csw init .` (confirm overwrite)
   - To skip bootstrap spec: use `--no-bootstrap-spec` flag

3. **Update scripts/automation**:
   - Replace `./install.sh` → `./csw install`
   - Replace `init-project.sh /path/to/project` → `csw init /path/to/project`
   - Replace `./uninstall.sh` → `csw uninstall`

4. **Windows users**: Use Git Bash or WSL2 (PowerShell no longer supported)

**No data loss**: All existing `spec/` directories and SHIPPED.md files preserved.

**See SHIPPED.md** for detailed success metrics (10 features, 100% metrics achieved on most)

_No other unreleased changes. See README.md Roadmap section for planned features._

## [0.2.2] - 2025-10-13

> **Script Library Phase 1**: Build primitive function library and CLI wrapper (internal refactoring, no user-facing changes yet)

### Added

- Script library infrastructure in `scripts/lib/` with 4 modules:
  - `common.sh` (54 lines) - Logging, path helpers, file operations, validation helpers
  - `git.sh` (123 lines) - Git operations: branches, merging, repository state
  - `validation.sh` (117 lines) - Test/lint/build runners with package manager detection
  - `archive.sh` (106 lines) - Archive operations for completed features
- CLI wrapper `bin/csw` (56 lines) with command routing
- Total: 5 files, 456 lines, 29 functions + CLI wrapper

### Technical Notes

- **Phase 1 of 3**: Primitives only (no integration)
- All scripts pass shellcheck with zero errors/warnings
- All sourcing chains tested and functional
- CLI wrapper tested: help, version, error handling, routing
- **Phase 2 (0.2.3)**: Will extract command logic
- **Phase 3 (0.3.0)**: Will wire everything and enable csw CLI for users

## [0.2.0] - 2025-10-12

> Stack configuration system rewritten. Achieves 60-93% token reduction per command invocation.

### Changed

- Replaced `spec/config.md` (YAML format) with `spec/stack.md` (Markdown with bash code blocks)
- Removed `init-stack.sh` and `init-stack.ps1` scripts - functionality consolidated into `init-project`
- Commands now require `spec/stack.md` and error with helpful message if missing
- Removed ~800 lines of inline stack conditionals from `/build`, `/check`, `/ship` commands
- Commands now load only 100-250 lines instead of 1500+ lines (60-93% token reduction)
- `init-project.sh` and `init-project.ps1` now accept `[target-path] [preset]` arguments
- Init scripts are now re-runnable with overwrite warnings and y/n confirmation prompts
- Default preset is `typescript-react-vite` if not specified
- Init scripts auto-detect their location for flexible invocation
- Converted all 5 presets from YAML to markdown with bash code blocks
- Preset format now uses section headers (## Lint, ## Test, etc.) with commands in bash blocks
- Updated README.md Stack Configuration section to reference `spec/stack.md`
- Updated troubleshooting section for new configuration system
- Updated templates/README.md validation standards section

### Added

- `templates/stack-template.md` - Reference template showing single-stack and monorepo structure
- Customization tips and examples in stack template
- Roadmap section in README.md with v0.3.0 plans
- `spec/stack.md` to project structure documentation

### Removed

- `init-stack.sh` and `init-stack.ps1` scripts
- Inline stack detection and defaults from all commands
- YAML config format and parsing logic
- `spec/config.md` references throughout documentation

## [0.1.0] - 2025-10-11

> **Pre-release for dogfooding**: Initial implementation to be validated through real-world use before v1.0.0 public release.

### Added

- Specification-driven development workflow with 5 slash commands: `/spec`, `/plan`, `/build`, `/check`, `/ship`
- Cross-platform installation scripts (Unix .sh + Windows .ps1)
- Project initialization system (`init-project` and `init-stack`)
- Stack configuration presets: TypeScript + React + Vite, Next.js App Router, Python + FastAPI, Go standard, Monorepo (Go + React + TimescaleDB)
- Template system for specs, configs, and documentation
- Example specification: User Profile Editing feature
- Automatic complexity assessment (0-10 scoring) in `/plan` command
- Complexity scoring based on file impact, subsystem coupling, task count, dependencies, and pattern novelty
- Mandatory split recommendation for features scoring 6-10/10
- Optional phase breakdown generation for complex features
- Mandatory clarifying questions gate before plan generation
- Quality/confidence scoring in implementation plans with one-pass success probability
- ULTRATHINK strategic thinking checkpoints in all 5 commands
- Mandatory validation gates: lint, types, tests, build (BLOCKING requirements)
- Full test suite gate before any commit in `/build` (cannot skip, 100% pass required)
- Code cleanup gate before final validation (removes console.log, debugger, commented code)
- Auto-detection and defaults for Node/TypeScript, Rust, Go, Python stacks
- Stack-aware validation commands and patterns
- Workspace-aware validation for monorepo projects
- Success Metrics section in spec template with tracking in SHIPPED.md
- Conventional Commits format with semantic versioning support
- Role-based personas for each command (Product Engineer, Architect, Engineer, Test Engineer, Tech Lead)
- Automatic archival of shipped features during `/plan` with y/n prompts
- SHIPPED.md tracking with date, commit, and success metrics
- Comprehensive README with installation and usage instructions
- Installation guides for macOS, Linux, and Windows
- Quick start guide with step-by-step workflow
- Stack configuration examples for single-stack and monorepo projects
- Complexity assessment methodology and examples
- Conventional commit format examples
- Troubleshooting sections for validation and workflow issues
- MIT License
