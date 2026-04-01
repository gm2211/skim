#!/usr/bin/env bash
set -euo pipefail

# ───────────────────────────────────────────────────────
# release.sh — Build a distributable macOS .app for Skim
# ───────────────────────────────────────────────────────

# llama.cpp uses std::filesystem which requires macOS 10.15+
# Must be set before any build tool runs
export MACOSX_DEPLOYMENT_TARGET="10.15"
export CMAKE_OSX_DEPLOYMENT_TARGET="10.15"
# Force C++ compiler to target 10.15 (cmake may ignore env vars with cached builds)
export CXXFLAGS="${CXXFLAGS:-} -mmacosx-version-min=10.15"
export CFLAGS="${CFLAGS:-} -mmacosx-version-min=10.15"

SIGN=false
UNIVERSAL=false
TARGET=""

usage() {
  cat <<EOF
Usage: ./release.sh [OPTIONS]

Options:
  --target <triple>   Rust target triple (default: auto-detect from uname -m)
  --universal         Build universal binary (Intel + Apple Silicon)
  --sign              Enable code signing (default: unsigned for local dev)
  -h, --help          Show this help message

Examples:
  ./release.sh                          # Build for current architecture, unsigned
  ./release.sh --universal              # Universal binary, unsigned
  ./release.sh --sign                   # Signed build for current architecture
  ./release.sh --target x86_64-apple-darwin
EOF
  exit 0
}

# ── Parse arguments ──────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      TARGET="$2"
      shift 2
      ;;
    --universal)
      UNIVERSAL=true
      shift
      ;;
    --sign)
      SIGN=true
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown option: $1"
      usage
      ;;
  esac
done

# ── Preflight checks ────────────────────────────────────

check_cmd() {
  if ! command -v "$1" &>/dev/null; then
    echo "Error: '$1' is not installed."
    echo "  $2"
    exit 1
  fi
}

check_cmd pnpm  "Install via: npm install -g pnpm"
check_cmd cargo "Install via: https://rustup.rs"
check_cmd rustc "Install via: https://rustup.rs"

if [[ "$(uname)" != "Darwin" ]]; then
  echo "Warning: macOS .app bundles can only be built on macOS."
  echo "  You are running on $(uname). The build will likely fail."
  echo ""
fi

# ── Determine target ────────────────────────────────────

if [[ "$UNIVERSAL" == true ]]; then
  TARGET="universal-apple-darwin"
elif [[ -z "$TARGET" ]]; then
  ARCH="$(uname -m)"
  case "$ARCH" in
    arm64|aarch64)
      TARGET="aarch64-apple-darwin"
      ;;
    x86_64)
      TARGET="x86_64-apple-darwin"
      ;;
    *)
      echo "Error: Could not auto-detect target for architecture '$ARCH'."
      echo "  Please specify --target <triple> manually."
      exit 1
      ;;
  esac
fi

# Ensure required Rust targets are installed
if [[ "$TARGET" == "universal-apple-darwin" ]]; then
  echo "Installing Rust targets for universal build..."
  rustup target add aarch64-apple-darwin x86_64-apple-darwin 2>/dev/null || true
else
  rustup target add "$TARGET" 2>/dev/null || true
fi

# ── Build ────────────────────────────────────────────────

echo ""
echo "Building Skim for $TARGET"
echo "  Signing: $SIGN"
echo ""

# Clean llama-cpp cmake cache to pick up new deployment target
find src-tauri/target -path "*/llama-cpp-sys-2-*/out" -type d -exec rm -rf {} + 2>/dev/null || true

# Install frontend dependencies
pnpm install

# Assemble build command
BUILD_CMD=(pnpm tauri build --target "$TARGET")

if [[ "$SIGN" != true ]]; then
  BUILD_CMD+=(--no-sign)
fi

echo "Running: ${BUILD_CMD[*]}"
echo ""
"${BUILD_CMD[@]}"

# ── Report output ────────────────────────────────────────

echo ""
echo "Build complete!"
echo ""

# Find the .app bundle
APP_PATH="$(find src-tauri/target -path '*/bundle/macos/Skim.app' -maxdepth 5 2>/dev/null | head -n 1)"

if [[ -n "$APP_PATH" ]]; then
  echo "App bundle: $APP_PATH"
  echo ""
  echo "To install, copy to /Applications:"
  echo "  cp -r \"$APP_PATH\" /Applications/"
else
  echo "Could not locate Skim.app — check src-tauri/target/*/release/bundle/macos/"
fi
