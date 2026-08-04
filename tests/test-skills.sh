#!/usr/bin/env bash
# Every skill must have parseable frontmatter, a description, and must not
# leak project-specific values or contradict the plan's hard rules.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/test-helpers.sh"

SKILLS="$REPO_ROOT/skills"

frontmatter() { sed -n '/^---$/,/^---$/p' "$1" | sed -e '1d' -e '$d'; }
fm_field() { frontmatter "$1" | sed -n "s/^$2: *//p" | head -1; }

# A test file that asserts nothing must never report success: fail loudly if
# skills/ is missing, and fail if it exists but contains zero skill
# directories, rather than letting the loop below iterate zero times and
# report a silent green.
if [ ! -d "$SKILLS" ]; then
  FAILURES=$((FAILURES + 1))
  printf 'FAIL skills/ directory does not exist\n' >&2
fi

skill_count=0
for dir in "$SKILLS"/*/; do
  [ -d "$dir" ] || continue
  skill_count=$((skill_count + 1))
  name=$(basename "$dir")
  file="$dir/SKILL.md"

  if [ -f "$file" ]; then
    PASSES=$((PASSES + 1))
  else
    FAILURES=$((FAILURES + 1))
    printf 'FAIL %s has no SKILL.md\n' "$name" >&2
    continue
  fi

  first_line=$(head -1 "$file")
  delim_count=$(grep -c '^---$' "$file" || true)

  assert_eq "$first_line" "---" "$name: starts with frontmatter"

  # Guard the shape before trusting frontmatter()/fm_field(): with only one
  # "---" line, the sed range runs to EOF and body text reads as frontmatter
  # fields. Require an opening "---" on line 1 and a second "---" to close
  # the block; otherwise record the failure and skip parsing this file's
  # fields rather than reading its body as frontmatter.
  if [ "$first_line" != "---" ] || [ "$delim_count" -lt 2 ]; then
    FAILURES=$((FAILURES + 1))
    printf 'FAIL %s: malformed frontmatter block (no closing ---)\n' "$name" >&2
    continue
  fi

  assert_eq "$(fm_field "$file" name)" "$name" "$name: frontmatter name matches its directory"

  desc=$(fm_field "$file" description)
  if [ -n "$desc" ]; then
    PASSES=$((PASSES + 1))
  else
    FAILURES=$((FAILURES + 1))
    printf 'FAIL %s: empty description\n' "$name" >&2
  fi

  # No Trakrf values may leak out of examples/ and docs/ into the skills.
  # Patterns are narrowed to the actual Trakrf values, not generic English:
  # bare "TRA-" false-positives on words like "extra-careful", and bare
  # "just validate" false-positives on ordinary prose about the config key
  # named "validate" that skills legitimately reference by name. "just
  # backend migrate-checksums" is the real gate command that must never leak.
  for leak in "TRA-[0-9]" "just backend migrate-checksums" "trakrf"; do
    if grep -qiE -- "$leak" "$file"; then
      FAILURES=$((FAILURES + 1))
      printf 'FAIL %s: leaks project-specific value: %s\n' "$name" "$leak" >&2
    else
      PASSES=$((PASSES + 1))
    fi
  done
done

if [ "$skill_count" -eq 0 ]; then
  FAILURES=$((FAILURES + 1))
  printf 'FAIL no skill directories found under skills/\n' >&2
fi

# --- assert_contains vs assert_guards, throughout this file ---
#
# Every assertion here guards a behaviour some skill documents, and its job is to
# go red when that behaviour is removed. A whole-file `assert_contains` only does
# that while its needle occurs *nowhere else in the file*: the moment it also
# appears somewhere the behaviour does not live, a revert leaves the needle
# behind and the assertion stays green while guarding nothing. That is #69.
#
# So the rule in this file is mechanical rather than stylistic: **if the needle
# is not unique to the behaviour's own region, the assertion uses
# `assert_guards`** and names the region it protects. A needle that occurs once
# already has the property — it vanishes with the region — and stays on
# `assert_contains`.
#
# A deliberate consequence: a region is *not* required to be the only place the
# needle appears in the file. Every skill restates its load-bearing rules in
# `## Red flags`, and this file separately asserts those restatements. Requiring
# the needle to be absent outside its region would fail on that convention
# working as intended, and would only be the uniqueness rule under another name.
# Present-inside-the-region is what makes a revert bite; that is the whole
# contract.

# --- work: the hard stop and the tools it must reach for ---
work="$SKILLS/work/SKILL.md"
assert_contains "$(cat "$work")" "csw-ticket normalize" "work: normalises the ticket reference"
assert_contains "$(cat "$work")" "csw-ticket branch" "work: derives the branch name"
assert_guards "$work" '^## Step 6: Validate' '^## Step 7: Commit and open the PR' \
  "csw-gates" "work: runs diff-triggered gates"
assert_guards "$work" '^## Step 4: Open an isolated workspace' '^## Step 5: Do the work' \
  "EnterWorktree" "work: prefers the native worktree tool"
assert_contains "$(cat "$work")" "--draft" "work: knows the draft-PR rule"
assert_contains "$(cat "$work")" "Hold for review is a hard stop" "work: states the hard stop"
assert_contains "$(cat "$work")" "No PR means Step 9, not Step 8" "work: Step 7 failures route to Step 9"
assert_contains "$(cat "$work")" 'csw-gates --worktree "<baseBranch>"' \
  "work: Step 6 gates the working tree, not a bare baseBranch diff"
# The old Step 6 hand-rolled the union out of `git status --porcelain | cut | sed`, which git's
# own quoting, rename format, and untracked-directory collapsing all broke. Deriving the list
# in the shell is the bug; --worktree exists so the skill does not have to.
if grep -q 'git status --porcelain' "$work"; then
  FAILURES=$((FAILURES + 1))
  printf 'FAIL work: Step 6 must not hand-roll the file list out of git status\n' >&2
else
  PASSES=$((PASSES + 1))
fi
assert_contains "$(cat "$work")" "returning control to the" \
  "work: Step 8's hard stop acknowledges being dispatched from csw:batch"
if grep -q "gh pr merge" "$work"; then
  FAILURES=$((FAILURES + 1))
  printf 'FAIL work: must never merge\n' >&2
else
  PASSES=$((PASSES + 1))
fi

# --- work: reading what csw:prep left behind ---
#
# Prep writes its spec and its open questions to a ticket comment. If Step 2 does not go and
# read that comment, prep is a command that produces nothing anyone consumes.
work_step2=$(sed -n '/^## Step 2/,/^## Step 3/p' "$work")
assert_contains "$work_step2" '**CSW prep**' \
  "work: Step 2 looks for the marker csw:prep writes"
assert_contains "$work_step2" "comments" \
  "work: Step 2 reads the ticket's comments, not only its description"
# A question prep asked and a human answered is a settled decision. Re-opening it burns the
# dispatch on a conversation that already happened.
assert_contains "$work_step2" "is a decision" \
  "work: an answered prep question is treated as settled, not re-litigated"
# Unanswered questions are the signal prep exists to produce. Guessing past them is exactly
# the wasted dispatch prep was added to avoid.
assert_contains "$work_step2" "rather than guessing" \
  "work: unanswered prep questions are not guessed past"
assert_contains "$work_step2" "Step 9" \
  "work: unanswered prep questions route to the draft path"
work_red_flags=$(sed -n '/^## Red flags/,$p' "$work")
assert_contains "$work_red_flags" "prep" \
  "work: red flags catch a dispatch that ignores the prep comment"

# --- work: the interactive modifier, and everything it does not change ---

# The word has to be discoverable from the hint, or the only people who type it are the
# ones who already read the skill — and they are not who the ambiguity bit.
assert_contains "$(fm_field "$work" 'argument-hint')" "interactive" \
  "work: the interactive modifier is discoverable from the argument hint"
assert_contains "$(cat "$work")" "superpowers:brainstorming" \
  "work: interactive brainstorms the ticket before planning it"
assert_contains "$(cat "$work")" "wait for the answers" \
  "work: an interactive run waits for answers instead of proceeding unattended"

# Step 5 skips brainstorming because nobody is there to brainstorm with. On an interactive
# run somebody is, so the skip has to be conditional rather than absolute — an unconditional
# "skip brainstorming" in Step 5 silently undoes what Step 1 was asked to do.
assert_contains "$(cat "$work")" "unless this run is interactive" \
  "work: Step 5's skip-brainstorming rule yields to an interactive run"

# Silently discarding a word someone deliberately typed is how a dispatch does something
# other than what was asked. All three of these have to be present: what was passed, that
# it is not recognised, and the question.
assert_contains "$(cat "$work")" "An unrecognised modifier is not ignored" \
  "work: an unrecognised modifier is never silently discarded"
assert_contains "$(cat "$work")" "say it is not recognised" \
  "work: an unrecognised modifier is named back and called unrecognised"

# interactive changes how the work is planned and nothing else. If it were read as
# "a human is watching, so the usual rules are softer", it would erode the one guarantee
# every other step in this skill exists to hold.
assert_contains "$(cat "$work")" "changes only how the work is planned" \
  "work: interactive leaves validation, gates and the PR untouched"
assert_contains "$(cat "$work")" "still ends at an open pull request and still never merges" \
  "work: an interactive run stops at Step 8 like any other"

# Red flags are where an agent looks when it is about to rationalise, so both failure
# modes have to be answered there too, not only in the step prose.
work_red_flags=$(sed -n '/^## Red flags/,$p' "$work")
assert_contains "$work_red_flags" "modifier" \
  "work: red flags catch a modifier being waved through"
assert_contains "$work_red_flags" "interactive" \
  "work: red flags deny that interactive relaxes the hard stop"

# --- prep: specs a ticket, touches nothing ---
prep="$SKILLS/prep/SKILL.md"
assert_contains "$(cat "$prep")" "csw-ticket normalize" "prep: normalises the ticket reference"
assert_contains "$(cat "$prep")" "superpowers:brainstorming" "prep: brainstorms the ticket"
# Brainstorming's default mode designs the implementation. Prep wants the questions instead —
# the design belongs to the dispatch that has a worktree to try it in.
assert_guards "$prep" '^## Step 3: Brainstorm it' '^## Step 4: Triage' \
  "surface-the-questions" \
  "prep: brainstorms for the questions rather than for a design"

# The marker is the whole interface between prep and the dispatch that reads it back. If it
# drifts, prep still writes a comment and csw:work still finds nothing. Scoped to Step 6,
# which is the step that writes it — Step 2's mention is prep *reading back* an earlier
# comment, and would keep this green with the writing side gone.
assert_guards "$prep" '^## Step 6: Write one comment' '^## Step 7: Stop' \
  '**CSW prep**' "prep: writes the stable marker"
assert_guards "$prep" '^## Step 6: Write one comment' '^## Step 7: Stop' \
  "One comment" "prep: leaves exactly one comment, not a thread"

# The three things the comment has to carry. A comment with only a spec is a summary of the
# ticket, which the ticket already is. Scoped to Step 6 for the same reason: Step 3 tells prep
# to *find* contradictions, Step 6 is what puts them in the comment.
assert_contains "$(cat "$prep")" "open questions" "prep: the comment carries the open questions"
assert_guards "$prep" '^## Step 6: Write one comment' '^## Step 7: Stop' \
  "the codebase contradicts" \
  "prep: the comment carries what the ticket asserts and the code denies"

# Zero side effects is the property that makes prep free to run before anything is decided,
# and it is enumerated rather than implied for the same reason batch's dry run enumerates it.
assert_contains "$(cat "$prep")" \
  "No worktree, no branch, no pull request, no validation run" \
  "prep: its no-side-effects property is enumerated, not implied"
# Todo is self-selecting for the batch loop. Claiming the ticket the way csw:work does would
# quietly remove every prepped ticket from the column prep exists to improve.
assert_contains "$(cat "$prep")" "stays in Todo" \
  "prep: leaves the ticket in Todo so the batch loop still picks it up"
assert_contains "$(cat "$prep")" "Do not claim it" \
  "prep: says not to claim the ticket, since reading it is where csw:work claims it"

# Prose has to be able to *name* the things prep must not do, so these match runnable
# invocations at the start of a line rather than any mention of the word.
prep_writes=$(grep -nE '^[[:space:]]*(gh pr create|gh pr merge|git worktree|git commit|git push|git checkout|git switch|git branch)' "$prep" || true)
assert_eq "$prep_writes" "" "prep: contains no runnable command that touches the repo"
prep_flags=$(fm_field "$prep" 'argument-hint')
assert_contains "$prep_flags" "ticket" "prep: takes a ticket reference"
prep_red_flags=$(sed -n '/^## Red flags/,$p' "$prep")
assert_contains "$prep_red_flags" "worktree" \
  "prep: red flags catch a prep run that starts doing the work"

# --- merge: never squash, always check CI, always chain into cleanup ---
merge="$SKILLS/merge/SKILL.md"
assert_guards "$merge" '^## Step 3: Check CI' '^## Step 4: Merge' \
  "gh pr checks" "merge: checks CI"
assert_guards "$merge" '^## Step 4: Merge' '^## Step 5: Chain into cleanup' \
  "gh pr merge" "merge: merges the PR"
assert_contains "$(cat "$merge")" "--merge --delete-branch" "merge: merge commit, delete the branch (local and remote)"
assert_contains "$(cat "$merge")" "csw:cleanup" "merge: chains into cleanup"
assert_contains "$(cat "$merge")" "gh pr view <number> --json state,mergedAt" \
  "merge: re-establishes ground truth on a non-zero gh pr merge exit instead of assuming it failed"
assert_contains "$(cat "$merge")" "git for-each-ref --merged" \
  "merge: cites the mechanism cleanup actually uses to find stale branches"
# The skill may *mention* --squash to forbid it; it must never *use* it.
bad_flags=$(grep "gh pr merge" "$merge" | grep -E -- "--squash|--rebase" || true)
assert_eq "$bad_flags" "" "merge: no gh pr merge line uses --squash or --rebase"
assert_eq "$(fm_field "$merge" 'disable-model-invocation')" "" "merge: stays model-invocable"
assert_contains "$(cat "$merge")" "only ever entered after a confirmed merge" "merge: cleanup gated on a confirmed merge"
assert_contains "$(cat "$merge")" "BLOCKED" "merge: covers mergeStateStatus BLOCKED"

# --- cleanup: sweeps unprompted, asks only about the tracker ---
cleanup="$SKILLS/cleanup/SKILL.md"
assert_guards "$cleanup" '^## Step 4: Sweep for everything else' \
  '^### The branch you are standing on' \
  "csw-sweep" "cleanup: runs the sweep"
assert_guards "$cleanup" '^## Step 2: Leave the worktree' '^### When ExitWorktree warns' \
  "ExitWorktree" "cleanup: prefers the native worktree exit"
# The removal itself belongs to Step 3's manual bullet: on the ExitWorktree path the tool has
# already done it, and every other occurrence in this file is prose *about* the command.
assert_guards "$cleanup" '^- \*\*Step 2 fell back to the manual' \
  '^If `git branch -d` refuses' \
  "git worktree remove" "cleanup: removes the worktree"
assert_guards "$cleanup" '^## Step 3: Remove this worktree and branch' \
  '^## Step 4: Sweep for everything else' \
  "git worktree prune" "cleanup: prunes stale registrations"
# The pull must bind both paths, not just the manual fallback — an ExitWorktree cleanup
# that skips it leaves the local base branch behind the merge it just landed.
assert_contains "$(cat "$cleanup")" "on either path" "cleanup: pulls the base branch on both paths"
assert_contains "$(cat "$cleanup")" "not only for the manual path" "cleanup: says the pull is not optional"
assert_contains "$(cat "$cleanup")" "Always ask before closing" "cleanup: never closes a ticket unasked"
# csw-sweep's `[gone]` arm reads `%(upstream:track)`, which only says `[gone]` once the
# remote-tracking ref is missing locally — and a plain `git pull` does not prune, so a branch
# deleted on the forge stays invisible to it. The sweep cannot fix this itself (it must never
# fetch), so the prune has to happen here, before Step 4 runs.
bare_pull=$(grep -nE '^[[:space:]]*git pull([[:space:]]|$)' "$cleanup" | grep -v -- '--prune' || true)
assert_eq "$bare_pull" "" \
  "cleanup: every runnable git pull prunes, so the sweep's [gone] arm reads fresh state"
assert_contains "$(cat "$cleanup")" "only a prune" \
  "cleanup: says why the prune is load-bearing, not cosmetic"
assert_guards "$cleanup" '^## Step 5: The tracker, last' '^## Red flags' \
  "sibling" "cleanup: checks for sibling PRs in other repos"
# The sibling search must be scoped to this repo's owner. Unscoped, `gh search prs` runs
# across all of GitHub, and with `tracker: github` the ticket is a bare number — searching
# for 81 returned 30 strangers' PRs and not one sibling.
assert_contains "$(cat "$cleanup")" "gh repo view --json owner" \
  "cleanup: derives the owner to scope the sibling search to"
# Matched at the start of a line so the skill can still *name* the unscoped form in prose to
# warn against it; what must not exist is a runnable invocation missing --owner.
unscoped=$(grep -E '^[[:space:]]*gh search prs' "$cleanup" | grep -v -- '--owner' || true)
assert_eq "$unscoped" "" "cleanup: no sibling search runs unscoped across all of GitHub"
# A numeric ticket is a weak query even when scoped, and a long result set means the query
# was too broad — not that there are many siblings.
assert_contains "$(cat "$cleanup")" "--match title,body" \
  "cleanup: offers a more precise query than a bare number for github tickets"
assert_contains "$(cat "$cleanup")" "A long result list is a symptom" \
  "cleanup: says a long result set means a bad query, not many siblings"
assert_contains "$(cat "$cleanup")" "never require a separate instruction" "cleanup: branch cleanup is unconditional"
assert_contains "$(cat "$cleanup")" "gh pr view --json state,mergedAt" "cleanup: verifies the PR is merged before removing anything"
assert_contains "$(cat "$cleanup")" "unknown, not absent" "cleanup: a failed sweep is reported distinctly from an empty one"
assert_contains "$(cat "$cleanup")" "the command failing for any reason" "cleanup: any gh pr view failure is a stop, not just a non-merged state"
# Scoped to the ExitWorktree bullet itself, not to the whole file and not to Step 3. The
# needle this replaces was `already gone` against the whole file, which also matched Step 3's
# unrelated "The remote branch is already gone…" sentence — so the assertion passed with the
# fix reverted and guarded nothing (#69). Section granularity does not fix it either: that
# sentence is inside Step 3's own section. The region has to be the bullet.
assert_guards "$cleanup" \
  '^- \*\*Step 2 used the native ExitWorktree tool\.\*\*' \
  '^- \*\*Step 2 fell back to the manual' \
  'that is "already gone," which is success' \
  "cleanup: Step 3 treats a worktree ExitWorktree already removed as success, not failure"
# The sweep now reports a merged branch even when it is checked out, which
# `git branch -d` refuses. Cleanup has to know to land on the base first.
assert_contains "$(cat "$cleanup")" "The branch you are standing on" \
  "cleanup: handles a swept branch that is the current branch"
assert_contains "$(cat "$cleanup")" "refuses the checked-out branch" \
  "cleanup: names why the current branch needs landing first, not -D"
# Cleanup exists to leave a clean checkout behind for the next session.
assert_contains "$(cat "$cleanup")" "End on the base branch" \
  "cleanup: states its end state explicitly"
assert_contains "$(cat "$cleanup")" "git branch --show-current      # must be" \
  "cleanup: verifies where it landed rather than assuming"
# ExitWorktree's "will discard N commits" warning fires on essentially every cleanup,
# because cleanup always runs right after a forge-side merge. It must be proven false
# against the remote, never waved through and never stalled on.
assert_guards "$cleanup" '^### When ExitWorktree warns it will discard commits' \
  '^### Land on the base branch' \
  "git merge-base --is-ancestor" \
  "cleanup: proves the discard warning false against the remote instead of trusting it"
assert_contains "$(cat "$cleanup")" "Non-zero means the warning is real" \
  "cleanup: a non-zero merge-base check stops the cleanup"
assert_guards "$cleanup" '^### When ExitWorktree warns it will discard commits' \
  '^### Land on the base branch' \
  "discard_changes: true" \
  "cleanup: names the flag that must never be passed unverified"
# Narrower than the subsection: this is the "not the branch rename" bullet specifically, which
# is the claim being guarded. The Red-flags row restating it is asserted separately below.
assert_guards "$cleanup" '^- \*\*Not the branch rename\.\*\*' \
  '^- \*\*Not a reason to skip Step 1\.\*\*' \
  "display only" \
  "cleanup: says the stale branch name in the warning is cosmetic, not a reason to dismiss the count"
# Red flags are where an agent looks when it is about to rationalise. The verification
# rule has to appear there too, not only in the step prose.
red_flags=$(sed -n '/^## Red flags/,$p' "$cleanup")
assert_contains "$red_flags" "merge-base" \
  "cleanup: red flags forbid waving the discard warning through"
assert_contains "$red_flags" "--owner" \
  "cleanup: red flags catch the unscoped sibling search"
# Measured in the cleanup for #82: local base was moved *ahead* of the branch head before the
# exit and the warning still fired, so the comparison is against the worktree's creation point.
# Saying so is what stops the next reader re-running the same disproved experiment.
assert_contains "$(cat "$cleanup")" "creation point" \
  "cleanup: names what the discard warning actually compares against"
assert_contains "$(cat "$cleanup")" "cannot be suppressed" \
  "cleanup: says the warning is unavoidable, so verification is the only defence"

# --- batch: never auto-invoked, always explains its skips ---
batch="$SKILLS/batch/SKILL.md"
assert_eq "$(fm_field "$batch" 'disable-model-invocation')" "true" "batch: never model-invoked"
assert_guards "$batch" '^## Step 2: Select' '^## Step 3: If this is a dry run' \
  "csw-batch-filter" "batch: delegates selection"
assert_guards "$batch" '^## Step 5: Dispatch each to a fresh subagent' \
  '^## Step 6: When a ticket blocks or fails' \
  "csw:work" "batch: dispatches through the work skill"
assert_contains "$(cat "$batch")" "--draft" "batch: blocked work becomes a draft PR"
assert_contains "$(cat "$batch")" "Morning summary" "batch: reports a morning summary"
# Case-insensitive: the prerequisite reads naturally as a sentence-initial "Backfill", and a
# case-sensitive check here is exactly the kind of assertion that breaks the day someone
# "corrects" the capitalisation back to what reads naturally in prose.
if grep -qi "backfill" "$batch"; then
  PASSES=$((PASSES + 1))
else
  FAILURES=$((FAILURES + 1))
  printf 'FAIL batch: warns about the blocking-relation prerequisite\n' >&2
fi
# csw:work now takes an `interactive` modifier, which brainstorms and waits for answers.
# A batch runs overnight with nobody to answer, so the dispatch has to say the reference
# goes over on its own.
assert_contains "$(cat "$batch")" "the ticket reference and nothing else" \
  "batch: dispatches csw:work with no modifier, so no ticket can stop for answers"
# Prep improves a dispatch but must not become a gate on one: a loop that skipped unprepped
# tickets would turn an optional command into a required step for every ticket in the column.
assert_contains "$(cat "$batch")" "Prepped tickets dispatch better" \
  "batch: names prep as the thing that makes a dispatch land better"
assert_contains "$(cat "$batch")" "does not skip unprepped" \
  "batch: prep is a recommendation, never a filter"
assert_contains "$(cat "$batch")" "A failed selection is never an empty selection" \
  "batch: a filter failure is reported distinctly from an empty batch"

# --- batch: one fresh subagent per ticket ---
#
# The loop used to run every csw:work dispatch in the controlling session, so ticket two
# inherited ticket one's plan, its diff and its dead ends. Worktrees were isolated; the mind
# driving them was not. Each ticket now gets a subagent, which is the programmatic equivalent
# of clearing context between dispatches.
assert_guards "$batch" '^## Step 5: Dispatch each to a fresh subagent' \
  '^## Step 6: When a ticket blocks or fails' \
  "fresh subagent" \
  "batch: each ticket is dispatched to a subagent of its own"
assert_contains "$(cat "$batch")" "Never run \`csw:work\` in this session" \
  "batch: the controlling session never does a ticket's work itself"
# A fork inherits the whole parent conversation, which is precisely the flaw being fixed —
# it would look like a subagent and contaminate exactly as badly.
assert_contains "$(cat "$batch")" "Not a fork" \
  "batch: says why a fork is not the isolation being asked for"
# csw:work Step 4 creates the worktree on a branch csw-ticket derives from the ticket. A
# subagent handed worktree isolation is already in one and cannot create that branch.
assert_contains "$(cat "$batch")" "no worktree isolation" \
  "batch: the dispatch leaves the worktree to csw:work rather than pre-isolating the subagent"
assert_contains "$(cat "$batch")" "creates the worktree itself" \
  "batch: names which step owns the worktree, so the dispatch does not duplicate it"
# The controller assembles the morning summary out of returned rows. If a subagent hands back
# prose, the summary is reconstructed from a transcript again — the thing this change removes.
assert_contains "$(cat "$batch")" "report contract" \
  "batch: each subagent returns a structured result, not a narrative"
assert_contains "$(cat "$batch")" "one row in the summary, not the end of the night" \
  "batch: one failed ticket does not stop the loop"
# Skill reachability is the one thing that makes this dispatch shape work at all: csw:work
# sets no disable-model-invocation, so a subagent can invoke it through the Skill tool.
# Matched on the sentence rather than the bare field name, which batch's own frontmatter
# already carries and which would therefore pass without the explanation being written.
assert_contains "$(cat "$batch")" "sets no \`disable-model-invocation\`" \
  "batch: records why csw:work is reachable from inside a subagent"
# The summary is now assembled from the rows Step 5 collected, not recovered from the night's
# transcript. Saying so in Step 7 is what stops the controller reaching for a transcript it
# deliberately no longer has.
batch_summary=$(sed -n '/^## Step 7/,/^## Red flags/p' "$batch")
assert_contains "$batch_summary" "rows Step 5 collected" \
  "batch: the morning summary is assembled from returned rows, not from a transcript"
batch_red_flags=$(sed -n '/^## Red flags/,$p' "$batch")
assert_contains "$batch_red_flags" "subagent" \
  "batch: red flags catch a dispatch run in the controlling session"
assert_contains "$(cat "$batch")" "can only lower tonight's cap, never raise it" \
  "batch: the cap override is documented as lower-only"
assert_guards "$batch" '^## Step 2: Select' '^## Step 3: If this is a dry run' \
  "csw-config get batch.maxTickets" \
  "batch: reads the configured cap before evaluating an override"

# --- batch: the filter's three-key output, and the dry run that reads it ---

# The skill has to name belowCap, because it is the group whose whole reason for existing
# is that a reader can tell it apart from skipped. Prose that only mentions two groups
# teaches the old shape back.
assert_guards "$batch" '^## Step 2: Select' '^## Step 3: If this is a dry run' \
  "belowCap" "batch: names the filter's belowCap group"
assert_contains "$(cat "$batch")" "never blames the cap" \
  "batch: says skipped carries no cap reason"

assert_contains "$(fm_field "$batch" 'argument-hint')" "--dry-run" \
  "batch: the dry-run modifier is discoverable from the argument hint"
assert_contains "$(cat "$batch")" '`dry-run` or `dry run`' \
  "batch: documents the spellings a human will actually type"
assert_contains "$(cat "$batch")" \
  "no dispatch, no worktree, no branch, no pull request, no change to any ticket's state" \
  "batch: a dry run is enumerated as having no side effects"
assert_contains "$(cat "$batch")" "effective cap and where it came from" \
  "batch: a dry run says which cap won, not just its value"
assert_contains "$(cat "$batch")" "A filter failure in a dry run is a failure, not an empty plan" \
  "batch: a dry run cannot launder a failed selection into a quiet night"

# --- batch: trackerCommand, the escape hatch from tracker MCP ---
#
# Step 1 is where the candidates come from, so it is the only step that changes: a non-empty
# trackerCommand replaces the fetch, and its stdout becomes the same variable Step 2 already
# pipes into the filter. Asserted on Step 1's own slice so a stray mention elsewhere in the
# skill cannot pass for the branch actually being written.
batch_step1=$(sed -n '/^## Step 1/,/^## Step 2/p' "$batch")
assert_contains "$batch_step1" "csw-config get trackerCommand" \
  "batch: Step 1 reads trackerCommand rather than assuming the tracker"
assert_contains "$batch_step1" "bash -c" \
  "batch: says how the command string is executed, matching validate and gates[].run"
assert_contains "$batch_step1" "read-only" \
  "batch: trackerCommand runs in a dry run too, so it must not have side effects"
# The whole point of the key is skipping in-context reshaping across ~20 tickets, which is
# where an agent introduces errors. Prose that merely runs the command and then reshapes its
# output has kept the failure mode it was added to remove.
assert_contains "$batch_step1" "is the filter's input" \
  "batch: the command's stdout is used as-is, not reshaped in context"
# `cmd | csw-batch-filter` reports the filter's status, not the command's, so a failing
# command that printed a partial array would read as a selection rather than a failure.
assert_contains "$batch_step1" "exit status before piping" \
  "batch: a non-zero trackerCommand is caught rather than masked by the pipe"
assert_contains "$batch_step1" "does not pre-check the shape" \
  "batch: shape validation stays in csw-batch-filter, which already names the bad field"
assert_contains "$batch_red_flags" "trackerCommand" \
  "batch: a red flag catches empty trackerCommand output read as a quiet night"

# --- prep: recommends by default, asks only what a recommendation cannot settle ---
# Measured over four tickets: prep asked 4-6 questions on each, and every question carrying a
# recommendation was answered by taking the recommendation. Those questions carried no
# information — they were a confirmation step billed to a human on every ticket. So the test
# for asking is mechanical and prep can apply it to itself: can a recommendation be formed?
assert_contains "$(cat "$prep")" '(Recommended)' \
  "prep: forming a recommendation at all is the test for not asking"
assert_contains "$(cat "$prep")" "Question count is a quality signal" \
  "prep: says explicitly that asking fewer is better, against the natural surface-them-all pull"

# The two branches that survive. Branch two is about blast radius rather than confidence, and
# has to name a class of consequence — left vague it reabsorbs everything branch one excluded
# and prep is back to six questions a ticket.
assert_contains "$(cat "$prep")" "No recommendation can be formed" \
  "prep: names the first branch that legitimately asks"
assert_guards "$prep" '^## Step 4: Triage' '^## Step 5: Ask, once' \
  "cannot be walked back by editing a file" \
  "prep: bounds the second branch to a class of consequence, not a feeling of importance"

# The answers have to land in the same comment they were asked in. A decision recorded
# without its reasoning is indistinguishable from a guess, which is the thing prep forbids.
assert_contains "$(cat "$prep")" "## Decisions" \
  "prep: the comment carries the decisions, not only what prep could not settle"
assert_contains "$(cat "$prep")" "the reasoning that made it a decision" \
  "prep: a recorded decision carries the reasoning a human would need to overturn it"
# An absent section is not a signal. "Nothing left open" is, and a dispatch reads it back.
assert_guards "$prep" '^## Step 6: Write one comment' '^## Step 7: Stop' \
  "_None._" \
  "prep: an empty open-questions section says so rather than disappearing"

# Prep is run with the person who can answer sitting there — that is the design centre, not a
# variant of it. Framed the other way round the skill defers every surviving question to a
# comment someone reads tomorrow, which is the day of latency prep exists to remove.
assert_contains "$(cat "$prep")" "Prep is an interactive command" \
  "prep: the run with a human present is the norm, not the exception"
# The two-end-states contract is stated in the preamble, which is also where the assertion
# above it looks. Elsewhere in the file "dispatchable" is prose leaning on that contract.
assert_guards "$prep" '^\*\*Prep is an interactive command\*\*' '^## Step 0' \
  "dispatchable" \
  "prep: names the state a run has to leave the ticket in"

# Recommending to a human who can reject it needs a human. Without one — a subagent, a column
# of tickets prepped in one pass — the questions that survive triage stay open.
assert_contains "$(cat "$prep")" "AskUserQuestion" \
  "prep: puts the surviving questions to the human who is actually sitting there"
assert_contains "$(cat "$prep")" "nobody is there to answer" \
  "prep: falls back to leaving questions open when there is no human in the room"
# Several prep sessions at once is the interactive path, not the fallback — the human is in
# every one of them. The only thing that actually collides is two sessions on one ticket,
# which races two markers into a thread whose supersede rule assumes one writer.
assert_contains "$(cat "$prep")" "One ticket per session" \
  "prep: parallel sessions are safe per ticket, and the collision is naming the same ticket twice"

# Both directions have to be answered where an agent looks when it is about to rationalise.
assert_contains "$prep_red_flags" "nobody watching" \
  "prep: red flags keep the ban on guessing, bounded to the unattended case"
assert_contains "$prep_red_flags" "so I'll ask" \
  "prep: red flags catch the reverse failure, asking rather than recommending"

report
