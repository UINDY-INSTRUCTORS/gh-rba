#!/usr/bin/env bash
# Unit tests for rba_lookup_user's three-way outcome. No network: `gh` is
# replaced by a stub on PATH that replays canned responses.
#
# The case that earns its keep is the third one. Treating a transient failure
# as "no such user" is what aborted a 36-name fan-out on 2026-09-03 and sent
# the operator off to fix a roster that was already correct.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
PATH="$TMP/bin:$PATH"

# A stub `gh` whose behaviour is chosen by $STUB_MODE. It also counts calls,
# so the retry behaviour can be asserted rather than assumed.
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo x >> "$STUB_CALLS"
case "$STUB_MODE" in
  ok)        echo "$STUB_LOGIN"; exit 0 ;;
  notfound)  echo '{"message":"Not Found","status":"404"}'; exit 1 ;;
  ratelimit) echo "API rate limit exceeded"; exit 1 ;;
  network)   echo "dial tcp: i/o timeout"; exit 1 ;;
esac
STUB
chmod +x "$TMP/bin/gh"

run() {  # $1 mode, $2 login -> "<rc>:<stdout>"
  export STUB_MODE="$1" STUB_LOGIN="${2:-}" STUB_CALLS="$TMP/calls"
  : > "$STUB_CALLS"
  local out rc
  out="$(rba_lookup_user someuser)"; rc=$?
  printf '%s:%s' "$rc" "$out"
}
calls() { wc -l < "$TMP/calls" | tr -d ' '; }

echo "rba_lookup_user:"

check "existing user -> rc 0 and the login" "0:someuser" "$(run ok someuser)"
check "  no retries needed"                 "1"          "$(calls)"

check "a real 404 -> rc 1"                  "1:"         "$(run notfound)"
check "  a 404 is not retried"              "1"          "$(calls)"

r="$(run ratelimit)"
check "rate limit -> rc 2, NOT rc 1"        "2"          "${r%%:*}"
check "  retried three times"               "3"          "$(calls)"

r="$(run network)"
check "network error -> rc 2, NOT rc 1"     "2"          "${r%%:*}"

echo "renames:"
check "GitHub answering under another name is reported" "0:alainshimwa" \
      "$(run ok alainshimwa)"

if (( FAILS == 0 )); then
  echo "test-lookup: PASS"
else
  echo "test-lookup: $FAILS FAILURE(S)"
  exit 1
fi
