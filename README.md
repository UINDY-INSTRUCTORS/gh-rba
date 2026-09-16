# gh-rba

A `gh` CLI extension for the R.B. Annis School of Engineering. Replaces GitHub Classroom with a lightweight tool for distributing assignment starter code, managing student repos, and collecting work for grading.

## Prerequisites

- [GitHub CLI](https://cli.github.com/) (`gh`) installed and authenticated (`gh auth login`)
- `jq` installed
- A GitHub organization for your course
- Faculty account must be an **Owner** of the organization

## Installation

```bash
gh extension install UINDY-INSTRUCTORS/gh-rba
```

Or to install from a local clone:

```bash
gh extension install /path/to/gh-rba
```

## Concepts

**Organization = Course.** Each course has its own GitHub organization, created by the instructor inside the UIndy enterprise. All student repos for that course live inside it.

**Assignment.** A named set of student repos created from a single template repo. Repos are named `<assignment-name>-<github-username>` and tagged with GitHub topics so the tool can find them later.

**Template repo.** A GitHub repo with "Template repository" enabled (Settings → General → Template repository). When an assignment is created, each student gets a private copy with a clean git history. Templates live alongside student repos in the course org — an org like `202520-EENG-340` might contain several template repos, one per assignment.

**Roster.** A plain-text file listing the GitHub usernames of your students.

**Outside collaborator.** Students are added as outside collaborators with write access on their own repo only — they cannot see each other's work.

## Setup

Create a GitHub org for your course inside the UIndy enterprise (e.g. `202520-EENG-340`).

`gh rba` reads a `course.env` file from the **current working directory**, so the directory you are standing in decides which course you are operating on. The intended arrangement is that the org owns a `course` repo holding `course.env` and the roster, cloned as the term directory:

```bash
git clone git@github.com:202520-EENG-340/course.git ~/courses/eeng/eeng-340/202520
cd ~/courses/eeng/eeng-340/202520
gh rba assignment list          # no --org needed
```

That keeps the roster in the org it describes, with an upstream, rather than in a local file that can quietly diverge between machines.

If you have no such repo, `gh rba init --org <org>` writes a minimal `course.env` where you stand. Any command also accepts `--org <org>` to override.

`course.env` is parsed as plain `KEY=value`, never executed — it is meant to be committed, so it must not be able to run anything. Unknown keys are ignored.

## Roster Format

A plain text file, one GitHub username per line:

```
# roster.txt
jsmith42
mjones99
alee2026
```

Or CSV with an optional full name column:

```
jsmith42,John Smith
mjones99,Mary Jones
alee2026,Alice Lee
```

Blank lines and lines starting with `#` are ignored. The full name is not currently used by any command but is useful for your own records.

## Commands

### `gh rba init`

```
gh rba init --org <org>
```

Writes a minimal `course.env` in the current directory. Refuses if one already exists, since it may hold roster or template settings this command does not know about — edit it instead.

Prefer cloning your org's `course` repo (see Setup); `init` is for when there is not one.

---

### `gh rba assignment create`

```
gh rba assignment create --name <name> --template <org/repo> --students <file> [--org <org>]
```

Creates a private repo for every student in the roster by copying the template, then adds each student as an outside collaborator with write access.

**Options:**

| Flag | Description |
|------|-------------|
| `--name` | Assignment name, e.g. `lab1`. Used as a prefix for all student repo names. |
| `--template` | Full name of the template repo, e.g. `202520-EENG-340/lab1-template`. Must have "Template repository" enabled. |
| `--students` | Path to the roster file. |
| `--org` | Override the default org (where student repos will be created). |

**Example:**

```bash
gh rba assignment create \
  --name lab1 \
  --template 202520-EENG-340/lab1-template \
  --students roster.txt
```

Creates repos named `lab1-jsmith42`, `lab1-mjones99`, etc. in the default org.

**Naming your template `<name>-template` matters.** `assignment patch` looks for
`<org>/<assignment-name>-template` by default, so a template named `lab1-template`
lets you later run `gh rba assignment patch lab1` with no extra flags. Any other
name works too — you just have to pass `--template` to `patch` every time.

**Note:** The template org and the destination org can differ. This is useful if you keep templates in a shared org and create student repos in a course-specific org:

```bash
gh rba assignment create \
  --name lab1 \
  --template 202520-EENG-340/lab1-template \
  --students roster.txt \
  --org 202520-EENG-340
```

**Template repo setup:** In the template repo's GitHub settings, go to Settings → General and check the "Template repository" box. The tool will verify this before creating any repos and exit with a clear error if it is not set.

---

### `gh rba assignment list`

```
gh rba assignment list [--org <org>]
```

Lists all assignments that have been created in the org, by searching for repos tagged with the `rba-assignment` topic.

**Example output:**

```
→ Assignments in org '202520-EENG-340':
lab1
lab2
midterm-project
```

---

### `gh rba assignment patch`

```
gh rba assignment patch <assignment-name> [--template <org/repo>] [--message <msg>]
                                          [--dry-run] [--yes|-y] [--org <org>]
```

Fix the template repo as normal, then push the fix to every student repo:

```bash
cd lab1-template
vim .github/workflows/test.yml
git commit -am "fix JUnit jar path"
git push

gh rba assignment patch lab1 --dry-run   # preview
gh rba assignment patch lab1             # do it
```

Each student repo is merged three ways: its own root commit (the snapshot it was
created from) is the merge base, its current branch is "ours", and the template
is "theirs". Student work is preserved. A repo whose student edited the same
lines you fixed is **left completely untouched** and reported at the end for you
to handle by hand.

Patching is idempotent — re-running reports "already up to date", so an
interrupted run is safe to resume.

**Options:**

| Flag | Default | Meaning |
|------|---------|---------|
| `--template <org/repo>` | `<org>/<assignment-name>-template` | Where the fix comes from. Pass this whenever the template is not named `<assignment-name>-template`. |
| `--message <msg>` | `Instructor patch: sync from template` | Commit message on student repos |
| `--dry-run` | off | Run every merge, print outcomes, push nothing |
| `--yes`, `-y` | off | Skip the confirmation prompt |
| `--org <org>` | from `course.env` | Override the default org |

**Example output:**

```
→ Patching 'lab1' in org '202520-EENG-340' from '202520-EENG-340/lab1-template'

  ✓ mjones99             applied
  ─ jsmith42             already up to date
  ⚠ kpatel7              CONFLICT (skipped)

1 applied, 1 up to date, 1 conflict, 0 skipped

Needs manual attention:
  kpatel7  src/Tokenizer.java
```

**Exit code.** The command exits **non-zero** whenever any repo conflicted or was
skipped, and zero only when every repo was applied or already up to date. This
applies to `--dry-run` too, which is what makes a dry run usable as a pre-flight
check in a script.

**Repos that get skipped rather than patched.** `patch` refuses to merge unless it
can prove the student repo really is an instance of this template:

| Skip reason | Meaning |
|------|---------|
| `GitHub records no template for this repo` | GitHub has no `template_repository` link — provenance cannot be verified |
| `created from a different template (...)` | The repo was instantiated from some other template |
| `root commit is not a snapshot of this template` | History was rewritten (squashed/orphaned), so the root commit is no longer the distribution snapshot |
| `N root commits, merge base is ambiguous` | Unrelated history was merged in |
| `no branch '<branch>': ...` | Fetch failed — the repo is empty, or authentication/network failed. git's own message is appended |

Every skip leaves the repo **completely untouched**. Fix those few by hand.

Requires git >= 2.38.

---

### `gh rba repos clone`

```
gh rba repos clone <assignment-name> [--into <dir>] [--org <org>]
```

Clones all student repos for an assignment into `./<assignment-name>/<username>/`. Skips repos that are already cloned, so re-running after a late submission is safe and will not touch your local edits.

**Options:**

| Flag | Description |
|------|-------------|
| `--into` | Directory to clone into, instead of `./<assignment-name>/`. Used exactly as given — see below. |
| `--org` | Override the default org. |

**Example:**

```bash
gh rba repos clone lab1
```

Produces:

```
lab1/
  jsmith42/
  mjones99/
  alee2026/
```

**`--into` is the destination, not a parent.** The per-student directories are
created directly inside it:

```bash
gh rba repos clone lab1 --into repos/lab1   # -> repos/lab1/jsmith42/
gh rba repos clone lab1 --into repos        # -> repos/jsmith42/
```

⚠️ **Do not pass a path as the assignment name.** `gh rba repos clone repos/lab1`
does not work: the assignment name is the *topic* used to find the repos
(`rba-assignment-lab1`), and GitHub topics cannot contain `/`, so the search
matches nothing and the command stops before it would have created any
directory. That is what `--into` is for.

ℹ️ Note that `course.env` is read from the **current** directory, so `cd`-ing
into a subdirectory to control where repos land loses your `ORG`. Staying in the
term directory and using `--into` avoids that.

---

### `gh rba repos report`

```
gh rba repos report <assignment-name> [--org <org>]
```

Generates a Markdown file named `<assignment-name>-report.md` with a table of every student repo, a link to it on GitHub, and the date of their last push.

**Example output file (`lab1-report.md`):**

```markdown
# Assignment: lab1

Org: `202520-EENG-340`
Generated: 2026-06-02 14:30

| Student | Repository | Last Push |
|---------|------------|-----------|
| jsmith42 | [lab1-jsmith42](https://github.com/202520-EENG-340/lab1-jsmith42) | 2026-05-30 |
| mjones99 | [lab1-mjones99](https://github.com/202520-EENG-340/lab1-mjones99) | 2026-05-29 |
| alee2026 | [lab1-alee2026](https://github.com/202520-EENG-340/lab1-alee2026) | 2026-05-31 |
```

## Typical Workflow

```bash
# 1. Set up your course directory
cd ~/courses/202520-EENG-340
gh rba init --org 202520-EENG-340   # or clone the org's `course` repo here

# 2. Distribute an assignment
gh rba assignment create \
  --name lab1 \
  --template 202520-EENG-340/lab1-template \
  --students roster.txt

# 3. Check what assignments exist
gh rba assignment list

# 4. Found a mistake in the starter code? Fix the template, then push the fix
#    to everyone. --dry-run first; a non-zero exit means someone needs a hand.
gh rba assignment patch lab1 --dry-run
gh rba assignment patch lab1

# 5. At the deadline — clone all submissions
gh rba repos clone lab1

# 6. Generate a report with links for quick review
gh rba repos report lab1
```

## How It Works

Student repos are tagged with two GitHub topics at creation time:

- `rba-assignment` — marks any repo as belonging to this system
- `rba-assignment-<name>` — scopes the repo to a specific assignment

`assignment list`, `repos clone`, and `repos report` all use the GitHub search API to find repos by topic, so they work from any machine without any local state beyond `course.env`.

## Limitations

- **100-student cap per assignment.** GitHub's search API returns up to 100 results. This covers all current class sizes; pagination can be added if needed.
- **Template must be accessible.** The authenticated `gh` user must have read access to the template repo, and write access to the destination org.
