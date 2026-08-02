# CSW reboot — design

**Status:** approved in brainstorming, not yet implemented
**Date:** 2026-08-02

## What changed

CSW was Claude *Spec* Workflow: a bespoke framework of `/csw:spec` → `/csw:plan` →
`/csw:build` → `/csw:ship` backed by a bash script and a `spec/` tree in each target repo.
Superpowers now owns that half of the job — brainstorming, specs, plans, TDD, execution.
Keeping a second framework for the same work produced two overlapping vocabularies and,
in practice, a half-retired one: the binary still on `PATH`, the commands still installed,
the `spec/` trees still checked in, and memory files in three projects instructing the
assistant not to use any of it.

CSW becomes Claude **Ship** Workflow. Superpowers owns *how the work gets done*. CSW owns
*how the work gets shipped and closed out*: dispatch a ticket into a worktree, land the PR,
clean up, close the loop.

The name is the only part of the reboot that is cosmetic. Everything else is a rewrite.

## Why it exists

The workflow it automates is already in daily use, established over roughly forty tickets
across four repos. It is currently driven by typing the same phrases over and over:

- Dispatch — `use superpowers to work TRA-1088 autonomous to PR then hold for review`
- Green light — `diffs look good go for merge`
- Cleanup — `clean up the worktree and merged branches`

Two problems with that. The dispatch phrase is long enough to typo (it has been, twice,
as "autonomuos"). And the cleanup phrase is the one that gets forgotten, because it comes
after the interesting part is over — producing a pile of merged-but-undeleted branches and
stale worktrees that surfaces later, mid-unrelated-work, as *"wait, why are we on a
TRA-1079 worktree?"*

The closest existing skill, superpowers' `finishing-a-development-branch`, stops at PR
creation and works by presenting a three-option menu that this workflow overrides with a
memory file on every project. The gap is real: nothing covers merge-after-review, tracker
state, or cleanup.

### Prior art worth mining before implementing

Not for architecture — the policy half is what makes this idiosyncratic, and the git half is
about fifteen lines of `git` and `gh`, some of which is a single flag (`gh pr merge --merge
--delete-branch`). But other people's production experience with the *edge cases* is worth
an hour:

- **Worktree Finish** and **End Session** (mcpmarket) — pre-flight checks, uncommitted
  changes at cleanup, orphaned worktrees, detached HEAD. mcpmarket returns 429 to automated
  fetches; pull the equivalents from the GitHub-hosted skill collections instead.
- **git-town** — the mature non-AI answer for the git mechanics. Note issue #6083 (March
  2026): `sync` fails to detect a shipped parent branch when it is held by a worktree. A
  dedicated tool with years of investment still has rough edges at exactly the
  worktree-plus-shipped intersection this workflow lives in. Expect to hit it.

## Scope

In scope: the autonomous dispatch flavor, the merge, the cleanup, and (stage two) a batch
loop. Out of scope: the interactive flavor — `use superpowers to work TRA-1069` with no
autonomy — which is used deliberately when surfacing all the brainstorming questions is the
point, and is better left freeform.

## Shape

A Claude Code plugin marketplace repo, MIT, public, with the disclaimer stated plainly in
the README: this is one person's idiosyncratic workflow and probably not yours.

Trakrf-specific values do not belong in the skill. They live in a config layer read from the
target repo, so a different project is a config file rather than a fork:

| Config | This project |
|---|---|
| Ticket prefix | `TRA` |
| Tracker | Linear (MCP) |
| Validate | `just validate` |
| Worktree dir | `.claude/worktrees/` |
| Branch pattern | `<type>/tra-NNNN-slug` |
| Extra gates | `just backend migrate-checksums` when migrations change; Playwright against preview for UI diffs, because CI never runs it |

What is idiosyncratic is the config and the gates. The ship-a-ticket-and-clean-up-after
shape is not, which is what makes the public version useful to someone else despite the
disclaimer.

## Phase 1 — Dispatch

`/csw:work TRA-1088` (bare `1088` also accepted). A slash command rather than natural
language, because this is the long error-prone phrase and it is typed at the start of a
session where a command feels natural.

Reads the ticket, sets it In Progress, infers `<type>` from the ticket, creates a worktree
via the native `EnterWorktree` tool. Runs the superpowers chain in autonomous mode —
`writing-plans` → `executing-plans` → `test-driven-development`, skipping `brainstorming`.
Runs the configured validate command and any gates the diff triggers. Conventional commit,
push, open the PR.

**Then it stops.** Hold for review is a hard stop, not a checkpoint to talk past. The report
names the PR, what changed, and what is worth testing on hardware.

## Phase 2 — Merge

Natural language, not a command: `go for merge`, `diffs look good`, `merge it`. These are
short and said mid-conversation, where a slash command would be friction. An ambiguous
"looks good" earns a clarifying question rather than a merge.

Checks CI; red stops. Then `gh pr merge --merge` — never squash. Chains directly into
phase 3, since that is what happens ~99% of the time; an exception is stated explicitly.

## Phase 3 — Cleanup

Switch to main and pull, remove the worktree, delete the local and remote branch.

