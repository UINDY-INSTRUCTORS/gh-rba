#!/usr/bin/env bash
# End-to-end tests for `gh rba assignment patch` — the command wrapper, not just
# the merge core. Covers flag handling, the confirmation prompt, the jq TSV
# extraction, the summary counters and the EXIT-CODE CONTRACT.
#
# gh-rba is run as a SUBPROCESS, never sourced: cmd_assignment_patch installs a
# global `trap ... EXIT` that would stomp this file's own fixture-cleanup trap,
# and the exit code is precisely what we are asserting on.
#
# `gh` is a stub on PATH serving canned JSON; every "remote" is a local bare
# repo. No network, no GitHub.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GHRBA="$HERE/../gh-rba"

command -v jq >/dev/null 2>&1 || { echo "  FAIL jq is required for these tests"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

REAL_GIT="$(command -v git)"
ORG="202610-CSCI-350"
ASSIGN="hw01"
TPL_FULL="${ORG}/${ASSIGN}-template"

FAILS=0
check() {  # $1 description, $2 expected, $3 actual
  if [[ "$2" == "$3" ]]; then
    echo "  ok   $1"
  else
    echo "  FAIL $1 — expected '$2', got '$3'"
    FAILS=$((FAILS + 1))
  fi
}

check_has() {  # $1 description, $2 needle, $3 haystack
  case "$3" in
    *"$2"*) echo "  ok   $1" ;;
    *) echo "  FAIL $1 — output did not contain '$2'"; FAILS=$((FAILS + 1)) ;;
  esac
}

check_lacks() {  # $1 description, $2 needle, $3 haystack
  case "$3" in
    *"$2"*) echo "  FAIL $1 — output unexpectedly contained '$2'"; FAILS=$((FAILS + 1)) ;;
    *) echo "  ok   $1" ;;
  esac
}

# ── Fixture builders ─────────────────────────────────────────────────────────

ITEMS=""   # accumulated search-API items for the case under construction

new_case() {  # $1 case dir
  C="$1"
  rm -rf "$C"
  mkdir -p "$C/stub"
  ITEMS=""

  "$REAL_GIT" init -q "$C/tpl"
  "$REAL_GIT" -C "$C/tpl" symbolic-ref HEAD refs/heads/main
  "$REAL_GIT" -C "$C/tpl" config user.email instructor@example.edu
  "$REAL_GIT" -C "$C/tpl" config user.name  "Instructor"

  echo https > "$C/stub/git_protocol"

  # `gh` stub: serves canned JSON, honours --jq, 404s on anything unknown.
  cat > "$C/stub/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
if [[ "${1:-}" == "config" ]]; then
  cat "$RBA_STUB_DIR/git_protocol" 2>/dev/null
  exit 0
fi
[[ "${1:-}" == "api" ]] || { echo "gh stub: unsupported invocation: $*" >&2; exit 1; }
shift
endpoint=""; jqexpr=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --jq) jqexpr="$2"; shift 2 ;;
    -*)   shift ;;
    *)    endpoint="$1"; shift ;;
  esac
