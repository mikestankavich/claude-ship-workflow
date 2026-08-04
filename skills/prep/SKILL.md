---
name: prep
description: Spec a ticket before it is dispatched. Brainstorms it, decides everything it can recommend an answer for, asks a present human about the little that survives, and leaves the spec, the decisions and anything still open as one ticket comment. No worktree, no branch, no pull request, and the ticket stays where it was.
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

Prep does not implement anything. It reads, it decides everything it can defend a
recommendation for, it asks about the little that survives that test, and it writes one
comment carrying all of it.

**Prep is an interactive command**, and that is the design centre rather than a variant of it.
The person who can answer typed the invocation and is sitting there for the whole run, so a
run ends in one of two states, both of which leave the ticket **dispatchable**:

- Every question that would block an autonomous build has an answer, recorded on the ticket in
  the run that asked it.
- There were none, and prep says so.

The second is the common one and the one to aim for. A question left in a comment for someone
to notice tomorrow is not a third state — it is the first state, deferred by a day, and that
day is exactly what prep exists to remove.

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
`**CSW prep**` comment is already there, this run supersedes it: carry its decisions forward,
say which of its questions are still open, and do not repeat the ones that have since been
settled.

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
- **The candidate questions** — the ones that must be answered before this can run
  *unattended*. That is the bar. "Which of these two names is nicer" does not stop a dispatch;
  "does this replace the existing path or sit alongside it" does. They are *candidates*: Step 4
  decides which of them prep answers itself and which are worth a human's attention.
- **Contradictions.** Anything the ticket asserts that the codebase contradicts, quoted from
  both sides so a human can adjudicate it without going and looking.

If the superpowers skills are not installed, say so once and do the same work by hand. The
skill is a strong recommendation, not a hard dependency.

## Step 4: Triage — decide what you can defend, keep only what you cannot

Take every candidate from Step 3 and apply one mechanical test:

> **If you can mark an option "(Recommended)", you have your answer.** Do not ask — decide,
> and record the decision with the reasoning that made it one.

That test is not a judgement call about how important the uncertainty feels. It is something
prep can apply to itself: if you find yourself writing an option list whose first entry is the
obvious one, that list is a decision you have not finished making. It comes from measurement —
prep run over four tickets asked 4-6 questions on every one of them, and **every question that
carried a recommendation was answered by taking the recommendation**, without exception. Those
questions carried no information. They were a confirmation step wearing a question's clothing,
and a human paid for it on every ticket.

A recommendation is what a precedent gives you: something the codebase already does, a
convention the repo already follows, or a choice that is cheap to reverse because reversing it
means editing a file.

Two branches survive, and everything else is a decision:

1. **No recommendation can be formed.** Not enough clarity to pick means it is genuinely a
   question. This is the common legitimate case, and it should still be rare.
2. **The cost of being wrong is paid outside this repo.** Ask even holding a recommendation,
   because the criterion here is blast radius rather than confidence: a released config key's
   name, a public output contract, production data touched or migrated — anything that
   **cannot be walked back by editing a file**. That is a named class of consequence, not a
   feeling that something seems important, and it has to stay that narrow. Left vague it
   reabsorbs everything branch one excluded and prep is back to six questions a ticket.

**Question count is a quality signal, and it runs the opposite way to the obvious reading.** A
run that asks nothing and records six reasoned decisions is a *better* run than one that asks
six questions. Zero questions is the expected outcome, and frequently the right one; 0-2 is the
range. Six on one ticket reads as prep failing to do its job, not as prep being thorough — and
"surface the questions" pulls naturally towards surfacing all of them, which is exactly the
failure this step exists to stop.

The asymmetry is why the test is set this way round. A question that should have been a
decision costs its prepper an answer on every ticket, and buries the one that mattered among
five that did not. A decision that should have been a question is written down in the comment
with its reasoning, where a human reads it and overturns it. **The comment is the safety
mechanism, not the asking.**

## Step 5: Ask, once, and get the answer in this run

If nothing survived Step 4, this step is a no-op. That is the good outcome, not a sign the
triage was too aggressive — go straight to Step 6.

Otherwise, put the surviving questions to the human in **one round**, with **AskUserQuestion**,
each with the recommended option first where there is one. Take the answers; they become
decisions and are recorded as such in Step 6, in the same comment the questions were asked
from.

Ask them here, in the run. Someone typed `/csw:prep <ticket>` and is sitting right there:
proposing a recommendation to a human who can reject it is not the failure this command exists
to prevent — leaving them to read the questions in a comment, answer them in chat, and have
somebody copy the answers back by hand is. A question that reaches the comment unanswered has
cost the dispatch a day, and it was answerable in thirty seconds by the person who was in the
room the whole time.

