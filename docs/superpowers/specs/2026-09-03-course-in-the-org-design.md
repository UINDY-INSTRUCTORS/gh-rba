# The course lives in the org — Design

**Date:** 2026-09-03
**Status:** Phase 1 implemented (v0.3.0). Decisions 1 and 2 settled: stay in
bash; `workshop-codespaces` is kept as a backup rather than archived.
**Supersedes:** `workshop-codespaces/create-workshop-repos.sh`, which this folds
into `gh rba`.

## Problem

Everything `gh rba` needs beyond an org name currently lives in **whatever local
directory the operator happens to be standing in**: rosters, per-course
defaults, and a wrapper script that validates before creating. Two consequences,
and the first one bit on 2026-09-03.

**1. The roster forked silently across machines.** The CSCI-350 roster was
maintained and committed on aluminum while an identical one was independently
rebuilt on intelmini from the `smoke-*` repos and left **untracked**. Same 36
usernames, two files, no relationship between them. The fan-out ran against the
untracked copy.

The precise defect is worth stating, because it determines the fix: the problem
was not that a local file existed. It was that **the local file had no
upstream**. An untracked file can diverge with nothing to report it. A checkout
of a repo cannot — `git status` and `git pull` both say so.

**2. The guards live in a wrapper, so they are optional.** The four checks in
`create-workshop-repos.sh` — every username resolves, the template is really
marked as a template, the template's last push is reported, and a per-repo
summary of who still owes an invitation — caught a renamed account, a
deleted-and-replaced account, and a transient API failure misreported as a
missing user, all on 2026-09-03. Anyone invoking `gh rba assignment create`
directly skips all four.

## Goal

**The semester's org owns the semester's data.** The tool ships with no course
data in it, and the directory you are standing in determines which course you
are operating on.

## Model

Each course, each term, is a fresh org, and the org holds everything:

```
202610-CSCI-350/                     ← the org IS the semester
  course/                            ← ONE private repo: this term's details
      course.env                     org + naming defaults  (committed)
      roster.txt                     usernames (+ optional ,Full Name)
      teams.txt                      optional, for --teams
      RUNBOOK.md                     term-specific operational notes
  act01-lexer-template/              templates
  hw01-lexer-template/
  act01-16micky/  act01-…/           student repos
  hw01-…/
```

Working on a course is then:

```bash
# clone it AS the term directory, so projs/ and repos/ sit inside it
git clone git@github.com:202610-CSCI-350/course.git \
  ~/Development/courses/csci/csci-350/202610
cd ~/Development/courses/csci/csci-350/202610
gh rba assignment create --name hw01
```

### The working directory is the course

`gh rba` already resolves its config relative to the current working directory
(`CONFIG_FILE`, sourced by `load_config`). That was previously unused — no
`.rba` file exists anywhere on this machine, and every invocation to date passed
`--org` explicitly — but the mechanism works, verified 2026-09-03:

```
$ printf 'ORG=202610-CSCI-350\n' > .rba && gh rba assignment list
→ Assignments in org '202610-CSCI-350':
act01
hw01
smoke
```

So CWD-scoping is not a flaw to design around; it is the feature. Same pattern
as git itself: the directory tells the tool what you are working on. **`cd` into
the course, and every command is scoped to that course.**

This is also why the tool needs no new machinery to read the roster over the
API. The `course` repo is an ordinary repo; clone it and `gh rba` reads
its files exactly as it reads local files today. The discipline is entirely in
*where those files live* — and a clone, unlike an untracked file, has an
upstream.

### Naming: the repo is `course`; the file is `course.env`

The repo is **`course`** — short, true, and it sorts away from the
`act01-*`/`hw01-*` crowd in the org's repo list. Created 2026-09-03 in both
live orgs. (`course-admin` was the first proposal; `course` reads better once
the clone *becomes* the term directory.)


The config file is **`course.env`** — the name already in use in
`workshop-codespaces`, moved as-is.

⚠️ **Not `.env`.** `.env` is the universal convention for *secrets*: four of the
five repos on this machine gitignore it, one holds a real 1 KB secrets file, and
the standing rule for this account is that a `.gitignore` must cover `.env` and
`.env.*`. A committed config file named `.env` would be ignored by reflex, by
template and by tooling, and the repo would ship without the file that
makes it work — silently. The header written into both repos says exactly why
the two names
must stay distinct:

