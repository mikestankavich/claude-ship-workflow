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
first.

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
- **Pending** — report what is still running and ask whether to wait or stop.
- **Green** — continue.

Also check `mergeStateStatus`. `BEHIND` means the base moved: update the branch and let CI
run again. `DIRTY` means conflicts: stop and report them.

## Step 4: Merge

```bash
gh pr merge <number> --merge --delete-branch
```

**Always `--merge`. Never `--squash`, never `--rebase`.** Cleanup finds stale branches with
`git branch --merged`, and a squash-merged branch is invisible to it — squashing here quietly
breaks the sweep that the next phase depends on.

## Step 5: Chain into cleanup

Roughly always, the merge is followed by cleanup. Go straight into **csw:cleanup** without
asking.

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
