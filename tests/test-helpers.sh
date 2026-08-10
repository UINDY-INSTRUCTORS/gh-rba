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

echo "rba_remote_url:"
SSH_U="git@github.com:org/repo.git"
HTTPS_U="https://github.com/org/repo.git"
check "ssh protocol selects ssh_url"     "$SSH_U"   "$(rba_remote_url "$SSH_U" "$HTTPS_U" ssh)"
check "https protocol selects clone_url" "$HTTPS_U" "$(rba_remote_url "$SSH_U" "$HTTPS_U" https)"
check "unknown protocol defaults https"  "$HTTPS_U" "$(rba_remote_url "$SSH_U" "$HTTPS_U" '')"

if (( FAILS == 0 )); then
  echo "test-helpers: PASS"
else
  echo "test-helpers: $FAILS FAILURE(S)"
  exit 1
fi
