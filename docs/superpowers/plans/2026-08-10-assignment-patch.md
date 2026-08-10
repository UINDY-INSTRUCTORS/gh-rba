# `gh rba assignment patch` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `gh rba assignment patch <name>`, which pushes a template repo's post-distribution fixes into every student repo for that assignment via a real three-way merge, skipping any repo where the student's work conflicts.

**Architecture:** One scratch bare repo per invocation holds both remotes' objects. Each student repo's own root commit is the merge base (template instantiation squashes to a fresh root, so it *is* the distribution snapshot). `git merge-tree --write-tree` produces a merged tree without any working tree; `git commit-tree` + `git push` deliver it. Conflicts are detected by merge-tree's exit code and cause the repo to be left untouched.

**Tech Stack:** bash, `git` (≥ 2.38), `gh` CLI, `jq`. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-08-10-assignment-patch-design.md`

## Global Constraints

- **bash 3.2 compatible.** Stock macOS ships bash 3.2.57. Do **not** use `mapfile`/`readarray`, associative arrays (`declare -A`), or `${var^^}`. The existing script is 3.2-safe; keep it that way.
- **git ≥ 2.38 required at runtime** for `merge-tree --write-tree --merge-base`. Check and fail clearly.
- **Match existing script style:** `die`/`info` helpers, `local` declarations, `while [[ $# -gt 0 ]]` flag parsing, `--org` accepted by every command, two-space indent, section banners (`# ── Name ───`).
- **Never rewrite student history.** Only ever add a commit on top of the student's branch tip.
- **A repo is fully patched or entirely untouched.** No partial application.
- Script keeps `set -euo pipefail`; any command whose non-zero exit is expected must run inside an `if`/`||` guard.

## Verified Behaviors (do not re-derive)

Confirmed empirically against git 2.52.0 on 2026-08-10:

| Case | `merge-tree --write-tree --name-only` exit | stdout |
|---|---|---|
| Clean merge | `0` | one line: merged tree OID |
| No-op (nothing changed upstream) | `0` | tree OID **equal to** `refs/rba/student^{tree}` |
| Conflict | `1` | line 1 = tree OID; lines 2..N = conflicted paths; blank line; then messages |

Also confirmed: a repo created from a GitHub template shares **no** commit SHAs with its template (`202520-EENG-340` root `09885ef1` → HTTP 422 against the template), and pushing to a **non-bare** repo's checked-out branch is refused — so test fixtures must use bare student remotes.

## File Structure

| File | Responsibility |
|---|---|
| `gh-rba` (modify) | All command logic. New: `rba_git_version_ok`, `rba_require_git_version`, `rba_remote_url`, `rba_patch_repo`, `cmd_assignment_patch`; dispatch + usage updates; `main()` wrapper so tests can source the script. |
| `tests/fixtures.sh` (create) | Builds template + template-instantiated student repo pairs reproducing the real topology. Sourced by tests only. |
| `tests/test-helpers.sh` (create) | Unit tests for pure helpers (`rba_git_version_ok`, `rba_remote_url`). |
| `tests/test-patch.sh` (create) | Behavioral tests for `rba_patch_repo` against local fixtures. No network. |
| `tests/run.sh` (create) | Runs every `tests/test-*.sh`, exits non-zero if any fail. |
| `README.md` (modify) | Document the new command. |
| `FUTURE.md` (modify) | Remove the now-implemented "Patching assignments after creation" section. |

---

### Task 1: Make the script sourceable and add the git version floor

**Files:**
- Modify: `gh-rba:214-270` (usage + dispatch), and the helpers block near `gh-rba:8-34`
- Create: `tests/test-helpers.sh`
- Create: `tests/run.sh`

**Interfaces:**
- Consumes: nothing
- Produces: `rba_git_version_ok <version-string>` → returns 0 if ≥ 2.38, else 1. `rba_require_git_version` → calls `die` if the installed git is too old. `main "$@"` → the dispatch entry point. Sourcing `gh-rba` defines functions and runs nothing.

- [ ] **Step 1: Write the failing test**

Create `tests/test-helpers.sh`:

```bash
#!/usr/bin/env bash
# Unit tests for pure helper functions. No network, no fixtures.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Sourcing must define functions without executing any command.
source "$HERE/../gh-rba"
set +e

FAILS=0
check() {  # $1 description, $2 expected, $3 actual
  if [[ "$2" == "$3" ]]; then
    echo "  ok   $1"
  else
    echo "  FAIL $1 — expected '$2', got '$3'"
    FAILS=$((FAILS + 1))
  fi
}

version_result() {  # $1 version string -> "ok" or "too-old"
  if rba_git_version_ok "$1"; then echo "ok"; else echo "too-old"; fi
}

echo "rba_git_version_ok:"
check "2.38.0 is the floor, accepted" ok      "$(version_result 2.38.0)"
check "2.52.0 accepted"               ok      "$(version_result 2.52.0)"
check "3.0.1 accepted"                ok      "$(version_result 3.0.1)"
check "2.37.9 rejected"               too-old "$(version_result 2.37.9)"
check "2.9.5 rejected (not 2.90)"     too-old "$(version_result 2.9.5)"
check "1.9.1 rejected"                too-old "$(version_result 1.9.1)"

if (( FAILS == 0 )); then
  echo "test-helpers: PASS"
else
  echo "test-helpers: $FAILS FAILURE(S)"
  exit 1
fi
```

Create `tests/run.sh`:

```bash
#!/usr/bin/env bash
# Run every test file. Exits non-zero if any fail.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILED=0

for t in "$HERE"/test-*.sh; do
  echo "=== $(basename "$t") ==="
  if ! bash "$t"; then FAILED=$((FAILED + 1)); fi
  echo
done

if (( FAILED == 0 )); then
  echo "ALL TESTS PASSED"
else
  echo "$FAILED TEST FILE(S) FAILED"
  exit 1
fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `chmod +x tests/run.sh tests/test-helpers.sh && bash tests/test-helpers.sh`
Expected: FAIL — sourcing `gh-rba` runs dispatch at source time with no arguments, so `usage` prints and exits. **Note this exits 0**, so judge by output, not exit code: the run prints the usage text and *no* `ok`/`FAIL` lines and *no* `test-helpers: PASS` line, because execution never reaches the assertions.

- [ ] **Step 3: Add the version helpers**

In `gh-rba`, immediately after the `info()` definition (currently line 11), add:

```bash
# Compare a git version string against the 2.38 floor required by
# `git merge-tree --write-tree --merge-base`. Numeric compare per component —
# a lexical compare would wrongly rank 2.9 above 2.38.
rba_git_version_ok() {
  local v="$1" major minor
  major="${v%%.*}"
  v="${v#*.}"
  minor="${v%%.*}"
  [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] || return 1
  (( major > 2 )) && return 0
  (( major == 2 && minor >= 38 )) && return 0
  return 1
}

rba_require_git_version() {
  local v
  v=$(git --version | awk '{print $3}')
  rba_git_version_ok "$v" \
    || die "git >= 2.38 is required for 'assignment patch' (found $v)."
}
```

- [ ] **Step 4: Wrap dispatch so the script can be sourced**

Replace the entire `# ── Dispatch ───` block at the end of `gh-rba` (currently lines 243-270) with:

```bash
# ── Dispatch ──────────────────────────────────────────────────────────────────

main() {
  [[ $# -eq 0 ]] && usage

  case "$1" in
    init)    shift; cmd_init "$@" ;;
    assignment)
      shift
      [[ $# -gt 0 ]] || usage
      case "$1" in
        create) shift; cmd_assignment_create "$@" ;;
        list)   shift; cmd_assignment_list "$@" ;;
        *)      usage ;;
      esac
      ;;
    repos)
      shift
      [[ $# -gt 0 ]] || usage
      case "$1" in
        clone)  shift; cmd_repos_clone "$@" ;;
        report) shift; cmd_repos_report "$@" ;;
        *)      usage ;;
      esac
      ;;
    version|--version) echo "gh-rba v${VERSION}" ;;
    help|--help|-h)    usage ;;
    *) die "Unknown command: $1. Run 'gh rba help' for usage." ;;
  esac
}

# Only dispatch when executed directly. Sourcing (the test suite) just defines
# functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash tests/run.sh`
Expected: PASS — `test-helpers: PASS`, then `ALL TESTS PASSED`.

- [ ] **Step 6: Verify the CLI still works unchanged**

Run: `./gh-rba version && ./gh-rba help && ./gh-rba assignment list --org 202610-CSCI-350`
Expected: `gh-rba v0.1.0`; the usage text; then `→ Assignments in org '202610-CSCI-350':` with no assignments listed (the org is empty). No errors.

- [ ] **Step 7: Commit**

```bash
git add gh-rba tests/
git commit -m "refactor: make gh-rba sourceable and add git version floor

Wraps dispatch in main() behind a BASH_SOURCE guard so the test suite can
source the script and unit-test individual functions. Adds rba_git_version_ok
for the git >= 2.38 requirement of merge-tree --write-tree."
```

---

### Task 2: Fixture builder and the clean-apply / no-op paths of `rba_patch_repo`

**Files:**
- Create: `tests/fixtures.sh`
- Create: `tests/test-patch.sh`
- Modify: `gh-rba` — add `rba_patch_repo` after `cmd_assignment_list`

**Interfaces:**
- Consumes: `die`, `info` from `gh-rba`.
- Produces: `rba_patch_repo <scratch> <remote> <branch> <message> <dry_run>` → prints exactly one outcome line to stdout and returns 0. Outcome is one of `applied`, `uptodate`, `conflict <path> [<path>...]`, `skipped <reason>`. Fixture functions: `fixture_new <dir>`, `fixture_tpl_file <dir> <path> <content>`, `fixture_tpl_commit <dir> <msg>`, `fixture_distribute <dir>`, `fixture_stu_file <dir> <path> <content>`, `fixture_stu_commit <dir> <msg>`, `fixture_scratch <dir>` (echoes the scratch path), `fixture_stu_show <dir> <path>`.

- [ ] **Step 1: Write the fixture builder**

Create `tests/fixtures.sh`:

```bash
#!/usr/bin/env bash
# Builds a template repo plus a "template-instantiated" student repo that
# reproduces the real GitHub topology: the student repo's root commit is a
# squashed snapshot of the template and shares no SHAs with it.
#
# Student remotes are BARE — git refuses pushes to a checked-out branch.

fixture_new() {  # $1 dir
  local d="$1"
  rm -rf "$d"
  mkdir -p "$d"
  git init -q "$d/tpl"
  git -C "$d/tpl" symbolic-ref HEAD refs/heads/main
  git -C "$d/tpl" config user.email instructor@example.edu
  git -C "$d/tpl" config user.name  "Instructor"
}

fixture_tpl_file() {  # $1 dir, $2 path, $3 content
  mkdir -p "$(dirname "$1/tpl/$2")"
  printf '%s' "$3" > "$1/tpl/$2"
}

fixture_tpl_commit() {  # $1 dir, $2 message
  git -C "$1/tpl" add -A
  git -C "$1/tpl" commit -qm "$2"
}

# Snapshot the template into a fresh bare student repo, exactly as GitHub's
# "create from template" does: one squashed root commit named "Initial commit".
fixture_distribute() {  # $1 dir
  local d="$1"
  git init -q --bare "$d/stu.git"
  git clone -q "$d/stu.git" "$d/stuwork" 2>/dev/null
  git -C "$d/stuwork" symbolic-ref HEAD refs/heads/main
  git -C "$d/stuwork" config user.email student@example.edu
  git -C "$d/stuwork" config user.name  "Student"
  ( cd "$d/tpl" && git archive HEAD ) | tar -x -C "$d/stuwork"
  git -C "$d/stuwork" add -A
  git -C "$d/stuwork" commit -qm "Initial commit"
  git -C "$d/stuwork" push -q origin HEAD:refs/heads/main
}

fixture_stu_file() {  # $1 dir, $2 path, $3 content
  mkdir -p "$(dirname "$1/stuwork/$2")"
  printf '%s' "$3" > "$1/stuwork/$2"
}

fixture_stu_commit() {  # $1 dir, $2 message
  git -C "$1/stuwork" add -A
  git -C "$1/stuwork" commit -qm "$2"
  git -C "$1/stuwork" push -q origin HEAD:refs/heads/main
}

# Fresh scratch bare repo with the template already fetched, mirroring what
# cmd_assignment_patch sets up once per invocation. Echoes its path.
fixture_scratch() {  # $1 dir
  local d="$1"
  rm -rf "$d/scratch"
  git init -q --bare "$d/scratch"
  git -C "$d/scratch" fetch -q --no-tags "$d/tpl" '+refs/heads/main:refs/rba/template'
  echo "$d/scratch"
}

# Read a file's content from the student's bare remote (post-push truth).
fixture_stu_show() {  # $1 dir, $2 path
  git -C "$1/stu.git" cat-file blob "main:$2"
}

# Count commits on the student's bare remote.
fixture_stu_count() {  # $1 dir
  git -C "$1/stu.git" rev-list --count main
}
```

- [ ] **Step 2: Write the failing tests for clean apply and no-op**

Create `tests/test-patch.sh`:

```bash
#!/usr/bin/env bash
# Behavioral tests for rba_patch_repo against local fixtures. No network.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../gh-rba"
source "$HERE/fixtures.sh"
set +e

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILS=0
check() {  # $1 description, $2 expected, $3 actual
  if [[ "$2" == "$3" ]]; then
    echo "  ok   $1"
  else
    echo "  FAIL $1 — expected '$2', got '$3'"
    FAILS=$((FAILS + 1))
  fi
}

MSG="Instructor patch: sync from template"

# ── Case 1: clean apply — template fixes a file the student never touched ────
D="$TMP/clean"
fixture_new "$D"
fixture_tpl_file "$D" ci.yml "workflow v1"$'\n'
fixture_tpl_file "$D" a.txt  "a"$'\n'"b"$'\n'"c"$'\n'
fixture_tpl_commit "$D" "initial commit"
fixture_distribute "$D"
fixture_tpl_file "$D" ci.yml "workflow v2 FIXED"$'\n'
fixture_tpl_commit "$D" "fix CI"
fixture_stu_file "$D" a.txt "a"$'\n'"b"$'\n'"c"$'\n'"STUDENT"$'\n'
fixture_stu_commit "$D" "student work"

S="$(fixture_scratch "$D")"
echo "clean apply:"
check "outcome is applied" "applied" \
  "$(rba_patch_repo "$S" "$D/stu.git" main "$MSG" false)"
check "template fix landed"  "workflow v2 FIXED" "$(fixture_stu_show "$D" ci.yml)"
check "student work survived" "a b c STUDENT"     "$(fixture_stu_show "$D" a.txt | tr '\n' ' ' | sed 's/ $//')"
check "one new commit"        "3"                 "$(fixture_stu_count "$D")"

# ── Case 2: no-op — template unchanged since distribution ────────────────────
D="$TMP/noop"
fixture_new "$D"
fixture_tpl_file "$D" ci.yml "workflow v1"$'\n'
fixture_tpl_commit "$D" "initial commit"
fixture_distribute "$D"
fixture_stu_file "$D" answer.txt "42"$'\n'
fixture_stu_commit "$D" "student work"

S="$(fixture_scratch "$D")"
echo "no-op:"
check "outcome is uptodate" "uptodate" \
  "$(rba_patch_repo "$S" "$D/stu.git" main "$MSG" false)"
check "no commit created" "2" "$(fixture_stu_count "$D")"

# ── Case 3: dry run does not push ────────────────────────────────────────────
D="$TMP/dryrun"
fixture_new "$D"
fixture_tpl_file "$D" ci.yml "workflow v1"$'\n'
fixture_tpl_commit "$D" "initial commit"
fixture_distribute "$D"
fixture_tpl_file "$D" ci.yml "workflow v2 FIXED"$'\n'
fixture_tpl_commit "$D" "fix CI"

S="$(fixture_scratch "$D")"
echo "dry run:"
check "reports applied" "applied" \
  "$(rba_patch_repo "$S" "$D/stu.git" main "$MSG" true)"
check "nothing pushed"  "1"                "$(fixture_stu_count "$D")"
check "file unchanged"  "workflow v1"      "$(fixture_stu_show "$D" ci.yml)"

if (( FAILS == 0 )); then
  echo "test-patch: PASS"
else
  echo "test-patch: $FAILS FAILURE(S)"
  exit 1
fi
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `bash tests/test-patch.sh`
Expected: FAIL — `rba_patch_repo: command not found` for every case.

- [ ] **Step 4: Implement `rba_patch_repo`**

In `gh-rba`, after `cmd_assignment_list` ends (currently line 126) and before the `cmd_repos_clone` banner, add:

```bash
# Apply the template's post-distribution changes to one student repo.
#
#   $1 scratch  bare repo that already holds refs/rba/template
#   $2 remote   student repo URL or local path
#   $3 branch   student's default branch
#   $4 message  commit message for the patch commit
#   $5 dry_run  "true" or "false"
#
# Prints exactly one outcome line and returns 0:
#   applied | uptodate | conflict <path>... | skipped <reason>
rba_patch_repo() {
  local scratch="$1" remote="$2" branch="$3" message="$4" dry_run="$5"
  local base tree cur_tree new_commit out rc roots root_count paths

  if ! git -C "$scratch" fetch -q --no-tags "$remote" \
        "+refs/heads/${branch}:refs/rba/student" 2>/dev/null; then
    echo "skipped no branch '${branch}'"
    return 0
  fi

  # Exactly one root commit is expected: the distribution snapshot. More than
  # one means unrelated history was merged in and the base is ambiguous.
  roots=$(git -C "$scratch" rev-list --max-parents=0 refs/rba/student)
  # `grep -c` exits 1 when it counts zero, which would trip `set -e` inside a
  # command substitution — hence the `|| true`.
  root_count=$(printf '%s\n' "$roots" | grep -c '[0-9a-f]' || true)
  if [[ "$root_count" != "1" ]]; then
    echo "skipped ${root_count} root commits, merge base is ambiguous"
    return 0
  fi
  base="$roots"

  # merge-tree exits 1 on conflict, so it must not trip `set -e`.
  if out=$(git -C "$scratch" merge-tree --write-tree --name-only \
             --merge-base="$base" refs/rba/student refs/rba/template 2>&1); then
    rc=0
  else
    rc=$?
  fi

  if [[ "$rc" == "1" ]]; then
    # Output: tree OID, then conflicted paths, then a blank line, then messages.
    paths=$(printf '%s\n' "$out" | awk 'NR==1 {next} /^$/ {exit} {print}' | tr '\n' ' ')
    echo "conflict ${paths% }"
    return 0
  fi
  if [[ "$rc" != "0" ]]; then
    echo "skipped merge failed"
    return 0
  fi

  tree=$(printf '%s\n' "$out" | head -1)
  cur_tree=$(git -C "$scratch" rev-parse "refs/rba/student^{tree}")
  if [[ "$tree" == "$cur_tree" ]]; then
    echo "uptodate"
    return 0
  fi

  if [[ "$dry_run" == "true" ]]; then
    echo "applied"
    return 0
  fi

  new_commit=$(git -C "$scratch" commit-tree "$tree" -p refs/rba/student -m "$message")
  if git -C "$scratch" push -q "$remote" "${new_commit}:refs/heads/${branch}" 2>/dev/null; then
    echo "applied"
  else
    echo "skipped push rejected"
  fi
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash tests/run.sh`
Expected: PASS — `test-helpers: PASS`, `test-patch: PASS`, `ALL TESTS PASSED`.

- [ ] **Step 6: Commit**

```bash
git add gh-rba tests/
git commit -m "feat: add rba_patch_repo three-way merge core

Merges template changes into a student repo using the repo's own root commit
as the merge base, via git merge-tree --write-tree. No working tree, no
history rewrite. Covers clean apply, no-op, and dry-run paths."
```

---

### Task 3: Conflict detection and edge cases

**Files:**
- Modify: `tests/test-patch.sh` — append cases 4-8 before the summary block

**Interfaces:**
- Consumes: `rba_patch_repo` and all fixture functions from Task 2.
- Produces: nothing new. This task only proves existing behavior.

**Note on ordering:** this task is deliberately test-only. `rba_patch_repo` is a
single cohesive function, so Task 2 necessarily wrote its conflict and skip
branches too — splitting one function across two tasks would be worse than the
mild TDD irregularity of testing it afterward. Treat any failure here as a real
defect in the Task 2 implementation.

- [ ] **Step 1: Write the failing tests**

In `tests/test-patch.sh`, insert the following immediately before the `if (( FAILS == 0 ))` summary block:

```bash
# ── Case 4: conflict — student and template edit the same lines ──────────────
D="$TMP/conflict"
fixture_new "$D"
fixture_tpl_file "$D" ci.yml "workflow v1"$'\n'
fixture_tpl_commit "$D" "initial commit"
fixture_distribute "$D"
fixture_tpl_file "$D" ci.yml "workflow v2 FIXED"$'\n'
fixture_tpl_commit "$D" "fix CI"
fixture_stu_file "$D" ci.yml "workflow STUDENT VERSION"$'\n'
fixture_stu_commit "$D" "student edits ci.yml"

S="$(fixture_scratch "$D")"
echo "conflict:"
check "outcome names the file" "conflict ci.yml" \
  "$(rba_patch_repo "$S" "$D/stu.git" main "$MSG" false)"
check "repo left untouched"     "2"                        "$(fixture_stu_count "$D")"
check "student version intact"  "workflow STUDENT VERSION" "$(fixture_stu_show "$D" ci.yml)"

# ── Case 5: disjoint edits to the SAME file merge cleanly ────────────────────
# This is what distinguishes a real three-way merge from an overwrite.
D="$TMP/disjoint"
fixture_new "$D"
fixture_tpl_file "$D" a.txt "header"$'\n'"body"$'\n'"footer"$'\n'
fixture_tpl_commit "$D" "initial commit"
fixture_distribute "$D"
fixture_tpl_file "$D" a.txt "HEADER FIXED"$'\n'"body"$'\n'"footer"$'\n'
fixture_tpl_commit "$D" "fix header"
fixture_stu_file "$D" a.txt "header"$'\n'"body"$'\n'"footer"$'\n'"student line"$'\n'
fixture_stu_commit "$D" "student appends"

S="$(fixture_scratch "$D")"
echo "disjoint edits, same file:"
check "outcome is applied" "applied" \
  "$(rba_patch_repo "$S" "$D/stu.git" main "$MSG" false)"
check "both edits present" "HEADER FIXED body footer student line" \
  "$(fixture_stu_show "$D" a.txt | tr '\n' ' ' | sed 's/ $//')"

# ── Case 6: idempotence — patching twice is a no-op the second time ──────────
S="$(fixture_scratch "$D")"
echo "idempotence:"
check "second run is uptodate" "uptodate" \
  "$(rba_patch_repo "$S" "$D/stu.git" main "$MSG" false)"
check "no extra commit" "3" "$(fixture_stu_count "$D")"

# ── Case 7: student repo with no commits is skipped, not crashed ─────────────
D="$TMP/empty"
fixture_new "$D"
fixture_tpl_file "$D" ci.yml "workflow v1"$'\n'
fixture_tpl_commit "$D" "initial commit"
git init -q --bare "$D/stu.git"

S="$(fixture_scratch "$D")"
echo "empty student repo:"
check "skipped with reason" "skipped no branch 'main'" \
  "$(rba_patch_repo "$S" "$D/stu.git" main "$MSG" false)"

# ── Case 8: multiple root commits make the base ambiguous → skip ─────────────
D="$TMP/multiroot"
fixture_new "$D"
fixture_tpl_file "$D" ci.yml "workflow v1"$'\n'
fixture_tpl_commit "$D" "initial commit"
fixture_distribute "$D"
fixture_tpl_file "$D" ci.yml "workflow v2 FIXED"$'\n'
fixture_tpl_commit "$D" "fix CI"
# Graft a second, unrelated root onto the student's history.
git -C "$D/stuwork" checkout -q --orphan stray
git -C "$D/stuwork" rm -rq --cached .
rm -f "$D/stuwork/ci.yml"
printf 'stray\n' > "$D/stuwork/stray.txt"
git -C "$D/stuwork" add -A
git -C "$D/stuwork" commit -qm "unrelated root"
git -C "$D/stuwork" checkout -q main
git -C "$D/stuwork" merge -q --allow-unrelated-histories --no-edit stray
git -C "$D/stuwork" push -q origin HEAD:refs/heads/main

S="$(fixture_scratch "$D")"
echo "multiple root commits:"
check "skipped with reason" "skipped 2 root commits, merge base is ambiguous" \
  "$(rba_patch_repo "$S" "$D/stu.git" main "$MSG" false)"
```

- [ ] **Step 2: Run tests to see which fail**

Run: `bash tests/test-patch.sh`
Expected: Cases 4-8 exercise code paths already written in Task 2, so most should pass immediately. Any FAIL here is a real defect in `rba_patch_repo` — most likely in the `awk` conflict-path parse or the `grep -c` root count. Fix `rba_patch_repo`, not the test, unless the expected string itself is wrong.

- [ ] **Step 3: Run the full suite**

Run: `bash tests/run.sh`
Expected: PASS — `test-helpers: PASS`, `test-patch: PASS`, `ALL TESTS PASSED`.

- [ ] **Step 4: Commit**

```bash
git add tests/
git commit -m "test: cover conflict, disjoint merge, idempotence, and edge cases

Case 5 (disjoint edits to the same file) is the one that proves this is a
real three-way merge rather than a file overwrite."
```

---

### Task 4: Remote URL protocol resolution

**Files:**
- Modify: `gh-rba` — add `rba_remote_url` after `rba_require_git_version`
- Modify: `tests/test-helpers.sh` — append a `rba_remote_url` section

**Interfaces:**
- Consumes: nothing.
- Produces: `rba_remote_url <ssh_url> <clone_url> <protocol>` → echoes `ssh_url` when protocol is `ssh`, otherwise `clone_url`. `rba_git_protocol` → echoes the effective protocol for github.com.

- [ ] **Step 1: Write the failing test**

Append to `tests/test-helpers.sh`, immediately before the `if (( FAILS == 0 ))` summary block:

```bash
echo "rba_remote_url:"
SSH_U="git@github.com:org/repo.git"
HTTPS_U="https://github.com/org/repo.git"
check "ssh protocol selects ssh_url"     "$SSH_U"   "$(rba_remote_url "$SSH_U" "$HTTPS_U" ssh)"
check "https protocol selects clone_url" "$HTTPS_U" "$(rba_remote_url "$SSH_U" "$HTTPS_U" https)"
check "unknown protocol defaults https"  "$HTTPS_U" "$(rba_remote_url "$SSH_U" "$HTTPS_U" '')"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-helpers.sh`
Expected: FAIL — `rba_remote_url: command not found` on all three checks.

- [ ] **Step 3: Implement both functions**

In `gh-rba`, directly after `rba_require_git_version`, add:

```bash
# Effective git protocol for github.com. Host-scoped config wins over global —
# a machine can be globally https while github.com is ssh, and reading only the
# global value would produce URLs that fail to authenticate.
rba_git_protocol() {
  local p
  p=$(gh config get -h github.com git_protocol 2>/dev/null)
  [[ -n "$p" ]] || p=$(gh config get git_protocol 2>/dev/null)
  echo "$p"
}

# Pick the clone/push URL matching the configured protocol.
rba_remote_url() {  # $1 ssh_url, $2 clone_url, $3 protocol
  if [[ "$3" == "ssh" ]]; then echo "$1"; else echo "$2"; fi
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run.sh`
Expected: PASS — all files pass, `ALL TESTS PASSED`.

- [ ] **Step 5: Verify protocol detection matches this machine**

Run: `source ./gh-rba && rba_git_protocol`
Expected: `ssh` — the host-scoped setting for github.com, not the global `https`.

- [ ] **Step 6: Commit**

```bash
git add gh-rba tests/
git commit -m "feat: resolve push URLs against host-scoped git protocol

gh config get -h github.com git_protocol takes precedence over the global
setting; reading only the global value yields URLs that fail to authenticate."
```

---

### Task 5: Wire up `cmd_assignment_patch`, dispatch, usage, and docs

**Files:**
- Modify: `gh-rba` — add `cmd_assignment_patch` after `rba_patch_repo`; update `usage()` and `main()`
- Modify: `README.md`
- Modify: `FUTURE.md`

**Interfaces:**
- Consumes: `rba_patch_repo`, `rba_remote_url`, `rba_git_protocol`, `rba_require_git_version`, `load_config`, `require_org`, `die`, `info`.
- Produces: `cmd_assignment_patch "$@"` — the full command. Exits 1 if any repo conflicted or was skipped, 0 otherwise.

- [ ] **Step 1: Implement the command**

In `gh-rba`, after `rba_patch_repo`, add:

```bash
cmd_assignment_patch() {
  load_config
  local name="" template="" message="Instructor patch: sync from template"
  local dry_run=false assume_yes=false

  [[ $# -gt 0 ]] || die "Usage: gh rba assignment patch <assignment-name> [--template <org/repo>] [--message <msg>] [--dry-run] [--yes]"
  name="$1"; shift

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --template) template="$2"; shift 2 ;;
      --message)  message="$2";  shift 2 ;;
      --org)      ORG="$2";      shift 2 ;;
      --dry-run)  dry_run=true;  shift ;;
      --yes|-y)   assume_yes=true; shift ;;
      *) die "Unknown option: $1" ;;
    esac
  done

  rba_require_git_version

  local org
  org=$(require_org)
  [[ -n "$template" ]] || template="${org}/${name}-template"

  # One API call for everything needed about the template.
  local tpl_json tpl_branch
  tpl_json=$(gh api "repos/$template" 2>/dev/null) \
    || die "Template repo '$template' not found. Pass --template <org/repo> if it is named differently."
  tpl_branch=$(echo "$tpl_json" | jq -r '.default_branch')

  local repos_json count
  repos_json=$(gh api "search/repositories?q=topic:rba-assignment-${name}+org:${org}&per_page=100")
  count=$(echo "$repos_json" | jq '.total_count')
  [[ "$count" -gt 0 ]] || die "No repos found for assignment '$name' in org '$org'"

  info "Patching '$name' in org '$org' from '$template'"
  if [[ "$dry_run" == "true" ]]; then
    info "DRY RUN — no changes will be pushed"
  elif [[ "$assume_yes" != "true" ]]; then
    if [[ ! -t 0 ]]; then
      die "Refusing to patch $count repos without confirmation. Pass --yes to proceed non-interactively."
    fi
    printf 'Patch %s student repo(s)? [y/N] ' "$count"
    local reply; read -r reply
    [[ "$reply" == "y" || "$reply" == "Y" ]] || die "Aborted."
  fi

  local proto scratch
  proto=$(rba_git_protocol)
  scratch=$(mktemp -d)
  trap 'rm -rf "$scratch"' EXIT

  git init -q --bare "$scratch"
  local tpl_url
  tpl_url=$(rba_remote_url \
    "$(echo "$tpl_json" | jq -r '.ssh_url')" \
    "$(echo "$tpl_json" | jq -r '.clone_url')" \
    "$proto")
  git -C "$scratch" fetch -q --no-tags "$tpl_url" \
    "+refs/heads/${tpl_branch}:refs/rba/template" \
    || die "Could not fetch template branch '$tpl_branch' from $template"

  local n_applied=0 n_uptodate=0 n_conflict=0 n_skipped=0
  local problems=""

  echo ""
  while IFS=$'\t' read -r repo_name ssh_url clone_url def_branch; do
    local username="${repo_name#"${name}-"}"
    local url outcome
    url=$(rba_remote_url "$ssh_url" "$clone_url" "$proto")
    outcome=$(rba_patch_repo "$scratch" "$url" "$def_branch" "$message" "$dry_run")

    case "$outcome" in
      applied)
        printf '  ✓ %-20s applied\n' "$username"; n_applied=$((n_applied + 1)) ;;
      uptodate)
        printf '  ─ %-20s already up to date\n' "$username"; n_uptodate=$((n_uptodate + 1)) ;;
      conflict\ *)
        printf '  ⚠ %-20s CONFLICT (skipped)\n' "$username"
        n_conflict=$((n_conflict + 1))
        problems="${problems}  ${username}  ${outcome#conflict }"$'\n' ;;
      *)
        printf '  ⚠ %-20s %s\n' "$username" "$outcome"
        n_skipped=$((n_skipped + 1))
        problems="${problems}  ${username}  ${outcome#skipped }"$'\n' ;;
    esac
  done < <(echo "$repos_json" \
    | jq -r '.items[] | [.name, .ssh_url, .clone_url, .default_branch] | @tsv')

  echo ""
  echo "${n_applied} applied, ${n_uptodate} up to date, ${n_conflict} conflict, ${n_skipped} skipped"

  if [[ -n "$problems" ]]; then
    echo ""
    echo "Needs manual attention:"
    printf '%s' "$problems"
    return 1
  fi
}
```

- [ ] **Step 2: Add dispatch and usage entries**

In `main()`, add `patch` to the `assignment` inner case, after the `list)` line:

```bash
        patch)  shift; cmd_assignment_patch "$@" ;;