> ⚠️ This file IS committed. Org and repo names only — never put a token or
> any other secret here. Secrets belong in `.env`, which is gitignored.

Not `.rba` either: it reads as tool-internal rather than as course
configuration, and `course.env` needs no migration. `.rba` is still read as a
fallback in v0.3.0, and no file of that name is known to exist anywhere.

⚠️ **Not `.github`** for the repo itself. That repo has org-level semantics and
its `profile/README.md` is **public**. A roster is a list of who is enrolled and
must not sit near public-by-default machinery.

⚠️ **`course` must be private.** Students are outside collaborators on
their own repos and cannot see it — but by configuration, not by luck.

## Required change: parse, don't source

✅ **Done in v0.3.0.** `load_config` used to `source "$CONFIG_FILE"`, i.e. shell-execute the
file. Harmless while nothing used it. Once the file is *designed* to be present
and committed to a shared repo, anyone who can write to `course` — a TA,
a compromised account — gets code execution on the instructor's machine via
`ORG=x; curl … | sh`.

Read `KEY=value` explicitly instead, ignoring anything that does not match, and
accept only known keys. This must land in the same change that starts relying
on the file.

## Command surface

### New

```
gh rba course init --org <org> --course CSCI-350 --term 202610
```
Creates the **private** `course` repo and seeds `course.env` with the
header warning above. Idempotent — safe against an org that already has
templates and student repos, which both live orgs already do.

### Changed

```
gh rba assignment create --name act01 [--template …] [--students …]
```
`--template` and `--students` become optional, defaulting from `course.env`
(`<name>-template` and `roster.txt`). The four wrapper guards run
**unconditionally**:

1. every roster username resolves — and a lookup that *fails* is reported as
   "could not check", never as "does not exist". A fan-out is ~70 API calls and
   the secondary rate limiter does fire at that size.
2. the template exists and `isTemplate` is true
3. the template's last push is reported, so a forgotten push is visible
4. a per-repo summary distinguishing `access ok` from `invite pending`

Guard 1 should also report when GitHub answers under a **different login** than
the roster spells — which is how a rename gets caught automatically instead of
by someone noticing a 404.

### Unchanged

`assignment list`, `assignment patch`, `repos clone`, `repos report`.
`init --org` is superseded by `course init` but can stay as an alias.

## Consequences worth accepting deliberately

**One clone per term per machine.** The cost of this approach. Two commands,
and far cheaper than teaching the tool to fetch files over the API.

**Roster edits become commits.** Heavier than editing a file in place. In
exchange the roster gets a history: on 2026-09-03 three names differed from what
students wrote down — a rename, a replacement account, and a hyphen — and that
knowledge survived only in a chat log.

✅ **`gh-rba`'s own `.gitignore`** now ignores `course.env` as well, so a course
directory used for testing cannot leak into the extension's own history.

## Open decisions

✅ **1. Stay in bash.** Settled 2026-09-04. `course.env` remains `KEY=value`, so
the `FUTURE.md` trigger fires only weakly, and pagination and Windows support
are still unmet.

✅ **2. `workshop-codespaces` stays**, kept as a fallback rather than archived.
Its rosters are now second copies of the ones in each org's `course` repo and
should be marked superseded.

**3. Migration for the two live orgs.** `202610-CSCI-350` and `202610-SWEN-200`
already hold templates and student repos, and their rosters exist in
`workshop-codespaces`. `course init` must import rather than require retyping.

## Phases

- [x] **1. `course.env` + parse-not-source.** — done 2026-09-04, v0.3.0. Rename `CONFIG_FILE`, replace
      `source` with an explicit `KEY=value` reader accepting known keys only,
      keep `.rba` working as a fallback for one release. Tests for both.
- [ ] **2. `course init`.** Creates the private repo, seeds `course.env`,
      imports an existing roster. Idempotent against a populated org.
- [ ] **3. Guards into `assignment create`**, and defaults resolved from
      `course.env`. Retire `create-workshop-repos.sh`.

Per this repo's existing practice, each phase lands with tests in `tests/`.
