#!/usr/bin/env bash
#
# Build Agent — file-based RPC for build/test commands only.
#
# Claude writes a command name to .build_agent/command
# This script runs the corresponding hardcoded command and writes output
# to .build_agent/result
#
# Usage:  ./build_agent.sh
# Stop:   Ctrl-C or kill the process
#
# Security:
#   - Commands are a fixed enum — no arguments, no interpolation, no eval
#   - Each command maps to an exact hardcoded invocation
#   - All execution is pinned to this directory
#   - Once finalized: chmod 444 build_agent.sh
#

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="$PROJECT_DIR/.build_agent"
COMMAND_FILE="$AGENT_DIR/command"
RESULT_FILE="$AGENT_DIR/result"
STATUS_FILE="$AGENT_DIR/status"
PID_FILE="$AGENT_DIR/agent.pid"

run_command() {
    case "$1" in
        check)
            cargo check 2>&1
            ;;
        build)
            cargo build 2>&1
            ;;
        build-release)
            cargo build --release 2>&1
            ;;
        test)
            cargo test 2>&1
            ;;
        clippy)
            cargo clippy 2>&1
            ;;
        fmt)
            cargo fmt 2>&1
            ;;
        fmt-check)
            cargo fmt --check 2>&1
            ;;
        tauri-dev)
            npx tauri dev 2>&1
            ;;
        tauri-build)
            npx tauri build 2>&1
            ;;
        *)
            echo "ERROR: Unknown command '$1'"
            echo "Available: check build build-release test clippy fmt fmt-check tauri-dev tauri-build"
            return 1
            ;;
    esac
}

cleanup() {
    rm -f "$PID_FILE"
    echo "stopped" > "$STATUS_FILE"
    echo "[build_agent] Stopped."
    exit 0
}
trap cleanup EXIT INT TERM

mkdir -p "$AGENT_DIR"
echo $$ > "$PID_FILE"
echo "idle" > "$STATUS_FILE"
: > "$COMMAND_FILE"
: > "$RESULT_FILE"

echo "[build_agent] Running in $PROJECT_DIR"
echo "[build_agent] Commands: check build build-release test clippy fmt fmt-check tauri-dev tauri-build"
echo ""

while true; do
    if [[ -s "$COMMAND_FILE" ]]; then
        # Read and sanitize: strip whitespace, take only first word
        CMD=$(head -1 "$COMMAND_FILE" | tr -d '[:space:]' | tr -cd 'a-z-')
        : > "$COMMAND_FILE"

        if [[ -z "$CMD" ]]; then
            continue
        fi

        echo "[build_agent] Received: $CMD"
        echo "running" > "$STATUS_FILE"

        (
            cd "$PROJECT_DIR"
            run_command "$CMD"
            echo ""
            echo "EXIT_CODE=$?"
        ) > "$RESULT_FILE" 2>&1

        echo "done" > "$STATUS_FILE"
        echo "[build_agent] Done."
    fi
    sleep 0.5
done
