# Future Work

## Patching assignments after creation

It's easy to post an assignment and then remember something you forgot to include.
A future `gh rba assignment patch` command would apply a commit (or patch file) to
all student repos for a given assignment — without requiring the fork relationship
that GitHub Classroom relied on. Likely implementation: iterate over student repos,
apply the patch via the GitHub Contents API or by cloning, committing, and pushing.

## Rewrite in Python

The current implementation is a bash script, which is fine for the current scope but
gets harder to maintain as complexity grows. Python would give us proper argument
parsing (`argparse`), real unit tests, safer string handling, and — critically —
native Windows support. Bash requires WSL or Git Bash on Windows; Python does not.

A rewrite makes sense when any of these become true:
- Pagination is needed (classes larger than 100 students)
- The patch command above is added (more complex logic)
- Windows support is required for faculty
- The config format needs to grow beyond a single `ORG=` line

## Pagination

GitHub's search API returns at most 100 results per page. Current class sizes are
well under this, but pagination should be added before the tool is used at scale.

## Student name mapping in reports

The roster CSV supports `username,Full Name` but the report currently only shows
the GitHub username. Surfacing the full name in the report table would make it
easier to match repos to students in a gradebook.
