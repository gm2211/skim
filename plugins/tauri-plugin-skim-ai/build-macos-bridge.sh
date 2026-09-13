#!/bin/sh
set -eu
PLUGIN_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SCRATCH_DIR="${TMPDIR:-/tmp}/skim-ai-macos-bridge-build"
export SKIM_AI_MAC_BRIDGE_ONLY=1
export MACOSX_DEPLOYMENT_TARGET=14.0
swift build --package-path "$PLUGIN_DIR/ios" --product skim-ai-macos-bridge -c release --scratch-path "$SCRATCH_DIR"
BIN_PATH=$(find "$SCRATCH_DIR" -path '*/release/skim-ai-macos-bridge' -type f | head -1)
test -n "$BIN_PATH"
mkdir -p "$PLUGIN_DIR/bin" "$PLUGIN_DIR/resources"
cp -f "$BIN_PATH" "$PLUGIN_DIR/bin/skim-ai-macos-bridge-aarch64-apple-darwin"
RESOURCE_PATH=$(find "$(dirname "$BIN_PATH")" -maxdepth 1 -name 'swift-transformers_Hub.bundle' -type d | head -1)
test -n "$RESOURCE_PATH"
rm -rf "$PLUGIN_DIR/resources/swift-transformers_Hub.bundle"
cp -R "$RESOURCE_PATH" "$PLUGIN_DIR/resources/swift-transformers_Hub.bundle"
MLX_METAL_DIR=$(find "$SCRATCH_DIR/checkouts/mlx-swift" -path '*/mlx-generated/metal' -type d | head -1)
test -n "$MLX_METAL_DIR"
AIR_DIR="$SCRATCH_DIR/skim-mlx-air"
rm -rf "$AIR_DIR"
mkdir -p "$AIR_DIR"
find "$MLX_METAL_DIR" -name '*.metal' -type f | while read -r SOURCE; do
  xcrun -sdk macosx metal -Wall -Wextra -fno-fast-math -Wno-c++17-extensions \
    -mmacosx-version-min=14.0 -c "$SOURCE" -I"$MLX_METAL_DIR" \
    -o "$AIR_DIR/$(basename "${SOURCE%.metal}").air"
done
xcrun -sdk macosx metallib "$AIR_DIR"/*.air -o "$PLUGIN_DIR/bin/mlx.metallib"
codesign --force --sign - "$PLUGIN_DIR/bin/skim-ai-macos-bridge-aarch64-apple-darwin"
echo "Built macOS AI bridge and SwiftPM resources."
