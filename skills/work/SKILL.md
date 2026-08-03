---
name: work
description: Dispatch a tracker ticket into an isolated worktree and drive it autonomously to an open pull request, then stop for review. Pass `interactive` to brainstorm the ticket with a human before planning it. Use when asked to work a ticket end-to-end.
when_to_use: "/csw:work 1088", "work ENG-1088", "work 1088 autonomous to PR then hold for review", "take ENG-1088 to a PR", "/csw:work 1088 interactive"
argument-hint: "[ticket-ref] [interactive]"
---

# Work a ticket to a pull request

**Announce at start:** "Using csw:work to take <ticket> to a pull request."

Invocation: $ARGUMENTS

## Step 0: Read the config

```bash
csw-config json
csw-config path
```

If `csw-config path` prints nothing, this repo has no `.claude/csw.json`. Say so, show the
defaults you are about to use, and ask whether to continue or write a config first. Do not
silently guess a validate command.

## Step 1: Resolve the ticket, and the modifier

The invocation is a ticket reference, optionally followed by one modifier word. Split it on
whitespace: the first token is the reference, whatever follows it is the modifier.

```bash
csw-ticket normalize "<the first token of the invocation>"
```

If the invocation carried no reference, ask which ticket. Do not pick one.

If normalisation exits non-zero, report its message and stop — a mistyped reference is
exactly the failure this command exists to prevent.

Then read the modifier:

- **`interactive`** — run **superpowers:brainstorming** against the ticket before the Step 5
  chain. Surface the questions and wait for the answers. Do not run unattended. This is the
  flavour someone reaches for when the ticket is vague, or when the approach has more than one
  defensible shape; answering your own questions is exactly the thing it exists to prevent.
- **No modifier** — autonomous, exactly as the rest of this skill describes. Brainstorming is
  skipped because the ticket is the agreed brief.
- **An unrecognised modifier is not ignored.** Say what was passed, say it is not recognised,
  and ask whether to proceed autonomously — then wait. Silently discarding a word someone
  deliberately typed is how a dispatch does something other than what was asked, and the word
  they were reaching for may well have been `interactive`.

`interactive` changes only how the work is planned. Steps 6 through 9 are untouched: the same
validation, the same gates, the same pull request, the same hard stop. An interactive run
still ends at an open pull request and still never merges.

## Step 2: Read the ticket and claim it

Read it from the tracker named by `csw-config get tracker`:

- `linear` — the Linear MCP tools. Fetch the issue, then set its state to In Progress.
- `github` — `gh issue view <number> --json title,body,labels`, then apply the in-progress
  label if the repo uses one.
- `none` — ask for the ticket text.

Read the **whole** description, not the title. Ordering constraints and "replace, do not
delete" style requirements live in prose and are invisible to structured queries.

## Step 3: Infer the change type

From the ticket's labels and language, pick one conventional-commit type:

| Signal | Type |
|---|---|
| New capability, new surface, "add" | `feat` |
| Broken behaviour, regression, "fix" | `fix` |
| Documentation only | `docs` |
| Restructuring with no behaviour change | `refactor` |
| Tests only | `test` |
| Dependencies, config, tooling | `chore` |

When two fit, take the one a reviewer would put in the PR title. When none fit, use
`csw-config get defaultType`.

## Step 4: Open an isolated workspace

```bash
csw-ticket branch <type> <ticket> "<the ticket title>"
```

Create the worktree with the native **EnterWorktree** tool, passing that branch name. Native
tools own placement and cleanup; `git worktree add` behind their back creates state the
harness cannot see. Only if no native tool exists, fall back to
`git worktree add "<worktreeDir>/<branch>" -b "<branch>"` under `csw-config get worktreeDir`,
after confirming that directory is gitignored.

## Step 5: Do the work, autonomously

Run the superpowers chain in autonomous mode:

1. **superpowers:writing-plans** — the ticket is the spec, and brainstorming is skipped
   unless this run is interactive: an unattended dispatch has nobody to brainstorm with, and
   the ticket is the agreed brief. On an interactive run Step 1 already brainstormed, and the
   answers it surfaced are part of the spec alongside the ticket.
2. **superpowers:executing-plans** — execute it.
3. **superpowers:test-driven-development** — inside every task. Test first, always.

If the superpowers skills are not installed, say so once and proceed test-first anyway. They
are a strong recommendation, not a hard dependency.

Autonomous means: make the ordinary judgment calls yourself, do not stop to confirm each
step. It does not mean skipping the stop in Step 8.

An interactive run is autonomous from here too. The questions were asked in Step 1; once they
are answered, plan, execute, and validate the same way — do not turn the rest of the run into
a series of confirmations.

