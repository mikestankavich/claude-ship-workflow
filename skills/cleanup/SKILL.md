---
name: cleanup
description: Clean up after a merged pull request — return to the base branch, remove the worktree, delete the branch, sweep other stale branches and worktrees, and report tracker state. Use after a merge or whenever asked what is left over.
when_to_use: "clean up the worktree and merged branches", "any remaining worktrees?", "delete merged branches", after csw:merge lands a PR
---

# Clean up after a merged pull request

**Announce at start:** "Using csw:cleanup to close out <ticket>."

Branch and worktree cleanup happens without asking. Closing a ticket always asks. Those two
rules are not symmetric and the asymmetry is deliberate.

## Step 1: Note where you are before you move

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

No confirmation. The PR is merged; this is bookkeeping, and it **should never require a separate instruction**.

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
| "I'll ask before deleting the worktree" | Do not. The PR merged; removing its worktree is bookkeeping. Asking is how it gets forgotten. |
| "The ticket is clearly done, I'll close it" | Always ask. Every time. |
| "The sweep is empty, nothing to report" | Report the empty sweep. Silence reads as "not checked". |
| "That other worktree is obviously stale too" | List it, ask, then act. |
| "`git branch -d` refused, I'll use -D" | Refusal means unmerged commits. Investigate. |
| "Uncommitted changes in the worktree are just scratch" | Show them first. That call is not yours. |
| "One repo's PR is merged, so the ticket is done" | Check for siblings in other repos. |
