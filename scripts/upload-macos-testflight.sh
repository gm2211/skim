#!/usr/bin/env bash
# Export a freshly built Tauri Mac app through Xcode's managed store signing.
set -euo pipefail
set +x
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-$ROOT/src-tauri/target/release/bundle/macos/Skim.app}"
OUTPUT_DIR="${SKIM_MAC_TESTFLIGHT_OUTPUT:-$ROOT/.build/mac-testflight}"
ENV_FILE="${SKIM_TESTFLIGHT_ENV_FILE:-$ROOT/.env.testflight.local}"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  source "$ENV_FILE"
  set +a
fi
: "${ASC_KEY_ID:?Set ASC_KEY_ID}"
: "${ASC_ISSUER_ID:?Set ASC_ISSUER_ID}"
: "${ASC_KEY_PATH:?Set ASC_KEY_PATH}"
TEAM_ID="${TEAM_ID:-6KQV68SJ5P}"
ARCHIVE_PATH="$OUTPUT_DIR/Skim.xcarchive"
mkdir -p "$OUTPUT_DIR/export"
if [[ -e "$ARCHIVE_PATH" ]]; then
  echo "Archive already exists: $ARCHIVE_PATH. Select a fresh output directory."
  exit 1
fi
python3 - "$ROOT/src-tauri/tauri.conf.json" "$APP_PATH/Contents/Info.plist" <<'PY'
import json, plistlib, sys
config = json.load(open(sys.argv[1]))
with open(sys.argv[2], 'rb') as f:
    app = plistlib.load(f)
expected = (config['version'], config['bundle']['macOS']['bundleVersion'])
actual = (app['CFBundleShortVersionString'], app['CFBundleVersion'])
if actual != expected:
    raise SystemExit(f'Bundle metadata mismatch: expected {expected}, got {actual}')
if app['CFBundleIdentifier'] != config['identifier']:
    raise SystemExit('Bundle identifier does not match release configuration')
print(f'Verified Mac bundle: {actual[0]} ({actual[1]})')
PY
# Xcode accepts an ad-hoc archive and applies managed distribution signing.
# Preserve the helper sandbox-inheritance signatures before export.
APPLE_SIGNING_IDENTITY=- sh "$ROOT/scripts/sign-macos.sh" "$APP_PATH"
mkdir -p "$ARCHIVE_PATH/Products/Applications"
ditto "$APP_PATH" "$ARCHIVE_PATH/Products/Applications/Skim.app"
python3 - "$ARCHIVE_PATH" "$TEAM_ID" <<'PY'
import datetime, pathlib, plistlib, sys
archive = pathlib.Path(sys.argv[1])
with (archive/'Products/Applications/Skim.app/Contents/Info.plist').open('rb') as f:
    app = plistlib.load(f)
metadata = {'ArchiveVersion': 2, 'CreationDate': datetime.datetime.now(datetime.timezone.utc),
    'Name': 'Skim', 'SchemeName': 'Skim macOS',
    'ApplicationProperties': {'ApplicationPath': 'Applications/Skim.app',
        'CFBundleIdentifier': app['CFBundleIdentifier'],
        'CFBundleShortVersionString': app['CFBundleShortVersionString'],
        'CFBundleVersion': app['CFBundleVersion'], 'SigningIdentity': '-', 'Team': sys.argv[2]}}
with (archive/'Info.plist').open('wb') as f:
    plistlib.dump(metadata, f)
options = {'destination': 'export', 'method': 'app-store-connect', 'signingStyle': 'automatic',
    'teamID': sys.argv[2], 'manageAppVersionAndBuildNumber': False, 'uploadSymbols': False}
with (archive.parent/'ExportOptions.plist').open('wb') as f:
    plistlib.dump(options, f)
PY
# Authentication-file compatibility fallback: private directory, owner-only copy,
# removed on success, failure, or handled interruption. Key contents never enter argv.
AUTH_DIR="$(mktemp -d "${TMPDIR:-/tmp}/skim-mac-auth.XXXXXX")"
trap 'rm -rf "$AUTH_DIR"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
chmod 700 "$AUTH_DIR"
(umask 077; cp -f "$ASC_KEY_PATH" "$AUTH_DIR/AuthKey.p8")
chmod 600 "$AUTH_DIR/AuthKey.p8"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$OUTPUT_DIR/export" \
  -exportOptionsPlist "$OUTPUT_DIR/ExportOptions.plist" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$AUTH_DIR/AuthKey.p8" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"

PACKAGE_PATH="$(find "$OUTPUT_DIR/export" -maxdepth 1 -name '*.pkg' -type f -print -quit)"
if [[ -z "$PACKAGE_PATH" ]]; then
  echo "Xcode export produced no Mac installer package."
  exit 1
fi
pkgutil --check-signature "$PACKAGE_PATH"
EXPANDED_PATH="$OUTPUT_DIR/verified-package"
pkgutil --expand-full "$PACKAGE_PATH" "$EXPANDED_PATH"
EXPORTED_APP="$(find "$EXPANDED_PATH" -type d -name Skim.app -print -quit)"
if [[ -z "$EXPORTED_APP" ]]; then
  echo "Exported package contains no Skim.app."
  exit 1
fi
codesign --verify --deep --strict "$EXPORTED_APP"
python3 - "$EXPORTED_APP" "$ROOT/src-tauri/tauri.conf.json" "$TEAM_ID" <<'PYVERIFY'
import json, pathlib, plistlib, subprocess, sys
app, config_path, team = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
config = json.load(open(config_path))
with (app/'Contents/Info.plist').open('rb') as f:
    info = plistlib.load(f)
assert (info['CFBundleShortVersionString'], info['CFBundleVersion']) == (config['version'], config['bundle']['macOS']['bundleVersion']), 'Export changed release metadata'
assert (app/'Contents/embedded.provisionprofile').is_file(), 'Missing store provisioning profile'
for executable in [app, app/'Contents/MacOS/skim-ai-macos-bridge', app/'Contents/MacOS/ds4-server']:
    result = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(executable)], capture_output=True, check=True)
    entitlements = plistlib.loads(result.stdout)
    assert entitlements.get('com.apple.security.app-sandbox'), f'Sandbox missing: {executable.name}'
    if executable != app:
        assert entitlements.get('com.apple.security.inherit'), f'Sandbox inheritance missing: {executable.name}'
    else:
        assert entitlements.get('com.apple.application-identifier') == team+'.'+config['identifier'], 'Wrong store application identifier'
        assert entitlements.get('com.apple.developer.team-identifier') == team, 'Wrong store signing team'
print('Verified exported metadata, provisioning profile, and helper sandbox inheritance')
PYVERIFY
shasum -a 256 "$PACKAGE_PATH"
xcrun altool --upload-package "$PACKAGE_PATH" --wait \
  --api-key "$ASC_KEY_ID" --api-issuer "$ASC_ISSUER_ID" \
  --p8-file-path "$AUTH_DIR/AuthKey.p8"
