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

Create a GitHub org for your course inside the UIndy enterprise (e.g. `202520-EENG-340`), then run once per course directory to save it as the default:

```bash
cd ~/courses/202520-EENG-340
gh rba init --org 202520-EENG-340
```

This writes a `.rba` file in the current directory. All subsequent commands run from this directory will use that org as the default. Any command also accepts `--org <org>` to override.

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

Saves the default org for this course directory to `.rba`. Run once when setting up a new course folder.

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
| `--org <org>` | from `.rba` | Override the default org |

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
gh rba repos clone <assignment-name> [--org <org>]
```

Clones all student repos for an assignment into `./<assignment-name>/<username>/`. Skips repos that are already cloned.

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
gh rba init --org 202520-EENG-340

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

`assignment list`, `repos clone`, and `repos report` all use the GitHub search API to find repos by topic, so they work from any machine without any local state beyond `.rba`.

## Limitations

- **100-student cap per assignment.** GitHub's search API returns up to 100 results. This covers all current class sizes; pagination can be added if needed.
- **Template must be accessible.** The authenticated `gh` user must have read access to the template repo, and write access to the destination org.
