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