**If nobody is there to answer, do not ask and do not guess.** Prep invoked from a subagent, or
a column of tickets prepped by one unattended run, has no one in the room; the surviving
questions stay open in the comment instead and the ticket is not yet dispatchable. This is the
degenerate case, not the shape prep is built around — say plainly, when you report, that the
run ended with questions nobody was there to answer, because the fix is a human re-running it
rather than a dispatch reading it. Nobody to ask is what makes an unanswered question a blocker
rather than a conversation.

**Several prep sessions running at once is the interactive path, not that fallback.** Four
sessions, four tickets, one human moving between them: you are present in every one, so every
session asks and gets its answer normally. It parallelises safely because prep writes nothing
to the repo and each session comments on a different ticket. What does collide is two sessions
given the *same* ticket — both write a `**CSW prep**` comment, neither is in a position to
supersede the other's the way Step 2 assumes, and the dispatch reads back two briefs for one
change. **One ticket per session.** Parallelism also sharpens the triage in Step 4 rather than
relaxing it: six questions apiece across four sessions is twenty-four interruptions to a human
who is already context-switching between four tickets.

## Step 6: Write one comment

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

## Decisions
1. <the choice, stated as settled> — <the reasoning that made it a decision rather than a
   question: the precedent it follows, or why it is cheap to reverse>
2. <a question Step 5 put to a human, and the answer they gave> — decided in this run.

## Open questions
_None._

## What the ticket asserts that the codebase contradicts
- <claim> — <what is actually there, with the path>
```

The marker `**CSW prep**` is load-bearing and must be exact. `csw:work` Step 2 searches the
comments for that string; a comment that says "Prep notes" instead is a comment nothing will
ever read back.

**Every decision carries its reasoning.** A decision written down without the precedent behind
it is indistinguishable from a guess, and a reader who cannot see why it was made cannot
overturn it — which is the one safety mechanism the triage in Step 4 relies on.

**An empty open-questions section says so.** Write `_None._` under the heading rather than
dropping the heading, because "nothing left open" is a dispatchable signal and an absent
section is not: a dispatch reading this back cannot tell a prep run that settled everything
from a prep run that never got that far.

**One comment, not a thread.** Answers to anything still open arrive as replies underneath it,
and a human scanning the ticket has to be able to tell prep's questions from prep's own
restatements of them. Three comments from prep means the answers interleave with the questions
and nobody can tell which is which — which is also why the answers Step 5 collected belong in
this comment rather than a second one.

Whatever survived Step 4 and had no human to answer it stays genuinely open. Prep answering
those questions unattended is the failure this command exists to prevent — the dispatch treats
the guess as the brief, and nothing downstream catches it.

## Step 7: Stop

Report what you wrote and stop. Say which of the two end states the run reached: the ticket is
dispatchable with nothing outstanding, or it is not and here is what is still open and why
nobody answered it.

**No worktree, no branch, no pull request, no validation run**, no commit, and no change to
the ticket's state — it **stays in Todo** so the batch loop still picks it up. That is prep's
whole contract, and it is the only reason it is safe to run against a column of tickets before
anything about them has been decided.

Do not continue into `csw:work`. The human who answered the questions has seen the comment go
by, not agreed to the work starting; deciding when a dispatchable ticket is dispatched is
theirs, and prep going on to implement against its own spec removes the one review point
between the brainstorm and a branch.

## Red flags

| Thought | Reality |
|---|---|
| "I know what they meant, I'll answer the question myself" | With **nobody watching**, that guess becomes the brief and nothing downstream catches it. Recommending it to a present human who can reject it is a different act; writing it into the comment unattended is not. |
| "I'm not fully certain, so I'll ask" | Then every ticket costs its prepper six answers and the two that mattered are buried. Recommend, record the reasoning, and move on. |
| "There's a recommendation, but this feels important enough to confirm" | Important is not the test. Public contract, production data, cannot be walked back by editing a file — otherwise it is a decision. |
| "Six questions means I was thorough" | It means triage did not run. A run that asks nothing and records six reasoned decisions is the better run. |
| "I'll leave it open in the comment for them to read" | They are here now — that is what interactive means. A question deferred to the comment is the same answer, a day later. |
| "I've read enough to just start it — I'll open the worktree" | Prep has no worktree. If it is ready to run, dispatch it with `csw:work`. |
| "Set it In Progress so nobody double-prepares it" | Todo is what the batch loop pulls. Claiming it un-batches it. |
| "The spec is the useful part, the rest is padding" | The decisions and the open questions are the product. The spec is context for them. |
| "Nothing is open, so I'll drop the section" | `_None._` is a signal a dispatch reads. A missing section is silence. |
| "One comment per question is easier to reply to" | One comment. Replies thread under it; multiple comments interleave with the answers. |
| "The title plus the labels tell me enough" | Read the description. The constraints that break a dispatch are in the prose. |
| "There's already a prep comment, nothing to do" | Re-read it against the thread. Prep again saying which of its questions are still open. |
| "I'll note the questions in my reply instead of on the ticket" | The comment is the durable artifact. A reply here is gone by the next session. |
