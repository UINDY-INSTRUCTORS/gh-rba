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
