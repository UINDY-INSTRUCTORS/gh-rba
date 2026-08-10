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
