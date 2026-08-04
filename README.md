# Claude Ship Workflow

**CSW** takes a ticket from your tracker to a merged pull request, then cleans up after
itself. Superpowers owns *how the work gets done*. CSW owns *how it gets shipped and closed
out*.

> **This is one person's idiosyncratic workflow, and it is probably not yours.** It assumes
> worktrees, merge commits, conventional commits, a review step that a human actually
> performs, and a tracker that holds the brief. It is MIT-licensed and public because the
> shape is reusable even when the details are not. Fork it, or lift the parts you want.

## The three phases

```
/csw:prep ENG-1088          # optional: spec it, settle what it can, touch nothing
/csw:work ENG-1088          # dispatch: worktree, autonomous implementation, PR, stop
  ... you review the diff ...
go for merge                # merge: CI gate, merge commit, chains into cleanup
                            # cleanup: worktree gone, branches gone, sweep reported
```

**Prep** is the optional pass in front of the dispatch. It reads the ticket, brainstorms it for
the questions that would stop an unattended run, and then **answers the ones it can defend an
answer to** — anything with a precedent in the codebase, a convention the repo follows, or a
cheap reversal becomes a recorded decision with its reasoning rather than a question. The test
is mechanical: if prep can mark an option "(Recommended)", it has its answer. What survives is
put to you **in the run**, in one round — and usually that is nothing.

Prep is interactive by design: you typed it and you are sitting there, so it ends either with
every blocking question answered or with prep confirming there were none. Either way the ticket
is dispatchable when it stops. All of it — the spec, the decisions, the open questions if any,
and anything the ticket asserts that the codebase contradicts — lands in **one ticket comment**
marked `**CSW prep**`. It opens no worktree, no branch and no PR, and leaves the ticket in Todo.
Dispatch reads that comment back as part of the brief — decisions and answers in the thread are
settled, and questions still unanswered send the run to a draft PR instead of a guess. Without
it the loop only learns after a failure, at the cost of one wasted dispatch per question.

**Dispatch** reads the ticket, sets it In Progress, opens a worktree, runs the work
autonomously test-first, validates, and opens a PR. Then it stops. Hold-for-review is a hard
stop, not a checkpoint to talk past.

```
/csw:work ENG-1088 interactive
```

Same dispatch, planned out loud. It brainstorms the ticket first, surfaces the questions, and
waits for your answers before it writes a plan — for the tickets that are vague, or where the
approach has more than one defensible shape. Everything after planning is unchanged: same
validation, same gates, same PR, same hard stop. A word that is neither this nor nothing gets
named back and asked about rather than quietly dropped.

**Merge** is natural language, not a command — `go for merge`, `diffs look good`, `merge it`
— because it is said mid-conversation where a slash command is friction. An ambiguous "looks
good" earns a clarifying question rather than a merge. CI red stops it.

**Cleanup** returns to the base branch, removes the worktree, deletes the branches, and then
sweeps: it reports *other* merged-but-undeleted branches and stale worktrees without being
asked. That turns "any remaining worktrees?" from a question you have to remember into
something reported unprompted. Branch cleanup never asks. Closing a ticket always asks.

## The nightly loop

```
/csw:batch
```

Pulls Todo tickets, excludes what cannot safely run tonight, and dispatches the rest — one
worktree and one PR each — then leaves a morning summary. Every ticket runs in a subagent of
its own, so it gets its own context as well as its own worktree: nothing ticket one planned,
tried, or abandoned is still in the room when ticket two starts. Three filters, because one is
not enough:

- **Blocked tickets**, which only works if your tracker actually records blocking relations.
- **Contended global resources.** Two migration-adding tickets each write the next number in
  a global sequence. Neither PR is wrong; one still has to be redone rather than rebased. At
  most one per batch.
- **Same-surface clusters.** Tickets that share related-issue links tend to land in each
  other's copy even when they touch different files. Highest priority per cluster.

Prepped tickets dispatch better, but the loop does not require prep and does not skip tickets
that lack it.

Three or four tickets a night, not the whole column — the cap comes from review, not from the
loop. Anything that does not reach merge-ready is left as a **draft** PR with a question on
the ticket, so preview automation filters it out and the morning review only sees PRs that
are genuinely asking to be merged.

```
/csw:batch --dry-run
```

Runs the selection and stops — no dispatch, no worktrees, no branches, no PRs, no ticket
state changes. It prints what would dispatch, what fell **below the cap**, and what was
**excluded** and why. Those last two are reported apart on purpose: "would have run with a
bigger cap" is an argument about the cap, and "blocked by ENG-1088" is an argument about the
ticket. Pass a lower cap alongside it — `/csw:batch 2 --dry-run` — to see where a smaller
night would cut.

## Install

```
/plugin marketplace add mikestankavich/claude-ship-workflow
/plugin install csw@claude-ship-workflow
```

**Requires:** `git` 2.30+, `gh` 2.x authenticated, `jq` 1.6+. `/csw:batch` also needs
`python3` 3.9+. [Superpowers](https://github.com/obra/superpowers) is a strong
recommendation, not a hard dependency — `/csw:work` uses its planning, execution, and TDD
skills when they are installed and proceeds test-first when they are not.

## Configure

Drop a `.claude/csw.json` in the repo you work in:

```json
{
  "ticketPrefix": "ENG",
  "tracker": "linear",
  "validate": "just validate",
  "worktreeDir": ".claude/worktrees",
  "gates": [
    { "when": "**/migrations/**", "run": "just backend migrate-checksums" }
  ]
}
```

A different project is a config file, not a fork. Full reference:
[docs/configuration.md](docs/configuration.md). Design rationale:
[docs/design.md](docs/design.md).

## Commands

| Command | Phase | Invocation |
|---|---|---|
| `/csw:prep <ticket>` | Before dispatch | Optional — interactive, spec only, no side effects |
| `/csw:work <ticket>` | Dispatch | Command, or "work ENG-1088" |
| `/csw:work <ticket> interactive` | Dispatch | Brainstorms first, then the same run |
| `/csw:merge` | Merge | Usually natural language: "go for merge" |
| `/csw:cleanup` | Cleanup | Usually automatic, chained from merge |
| `/csw:batch` | Nightly loop | Command only — never inferred |
| `/csw:batch --dry-run` | Nightly loop | Selection only, no side effects |

## What happened to v0.x

Versions through **v0.4.0** were *Claude **Spec** Workflow*: a bespoke spec → plan → build →
ship command framework with a bash CLI and a `spec/` tree checked into every target repo.
Superpowers now does that job better, and running both produced two overlapping vocabularies
and one half-retired framework.

**v0.4.0 is unmaintained, superseded, and wrong in places. Do not install it.** The tag
exists as archaeology, not as an offer. There is no migration path: if you were using it,
move to [superpowers](https://github.com/obra/superpowers) for the spec-and-build half and
use this for the ship half.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Tests: `bash tests/run-tests.sh`.

## License

MIT — see [LICENSE](LICENSE).