```

In `usage()`, add after the `assignment list` line:

```
  gh rba assignment patch <assignment-name> [--template <org/repo>] [--message <msg>] [--dry-run] [--yes] [--org <org>]
```

And append to the `NOTES` section of `usage()`:

```
  'assignment patch' merges the template's post-distribution changes into every
  student repo. Student work is preserved; repos that conflict are left untouched
  and reported. Requires git >= 2.38.
```

- [ ] **Step 3: Verify the command wires up and validates input**

Run: `./gh-rba assignment patch` (no arguments)
Expected: `Error: Usage: gh rba assignment patch <assignment-name> ...`, exit 1.

Run: `./gh-rba assignment patch hw01 --org 202610-CSCI-350`
Expected: `Error: Template repo '202610-CSCI-350/hw01-template' not found. Pass --template <org/repo> if it is named differently.` — the org is empty, so this is the correct failure and it proves template resolution and the default naming both work.

Run: `./gh-rba help`
Expected: usage text now lists `assignment patch` and the new NOTES paragraph.

- [ ] **Step 4: Confirm the test suite still passes**

Run: `bash tests/run.sh`
Expected: PASS — `ALL TESTS PASSED`.

- [ ] **Step 5: Update README.md**

In `README.md`, after the `assignment create` documentation section, add:

````markdown
### Patching a distributed assignment

Fix the template repo as normal, then push the fix to every student repo:

```bash
cd hw01-java-intro-template
vim .github/workflows/test.yml
git commit -am "fix JUnit jar path"
git push

