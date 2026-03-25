#!/usr/bin/env bash
set -uo pipefail

OUTPUT="test_output.txt"
SIGNAL="test_signal.txt"

cd "$(dirname "$0")"

case "${1:-}" in
  read)
    cat "$OUTPUT" 2>/dev/null || echo "No test output yet"
    ;;
  wait)
    # Wait for FRESH results — check file modification time
    local_ts=$(stat -f %m "$OUTPUT" 2>/dev/null || stat -c %Y "$OUTPUT" 2>/dev/null || echo 0)
    while true; do
      sleep 3
      new_ts=$(stat -f %m "$OUTPUT" 2>/dev/null || stat -c %Y "$OUTPUT" 2>/dev/null || echo 0)
      if [ "$new_ts" != "$local_ts" ] && grep -q "TEST_DONE" "$OUTPUT" 2>/dev/null; then
        cat "$OUTPUT"
        exit 0
      fi
    done
    ;;
  rerun)
    echo "READY" > "$SIGNAL"
    echo "Signaled rerun."
    # Now wait for fresh results
    local_ts=$(stat -f %m "$OUTPUT" 2>/dev/null || stat -c %Y "$OUTPUT" 2>/dev/null || echo 0)
    while true; do
      sleep 3
      new_ts=$(stat -f %m "$OUTPUT" 2>/dev/null || stat -c %Y "$OUTPUT" 2>/dev/null || echo 0)
      if [ "$new_ts" != "$local_ts" ] && grep -q "TEST_DONE" "$OUTPUT" 2>/dev/null; then
        cat "$OUTPUT"
        exit 0
      fi
    done
    ;;
  *)
    echo "Usage: $0 {read|wait|rerun}"
    ;;
esac
