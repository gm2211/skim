#!/bin/sh
# Build the pinned DS4 runtime; model weights are downloaded separately in-app.
set -eu
PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DS4_REVISION=bd66c402070042bf0a79ad6ece8242de4c93680c
SOURCE_DIR="$PROJECT_DIR/.build/ds4-source"
OUTPUT_DIR="$PROJECT_DIR/.build/ds4-bundle"
if [ ! -d "$SOURCE_DIR/.git" ]; then
  git clone https://github.com/antirez/ds4.git "$SOURCE_DIR"
fi
if [ "$(git -C "$SOURCE_DIR" rev-parse HEAD)" != "$DS4_REVISION" ]; then
  test -z "$(git -C "$SOURCE_DIR" status --porcelain --untracked-files=no)"
  git -C "$SOURCE_DIR" fetch origin "$DS4_REVISION"
  git -C "$SOURCE_DIR" checkout --detach "$DS4_REVISION"
fi
make -C "$SOURCE_DIR" clean
make -C "$SOURCE_DIR" -j4 ds4-server \
  CFLAGS="-O3 -ffast-math -mcpu=apple-m1 -mmacosx-version-min=14.0 -Wall -Wextra -std=c99" \
  OBJCFLAGS="-O3 -ffast-math -mcpu=apple-m1 -mmacosx-version-min=14.0 -Wall -Wextra -fobjc-arc"
mkdir -p "$OUTPUT_DIR/resources"
cp -f "$SOURCE_DIR/ds4-server" "$OUTPUT_DIR/ds4-server-aarch64-apple-darwin"
ditto "$SOURCE_DIR/metal" "$OUTPUT_DIR/resources/metal"
ditto "$SOURCE_DIR/licenses" "$OUTPUT_DIR/resources/licenses"
cp -f "$SOURCE_DIR/LICENSE" "$OUTPUT_DIR/resources/LICENSE"
printf '%s\n' "$DS4_REVISION" > "$OUTPUT_DIR/resources/REVISION"
