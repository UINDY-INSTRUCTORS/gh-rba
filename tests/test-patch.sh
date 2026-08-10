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

# Outcome lines for git failures now carry git's own first stderr line, which
# varies by git version — assert on the stable prefix.
check_prefix() {  # $1 description, $2 expected prefix, $3 actual
  case "$3" in
    "$2"*) echo "  ok   $1" ;;
    *) echo "  FAIL $1 — expected prefix '$2', got '$3'"; FAILS=$((FAILS + 1)) ;;
  esac
}

MSG="Instructor patch: sync from template"

# Mirror cmd_assignment_patch's call: the template's tree-OID set is computed
# once from the scratch repo and handed to rba_patch_repo.
patch_repo() {  # $1 scratch, $2 remote, $3 branch, $4 message, $5 dry_run
  rba_patch_repo "$1" "$2" "$3" "$4" "$5" "$(fixture_tpl_trees "$1")"
}

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
  "$(patch_repo "$S" "$D/stu.git" main "$MSG" false)"
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
  "$(patch_repo "$S" "$D/stu.git" main "$MSG" false)"
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
  "$(patch_repo "$S" "$D/stu.git" main "$MSG" true)"
check "nothing pushed"  "1"                "$(fixture_stu_count "$D")"
check "file unchanged"  "workflow v1"      "$(fixture_stu_show "$D" ci.yml)"

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
  "$(patch_repo "$S" "$D/stu.git" main "$MSG" false)"
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
  "$(patch_repo "$S" "$D/stu.git" main "$MSG" false)"
check "both edits present" "HEADER FIXED body footer student line" \
  "$(fixture_stu_show "$D" a.txt | tr '\n' ' ' | sed 's/ $//')"

# ── Case 6: idempotence — patching twice is a no-op the second time ──────────
S="$(fixture_scratch "$D")"
echo "idempotence:"
check "second run is uptodate" "uptodate" \
  "$(patch_repo "$S" "$D/stu.git" main "$MSG" false)"
check "no extra commit" "3" "$(fixture_stu_count "$D")"

# ── Case 7: student repo with no commits is skipped, not crashed ─────────────
D="$TMP/empty"
fixture_new "$D"
fixture_tpl_file "$D" ci.yml "workflow v1"$'\n'
fixture_tpl_commit "$D" "initial commit"
git init -q --bare "$D/stu.git"

S="$(fixture_scratch "$D")"
echo "empty student repo:"
check_prefix "skipped with reason" "skipped no branch 'main'" \
  "$(patch_repo "$S" "$D/stu.git" main "$MSG" false)"
check_prefix "reason carries git's own message" "skipped no branch 'main': fatal:" \
  "$(patch_repo "$S" "$D/stu.git" main "$MSG" false)"

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
  "$(patch_repo "$S" "$D/stu.git" main "$MSG" false)"

# ── Case 9 (I1): one root, but a REWRITTEN one → skip, do not overwrite ──────
# A student who squashes history still presents exactly one root, but its tree
# is their current work rather than the distribution snapshot. Merging would
# make diff(base->ours) empty and hand back the template tree verbatim,
# deleting every student-authored file.
D="$TMP/rewrittenroot"
fixture_new "$D"
fixture_tpl_file "$D" ci.yml   "workflow v1"$'\n'
fixture_tpl_file "$D" README.md "readme"$'\n'
fixture_tpl_commit "$D" "initial commit"
fixture_distribute_squashed "$D" Solution.java "class Solution {}"$'\n'
fixture_tpl_file "$D" ci.yml "workflow v2 FIXED"$'\n'
fixture_tpl_commit "$D" "fix CI"

S="$(fixture_scratch "$D")"
echo "rewritten root commit:"
check "exactly one root" "1" \
  "$(git -C "$S" fetch -q --no-tags "$D/stu.git" '+refs/heads/main:refs/rba/student' \
     && git -C "$S" rev-list --max-parents=0 --count refs/rba/student)"
check "skipped, not overwritten" "skipped root commit is not a snapshot of this template" \
  "$(patch_repo "$S" "$D/stu.git" main "$MSG" false)"
check "student file still present" "class Solution {}" \
  "$(fixture_stu_show "$D" Solution.java)"
check "repo left untouched" "1" "$(fixture_stu_count "$D")"

