---
name: batch
description: Dispatch a night's batch of Todo tickets — one worktree and one pull request each — and leave a morning summary. Run explicitly; never inferred.
argument-hint: "[max-tickets] [--dry-run]"
disable-model-invocation: true
---

# Dispatch a batch of tickets

**Announce at start:** "Using csw:batch to dispatch tonight's tickets."

Tonight's invocation carried: $ARGUMENTS

Two modifiers, and they compose:

- **A bare integer** lowers tonight's cap. Never raises it — see Step 2.
- **`--dry-run`**, also written `dry-run` or `dry run`, runs selection and stops — see
  Step 3.

So `/csw:batch 2 --dry-run` shows tonight's plan cut at 2 without dispatching anything.
Anything else in $ARGUMENTS is not a modifier: say what you ignored and why, rather than
guessing at what it meant.

## Before the first run: the prerequisite

This loop's first filter is "drop blocked tickets," and it only works if the tracker knows
what blocks what. If `blockedBy` is empty on most tickets while `relatedTo` carries three or
four links each, the dependency information exists but is in the wrong field and in prose.

**Backfill blocking relations on the Todo column before relying on this.** Check a sample
first, and if `blockedBy` is empty across the board, say so and stop rather than dispatching
a batch whose ordering constraints are invisible.

## Step 1: Pull the candidates

Read every Todo ticket from the tracker named by `csw-config get tracker` and shape it into
the filter's input:

```json
[
  {
    "id": "ENG-1075",
    "state": "Todo",
    "priority": 2,
    "labels": ["migration"],
    "blockedBy": [],
    "relatedTo": ["ENG-1080", "ENG-1081"]
  }
]
```

## Step 2: Select

```bash
printf '%s' "$candidates_json" | csw-batch-filter
```

Three filters, none of which is guesswork:

1. **Blocked and not-Todo** tickets are dropped.
2. **Same-surface clusters** keep their highest-priority member. Two tickets on one nav
   surface do not conflict textually, but a same-surface audit rule means the agent doing one
   properly lands in the other's copy.
3. **Single-writer labels** admit one ticket per batch. Two migration-adding tickets each
   write the next number in a global sequence and both regenerate the checksums file; neither
   PR is wrong, both validated against the base, and one still has to be redone rather than
   rebased.

Then the cap — three or four, not the whole column. The ceiling is not the loop, it is
review: preview environments merge every open non-draft PR together, so the morning review
tests the *combination*. Past three or four, a bug found there cannot be attributed without
bisecting, and the review gate is what this whole design rests on.

The cap is not a fourth filter, and the output keeps it separate. Three keys come back:

| Key | Contents |
|---|---|
| `selected` | Dispatching tonight, in dispatch order. |
| `belowCap` | Passed every filter and still fell outside the cap, in the order it would have been dispatched. |
| `skipped` | Genuinely excluded — blocked, not Todo, same-surface cluster, single-writer conflict — each with its reason. |

`belowCap` is never an exclusion, and `skipped` never blames the cap. Keep them apart
everywhere you report them. Merged, nothing downstream can tell "must not run tonight" from
"would have run with a bigger cap" — and those two answer different questions: the first is
tuning data for the exclusion heuristics, the second is an argument for a different cap.

**If `csw-batch-filter` exits non-zero, the batch does not run.** Report its stderr message
verbatim, say plainly that selection failed and no tickets were dispatched, and stop — do not
continue to Step 3. A failed selection is never an empty selection: a malformed ticket, a bad
`priority` type, a duplicate id, or a negative configured cap all exit non-zero with no usable
`selected`/`skipped` on stdout, and none of them mean "nothing eligible tonight."

The optional cap override — $ARGUMENTS — can only lower tonight's cap, never raise it: the
configured `batch.maxTickets` is a safety ceiling, not a default to override upward. To
evaluate it you need that ceiling in hand, so read it the same way Step 1 reads the tracker:

```bash
csw-config get batch.maxTickets
```

Apply the override after the filter returns. If $ARGUMENTS is a positive integer smaller than
the length of `selected`, keep only its first that many entries — `selected` is already in
dispatch order — and move the rest to the **front** of `belowCap`, ahead of the filter's own
entries. They belong there and not in the skip list: nothing excluded them, and they are the
very next tickets that would dispatch if the cap went back up. Front, because they outrank
everything the filter had already put below the cap.

If $ARGUMENTS is absent, not a positive integer, or greater than or equal to the value
`csw-config get batch.maxTickets` just printed, ignore it, say so in the summary, and dispatch
the filter's own `selected` unchanged. Never guess at what a malformed override meant, and
never guess at the configured cap either — read it.

## Step 3: If this is a dry run, report and stop

A dry run answers "what would tonight do?" and nothing else. **It has no side effects:**
no dispatch, no worktree, no branch, no pull request, no change to any ticket's state.
Steps 4 through 7 do not run. The whole value is that it is free to run before an unattended
night, and it is only free while it stays free of side effects.

Report all three groups — the plan is not the selected list alone:

