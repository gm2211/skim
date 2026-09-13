#!/bin/sh
# Sign nested code first so the helper inherits the app sandbox.
set -eu
PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_PATH=${1:-"$PROJECT_DIR/src-tauri/target/release/bundle/macos/Skim.app"}
IDENTITY=${APPLE_SIGNING_IDENTITY:--}
# Data stays in Resources so codesign does not interpret it as nested code.
# MLX and SwiftPM resolve these relative aliases beside the executable.
ln -sfn ../Resources/mlx.metallib "$APP_PATH/Contents/MacOS/mlx.metallib"
ln -sfn ../Resources/swift-transformers_Hub.bundle "$APP_PATH/Contents/MacOS/swift-transformers_Hub.bundle"
codesign --force --sign "$IDENTITY" --entitlements "$PROJECT_DIR/src-tauri/HelperEntitlements.plist" \
  "$APP_PATH/Contents/MacOS/skim-ai-macos-bridge"
codesign --force --sign "$IDENTITY" --entitlements "$PROJECT_DIR/src-tauri/Entitlements.plist" "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
