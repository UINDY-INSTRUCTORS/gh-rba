# Future Work

> **See also:** `docs/superpowers/specs/2026-09-03-course-in-the-org-design.md`,
> which proposes that each semester's org own its own data in a private
> `course-admin` repo, cloned and worked in, so the working directory identifies
> the course. It argues for staying in bash: `course.env` remains `KEY=value`,
> so the trigger below fires only weakly, and pagination and Windows are still
> unmet.

## Rewrite in Python

The current implementation is a bash script, which is fine for the current scope but
gets harder to maintain as complexity grows. Python would give us proper argument
parsing (`argparse`), real unit tests, safer string handling, and — critically —
native Windows support. Bash requires WSL or Git Bash on Windows; Python does not.

A rewrite makes sense when any of these become true:
- Pagination is needed (classes larger than 100 students)
- ~~The patch command above is added~~ — done in bash (see
  `docs/superpowers/specs/2026-08-10-assignment-patch-design.md`). Whether that
  turns out painful to maintain is evidence for this decision.
- Windows support is required for faculty
- The config format needs to grow beyond a single `ORG=` line

## Pagination

GitHub's search API returns at most 100 results per page. Current class sizes are
well under this, but pagination should be added before the tool is used at scale.

## Student name mapping in reports

The roster CSV supports `username,Full Name` but the report currently only shows
the GitHub username. Surfacing the full name in the report table would make it
easier to match repos to students in a gradebook.