done
file=""
case "$endpoint" in
  search/repositories*) file="$RBA_STUB_DIR/search.json" ;;
  repos/*) file="$RBA_STUB_DIR/repo-$(printf '%s' "${endpoint#repos/}" | tr '/' '_').json" ;;
esac
if [[ -z "$file" || ! -f "$file" ]]; then
  echo "gh: Not Found (HTTP 404)" >&2
  exit 1
fi
if [[ -n "$jqexpr" ]]; then jq -r "$jqexpr" < "$file"; else cat "$file"; fi
STUB
  chmod +x "$C/stub/gh"

  # `git` passthrough that can be told to fail `commit-tree` — the C1 fixture.
  cat > "$C/stub/git" <<'STUB'
#!/usr/bin/env bash
if [[ -n "${RBA_STUB_FAIL_COMMIT_TREE:-}" && " $* " == *" commit-tree "* ]]; then
  echo "fatal: simulated commit-tree failure" >&2
  exit 128
fi
exec "$RBA_REAL_GIT" "$@"
STUB
  chmod +x "$C/stub/git"

  cat > "$C/stub/repo-$(printf '%s' "$TPL_FULL" | tr '/' '_').json" <<EOF
{"full_name":"${TPL_FULL}","default_branch":"main","is_template":true,
 "ssh_url":"${C}/tpl","clone_url":"${C}/tpl"}
EOF
}

tpl_file()   { mkdir -p "$(dirname "$C/tpl/$1")"; printf '%s' "$2" > "$C/tpl/$1"; }
tpl_commit() { "$REAL_GIT" -C "$C/tpl" add -A; "$REAL_GIT" -C "$C/tpl" commit -qm "$1"; }

# Register a student repo. $2 = provenance recorded on GitHub:
#   "" → template_repository is null;  otherwise the full_name to report.
add_student() {  # $1 username, $2 provenance
  local user="$1" prov="$2"
  local bare="$C/stu-$user.git" work="$C/work-$user"
  "$REAL_GIT" init -q --bare "$bare"
  "$REAL_GIT" clone -q "$bare" "$work" 2>/dev/null
  "$REAL_GIT" -C "$work" symbolic-ref HEAD refs/heads/main
  "$REAL_GIT" -C "$work" config user.email "$user@example.edu"
  "$REAL_GIT" -C "$work" config user.name  "$user"
  ( cd "$C/tpl" && "$REAL_GIT" archive HEAD ) | tar -x -C "$work"
  "$REAL_GIT" -C "$work" add -A
  "$REAL_GIT" -C "$work" commit -qm "Initial commit"
  "$REAL_GIT" -C "$work" push -q origin HEAD:refs/heads/main
  register_student "$user" "$prov"
}

register_student() {  # $1 username, $2 provenance
  local user="$1" prov="$2" repo="${ASSIGN}-$1"
  local provjson="null"
  [[ -z "$prov" ]] || provjson="{\"full_name\":\"$prov\"}"
  cat > "$C/stub/repo-$(printf '%s' "${ORG}/${repo}" | tr '/' '_').json" <<EOF
{"full_name":"${ORG}/${repo}","default_branch":"main","template_repository":${provjson}}
EOF
  [[ -z "$ITEMS" ]] || ITEMS="${ITEMS},"
  ITEMS="${ITEMS}{\"name\":\"${repo}\",\"full_name\":\"${ORG}/${repo}\",\"default_branch\":\"main\",\"ssh_url\":\"$C/stu-$user.git\",\"clone_url\":\"$C/stu-$user.git\"}"
}

stu_file()   { mkdir -p "$(dirname "$C/work-$1/$2")"; printf '%s' "$3" > "$C/work-$1/$2"; }
stu_commit() {
  "$REAL_GIT" -C "$C/work-$1" add -A
  "$REAL_GIT" -C "$C/work-$1" commit -qm "$2"
  "$REAL_GIT" -C "$C/work-$1" push -q origin HEAD:refs/heads/main
}
stu_show()  { "$REAL_GIT" -C "$C/stu-$1.git" cat-file blob "main:$2"; }
stu_count() { "$REAL_GIT" -C "$C/stu-$1.git" rev-list --count main; }
stu_sha()   { "$REAL_GIT" -C "$C/stu-$1.git" rev-parse refs/heads/main; }

seal_case() {
  local n
  n=$(printf '%s' "$ITEMS" | tr ',' '\n' | grep -c '"name"' || true)
  printf '{"total_count":%s,"items":[%s]}\n' "$n" "$ITEMS" > "$C/stub/search.json"
}

# Run gh-rba as a subprocess. stdin is /dev/null so the interactive-prompt path
# is deterministic regardless of how the suite itself was launched.
OUT=""; RC=0; FAIL_COMMIT_TREE=""
run_patch() {  # gh-rba flags...
  OUT=$(cd "$C" && PATH="$C/stub:$PATH" RBA_STUB_DIR="$C/stub" RBA_REAL_GIT="$REAL_GIT" \
        RBA_STUB_FAIL_COMMIT_TREE="$FAIL_COMMIT_TREE" \
        bash "$GHRBA" assignment patch "$ASSIGN" --org "$ORG" "$@" 2>&1 </dev/null)
  RC=$?
  OUT=$(printf '%s' "$OUT" | tr -s ' ')   # collapse column padding
}

# ── Case A: clean all-success run exits 0 ────────────────────────────────────
# Regression test for the `local scratch` + EXIT-trap bug, where a wholly
# successful run still exited 1.
new_case "$TMP/clean"
tpl_file ci.yml "workflow v1"$'\n'
tpl_file a.txt  "a"$'\n'"b"$'\n'"c"$'\n'
tpl_commit "initial commit"
add_student alice "$TPL_FULL"
add_student bob   "$TPL_FULL"
tpl_file ci.yml "workflow v2 FIXED"$'\n'
tpl_commit "fix CI"
stu_file alice a.txt "a"$'\n'"b"$'\n'"c"$'\n'"ALICE"$'\n'
stu_commit alice "alice works"
seal_case

echo "clean all-success run:"
run_patch --yes
check      "exit code is 0"            "0" "$RC"
check_has  "alice applied"             "✓ alice applied" "$OUT"
check_has  "bob applied"               "✓ bob applied" "$OUT"
check_has  "summary counts"            "2 applied, 0 up to date, 0 conflict, 0 skipped" "$OUT"
check_lacks "no manual-attention block" "Needs manual attention" "$OUT"
check      "template fix reached alice" "workflow v2 FIXED" "$(stu_show alice ci.yml)"
check      "alice work survived"        "a b c ALICE" \
  "$(stu_show alice a.txt | tr '\n' ' ' | sed 's/ $//')"

# ── Case B: second run reports already up to date ────────────────────────────
echo "second run:"
run_patch --yes
check     "exit code is 0"   "0" "$RC"
check_has "alice up to date" "─ alice already up to date" "$OUT"
check_has "summary counts"   "0 applied, 2 up to date, 0 conflict, 0 skipped" "$OUT"

# ── Case C: dry run with a conflict → exit 1, nothing pushed ─────────────────
new_case "$TMP/dryconflict"
tpl_file ci.yml        "workflow v1"$'\n'
tpl_file "lab notes.md" "notes v1"$'\n'
tpl_commit "initial commit"
add_student alice "$TPL_FULL"
add_student bob   "$TPL_FULL"
tpl_file ci.yml        "workflow v2 FIXED"$'\n'
tpl_file "lab notes.md" "notes v2 FIXED"$'\n'
tpl_commit "fix CI"
stu_file bob ci.yml        "workflow BOB VERSION"$'\n'
stu_file bob "lab notes.md" "notes BOB VERSION"$'\n'
stu_commit bob "bob edits both"
seal_case
alice_before="$(stu_sha alice)"; bob_before="$(stu_sha bob)"

echo "dry run with a conflict:"
run_patch --dry-run
check      "exit code is 1"          "1" "$RC"
check_has  "dry-run banner"          "DRY RUN — no changes will be pushed" "$OUT"
check_has  "alice reads 'would apply'" "✓ alice would apply" "$OUT"
check_has  "bob conflicts"           "⚠ bob CONFLICT (skipped)" "$OUT"
check_has  "summary says would be applied" "1 would be applied, 0 up to date, 1 conflict, 0 skipped" "$OUT"
check_has  "manual attention block"  "Needs manual attention:" "$OUT"
check_has  "conflicting path listed" "bob ci.yml" "$OUT"
# One path PER LINE: a path containing a space must not read as two paths.
check_has  "space-bearing path on its own line" $'\n'" bob lab notes.md" "$OUT"
check      "alice not pushed"        "$alice_before" "$(stu_sha alice)"
check      "bob not pushed"          "$bob_before"   "$(stu_sha bob)"

# ── Case D: non-interactive without --yes refuses ────────────────────────────
echo "non-interactive without --yes:"
run_patch
check     "exit code is 1"     "1" "$RC"
check_has "refusal message"    "Refusing to patch 2 repos without confirmation. Pass --yes to proceed non-interactively." "$OUT"
check     "alice untouched"    "$alice_before" "$(stu_sha alice)"
check     "bob untouched"      "$bob_before"   "$(stu_sha bob)"

# ── Case E: --yes with a mix of applied and conflict ─────────────────────────
echo "real run, applied + conflict:"
run_patch --yes
check      "exit code is 1"        "1" "$RC"
check_has  "alice applied"         "✓ alice applied" "$OUT"
check_has  "bob conflicts"         "⚠ bob CONFLICT (skipped)" "$OUT"
check_has  "summary counts"        "1 applied, 0 up to date, 1 conflict, 0 skipped" "$OUT"
check      "alice got the fix"     "workflow v2 FIXED"     "$(stu_show alice ci.yml)"
check      "bob left untouched"    "workflow BOB VERSION"  "$(stu_show bob ci.yml)"
check      "bob's SHA unchanged"   "$bob_before"           "$(stu_sha bob)"

# ── Case F (C1): commit-tree failure skips and does NOT delete the branch ────
new_case "$TMP/commitfail"
tpl_file ci.yml "workflow v1"$'\n'
tpl_commit "initial commit"
add_student alice "$TPL_FULL"
tpl_file ci.yml "workflow v2 FIXED"$'\n'
tpl_commit "fix CI"
seal_case
alice_before="$(stu_sha alice)"

echo "commit-tree fails (C1):"
FAIL_COMMIT_TREE=1; run_patch --yes; FAIL_COMMIT_TREE=""
check     "exit code is 1"        "1" "$RC"
check_has "skip reason surfaced"  "could not create patch commit" "$OUT"
check_has "counted as skipped"    "0 applied, 0 up to date, 0 conflict, 1 skipped" "$OUT"
check     "branch NOT deleted"    "$alice_before" "$(stu_sha alice)"
check     "content intact"        "workflow v1"   "$(stu_show alice ci.yml)"

# ── Case G (I1): a rewritten root commit is skipped ──────────────────────────
new_case "$TMP/rewrittenroot"
tpl_file ci.yml    "workflow v1"$'\n'
tpl_file README.md "readme"$'\n'
tpl_commit "initial commit"
add_student alice "$TPL_FULL"
# alice squashes everything into one root that also contains her own work.
stu_file alice Solution.java "class Solution {}"$'\n'
"$REAL_GIT" -C "$C/work-alice" add -A
"$REAL_GIT" -C "$C/work-alice" commit -qm "alice works"
"$REAL_GIT" -C "$C/work-alice" checkout -q --orphan squashed
"$REAL_GIT" -C "$C/work-alice" add -A
"$REAL_GIT" -C "$C/work-alice" commit -qm "squashed history"
"$REAL_GIT" -C "$C/work-alice" push -qf origin HEAD:refs/heads/main
tpl_file ci.yml "workflow v2 FIXED"$'\n'
tpl_commit "fix CI"
seal_case
alice_before="$(stu_sha alice)"

echo "rewritten root commit (I1):"
run_patch --yes
check     "exit code is 1"       "1" "$RC"
check_has "skip reason surfaced" "root commit is not a snapshot of this template" "$OUT"
check     "repo untouched"       "$alice_before"     "$(stu_sha alice)"
check     "student file survives" "class Solution {}" "$(stu_show alice Solution.java)"

# ── Case H (I2): provenance mismatch is skipped, not merged ──────────────────
new_case "$TMP/wrongtemplate"
tpl_file ci.yml "workflow v1"$'\n'
tpl_commit "initial commit"
add_student alice "${ORG}/some-other-template"
add_student bob   ""
tpl_file ci.yml "workflow v2 FIXED"$'\n'
tpl_commit "fix CI"
seal_case
alice_before="$(stu_sha alice)"; bob_before="$(stu_sha bob)"

echo "template provenance (I2):"
run_patch --yes
check     "exit code is 1"          "1" "$RC"
check_has "mismatch is explained"   "created from a different template (${ORG}/some-other-template)" "$OUT"
check_has "null provenance skipped" "GitHub records no template for this repo" "$OUT"
check_has "both counted as skipped" "0 applied, 0 up to date, 0 conflict, 2 skipped" "$OUT"
check     "alice untouched"         "$alice_before" "$(stu_sha alice)"
check     "bob untouched"           "$bob_before"   "$(stu_sha bob)"

# ── Case I: unreachable student remote reports git's own error ───────────────
new_case "$TMP/badremote"
tpl_file ci.yml "workflow v1"$'\n'
tpl_commit "initial commit"
add_student alice "$TPL_FULL"
tpl_file ci.yml "workflow v2 FIXED"$'\n'
tpl_commit "fix CI"
rm -rf "$C/stu-alice.git"
seal_case

echo "unreachable student remote (I3):"
run_patch --yes
check     "exit code is 1"      "1" "$RC"
check_has "git's own message"   "does not appear to be a git repository" "$OUT"

# ── Case J: a missing template dies with gh's real error ────────────────────
new_case "$TMP/notemplate"
tpl_file ci.yml "workflow v1"$'\n'
tpl_commit "initial commit"
add_student alice "$TPL_FULL"
seal_case
rm -f "$C/stub/repo-$(printf '%s' "$TPL_FULL" | tr '/' '_').json"

echo "template not readable:"
run_patch --yes
check     "exit code is 1"    "1" "$RC"
check_has "gh's real error"   "Not Found (HTTP 404)" "$OUT"
check_has "names the repo"    "Could not read template repo '${TPL_FULL}'" "$OUT"

if (( FAILS == 0 )); then
  echo "test-command: PASS"
else
  echo "test-command: $FAILS FAILURE(S)"
  exit 1
fi
