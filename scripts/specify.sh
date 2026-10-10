#!/usr/bin/env bash
# Run Giulio's Specify (https://github.com/gm2211/specify) against Skim's spec.
#
# Never resolve `specify` from PATH: GitHub's Spec Kit installs a CLI with the
# same name. This wrapper finds gm2211/specify in this order:
#   1. $SPECIFY_CLI (absolute path to the `specify` entry point)
#   2. ~/projects/specify/specify
#   3. a sibling checkout at ../specify/specify
#   4. a cached clone in ~/.cache/skim/specify (cloned on first use)
#
#   scripts/specify.sh spec lint --spec skim.spec
#   scripts/specify.sh spec check --spec skim.spec --base "$(git merge-base HEAD origin/main)"
#   scripts/specify.sh view --spec skim.spec

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/skim/specify"

find_cli() {
  local candidate
  for candidate in \
    "${SPECIFY_CLI:-}" \
    "$HOME/projects/specify/specify" \
    "$REPO_ROOT/../specify/specify" \
    "$CACHE_DIR/specify"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

if ! CLI="$(find_cli)"; then
  echo "Cloning gm2211/specify into $CACHE_DIR..." >&2
  mkdir -p "$(dirname "$CACHE_DIR")"
  git clone --depth 1 https://github.com/gm2211/specify "$CACHE_DIR" >&2
  CLI="$CACHE_DIR/specify"
fi

cd "$REPO_ROOT"
exec "$CLI" "$@"
