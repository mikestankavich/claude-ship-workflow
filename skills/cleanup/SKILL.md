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

### When ExitWorktree warns it will discard commits

`ExitWorktree` refuses to remove a worktree whose branch it believes carries unmerged
commits, and asks to be re-invoked with `discard_changes: true`:

```
Worktree has 2 commits on worktree-fix+76-csw-sweep-misses-branches-merged-upstrea.
Removing will discard this work permanently. Confirm with the user, then re-invoke
with discard_changes: true — or use action: "keep" to preserve the worktree.
```

**Expect this on every single cleanup.** The tool compares the branch against the worktree's
**creation point** — the commit the base branch was on when the worktree was cut — and cleanup
by definition runs after commits have been added since. So the warning **cannot be suppressed
by anything cleanup does**. Pulling or fast-forwarding the base first does not help: that was
measured directly, by moving the local base *ahead* of the branch head before exiting and
watching the warning fire anyway. Do not re-run that experiment.

Because it always fires, it carries no information on its own, and both reflexes it invites
are wrong: stalling on a warning you have not checked, and passing `discard_changes: true`
because the PR is merged so the warning "must" be spurious. The second one eventually discards
work that really was unmerged.

Prove it instead. The refused exit leaves you still inside the worktree, so this runs from
right there — capture the branch head **before** exiting, because afterwards the branch may
be gone:

```bash
head_sha=$(git rev-parse HEAD)
git fetch -q origin
git merge-base --is-ancestor "$head_sha" "origin/<baseBranch>"
```

Exit 0 proves every commit on this branch is already in `origin/<baseBranch>`. Nothing is
lost; re-invoke `ExitWorktree` with `discard_changes: true` and carry on.
**Non-zero means the warning is real** — there are commits here that did not ship. Stop,
report the SHAs (`git log --oneline "origin/<baseBranch>..HEAD"`), and do not discard.

This proves safety directly rather than inferring it from the tool's warning, so it holds no
matter what the tool is comparing against.

Two things this is **not**:

- **Not the branch rename.** The name in the warning is the pre-rename `worktree-<slug>` that
  `csw:work` Step 4 renamed away, which makes the rename look causal. It is not: the commit
  *count* is correct, and a branch name that no longer exists could not produce a correct
  count. The stale name is display only. Renaming back will not suppress the warning, and the
  rename is what ties the branch to its ticket — do not abandon it.
- **Not a reason to skip Step 1.** A merged PR is not by itself proof that *this* branch head
  is in the base. Verify the SHA.

### Land on the base branch

Once the worktree is gone, **on either path**, land on the base branch and take the remote's
latest:

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

### The branch you are standing on

The sweep reports a merged branch even when it is the one currently checked out, marking it
`(current branch — check out <base> first, then delete)`. On the normal chained path this
never fires: Steps 2–3 already landed on the base branch and deleted the branch this run was
about. It fires when cleanup is invoked in a plain checkout that is simply sitting on work
that already shipped.

`git branch -d` refuses the checked-out branch, so — once it is approved along with the rest
of the sweep — land first, then delete:

```bash
git checkout "<baseBranch>"
git pull
git branch -d "<the current branch the sweep flagged>"
```

That is the same land-then-delete Step 2 and Step 3 do, applied to a branch this run did not
open. The approval rule above is unchanged: it is still swept work, so it is still proposed
and waited on, never deleted on sight.

## Step 4a: End on the base branch

Cleanup finishes on the base branch, current with its remote, with nothing merged left lying
around. That is the whole point of the exercise — the next piece of work starts from a clean
checkout in a fresh session, with no leftovers to trip over. Before moving to the tracker:

```bash
git branch --show-current      # must be <baseBranch>
git status -sb                 # must be clean, and not behind
```

If either says otherwise, say so explicitly rather than letting the session end somewhere
unexpected. Being left on a deleted branch's detached HEAD, or on a base branch three commits
behind its remote, is exactly the state that silently backdates the next branch cut from it.

## Step 5: The tracker, last

Report the ticket's current state. If the PR body said `Closes <TICKET>`, the tracker may
have moved it already — check rather than assume.

Then look for siblings before declaring it done. **Scope the search to this repo's owner.**
`gh search prs` with no scope searches all of GitHub, which is almost never what this step
wants:

```bash
owner=$(gh repo view --json owner --jq .owner.login)
gh search prs "<TICKET>" --owner "$owner" --state open --json repository,number,title,url
```

With `tracker: linear` the ticket is a distinctive string like `ENG-123`, and even that query
wants the scope. With `tracker: github` it is a **bare number**, which matches every PR whose
title happens to contain those digits — version bumps, unrelated issue numbers, strangers'
repos. Run unscoped for `81` and you get thirty PRs from thirty projects, none of them
siblings.

Scoping is the floor, not the whole answer. For a numeric ticket, also search what the work
was actually *about*, and search the `#<TICKET>` form against titles and bodies rather than the
bare digits:

```bash
gh search prs "<a distinctive phrase from the ticket title>" --owner "$owner" --state open --json repository,number,title,url
gh search prs "#<TICKET>" --owner "$owner" --match title,body --state open --json repository,number,title,url
```

**A long result list is a symptom, not a finding.** A couple of candidates is an answer worth
reading; thirty means the query was too broad. Narrow it and run it again — do not paste the
list into the report. This step exists so that one genuine cross-repo sibling gets noticed, and
burying it in thirty false positives is indistinguishable from missing it.

A platform ticket is not done while its docs counterpart is still open. Report the siblings you
find — and when the scoped search comes back empty, report that too. `[]` is the answer this
step is usually looking for, and saying so is what shows it ran.

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
| "The PR is merged, so ExitWorktree's discard warning is obviously spurious" | Prove it. `git merge-base --is-ancestor "$head_sha" origin/<base>` exiting 0, or stop. Reflexive `discard_changes: true` is how real work gets deleted. |
| "The warning names a branch that no longer exists, so it's stale nonsense" | The name is display only; the commit count is correct. Run the `merge-base` check — do not dismiss it, and do not stall on it either. |
| "The sweep flagged the branch I'm on, so it must be confused" | It is not. Land on the base branch, then delete it. Standing on shipped work is the ordinary case, not an anomaly. |
| "`git branch -d` refused the current branch, so I'll leave it" | Refusing the *checked-out* branch is not the unmerged-commits refusal. Check out the base first, then delete. |
| "Cleanup is done, wherever the checkout happens to be" | It ends on the base branch, current with its remote. Anything else backdates the next branch cut from it. |
| "That other worktree is obviously stale too" | List it, ask, then act. |
| "`git branch -d` refused, I'll use -D" | Refusal means unmerged commits. Investigate. |
| "Uncommitted changes in the worktree are just scratch" | Show them first. That call is not yours. |
| "One repo's PR is merged, so the ticket is done" | Check for siblings in other repos. |
| "The sibling search returned thirty open PRs" | That is an unscoped query, not thirty siblings. Add `--owner` and run it again. |
| "The ticket number is enough of a query on its own" | Not for a `github` ticket. Scope it with `--owner`, then search the title too. |
