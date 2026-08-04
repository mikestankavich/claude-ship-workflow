# Configuration

CSW reads `.claude/csw.json` from the repo you are working in. Every key is optional; the
defaults below apply when the file or the key is absent. From a linked worktree, CSW also
looks in the main worktree's root, so the file works whether or not it is committed.

Inspect what CSW actually sees:

```bash
csw-config json          # the effective config
csw-config get validate  # one value
csw-config path          # which file it read, if any
```

## Keys

| Key | Default | What it does |
|---|---|---|
| `ticketPrefix` | `""` | Prefix added to a bare number, so `/csw:work 1088` becomes `TRA-1088`. Leave empty and bare numbers are rejected as ambiguous. |
| `tracker` | `"none"` | `linear` (via MCP), `github` (via `gh`), or `none` (paste the ticket text). |
| `baseBranch` | `"main"` | What PRs target, what "merged" is measured against, and where cleanup returns to. |
| `defaultType` | `"feat"` | Conventional-commit type used when the ticket gives no signal. |
| `validate` | `""` | The one command that must pass before a PR opens. Empty means the repo declared none, and CSW will say so rather than guess. |
| `worktreeDir` | `".worktrees"` | Where fallback worktrees go. Must be gitignored. Ignored when a native worktree tool is available. |
| `branchPattern` | `"<type>/<ticket>-<slug>"` | Branch name template. Tokens: `<type>`, `<ticket>` (lowercased), `<slug>` (from the title, max 40 chars). |
| `gates` | `[]` | Extra validation triggered by which files changed. See below. |
| `batch.maxTickets` | `3` | Cap on a single `/csw:batch` run. |
| `batch.singleWriterLabels` | `["migration"]` | Labels admitting at most one ticket per batch. |

`csw-config json` prints the full merged object, defaults and all — the table above is a
key-by-key reading of that same output, not a separate description.

## Ticket references

`ticketPrefix` must start with a letter and contain only letters and digits after that
(`TRA`, `ENG`, `K8S` are all valid). `csw-ticket` accepts a bare number, a dashed reference
(`tra-1088`, `K8S-42`), or an undashed one when the prefix is pure letters (`tra1088`). An
undashed reference where the prefix itself contains digits (`k8s42`) is genuinely ambiguous
about where the prefix ends and the ticket number begins, so it is rejected rather than
guessed.

### Ticket references and `tracker: github`

`ticketPrefix` exists for trackers whose keys look like `ENG-1088`. GitHub has no such
prefix — issues are numbered per repository, so the number alone already identifies one.

With `"tracker": "github"` and no `ticketPrefix`, a bare number is therefore a valid
reference and normalises to itself, and a leading `#` is accepted and stripped:

```bash
csw-ticket normalize 68     # -> 68
csw-ticket normalize '#68'  # -> 68
csw-ticket branch feat 68 'Add the prep pass'
# -> feat/68-add-the-prep-pass
```

Set `ticketPrefix` alongside `tracker: github` and it still applies, so `68` becomes
`GH-68` if that is what you want.

Every other tracker keeps the strict rule: with no `ticketPrefix`, a bare number does not
identify anything and is rejected with exit 2. That is deliberate — silently guessing which
project a number belongs to is worse than refusing.

## Gates

A gate is a glob and a command. When a changed file matches the glob, the command joins the
validation run:

```json
"gates": [
  { "when": "**/migrations/**", "run": "just backend migrate-checksums" },
  { "when": "web/**.tsx",       "run": "just playwright-preview" }
]
```

Glob semantics:

| Pattern | Matches |
|---|---|
| `**` | Any characters, including `/` |
| `*` | Any characters except `/` |
| `?` | One character except `/` |

Patterns are anchored to the whole path, so `migrations/**` matches `migrations/0042.sql`
but not `backend/migrations/0042.sql`. Use `**/migrations/**` for the nested case.

Watch for the same trap the other way around: `web/**/*.tsx` requires a directory segment
between `web/` and the file, because the `/` between `**` and `*.tsx` is a literal character in
the pattern — it matches `web/nav/Menu.tsx` but **not** `web/Menu.tsx` directly under `web/`.
Drop the middle slash — `web/**.tsx` — to match both, since `**` can absorb the separator itself.

Gates exist for the checks CI cannot or does not run — a checksum regeneration that only
matters when a migration lands, or a browser suite that only runs against a preview
deployment.

Preview the gates a branch triggers:

```bash
csw-gates main              # committed history only
csw-gates --worktree main   # ...plus whatever is still uncommitted
```

`--worktree` is the one to reach for before a commit exists — it unions the committed diff with
the working tree and reports the gates for the tree as it will look once you commit it, so a
migration you have written but not yet added still fires its gate. Uncommitted deletions drop
out, renames and copies count as their destination, and a path containing a literal newline is
a hard error rather than a gate that quietly does not run.

`gates` must be a JSON array of objects, each with both `when` and `run`; anything else
(a non-array, a non-object entry, or an entry missing either key) is a configuration error,
not a gate that is silently skipped.

## Priority ordering

`/csw:batch` sorts by priority. With `tracker: linear`, Linear's own scale applies — `1` is
Urgent through `4` is Low, and `0` (no priority) sorts last. Any other tracker sorts
numerically descending.

## Example

A full config, from the project this workflow grew out of:

```json
{
  "ticketPrefix": "TRA",
  "tracker": "linear",
  "validate": "just validate",
  "worktreeDir": ".claude/worktrees",
  "gates": [
    { "when": "**/migrations/**", "run": "just backend migrate-checksums" }
  ],
  "batch": { "maxTickets": 3, "singleWriterLabels": ["migration"] }
}
```

See [examples/csw.json](../examples/csw.json) for the complete version, and this repo's own
[.claude/csw.json](../.claude/csw.json) for a second, simpler worked example.

## Errors

`csw-config` and the tools built on it fail loudly rather than guess:

| Exit | Meaning |
|---|---|
| `0` | Success. A key explicitly set to `null` prints `null` at exit `0` — that is different from the key being absent. |
| `1` | `csw-sweep` only: the current directory is a bare repository (no working tree), so there is nothing to sweep. |
| `2` | Bad usage: an unknown subcommand, wrong argument count, or an unknown config key. |
| `3` | Not inside a git repository. |
| `4` | The config file is not valid JSON, or is valid JSON that is not a JSON object (an array, a string, a number). |

`csw-gates` reuses exit `4` for a malformed `gates` value: not an array, an entry that is
not an object, or an entry missing `when` or `run`.

`csw-ticket` reuses exit `4` for a broken `ticketPrefix` or `branchPattern` — an invalid prefix,
or a `branchPattern` that has no `<ticket>`/`<slug>` placeholder or renders to something that
is not a legal git branch name. That is a config problem, the same class as the two rows above
it, not a bad invocation of `csw-ticket` itself (which is exit `2`).
