#!/usr/bin/env bash
# run-tests.sh — make-less test runner for the claude-obsidian machinery.
#
# Mirrors the Makefile `test` target so the suite runs on boxes without `make`
# (e.g. Windows). Prepends bin/pyshim so hardcoded `python3` calls resolve to a
# real interpreter. Exit 0 iff every test passes; non-zero otherwise.
#
# Usage: bash bin/run-tests.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
export PATH="$ROOT/bin/pyshim:$PATH"

TESTS=(
  "bash tests/test_allocate_address.sh"
  "python3 tests/test_tiling_check.py"
  "python3 tests/test_boundary_score.py"
  "python3 tests/test_bm25_index.py"
  "python3 tests/test_retrieve.py"
  "bash tests/test_wiki_lock.sh"
  "bash tests/test_concurrent_write.sh"
  "python3 tests/test_wiki_mode.py"
  "python3 tests/test_contextual_prefix.py"
)

pass=0; fail=0; failed=()
for t in "${TESTS[@]}"; do
  echo "=== $t ==="
  if $t; then pass=$((pass+1)); else fail=$((fail+1)); failed+=("$t"); fi
done

echo ""
echo "run-tests: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
  printf 'FAILED: %s\n' "${failed[@]}"
  exit 1
fi
echo "All tests passed."
