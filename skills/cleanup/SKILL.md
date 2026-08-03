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

The only thing that authorises deletion is `gh pr view` reporting `state: MERGED`. Anything
else is a stop-and-ask: a non-merged state, no PR for this branch, or
**the command failing for any reason** — no auth, no configured remote, a network error, or
anything else. Command failure is not "no signal, treat it as merged" — it is exactly the same
stop as an explicit non-merged state. No substitute may be used to establish the merge
instead: not `git log --merges`, not `git branch --merged`, not reading the PR page. Only
`gh pr view` reporting `state: MERGED` counts.

If the check does not clear, **stop**. Name the branch and what you found — including the raw
error if the command itself failed — and ask whether to clean up anyway. This is the one case
where branch and worktree cleanup asks: `git branch -d` refuses an unmerged branch on its own,
but nothing stops `git worktree remove` from deleting the checkout that holds someone's
unlanded work, and the worktree carries no such protection of its own.

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
```

Worktree removal must run from outside the worktree being removed.

Then, **on either path**, land on the base branch and take the remote's latest:

```bash
git checkout "<baseBranch>"
git pull
```

`git pull` is not optional and is not only for the manual path. The merge you just landed
is on the remote, not in this checkout — skip the pull and the local base branch sits one
commit behind from the moment cleanup finishes, which then silently backdates the next
worktree branched from it. If the pull fails, say so and stop before removing anything.

## Step 3: Remove this worktree and branch

No confirmation here — Step 1 already confirmed the merge. This is bookkeeping, and it **should never require a separate instruction**.

What happens next depends on what Step 2 actually did:

- **Step 2 used the native ExitWorktree tool.** It already owns removal, so the worktree is
  already gone. Running `git worktree remove` again on a path it already removed fails with
  `fatal: '<path>' is not a working tree` (exit 128) — that is "already gone," which is success,
  not a problem to report. Skip straight to pruning and the branch delete:

  ```bash
  git worktree prune
  git branch -d "<branch from Step 1>"
  ```

- **Step 2 fell back to the manual `cd`/`checkout` path** because no native tool existed. The
  worktree is still there, so remove it first:

  ```bash
  git worktree remove "<path from Step 1>"
  git worktree prune
  git branch -d "<branch from Step 1>"
  ```

  If `git worktree remove` refuses because of uncommitted changes, stop and show them. Work
  that never made it into the merged PR is not clutter — report it and let the human decide.
  Only use `--force` if they say so. This uncommitted-changes stop is specific to the manual
  path — it cannot happen on the ExitWorktree path, since that tool has already removed the
  worktree by the time this step runs.

If `git branch -d` refuses, the branch is not merged into the base. Say so and stop; do not
reach for `-D`.

The remote branch is already gone if the merge used `--delete-branch`. If it is still there:

```bash
git push origin --delete "<branch from Step 1>"
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
session is concerned — list them, propose removing them, and wait. A vague "sure, clean it
up" is not approval for a list: either they name what goes, or ask again.

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
| "`gh pr view` failed, but I can check `git log` instead" | No substitute counts. Command failure is a stop, the same as an explicit non-merged state. |
| "I'll ask before deleting the worktree" | Once the merge is confirmed, do not. Removing its worktree from there is bookkeeping. Asking again is how it gets forgotten. |
| "The ticket is clearly done, I'll close it" | Always ask. Every time. |
| "The sweep is empty, nothing to report" | Report the empty sweep. Silence reads as "not checked". |
| "`csw-sweep` printed nothing, so there's nothing stale" | Check the exit code. Non-zero means the sweep did not run — unknown is not the same as absent. |
| "That other worktree is obviously stale too" | List it, ask, then act. |
| "`git branch -d` refused, I'll use -D" | Refusal means unmerged commits. Investigate. |
| "Uncommitted changes in the worktree are just scratch" | Show them first. That call is not yours. |
| "One repo's PR is merged, so the ticket is done" | Check for siblings in other repos. |
