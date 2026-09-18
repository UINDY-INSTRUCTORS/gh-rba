#!/usr/bin/env bash
# End-to-end tests for `gh rba assignment create` — specifically the plan shown
# before anything is created, and the confirmation gating it.
#
# gh-rba runs as a SUBPROCESS with a `gh` stub on PATH. The stub logs every
# `gh repo create` it sees, so "nothing was created" is asserted against what
# the tool actually tried to do rather than against its own output.
#
# The interactive y/N branch is not exercised here: stdin is a pipe under the
# harness, so the tool takes the non-interactive path by design. That branch is
# the same idiom as `assignment patch`, which test-command.sh covers.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GHRBA="$HERE/../gh-rba"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILS=0
check_has() {  # $1 description, $2 needle, $3 haystack
  case "$3" in
    *"$2"*) echo "  ok   $1" ;;
    *) echo "  FAIL $1 — output did not contain '$2'"; FAILS=$((FAILS + 1)) ;;
  esac
}
check_lacks() {  # $1 description, $2 needle, $3 haystack
  case "$3" in
    *"$2"*) echo "  FAIL $1 — output should not contain '$2'"; FAILS=$((FAILS + 1)) ;;
    *) echo "  ok   $1" ;;
  esac
}
check() {  # $1 description, $2 expected, $3 actual
  if [[ "$2" == "$3" ]]; then echo "  ok   $1"
  else echo "  FAIL $1 — expected '$2', got '$3'"; FAILS=$((FAILS + 1)); fi
}

ORG="202610-SWEN-200"
C="$TMP/course"
mkdir -p "$C/stub"

cat > "$C/stub/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
case "${1:-}" in
  repo)
    # gh repo create <org/name> --template ... --private
    echo "$3" >> "$RBA_STUB_DIR/created.log"
    exit 0 ;;
  api) shift ;;
  *) exit 0 ;;
esac
endpoint=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --jq|--field|--method) shift 2 ;;
    -*) shift ;;
    *)  endpoint="$1"; shift ;;
  esac
done
case "$endpoint" in
  repos/*/topics|repos/*/collaborators/*) exit 0 ;;
  repos/*)  echo "true" ;;              # is_template
  users/*)  echo "${endpoint#users/}" ;; # login echoes back: user exists
  *) exit 0 ;;
esac
STUB
chmod +x "$C/stub/gh"

printf 'ORG=%s\nROSTER=roster.txt\n' "$ORG" > "$C/course.env"
printf 'alice\nbob\ncarol\ndave\n' > "$C/roster.txt"

run() {  # remaining args go to gh-rba
  : > "$C/stub/created.log"
  OUT=$(cd "$C" && PATH="$C/stub:$PATH" RBA_STUB_DIR="$C/stub" \
        bash "$GHRBA" assignment create "$@" 2>&1 </dev/null)
  RC=$?
  CREATED=$(wc -l < "$C/stub/created.log" | tr -d ' ')
  OUT=$(printf '%s' "$OUT" | tr -s ' ')
}

echo "assignment create — the plan:"
run --name icp-3
check_has "names the org and where it came from"   "org $ORG (ORG in course.env)" "$OUT"
check_has "names the template"                     "template $ORG/icp-3-template" "$OUT"
check_has "says the template came from convention" "(<name>-template convention)" "$OUT"
check_has "names the roster and its source"        "roster roster.txt (ROSTER in course.env)" "$OUT"
check_has "says which mode"                        "individual — one repo per student" "$OUT"
check_has "counts the repos"                       "repos 4 private repo(s)" "$OUT"
check_has "shows example repo names"               "icp-3-alice, icp-3-bob, icp-3-carol, …" "$OUT"

echo "the gate:"
check "refuses without confirmation"  "1" "$RC"
check_has "explains how to proceed"   "Pass --yes to proceed non-interactively." "$OUT"
check "and creates NOTHING"           "0" "$CREATED"
check_lacks "does not validate first" "Validating GitHub usernames" "$OUT"

run --name icp-3 --yes
check "--yes proceeds"            "0" "$RC"
check "and creates every repo"    "4" "$CREATED"
check_has "still shows the plan"  "repos 4 private repo(s)" "$OUT"

echo "provenance is honest:"
run --name icp-3 --template "$ORG/something-else" --yes
check_has "an explicit template says so" "template $ORG/something-else (--template)" "$OUT"

printf 'TEMPLATE_icp_3="borrowed-template"\n' >> "$C/course.env"
run --name icp-3
check_has "a config override is named" "TEMPLATE_icp_3 in course.env" "$OUT"
check_has "and is the template used"   "template $ORG/borrowed-template" "$OUT"
sed -i.bak '/TEMPLATE_icp_3/d' "$C/course.env"

printf 'team-1, alice, bob\nteam-2, carol, dave\n' > "$C/teams.txt"
run --name icp-3 --teams teams.txt
check_has "teams mode is named"   "teams — one repo per team" "$OUT"
check_has "and counts teams"      "repos 2 private repo(s): icp-3-team-1, icp-3-team-2" "$OUT"
check_has "roster source is the flag" "roster teams.txt (--teams)" "$OUT"

if [[ "$FAILS" -eq 0 ]]; then echo "test-create: PASS"; else echo "test-create: FAIL ($FAILS)"; exit 1; fi
