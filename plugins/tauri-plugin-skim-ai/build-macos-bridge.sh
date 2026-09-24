#!/bin/sh
set -eu
PLUGIN_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SCRATCH_DIR="${TMPDIR:-/tmp}/skim-ai-macos-bridge-build"
export SKIM_AI_MAC_BRIDGE_ONLY=1
export MACOSX_DEPLOYMENT_TARGET=14.0
# Query the same build configuration: SwiftPM's output layout changes between
# toolchains, and old products may coexist in this reusable scratch directory.
set -- --package-path "$PLUGIN_DIR/ios" --product skim-ai-macos-bridge -c release --scratch-path "$SCRATCH_DIR"
swift build "$@"
BIN_DIR=$(swift build "$@" --show-bin-path)
BIN_PATH="$BIN_DIR/skim-ai-macos-bridge"
RESOURCE_PATH="$BIN_DIR/swift-transformers_Hub.bundle"
if [ ! -f "$BIN_PATH" ] || [ ! -d "$RESOURCE_PATH" ]; then
  echo "Missing macOS AI bridge or resource bundle in SwiftPM output: $BIN_DIR" >&2
  exit 1
fi
mkdir -p "$PLUGIN_DIR/bin" "$PLUGIN_DIR/resources"
cp -f "$BIN_PATH" "$PLUGIN_DIR/bin/skim-ai-macos-bridge-aarch64-apple-darwin"
rm -rf "$PLUGIN_DIR/resources/swift-transformers_Hub.bundle"
cp -Rf "$RESOURCE_PATH" "$PLUGIN_DIR/resources/swift-transformers_Hub.bundle"
chmod -R u+w "$PLUGIN_DIR/resources/swift-transformers_Hub.bundle"
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