# ── Case 10 (I1): a genuine template-instantiated root is NOT skipped ────────
# Guards against the I1 check being so strict it rejects every real repo.
D="$TMP/rootok"
fixture_new "$D"
fixture_tpl_file "$D" ci.yml "workflow v1"$'\n'
fixture_tpl_commit "$D" "initial commit"
fixture_distribute "$D"
fixture_tpl_file "$D" ci.yml "workflow v2 FIXED"$'\n'
fixture_tpl_commit "$D" "fix CI"
fixture_tpl_file "$D" ci.yml "workflow v3 FIXED"$'\n'
fixture_tpl_commit "$D" "fix CI again"

S="$(fixture_scratch "$D")"
echo "root tree matches a NON-head template commit:"
check "template has 3 commits" "3" "$(fixture_tpl_trees "$S" | grep -c .)"
check "outcome is applied" "applied" \
  "$(patch_repo "$S" "$D/stu.git" main "$MSG" false)"

# ── Case 11 (I1): rewritten TEMPLATE history fails safe → skip ───────────────
S="$(fixture_scratch "$D")"
echo "template tree set unavailable (template history rewritten):"
check "skipped rather than merged" "skipped root commit is not a snapshot of this template" \
  "$(rba_patch_repo "$S" "$D/stu.git" main "$MSG" false "")"

# ── Case 12 (C1): commit-tree failure must skip, never delete the branch ─────
# An unguarded commit-tree leaves $new_commit empty, and ":refs/heads/main" is
# git's branch-DELETE refspec. errexit does not propagate out of the command
# substitution this function is always called from, so the guard is the only
# thing standing between a failed commit-tree and destroyed student work.
D="$TMP/commitfail"
fixture_new "$D"
fixture_tpl_file "$D" ci.yml "workflow v1"$'\n'
fixture_tpl_commit "$D" "initial commit"
fixture_distribute "$D"
fixture_tpl_file "$D" ci.yml "workflow v2 FIXED"$'\n'
fixture_tpl_commit "$D" "fix CI"

S="$(fixture_scratch "$D")"
before_sha="$(git -C "$D/stu.git" rev-parse refs/heads/main)"
git() {  # shadow only for this case
  if [[ "$*" == *" commit-tree "* ]]; then
    echo "fatal: simulated commit-tree failure" >&2
    return 128
  fi
  command git "$@"
}
echo "commit-tree fails:"
check_prefix "skipped with a reason" "skipped could not create patch commit" \
  "$(patch_repo "$S" "$D/stu.git" main "$MSG" false)"
unset -f git
check "branch still exists" "$before_sha" "$(git -C "$D/stu.git" rev-parse refs/heads/main)"
check "history intact" "1" "$(fixture_stu_count "$D")"
check "student content intact" "workflow v1" "$(fixture_stu_show "$D" ci.yml)"

# ── Case 13 (C1): garbage on merge-tree's first line must not reach a push ───
S="$(fixture_scratch "$D")"
git() {
  if [[ "$*" == *" merge-tree "* ]]; then
    echo "warning: unable to access '/nonexistent/.gitconfig'"
    return 0
  fi
  command git "$@"
}
echo "merge-tree emits a non-OID first line:"
check "skipped unparseable" "skipped unparseable merge result" \
  "$(patch_repo "$S" "$D/stu.git" main "$MSG" false)"
unset -f git
check "repo untouched" "1" "$(fixture_stu_count "$D")"

# ── Case 14 (minor): conflicted paths containing spaces stay separable ───────
D="$TMP/spacepath"
fixture_new "$D"
fixture_tpl_file "$D" "b.txt"       "v1"$'\n'
fixture_tpl_file "$D" "my file.txt" "v1"$'\n'
fixture_tpl_commit "$D" "initial commit"
fixture_distribute "$D"
fixture_tpl_file "$D" "b.txt"       "template"$'\n'
fixture_tpl_file "$D" "my file.txt" "template"$'\n'
fixture_tpl_commit "$D" "fix both"
fixture_stu_file "$D" "b.txt"       "student"$'\n'
fixture_stu_file "$D" "my file.txt" "student"$'\n'
fixture_stu_commit "$D" "student edits both"

S="$(fixture_scratch "$D")"
echo "conflicted path containing a space:"
check "paths are TAB-separated, one line" "conflict b.txt"$'\t'"my file.txt" \
  "$(patch_repo "$S" "$D/stu.git" main "$MSG" false)"

if (( FAILS == 0 )); then
  echo "test-patch: PASS"
else
  echo "test-patch: $FAILS FAILURE(S)"
  exit 1
fi
