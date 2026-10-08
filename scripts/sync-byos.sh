#!/usr/bin/env bash
# Export a committed BYOS package closure. Never edit shared/byos-* directly.
# Usage: BYOS_REPO=/path/to/byos scripts/sync-byos.sh <full-commit-sha>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REF="${1:?Usage: scripts/sync-byos.sh <full-commit-sha>}"
REPO="${BYOS_REPO:-https://github.com/gm2211/byos.git}"
if [[ ! "$REF" =~ ^[0-9a-fA-F]{40}$ ]]; then
  echo 'sync-byos: use a full immutable commit SHA.' >&2
  exit 1
fi
if [[ "$REPO" =~ ^[A-Za-z][A-Za-z0-9+.-]*:// ]]; then
  authority="${REPO#*://}"
  authority="${authority%%/*}"
  if [[ "$authority" == *@* || "$REPO" == *\?* || "$REPO" == *\#* ]]; then
    echo 'sync-byos: remove URL credentials, queries and fragments; use a credential helper.' >&2
    exit 1
  fi
fi
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
git clone --quiet --no-checkout "$REPO" "$WORK/byos"
git -C "$WORK/byos" checkout --quiet --detach "$REF"
node "$WORK/byos/scripts/vendor.mjs" --source "$WORK/byos" --ref "$REF" \
  --mode packages --packages core,providers --out "$ROOT/shared" \
  --revision "$ROOT/shared/BYOS_REVISION" --engine omit
