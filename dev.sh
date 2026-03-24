#!/usr/bin/env bash
set -euo pipefail

# Install missing build dependencies
install_if_missing() {
  if ! command -v "$1" &>/dev/null; then
    echo "Installing $1..."
    ${@:2}
  fi
}

if ! command -v brew &>/dev/null; then
  echo "Homebrew required. Install: https://brew.sh"
  exit 1
fi

install_if_missing rustc  bash -c 'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y && source "$HOME/.cargo/env"'
install_if_missing pnpm   brew install pnpm
install_if_missing cmake  brew install cmake

# Ensure cargo is on PATH (fresh rustup install)
[[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"

pnpm install --silent 2>/dev/null

# --clean flag forces a full rebuild
if [[ "${1:-}" == "--clean" ]]; then
  echo "Cleaning build cache..."
  cd src-tauri && cargo clean && cd ..
fi

pnpm tauri dev