gh rba assignment patch hw01 --dry-run   # preview
gh rba assignment patch hw01             # do it
```

Each student repo is merged three ways: its own root commit (the snapshot it was
created from) is the merge base, its current branch is "ours", and the template
is "theirs". Student work is preserved. A repo whose student edited the same
lines you fixed is **left completely untouched** and reported at the end for you
to handle by hand.

Patching is idempotent — re-running reports "already up to date", so an
interrupted run is safe to resume.

| Flag | Default | Meaning |
|------|---------|---------|
| `--template <org/repo>` | `<org>/<assignment>-template` | Where the fix comes from |
| `--message <msg>` | `Instructor patch: sync from template` | Commit message |
| `--dry-run` | off | Run every merge, push nothing |
| `--yes` | off | Skip the confirmation prompt |

Requires git >= 2.38.
````

- [ ] **Step 6: Remove the implemented section from FUTURE.md**

Delete the entire `## Patching assignments after creation` section (its heading and paragraph) from `FUTURE.md`.

Then, in the `## Rewrite in Python` section, replace the bullet line `- The patch command above is added (more complex logic)` with:

```markdown
- ~~The patch command above is added~~ — done in bash (see
  `docs/superpowers/specs/2026-08-10-assignment-patch-design.md`). Whether that
  turns out painful to maintain is evidence for this decision.
```