| Section | Contents |
|---|---|
| Would dispatch | Every `selected` id, in dispatch order |
| Below the cap | Every `belowCap` id, in the order it would have been dispatched |
| Excluded, and why | Every `skipped` id with its verbatim reason |

Then state the **effective cap and where it came from** — the configured `batch.maxTickets`,
or tonight's override, naming both the number and which one won. Someone reading this is
deciding whether the cap is right; a bare "cap: 2" does not say whether that came from the
config or from what they just typed.

Then stop. A dry run ends here — there is no go-ahead to give, because nothing is waiting on
one.

**A filter failure in a dry run is a failure, not an empty plan.** Step 2 already stopped if
`csw-batch-filter` exited non-zero; do not print three empty groups underneath it. Three
empty groups mean "nothing was eligible tonight", which is the one thing a failed selection
does not mean.

## Step 4: Confirm the selection

Show all three groups — `selected`, `belowCap`, and every `skipped` entry with its reason —
then wait for a go-ahead. `belowCap` belongs in front of the human here: it is the only
moment where "there were three more ready to go" can still change tonight's cap. This is the
last human checkpoint before an unattended night — once given, Steps 5 through 7 run straight
through with no further prompting and no further confirmation, until the morning summary
reports what happened.

## Step 5: Dispatch each, in order

For each selected ticket, run **csw:work** with the ticket reference and nothing else. Let it
run to its hard stop at an open PR, then move to the next one. One worktree and one PR per
ticket.

Nothing else, because `csw:work` takes an `interactive` modifier that brainstorms the ticket
and waits for a human to answer. At 3am there is nobody to answer, and a ticket parked on an
unanswered question is a night that stops on the first one rather than working the rest. A
ticket that genuinely needs the conversation is a ticket for tomorrow, dispatched by hand.

## Step 6: When a ticket blocks

An unattended batch has nobody to ask. So instead of stopping and waiting:

1. Write the question as a comment on the ticket.
2. Push a **draft** PR carrying the work so far (`gh pr create --draft`), referencing it.
3. Leave the ticket In Progress.
4. Continue to the next ticket.

Draft is load-bearing: preview automation filters drafts out, so blocked work survives and
stays reviewable without polluting the environment used to review the PRs that finished. In
Progress is self-excluding, since this loop only pulls Todo — no risk of re-dispatching into
the same wall tomorrow night.

The same applies to any ticket that does not reach merge-ready: failed validation, a partial
implementation, an approach that ran out of road. Draft is the state for "there is work here
worth keeping, but it is not a merge candidate."

The answer then lands in the ticket as durable context, so a re-dispatch starts from a better
brief than the original. The loop compounds rather than merely parallelizes.

## Step 7: Morning summary

Report, so the night does not have to be reconstructed by hand across the tracker:

| Section | Contents |
|---|---|
| Dispatched | Every ticket the loop started |
| PRs open | Ticket, PR URL, one line on what changed |
| Blocked with questions | Ticket, the question asked, the draft PR |
| Below the cap | Every `belowCap` id from Step 2, in order — tonight's queue, not tonight's rejects |
| Skipped and why | Every `skipped` entry from Step 2, verbatim reason |

If Step 2 failed outright, this table is not the report. Say plainly that selection failed,
quote the filter's message, and that nothing was evaluated or dispatched — never fold a
failed run into an empty Dispatched/Skipped table, which is reserved for a night where
candidates existed and were legitimately skipped.

Then stop. Merging the night's PRs is a morning decision, made by a human looking at diffs.

## Red flags

| Thought | Reality |
|---|---|
| "The column has twelve Todo tickets, dispatch them all" | Three or four. The cap is about attributable review, not throughput. |
| "Two migration tickets, they touch different tables" | They share a global sequence and one checksums file. One per batch. |
| "`blockedBy` is empty, so nothing is blocked" | Empty `blockedBy` usually means an unfilled field. Check before trusting it. |
| "This one's blocked, I'll open a normal PR and note it" | Draft. Always draft. Preview merges non-draft PRs. |
| "I'll merge the PRs that clearly passed" | The morning review is the gate. Do not pre-empt it. |
| "The skip reasons are noise in the summary" | They are the tuning data for the next batch. Report all of them. |
| "csw-batch-filter printed nothing, must mean no tickets were eligible" | Check the exit code first. Non-zero means selection failed — report the failure, don't dispatch nothing and call it a quiet night. |
| "They said cap it at 6 tonight, I'll pass that through" | The override can only lower the cap. `batch.maxTickets` is the ceiling; ignore anything at or above it, and say so. |
| "Over the cap is skipped, same table" | Different questions. `skipped` is why a ticket must not run; `belowCap` is what a bigger cap would have picked up. Merged, neither is answerable. |
| "A dry run may as well make the worktrees, they're cheap" | A dry run has no side effects at all. No branches, no worktrees, no ticket state changes — that is the only reason it is safe to run before anything is decided. |
| "The dry run found nothing, quiet night" | Check whether selection *failed*. Three empty groups mean nothing was eligible; a non-zero exit means nothing was evaluated. |
