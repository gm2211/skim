#!/usr/bin/env bash
set -uo pipefail

OUTPUT="test_output.txt"
SIGNAL="test_signal.txt"
TEST_PATTERN="${1:-test_json_schema}"

cd "$(dirname "$0")"

run_tests() {
  echo "=== Running tests: $TEST_PATTERN ==="
  echo "=== $(date) ===" > "$OUTPUT"
  LLAMA_LOG_LEVEL=4 cargo test "$TEST_PATTERN" -- --nocapture >> "$OUTPUT" 2>&1 || true
  echo "" >> "$OUTPUT"
  echo "---TEST_DONE---" >> "$OUTPUT"
  # Clear signal file so we wait fresh
  echo "" > "$SIGNAL"
  echo "Tests done. Touch $SIGNAL with READY to rerun."
}

run_tests

while true; do
  while ! grep -q "READY" "$SIGNAL" 2>/dev/null; do
    sleep 2
  done
  echo "Detected READY — rerunning..."
  run_tests
done