- [ ] **Step 7: Commit**

```bash
git add gh-rba README.md FUTURE.md
git commit -m "feat: add 'gh rba assignment patch'

Pushes a template's post-distribution fixes into every student repo via a
three-way merge against each repo's root commit. Conflicting repos are left
untouched and reported; exit is non-zero when any repo needs attention.

Closes the 'Patching assignments after creation' item in FUTURE.md."
```

---

### Task 6: End-to-end verification against a real GitHub org

**Files:** none modified — this is a live verification task.

**Interfaces:**
- Consumes: the complete `gh rba assignment patch` command.
- Produces: confidence that the command works against real GitHub, not just local fixtures.

**Why this task exists:** every prior test used local paths as remotes. This is the first exercise of `gh api` discovery, real clone URLs, SSH auth, and GitHub's actual template instantiation.

- [ ] **Step 1: Create a throwaway template repo**

```bash
cd "$(mktemp -d)"
mkdir tpl && cd tpl && git init -q
printf 'workflow v1\n' > ci.yml
printf 'a\nb\nc\n' > a.txt
git add -A && git commit -qm "initial commit"
gh repo create 202610-CSCI-350/patchtest-template --private --source=. --push
gh repo edit 202610-CSCI-350/patchtest-template --template
```

- [ ] **Step 2: Distribute it to yourself**

