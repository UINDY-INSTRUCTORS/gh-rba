#!/usr/bin/env bash
# Tests for `gh rba repos clone`, which had no coverage before --into was added.
#
# Same conventions as test-command.sh: gh-rba runs as a SUBPROCESS, `gh` is a
# stub on PATH, and every "remote" is a local bare repo. No network.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GHRBA="$HERE/../gh-rba"

command -v jq >/dev/null 2>&1 || { echo "  FAIL jq is required for these tests"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

REAL_GIT="$(command -v git)"
ORG="202610-CSCI-350"
ASSIGN="hw02"
USERS=(aboubacars22 shimwaa)

FAILS=0
check() {  # $1 description, $2 expected, $3 actual
  if [[ "$2" == "$3" ]]; then echo "  ok   $1"
  else echo "  FAIL $1 — expected '$2', got '$3'"; FAILS=$((FAILS + 1)); fi
}
check_has() {  # $1 description, $2 needle, $3 haystack
  case "$3" in
    *"$2"*) echo "  ok   $1" ;;
    *) echo "  FAIL $1 — output did not contain '$2'"; FAILS=$((FAILS + 1)) ;;
  esac
}

# ── fixture ───────────────────────────────────────────────────────────────────
C="$TMP/case"; mkdir -p "$C/stub" "$C/run"

items=""
for u in "${USERS[@]}"; do
  bare="$C/stu-$u.git"
  "$REAL_GIT" init -q --bare "$bare"
  w="$C/w-$u"; "$REAL_GIT" clone -q "$bare" "$w" 2>/dev/null
  "$REAL_GIT" -C "$w" symbolic-ref HEAD refs/heads/main
  "$REAL_GIT" -C "$w" config user.email "$u@example.edu"
  "$REAL_GIT" -C "$w" config user.name "$u"
  echo "$u" > "$w/WHO"
  "$REAL_GIT" -C "$w" add -A
  "$REAL_GIT" -C "$w" commit -qm init
  "$REAL_GIT" -C "$w" push -q origin HEAD:main 2>/dev/null
  items="${items}{\"full_name\":\"${ORG}/${ASSIGN}-${u}\"},"
done
printf '{"items":[%s]}' "${items%,}" > "$C/stub/search.json"

# gh stub: `api` serves the canned search; `repo clone` clones the local bare.
cat > "$C/stub/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
if [[ "${1:-}" == "repo" && "${2:-}" == "clone" ]]; then
  full="$3"; dest="$4"
  user="${full##*-}"
  exec "$RBA_REAL_GIT" clone -q "$RBA_STUB_DIR/../stu-$user.git" "$dest"
fi
[[ "${1:-}" == "api" ]] || { echo "gh stub: unsupported: $*" >&2; exit 1; }
shift
endpoint=""; jqexpr=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --jq) jqexpr="$2"; shift 2 ;;
    -*) shift ;;
    *) endpoint="$1"; shift ;;
  esac
done
case "$endpoint" in
  search/repositories*) f="$RBA_STUB_DIR/search.json" ;;
  *) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
esac
if [[ -n "$jqexpr" ]]; then jq -r "$jqexpr" < "$f"; else cat "$f"; fi
STUB
chmod +x "$C/stub/gh"

echo "ORG=\"$ORG\"" > "$C/run/course.env"

run() { ( cd "$C/run" && PATH="$C/stub:$PATH" RBA_STUB_DIR="$C/stub" \
          RBA_REAL_GIT="$REAL_GIT" bash "$GHRBA" "$@" 2>&1 ); }

# ── 1. default destination is still ./<assignment>/ ───────────────────────────
out="$(run repos clone "$ASSIGN")"
check "default: creates ./hw02/aboubacars22" "yes" \
      "$([[ -f "$C/run/$ASSIGN/aboubacars22/WHO" ]] && echo yes || echo no)"
check "default: creates ./hw02/shimwaa" "yes" \
      "$([[ -f "$C/run/$ASSIGN/shimwaa/WHO" ]] && echo yes || echo no)"

# ── 2. re-running skips, does not clobber ─────────────────────────────────────
echo "LOCAL EDIT" > "$C/run/$ASSIGN/shimwaa/WHO"
out="$(run repos clone "$ASSIGN")"
check_has "rerun: reports skipping" "skipping shimwaa" "$out"
check "rerun: local edit survives" "LOCAL EDIT" "$(cat "$C/run/$ASSIGN/shimwaa/WHO")"

# ── 3. --into puts them exactly there, no assignment subdir ───────────────────
out="$(run repos clone "$ASSIGN" --into repos/hw02)"
check "--into: creates repos/hw02/aboubacars22" "yes" \
      "$([[ -f "$C/run/repos/hw02/aboubacars22/WHO" ]] && echo yes || echo no)"
check "--into: does NOT nest an extra hw02" "no" \
      "$([[ -d "$C/run/repos/hw02/hw02" ]] && echo yes || echo no)"

# ── 4. a bare --into is an error, not an unbound-variable crash ───────────────
out="$(run repos clone "$ASSIGN" --into)"
check_has "--into with no value explains itself" "--into needs a directory" "$out"

# ── 5. trailing slash is tolerated, and does not double up ────────────────────
out="$(run repos clone "$ASSIGN" --into "graded/")"
check "--into with trailing slash" "yes" \
      "$([[ -f "$C/run/graded/shimwaa/WHO" ]] && echo yes || echo no)"
check_has "--into slash: message has no //" "Cloning into graded/" "$out"

if (( FAILS == 0 )); then echo "  test-clone.sh PASSED"; else echo "  test-clone.sh: $FAILS failure(s)"; exit 1; fi
