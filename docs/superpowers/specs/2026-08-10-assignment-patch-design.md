# `gh rba assignment patch` — Design

**Date:** 2026-08-10
**Status:** Approved, ready for implementation planning
**Supersedes:** the "Patching assignments after creation" section of `FUTURE.md`

## Problem

`gh rba assignment create` distributes a template repo to N students as independent
private repos. There is no fork relationship and no shared git history, so GitHub
Classroom's "sync from upstream" mechanism is unavailable.

When the instructor discovers a mistake in an already-distributed assignment — a
broken CI workflow, a wrong path in `devcontainer.json`, a missing test case — the
only remedy today is editing up to 34 repos by hand. This is the single largest
operational risk in using `gh rba` for a full course.

## Goal

Fix the template repo as normal, then push that fix to every student repo with one
command, without destroying student work.

```bash
cd hw01-java-intro-template
vim .github/workflows/test.yml
git commit -am "fix JUnit jar path"
git push

gh rba assignment patch hw01
```

## Key insight: the baseline is free

A repo created via `gh repo create --template` gets a **fresh squashed root commit**
containing the template's content at creation time. It shares no commit SHAs with the
template.

Verified empirically against `202520-EENG-340` on 2026-08-10:
`202520-eeng-340-lab-1-curve-tracer-lab1-template` reports
`template_repository: 202520-EENG-340/lab1-template` and `fork: false`, and its root
commit `09885ef1` returns HTTP 422 from
`repos/202520-EENG-340/lab1-template/commits/09885ef1` — the SHA does not exist in the
template.

Therefore, **each student repo's own root commit is the distribution snapshot**. That
gives a three-way merge for free:

| Merge input | Source |
|---|---|
| base | the student repo's root commit |
| ours | the student repo's current default branch |
| theirs | the template repo's current default branch |

No state file, no tags, no record of "which template commit did I distribute." Nothing
to keep in sync and nothing to lose when switching machines.

Although base and ours/theirs come from unrelated histories, git resolves the merge
correctly because **blobs are content-addressed**: unchanged files at distribution time
have identical blob SHAs in both repos, so the base tree's objects are present once both
remotes are fetched into a shared object store.

## Why no path filtering

Per the README and the CSCI-350 plan §4e, **each assignment has its own template repo**
(`lab1-template`, `hw01-java-intro-template`). After distribution, any change to that
template is by definition a correction intended for students. "Sync everything since
distribution" is the complete feature. A `--path` filter would add a flag, a code path,
and a way to be wrong, for no scenario that arises.

Cross-term reuse is not a counterexample: orgs are per-term (`202610-CSCI-350`), so each
term's templates are separate repos, and the assignment is over before next term's edits
begin.

## Command surface

```
gh rba assignment patch <assignment-name> [--org <org>] [--template <org/repo>]
                                          [--message <msg>] [--dry-run] [--yes]
```

| Flag | Default | Meaning |
|---|---|---|
| `--org` | from `.rba` | Course org, consistent with every other command |
| `--template` | `<org>/<assignment-name>-template` | Source of the fix |
| `--message` | `Instructor patch: sync from template` | Commit message on student repos |
| `--dry-run` | off | Run every merge, print outcomes, push nothing |
| `--yes` | off | Skip the confirmation prompt |

The `--template` default follows the existing `lab1-template` convention. When it is
wrong, the command fails with a clear message naming the repo it looked for.

## Algorithm

### Setup (once per invocation)

1. `load_config`; resolve `org` via `require_org`.
2. Resolve the template repo; `die` if it does not exist or is inaccessible.
3. Read the template's `default_branch` from the API.
4. Discover student repos with the existing topic search:
   `search/repositories?q=topic:rba-assignment-<name>+org:<org>&per_page=100`.
   `die` if zero results. This reuses the discovery mechanism of `repos clone` and
   `repos report`, so `patch` operates on exactly the set `create` produced.
5. Create one scratch **bare** repo in `mktemp -d`, registered for cleanup on exit
   via `trap`.
6. Fetch the template **once** into `refs/rba/template`. All 34 merges then share one
   object store, so template blobs transfer a single time.

### Per student repo

```bash
git fetch -q --no-tags "$student_url" "+refs/heads/$branch:refs/rba/student"

# Exactly one root commit is expected. More than one means the student merged in
# unrelated history; the correct base is then ambiguous, so skip rather than guess.
mapfile -t roots < <(git rev-list --max-parents=0 refs/rba/student)
(( ${#roots[@]} == 1 )) || { outcome=skipped; reason="multiple root commits"; continue; }
BASE="${roots[0]}"

TREE=$(git merge-tree --write-tree --name-only \
         --merge-base="$BASE" refs/rba/student refs/rba/template)
# exit 0 → clean;  exit 1 → conflict;  exit >1 → error

# no-op check
[[ "$TREE" == "$(git rev-parse refs/rba/student^{tree})" ]] && outcome=uptodate

NEW=$(git commit-tree "$TREE" -p refs/rba/student -m "$MESSAGE")
git push -q "$student_url" "$NEW:refs/heads/$branch"
```

`git merge-tree --write-tree` prints the resulting tree OID on the first line. On
conflict it exits 1 and the following section lists conflicted paths; `--name-only`
reduces that section to bare filenames for the report.

