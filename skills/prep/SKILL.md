---
name: prep
description: Spec a ticket before it is dispatched. Brainstorms it for the questions that must be answered before it can run unattended, then leaves a first-pass spec as one ticket comment. No worktree, no branch, no pull request, and the ticket stays where it was.
when_to_use: "/csw:prep 1088", "prep ENG-1088", "spec ENG-1088 before tonight's batch", "is this ticket ready to dispatch?"
argument-hint: "[ticket-ref]"
---

# Prep a ticket for dispatch

**Announce at start:** "Using csw:prep to spec <ticket> without touching the repo."

Invocation: $ARGUMENTS

A batch loop only compounds *after* a failure: a ticket blocks, the question lands on the
ticket, and the next dispatch starts from a better brief — so one wasted dispatch is the price
of every question discovered. Prep moves that discovery in front of the dispatch, where it
costs a comment instead of a night.

Prep does not implement anything, and it does not decide anything a human should. It reads,
it asks, and it writes one comment.

## Step 0: Read the config

```bash
csw-config json
csw-config path
```

If `csw-config path` prints nothing, this repo has no `.claude/csw.json`. Say so and show the
defaults you are about to use. Prep runs nothing destructive, so this is a note rather than a
stop — but `tracker` is the one key it genuinely needs, because it decides where the comment
goes.

## Step 1: Resolve the ticket

```bash
csw-ticket normalize "<the reference from the invocation>"
```

If the invocation carried no reference, ask which ticket. Do not pick one.

If normalisation exits non-zero, report its message and stop. Prepping the wrong ticket is
worse than prepping none: the comment lands somewhere a later dispatch will read it as its
brief.

## Step 2: Read the ticket — and only read it

Read it from the tracker named by `csw-config get tracker`:

- `linear` — the Linear MCP tools. Fetch the issue and its existing comments.
- `github` — `gh issue view <number> --json title,body,labels` and
  `gh issue view <number> --comments`.
- `none` — ask for the ticket text.

Read the **whole** description, not the title. Ordering constraints and "replace, do not
delete" style requirements live in prose and are invisible to structured queries — and those
are exactly the requirements a dispatch discovers too late.

**Do not claim it.** `csw:work` Step 2 moves the ticket to In Progress because it is about to
do the work; prep is not. A prepped ticket that left Todo is a ticket the batch loop no longer
pulls, which removes it from the very column prep exists to improve.

Read the existing comments too, and read them before brainstorming rather than after. A
question already asked and answered in the thread is a decision, not an open question, and
re-asking it in the prep comment tells the next dispatch to go and re-litigate it. If a prior
`**CSW prep**` comment is already there, this run supersedes it: say which questions it left
unanswered and do not simply repeat the ones that have since been settled.

## Step 3: Brainstorm it, in surface-the-questions mode

Run **superpowers:brainstorming** against the ticket.

Its usual mode designs the implementation. This is not that mode: prep runs in
**surface-the-questions mode**, and the difference is the whole point of the command. The
design belongs to the dispatch, which will have a worktree to try it in and tests to find out
whether it was right. What prep produces is the set of things that dispatch would otherwise
stop on.

You may read anything in the repo. Reading is not a side effect. Check what the ticket asserts
against what the code actually does — a ticket that names a file, a flag, or a function that
has since moved is a dispatch that will spend its run discovering that.

What to come out with:

- **A first-pass spec.** What the change is, in the terms the codebase actually uses.
- **The open questions** — specifically the ones that must be answered before this can run
  *unattended*. That is the bar. "Which of these two names is nicer" does not stop a dispatch;
  "does this replace the existing path or sit alongside it" does.
- **Contradictions.** Anything the ticket asserts that the codebase contradicts, quoted from
  both sides so a human can adjudicate it without going and looking.

If the superpowers skills are not installed, say so once and do the same work by hand. The
skill is a strong recommendation, not a hard dependency.

## Step 4: Write one comment

**One comment**, on the ticket, prefixed with the marker exactly:

```bash
# tracker: github
gh issue comment <number> --body "$body"
```

For `linear`, the same body through the Linear MCP comment tool. For `none`, print it and say
where it should be pasted.

The body:

```markdown
**CSW prep**

## First-pass spec
<what the change is, in the codebase's own terms>

## Open questions
1. <a question that would stop an unattended dispatch>
2. <another>

## What the ticket asserts that the codebase contradicts
- <claim> — <what is actually there, with the path>
```

The marker `**CSW prep**` is load-bearing and must be exact. `csw:work` Step 2 searches the
comments for that string; a comment that says "Prep notes" instead is a comment nothing will
ever read back.

**One comment, not a thread.** Answers arrive as replies underneath it, and a human scanning
the ticket has to be able to tell prep's questions from prep's own restatements of them. Three
comments from prep means the answers interleave with the questions and nobody can tell which
is which.

Leave the questions genuinely open. Prep answering its own questions is the failure this
command exists to prevent — an unattended dispatch will then treat the guess as the brief.

## Step 5: Stop

Report what you wrote and stop.

**No worktree, no branch, no pull request, no validation run**, no commit, and no change to
the ticket's state — it **stays in Todo** so the batch loop still picks it up. That is prep's
whole contract, and it is the only reason it is safe to run against a column of tickets before
anything about them has been decided.

Do not continue into `csw:work`. Prep ending is the point at which a human reads the questions;
answering them is not prep's job, and neither is starting the work while nobody has.

## Red flags

| Thought | Reality |
|---|---|
| "I know what they meant, I'll answer the question myself" | Then the dispatch inherits your guess as the brief. Leave it open. |
| "I've read enough to just start it — I'll open the worktree" | Prep has no worktree. If it is ready to run, dispatch it with `csw:work`. |
| "Set it In Progress so nobody double-prepares it" | Todo is what the batch loop pulls. Claiming it un-batches it. |
| "The spec is the useful part, questions are padding" | The questions are the product. The spec is context for them. |
| "One comment per question is easier to reply to" | One comment. Replies thread under it; multiple comments interleave with the answers. |
| "The title plus the labels tell me enough" | Read the description. The constraints that break a dispatch are in the prose. |
| "There's already a prep comment, nothing to do" | Re-read it against the thread. Prep again saying which of its questions are still open. |
| "I'll note the questions in my reply instead of on the ticket" | The comment is the durable artifact. A reply here is gone by the next session. |