Create `roster.txt` containing the single line `sspickle`, then:

```bash
cd "$(mktemp -d)"
gh rba init --org 202610-CSCI-350
printf 'sspickle\n' > roster.txt
gh rba assignment create --name patchtest \
  --template 202610-CSCI-350/patchtest-template \
  --students roster.txt
```

Expected: creates `202610-CSCI-350/patchtest-sspickle`.

- [ ] **Step 3: Simulate student work, then fix the template**

```bash
gh repo clone 202610-CSCI-350/patchtest-sspickle stu
cd stu && printf 'a\nb\nc\nSTUDENT WORK\n' > a.txt
git commit -qam "student work" && git push -q && cd ..

gh repo clone 202610-CSCI-350/patchtest-template tpl2
cd tpl2 && printf 'workflow v2 FIXED\n' > ci.yml
git commit -qam "fix CI" && git push -q && cd ..
```

- [ ] **Step 4: Dry run**

Run: `gh rba assignment patch patchtest --dry-run`
Expected: `✓ sspickle  applied`, summary `1 applied, 0 up to date, 0 conflict, 0 skipped`, exit 0.

Then verify nothing was pushed:
Run: `gh api repos/202610-CSCI-350/patchtest-sspickle/commits --jq 'length'`
Expected: `2` — the dry run did not create a commit.