The student repo's own `default_branch` is used, read per-repo from the search results,
not assumed to match the template's.

No working tree is ever checked out. Requires **git ≥ 2.38** for
`merge-tree --write-tree --merge-base`; the tool should check `git --version` at startup
and `die` with a clear message below that.

### Outcomes

Exactly one per repo:

| Outcome | Condition | Action |
|---|---|---|
| **applied** | merge clean, tree differs from student's | commit + push |
| **already up to date** | merge clean, tree identical | nothing — no empty commit, no push |
| **conflict** | `merge-tree` exit 1 | repo left completely untouched, paths recorded |
| **skipped** | repo empty, or >1 root commit | left untouched, reason recorded |

A repo is either fully patched or entirely untouched. There is no partial application.

## Remote URLs and authentication

Push and fetch use raw git, not `gh`, so the URL must match the user's configured
protocol. Resolve it as `gh` itself does:

```bash
proto=$(gh config get -h github.com git_protocol 2>/dev/null || gh config get git_protocol)
```

Host-scoped configuration wins over global — on this machine the global value is `https`
while `github.com` is `ssh`, so reading only the global value would produce URLs that
fail to authenticate. Select `.ssh_url` when the resolved protocol is `ssh`, otherwise
`.clone_url` (which works with the `osxkeychain` credential helper `gh` installs).

## Safety

`patch` is the first `gh rba` command that mutates existing student work, so it carries
guardrails the additive commands do not need.

- **`--dry-run`** performs every fetch and merge and prints the full outcome table
  without pushing. Conflict detection is real, not predicted.
- **Confirmation prompt** before the first push, stating the repo count, the template,
  and the org. `--yes` bypasses it for scripted use. Non-interactive shells without
  `--yes` abort rather than assume consent.
- **Idempotent.** Because the base is always the root commit, re-running re-merges
  cleanly and reports "already up to date." An interrupted run is safe to resume, and
  running twice is harmless.
- **Conflicts are never forced.** No `--force` flag exists. The escape hatch for the
  one or two repos that conflict is to fix them by hand.
- **Never rewrites history.** Every change is a new commit on top of the student's
  existing branch, so their work remains reachable and their local clone fast-forwards.

## Output

```
→ Patching 'hw01' in org '202610-CSCI-350' from '202610-CSCI-350/hw01-java-intro-template'

  ✓ mjones99      applied
  ✓ alee2026      applied
  ─ jsmith42      already up to date
  ⚠ kpatel7       CONFLICT (skipped)

32 applied, 1 up to date, 1 conflict

Needs manual attention:
  kpatel7  src/Tokenizer.java
```

Exit non-zero when any repo conflicts or is skipped, so the command is usable in a
script that must notice partial success. This applies to `--dry-run` too: a dry run that
detects a conflict exits non-zero, which is what makes it useful as a pre-flight check.
Conflicted repos are listed with their conflicting paths, since that is the information
needed to go fix them.

Because the outcome table is the only record of what happened, it prints to stdout as
work proceeds rather than being buffered to the end — a run interrupted partway still
shows which repos were already pushed.

## Testing

The merge logic is the risky part and it is pure git, so it is testable locally with no
GitHub involvement. Build fixtures in a temp dir: a "template" repo, and an
"instantiated" repo whose root commit is a squashed copy of the template at that point,
reproducing the real topology.

Cases:

1. **Clean apply** — template changes a file the student never touched → applied, tree
   contains both the student's work and the fix.
2. **No-op** — template unchanged since distribution → already up to date, no commit
   created.
3. **Conflict** — student and template edit the same lines → exit 1, student repo
   untouched, path reported.
4. **Disjoint edits, same file** — student edits the bottom of a file, template edits the
   top → applied, both changes present. This is the case that distinguishes a real
   three-way merge from an overwrite, and the main reason for choosing `merge-tree`.
5. **Idempotence** — apply case 1 twice → second run reports already up to date.
6. **Empty student repo** — no commits → skipped with a reason, no crash.

Plus one end-to-end run against a throwaway repo in `202610-CSCI-350` before the command
touches any real student work.

## Out of scope

Deliberately excluded; each is a plausible later addition that does not earn its
complexity for a 34-student course:

- `--force` / "template always wins" conflict resolution
- `--path` filtering
- PR-based delivery instead of direct push
- Patching a subset of students
- Pagination beyond 100 repos — a pre-existing limitation of `assignment list`,
  `repos clone`, and `repos report`, tracked separately in `FUTURE.md`

## Implementation notes

- Written in **bash**, consistent with the existing 270-line script and its
  `die`/`info`/`load_config`/`require_org` helpers, and its flag-parsing style.
  `FUTURE.md` names this command as a trigger condition for rewriting the tool in
  Python. That trade was considered and declined for now: the rewrite is a much larger
  change than the feature, and CSCI-350 needs this command before the term starts on
  2026-08-31. Whether this command turns out to be painful in bash is useful evidence
  for that decision later.
- Dispatch: add `patch)` to the existing `assignment` case block.
- Update `usage()` with the new command.
- Remove the "Patching assignments after creation" section from `FUTURE.md` and add
  the command to `README.md` alongside `assignment create`.
