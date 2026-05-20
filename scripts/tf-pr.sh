#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# tf-pr.sh — Build the current branch and upload to TestFlight (internal-only)
#
# Run locally for each PR push. No CI required.
#
# Usage:
#   ./scripts/tf-pr.sh                # uses current git branch, auto build num
#   ./scripts/tf-pr.sh --pr 58        # also posts a comment on PR #58
#   ./scripts/tf-pr.sh --version 0.1.5
#
# Build number scheme:
#   Default = unix epoch seconds. Monotonic, unique across branches, no state.
#   Override with SKIM_BUILD_NUMBER=...
#
# Requires .env.testflight.local with ASC creds (see scripts/testflight.env.example).
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PR_NUMBER=""
SKIM_VERSION_OVERRIDE=""
SKIP_COMMENT=false

usage() {
  cat <<EOF
Usage: ./scripts/tf-pr.sh [OPTIONS]

Options:
  --pr <number>       Auto-detect omitted; if set, posts build info as a PR comment.
  --version <semver>  Override MARKETING_VERSION (default: keep current).
  --no-comment        Don't post to PR even if --pr is set.
  -h, --help          This help.

Env:
  SKIM_BUILD_NUMBER   Override (default: unix epoch).
  TESTFLIGHT_INTERNAL_ONLY  Default forced to true here.
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr) PR_NUMBER="$2"; shift 2 ;;
    --version) SKIM_VERSION_OVERRIDE="$2"; shift 2 ;;
    --no-comment) SKIP_COMMENT=true; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown arg: $1"; usage ;;
  esac
done

# ── Auto-detect PR from current branch if --pr not given ────────────────────
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ -z "$PR_NUMBER" ]] && command -v gh >/dev/null 2>&1; then
  PR_NUMBER="$(gh pr view --json number --jq .number 2>/dev/null || true)"
fi

# ── Refuse dirty tree ───────────────────────────────────────────────────────
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Working tree has uncommitted changes. Commit or stash before uploading."
  git status --short
  exit 1
fi

COMMIT_SHA="$(git rev-parse --short HEAD)"

# ── Build number = epoch (monotonic, unique) ────────────────────────────────
export SKIM_BUILD_NUMBER="${SKIM_BUILD_NUMBER:-$(date +%s)}"
[[ -n "$SKIM_VERSION_OVERRIDE" ]] && export SKIM_VERSION="$SKIM_VERSION_OVERRIDE"

# ── Internal-only, always ───────────────────────────────────────────────────
export TESTFLIGHT_INTERNAL_ONLY=true

# ── iOS build env (per ios-build-env memory) ────────────────────────────────
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
export PATH="$HOME/.cargo/bin:/Applications/Xcode.app/Contents/Developer/usr/bin:$PATH"

echo "─────────────────────────────────────────────────────────────"
echo "TestFlight upload (internal-only)"
echo "  Branch:     $BRANCH"
echo "  Commit:     $COMMIT_SHA"
echo "  PR:         ${PR_NUMBER:-<none detected>}"
echo "  Build no.:  $SKIM_BUILD_NUMBER"
echo "  Version:    ${SKIM_VERSION:-<keep current>}"
echo "─────────────────────────────────────────────────────────────"

# ── Save current MARKETING_VERSION + CURRENT_PROJECT_VERSION so we can revert.
# upload-testflight.sh mutates native/SkimNative/project.yml; we don't want
# PRs accidentally bumping the project spec.
PROJECT_SPEC="$ROOT/native/SkimNative/project.yml"
ORIG_VERSION="$(awk '/MARKETING_VERSION:/ { print $2; exit }' "$PROJECT_SPEC")"
ORIG_BUILD="$(awk '/CURRENT_PROJECT_VERSION:/ { print $2; exit }' "$PROJECT_SPEC")"

cleanup() {
  # Restore project.yml so the per-PR bump doesn't pollute git.
  if [[ -n "$ORIG_VERSION" && -n "$ORIG_BUILD" ]]; then
    perl -0pi -e "s/(MARKETING_VERSION: )\\S+/\${1}$ORIG_VERSION/g; s/(CURRENT_PROJECT_VERSION: )\\S+/\${1}$ORIG_BUILD/g" "$PROJECT_SPEC"
    if command -v xcodegen >/dev/null 2>&1; then
      xcodegen generate --spec "$PROJECT_SPEC" >/dev/null 2>&1 || true
    fi
  fi
}
trap cleanup EXIT

bash "$ROOT/scripts/upload-testflight.sh"

# ── Optional: post PR comment ───────────────────────────────────────────────
if [[ -n "$PR_NUMBER" && "$SKIP_COMMENT" != true ]] && command -v gh >/dev/null 2>&1; then
  COMMENT_BODY=$(cat <<EOF
:airplane: **TestFlight build uploaded** (internal-only)

| | |
|---|---|
| Version | \`${SKIM_VERSION:-$ORIG_VERSION}\` |
| Build | \`$SKIM_BUILD_NUMBER\` |
| Commit | \`$COMMIT_SHA\` |
| Branch | \`$BRANCH\` |

Available in TestFlight internal group in a few minutes after Apple processing.
EOF
)
  if gh pr comment "$PR_NUMBER" --body "$COMMENT_BODY" >/dev/null 2>&1; then
    echo "Posted comment on PR #$PR_NUMBER"
  else
    echo "Could not post PR comment (non-fatal)"
  fi
fi

echo "Done."