Then sweep: report any *other* merged-but-undeleted branches or stale worktrees, and ask
before touching them. This is what turns *"any remaining worktrees or merged branches?"*
from a question that has to be remembered into something reported unprompted.

Tracker last. Report the ticket state and check for open sibling PRs referencing the same
ticket in other repos — a platform ticket is not done while its docs counterpart is still
open. **Always ask before closing.** Branch and worktree cleanup needs no such caveat and
should never require a separate instruction.

## Phase 4 — Batch loop (stage two)

Pull Todo tickets, exclude what cannot safely run tonight, sort by descending priority,
dispatch each. Review the resulting PRs in the morning and merge them.

This is specced now and built after phases 1–3, because it depends on a tracker backfill
that has not happened and on exclusion heuristics that want tuning against real batches.
Once the cycle exists, the loop is a sorted for-loop over phase 1.

### Exclusion needs three filters, not one

**1. Blocked tickets.** Only works if the tracker knows. It currently does not: of the Todo
tickets sampled, every one had empty `blocks` and `blockedBy` arrays while carrying three to
four `relatedTo` links. The dependency information is real and detailed — it is in
`relatedTo` and in prose. TRA-1076's description states outright that TRA-1074 must
*replace* the DSN setting rather than delete it: a hard ordering constraint, in a paragraph,
invisible to any structured query. Backfilling blocking relations on the existing Todo
column is a prerequisite for the loop, not a nice-to-have.

**2. Contended global resources.** Two tickets can be mutually unblocked and still be
irreconcilable. TRA-1075 and TRA-1076 are both database tickets that need a new forward
migration. Dispatched the same night, each agent writes the next number in a global sequence
and both regenerate `migrations/checksums.txt`. Neither PR is wrong; both validated against
main; one has to be redone rather than rebased. **At most one migration-adding ticket per
batch.** Single-writer by construction.

**3. Same-surface clustering.** TRA-1081 and TRA-1082 touch different files and would not
conflict textually, but they are the same nav-vocabulary surface — and the standing rule
that a named-instance fix triggers a same-surface audit means an agent doing TRA-1082
properly will land in TRA-1081's copy. Shared `relatedTo` targets are a usable proxy for
clustering; take the highest priority per cluster.

### Batch size is capped by preview, not by the loop

`sync-preview.yml` resets `preview` to `main` and merges *every* open non-draft PR into it.
That is free N-way integration testing, and it already posts conflict comments on the PRs
that collide. It also means the morning review tests the *combination*, not any individual
PR. Past roughly three or four open PRs, a bug found on preview cannot be attributed without
bisecting — and the review gate is what the whole design rests on.

Three to four tickets a night, not the whole column. Still a large multiple of one.

### Blocked-on-a-question path

The dispatch phrasing already stops at the right places; that behavior is validated and
needs no rubric here. What is new is that an unattended batch has nobody to ask. So instead
of stopping and waiting:

1. Write the question as a comment on the ticket
2. Push a **draft** PR carrying the work so far, referencing it
3. Leave the ticket In Progress
4. Continue to the next ticket

Draft is load-bearing: `sync-preview` filters drafts out, so blocked work survives and stays
reviewable without polluting the environment used to review the PRs that finished. In
Progress is self-excluding, since the loop only pulls Todo — no risk of re-dispatching into
the same wall the next night.

The answer then lands in the ticket as durable context, so a re-dispatch starts from a
better brief than the original. The loop compounds rather than merely parallelizes.

### Morning summary

Dispatched, PRs open, blocked-with-questions, skipped-and-why — so the night does not have
to be reconstructed by hand across the tracker.

## Migration from v0.4.0

Current HEAD is `0.4.0`, tagged `v0.1.0` only. Before deleting anything, tag current HEAD
`v0.4.0` — as archaeology, not as an offer. The README must state plainly that v0.x is
unmaintained, superseded, and likely wrong in places, and should not be installed. A bare
tag sitting next to a 1.0.0 release otherwise reads as "the old stable version," which is
the wrong signal for code nobody has maintained in months. The reboot ships as `1.0.0`.

The only two known users are the author and a contract developer who has already been told
to move to superpowers, so there is no migration path to write.

Repo renames to `claude-ship-workflow`; GitHub keeps redirects. History, issues, PR record,
CHANGELOG, and MIT license all carry over — nothing is copied, and the reboot reads as a
diff rather than as an unexplained fresh repo.

Removed: `commands/` (the five old phase commands), `skills/`, the `csw` script, `scripts/`,
`presets/`, `templates/`, `spec/`. Kept: LICENSE, CONTRIBUTING, CODE_OF_CONDUCT, CHANGELOG,
README (rewritten).

Old and new must not coexist. `/csw:spec` → `/csw:plan` → `/csw:build` → `/csw:ship` is a
different workflow, and leaving it installed beside the reboot recreates exactly the
ambiguity this is meant to end.

### Leftovers outside this repo

- `~/.local/bin/csw` — the v0.4.0 binary, still on `PATH`
- `trakrf/platform` `spec/` — nine checked-in v0.4.0 feature dirs; its own small PR
- Memory files in three projects saying "do not use CSW" — need updating once CSW means this
