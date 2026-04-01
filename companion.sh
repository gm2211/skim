#!/usr/bin/env bash
#
# Companion — file-based RPC for sandbox → host operations.
#
# Claude writes a command name to .companion/command
# This script runs the corresponding hardcoded command and writes output
# to .companion/result
#
# Usage:  bash companion.sh
# Stop:   Ctrl-C or kill the process
#
# Security:
#   - Commands are a fixed enum — no arguments, no interpolation, no eval
#   - Each command maps to an exact hardcoded invocation
#   - Self-locks on first run (chmod 444, chown root)
#

set -euo pipefail

SCRIPT_PATH="$(realpath "$0")"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="$PROJECT_DIR/.companion"
COMMAND_FILE="$AGENT_DIR/command"
RESULT_FILE="$AGENT_DIR/result"
STATUS_FILE="$AGENT_DIR/status"
PID_FILE="$AGENT_DIR/agent.pid"

# ──────────────────────────────────────────────
# Self-lockdown: runs once on first invocation
# ──────────────────────────────────────────────
lockdown() {
    local perms owner
    perms=$(stat -f "%OLp" "$SCRIPT_PATH" 2>/dev/null || stat -c "%a" "$SCRIPT_PATH" 2>/dev/null)
    owner=$(stat -f "%Su" "$SCRIPT_PATH" 2>/dev/null || stat -c "%U" "$SCRIPT_PATH" 2>/dev/null)

    if [[ "$perms" != "444" || "$owner" != "root" ]]; then
        echo "[companion] This script is not locked down yet."
        echo "[companion] Locking: chmod 444 + chown root"
        echo ""

        if [[ "$(uname)" == "Darwin" ]]; then
            sudo chown root:wheel "$SCRIPT_PATH"
        else
            sudo chown root:root "$SCRIPT_PATH"
        fi
        sudo chmod 444 "$SCRIPT_PATH"

        echo "[companion] Locked. Re-run with: bash $SCRIPT_PATH"
        exit 0
    fi
}

run_command() {
    case "$1" in
        check)
            cd src-tauri && cargo check 2>&1
            ;;
        test)
            cd src-tauri && cargo test 2>&1
            ;;
        clippy)
            cd src-tauri && cargo clippy 2>&1
            ;;
        fmt)
            cd src-tauri && cargo fmt 2>&1
            ;;
        release)
            bash release.sh 2>&1
            ;;
        release-sign)
            bash release.sh --sign 2>&1
            ;;
        open)
            cp -r src-tauri/target/aarch64-apple-darwin/release/bundle/macos/Skim.app /Applications/ 2>&1
            open /Applications/Skim.app 2>&1
            echo "Opened Skim.app"
            ;;
        *)
            echo "ERROR: Unknown command '$1'"
            echo "Available: check test clippy fmt release release-sign open"
            return 1
            ;;
    esac
}

cleanup() {
    rm -f "$PID_FILE" 2>/dev/null
    echo "stopped" > "$STATUS_FILE" 2>/dev/null
    echo "[companion] Stopped."
    exit 0
}
trap cleanup EXIT INT TERM

lockdown

mkdir -p "$AGENT_DIR"
echo $$ > "$PID_FILE"
echo "idle" > "$STATUS_FILE"
: > "$COMMAND_FILE"
: > "$RESULT_FILE"

echo "[companion] Running in $PROJECT_DIR"
echo "[companion] Commands: check test clippy fmt release release-sign open"
echo ""

while true; do
    if [[ -s "$COMMAND_FILE" ]]; then
        CMD=$(head -1 "$COMMAND_FILE" | tr -d '[:space:]' | tr -cd 'a-z-')
        : > "$COMMAND_FILE"

        if [[ -z "$CMD" ]]; then
            continue
        fi

        echo "[companion] Received: $CMD"
        echo "running" > "$STATUS_FILE"

        (
            cd "$PROJECT_DIR"
            run_command "$CMD"
            echo ""
            echo "EXIT_CODE=$?"
        ) > "$RESULT_FILE" 2>&1

        echo "done" > "$STATUS_FILE"
        echo "[companion] Done."
    fi
    sleep 0.5
done