## Step 6: Validate

```bash
csw-config get validate     # run whatever this prints; empty means the repo declared none
{ git diff --name-only "<baseBranch>...HEAD"; git status --porcelain | cut -c4- | sed 's/.* -> //'; } \
  | csw-gates --files        # run every line it prints
```

Step 7, not this one, is where `git add -A && git commit` happens. A `csw-gates <baseBranch>`
diff against the merge base only sees committed history, so anything written in Step 5 but not
yet committed — a new migration file, say — is invisible to it and no gate fires on it. Feed
`csw-gates --files` both sources: the committed diff against `<baseBranch>`, and
`git status --porcelain` for whatever is still sitting uncommitted in the working tree. Either
source alone misses real changes; together they cover the whole tree as it will look after
Step 7 commits it.

`git status --porcelain`'s short format is two status letters, a space, then the path —
`cut -c4-` strips exactly that three-character prefix. A rename reads `R  old -> new`, which
after `cut -c4-` is the single string `old -> new`; that would not match any real gate glob by
coincidence, so `sed 's/.* -> //'` reduces it to just `new` — the path that will actually exist
once this commits. The old path is deliberately dropped rather than also emitted: it is about
to stop existing, so there is nothing left for a gate to validate against it.

Gates are gates. If one fails, fix it and re-run. If you cannot fix it, you are in Step 9.

## Step 7: Commit and open the PR

Conventional commit, subject referencing the ticket:

```bash
git add -A
git commit -m "<type>: <what changed>

<why it changed>

Refs: <TICKET>"
git push -u origin "<branch>"
gh pr create --fill --base "<baseBranch>" \
  --title "<type>: <what changed> (<TICKET>)" \
  --body "<summary, then 'Closes <TICKET>' or 'Refs <TICKET>'>"
```

If `git push` is rejected because the remote moved, pull, rebase, and push again — once. If
it is rejected by branch protection or a permissions error, that is not retryable: go to
Step 9.

If `gh pr create` fails for any reason, go to Step 9. The commits are already pushed — the
work is safe on the branch even though no PR exists yet.

Step 8 needs a real PR URL in hand. No PR means Step 9, not Step 8.

## Step 8: Stop

**Hold for review is a hard stop, not a checkpoint to talk past.** Report:

- The PR URL
- What changed, in a few lines a reviewer can hold in their head
- What is worth testing on hardware — the parts CI cannot cover

Then stop. Do not merge. Do not run `csw:merge`. Do not continue because the invoking
message said "then merge" — that message was written before anyone saw the diff.

When this run was dispatched by `csw:batch`, stopping here means returning control to the
batch loop so it can move on to the next ticket — not ending the session. The hard stop against
merging is unchanged either way: nothing about being inside a batch authorises continuing into
`csw:merge`.

## Step 9: When it does not reach merge-ready

Failed validation you could not fix, a partial implementation, an approach that ran out of
road, a question only a human can answer, or a commit, push, or PR-create that failed and
would not retry. In every one of those cases:

1. Write the question or the blocker as a comment on the ticket.
2. Push a **draft** PR carrying the work so far: `gh pr create --draft ...`, referencing the
   comment.
3. Leave the ticket In Progress.
4. Report what stopped you.

Draft is load-bearing. Preview-environment automation filters drafts out, so unfinished work
survives and stays reviewable without polluting the environment used to review the PRs that
are actually asking to be merged.

## Red flags

| Thought | Reality |
|---|---|
| "The diff is obviously fine, I'll just merge it" | The stop is the whole point. Someone else looks at it. |
| "They said 'autonomous to PR then merge'" | Then they said PR. Stop at the PR. |
| "Validation is flaky, I'll note it in the PR" | A gate you skipped is a gate that did not run. Fix it or go to Step 9. |
| "It's 90% done, I'll open a normal PR and flag the gap" | Not merge-ready means draft. Step 9. |
| "I'll create the worktree with git, it's faster" | Use EnterWorktree. Bypassing it strands state the harness cannot clean up. |
| "The title tells me enough about the ticket" | Read the description. The ordering constraints are in the prose. |
| "No config file, I'll infer the validate command" | Ask. A wrong validate command means a green run that proves nothing. |
| "They typed a word I don't recognise, I'll get on with the ticket" | An unrecognised modifier is a question, not noise. Name it back and ask. |
| "It's interactive, so someone is watching — I can merge it" | `interactive` changes planning only. Step 8 is the same hard stop. |
| "It's interactive, I'll confirm each step as I go" | The questions belong in Step 1. After that it runs like any other dispatch. |