- [ ] **Step 5: Real run**

Run: `gh rba assignment patch patchtest --yes`
Expected: `✓ sspickle  applied`, summary `1 applied, ...`, exit 0.

Verify the merge did the right thing:
```bash
gh api repos/202610-CSCI-350/patchtest-sspickle/contents/ci.yml --jq '.content' | base64 -d
gh api repos/202610-CSCI-350/patchtest-sspickle/contents/a.txt  --jq '.content' | base64 -d
```
Expected: `workflow v2 FIXED`, and `a b c STUDENT WORK` — the fix applied and the student's work preserved.

- [ ] **Step 6: Verify idempotence against real GitHub**

Run: `gh rba assignment patch patchtest --yes`
Expected: `─ sspickle  already up to date`, summary `0 applied, 1 up to date, ...`, exit 0.

- [ ] **Step 7: Verify conflict handling against real GitHub**

```bash
cd tpl2 && printf 'workflow v3\n' > ci.yml && git commit -qam "another fix" && git push -q && cd ..
cd stu && git pull -q && printf 'workflow STUDENT EDIT\n' > ci.yml
git commit -qam "student edits ci.yml" && git push -q && cd ..
```

Run: `gh rba assignment patch patchtest --yes`
Expected: `⚠ sspickle  CONFLICT (skipped)`, a `Needs manual attention:` block naming `ci.yml`, and a **non-zero exit**.

Verify the repo was untouched:
Run: `gh api repos/202610-CSCI-350/patchtest-sspickle/contents/ci.yml --jq '.content' | base64 -d`
Expected: `workflow STUDENT EDIT` — the student's version, unmodified.

- [ ] **Step 8: Clean up the throwaway repos**

```bash
gh repo delete 202610-CSCI-350/patchtest-template --yes
gh repo delete 202610-CSCI-350/patchtest-sspickle --yes
```

- [ ] **Step 9: Record the result**

Append to `FUTURE.md` under a new `## Verified` heading:

```markdown
## Verified

- `assignment patch` end-to-end against `202610-CSCI-350` on 2026-08-10:
  clean apply, idempotent re-run, and conflict-skip all confirmed against real
  GitHub template instantiation.
```

```bash
git add FUTURE.md
git commit -m "docs: record end-to-end verification of assignment patch"
```
