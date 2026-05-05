#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT/.env.testflight.local"
PROJECT_SPEC="$ROOT/native/SkimNative/project.yml"
PROJECT="$ROOT/native/SkimNative/SkimNative.xcodeproj"
SCHEME="Skim iOS"
TEAM_ID="${TEAM_ID:-6KQV68SJ5P}"
EXPORT_METHOD="${EXPORT_METHOD:-app-store-connect}"
OUTPUT_DIR="$ROOT/.build/testflight"
DERIVED_DATA="$OUTPUT_DIR/DerivedData"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

need_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required environment variable: $name"
    echo "Set it in $ENV_FILE or export it before running this script."
    exit 1
  fi
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1"
    exit 1
  fi
}

need_env ASC_KEY_ID
need_env ASC_ISSUER_ID
need_env ASC_KEY_PATH
need_cmd xcodebuild
need_cmd xcodegen

if [[ ! -f "$ASC_KEY_PATH" ]]; then
  echo "App Store Connect key not found: $ASC_KEY_PATH"
  exit 1
fi

current_version="$(awk '/MARKETING_VERSION:/ { print $2; exit }' "$PROJECT_SPEC")"
current_build="$(awk '/CURRENT_PROJECT_VERSION:/ { print $2; exit }' "$PROJECT_SPEC")"

if [[ -z "$current_version" || -z "$current_build" ]]; then
  echo "Could not read MARKETING_VERSION/CURRENT_PROJECT_VERSION from $PROJECT_SPEC"
  exit 1
fi

version="${SKIM_VERSION:-$current_version}"
if [[ -n "${SKIM_BUILD_NUMBER:-}" ]]; then
  build_number="$SKIM_BUILD_NUMBER"
elif [[ "$current_build" =~ ^[0-9]+$ ]]; then
  build_number="$((current_build + 1))"
else
  echo "CURRENT_PROJECT_VERSION is not numeric; set SKIM_BUILD_NUMBER explicitly."
  exit 1
fi

if [[ "$version" == "$current_version" && "$build_number" == "$current_build" ]]; then
  echo "Refusing to archive unchanged version/build metadata ($version/$build_number)."
  echo "Set SKIM_BUILD_NUMBER or SKIM_VERSION to a bumped value."
  exit 1
fi

case "${TESTFLIGHT_INTERNAL_ONLY:-false}" in
  1|true|TRUE|yes|YES) internal_only=true ;;
  *) internal_only=false ;;
esac

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

mkdir -p "$OUTPUT_DIR/archives" "$OUTPUT_DIR/export"

echo "Bumping project metadata: $current_version/$current_build -> $version/$build_number"
perl -0pi -e "s/(MARKETING_VERSION: )\\S+/\${1}$version/g; s/(CURRENT_PROJECT_VERSION: )\\S+/\${1}$build_number/g" "$PROJECT_SPEC"

echo "Regenerating Xcode project"
xcodegen generate --spec "$PROJECT_SPEC"

archive_path="$OUTPUT_DIR/archives/Skim-$version-$build_number.xcarchive"
export_path="$OUTPUT_DIR/export/Skim-$version-$build_number"
export_options="$OUTPUT_DIR/ExportOptions.plist"

cat > "$export_options" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>destination</key>
  <string>upload</string>
  <key>method</key>
  <string>$EXPORT_METHOD</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>teamID</key>
  <string>$TEAM_ID</string>
  <key>manageAppVersionAndBuildNumber</key>
  <false/>
  <key>uploadSymbols</key>
  <true/>
  <key>testFlightInternalTestingOnly</key>
  <$internal_only/>
</dict>
</plist>
PLIST

echo "Archiving Skim iOS $version ($build_number)"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "$archive_path" \
  -derivedDataPath "$DERIVED_DATA" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  MARKETING_VERSION="$version" \
  CURRENT_PROJECT_VERSION="$build_number"

app_plist="$archive_path/Products/Applications/Skim.app/Info.plist"
archived_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_plist")"
archived_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_plist")"

if [[ "$archived_version" != "$version" || "$archived_build" != "$build_number" ]]; then
  echo "Archive metadata mismatch: expected $version/$build_number, got $archived_version/$archived_build"
  exit 1
fi

echo "Verified archive metadata: $archived_version ($archived_build)"
echo "Uploading archive to App Store Connect/TestFlight"
xcodebuild -exportArchive \
  -archivePath "$archive_path" \
  -exportPath "$export_path" \
  -exportOptionsPlist "$export_options" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"

echo "Upload command completed."
