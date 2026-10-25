#!/usr/bin/env bash
# Bump the app version and build number for the next TestFlight ship.
#
# Every new build gets a new version (patch + 1), not only a new build number,
# so each one shows up as a new entry in TestFlight. iOS and macOS share one
# version: the next patch after the higher of the two current versions.
#
# Usage:
#   ./scripts/bump-version.sh            # 0.1.52 -> 0.1.53, builds +1
#   ./scripts/bump-version.sh 0.2.0      # explicit version, builds +1
#   ./scripts/bump-version.sh --check    # print current metadata, change nothing
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT" "${1:-}" <<'PY'
import json, pathlib, re, sys

root, arg = pathlib.Path(sys.argv[1]), sys.argv[2]
spec = root/'native/SkimNative/project.yml'
pbx = root/'native/SkimNative/SkimNative.xcodeproj/project.pbxproj'
tauri = root/'src-tauri/tauri.conf.json'

def parse(v):
    if not re.fullmatch(r'\d+\.\d+\.\d+', v):
        raise SystemExit(f'Not a MAJOR.MINOR.PATCH version: {v!r}')
    return tuple(int(p) for p in v.split('.'))

spec_text = spec.read_text()
ios_version = re.search(r'MARKETING_VERSION: (\S+)', spec_text).group(1)
ios_build = int(re.search(r'CURRENT_PROJECT_VERSION: (\d+)', spec_text).group(1))
config = json.loads(tauri.read_text())
mac_version = config['version']
mac_build = int(config['bundle']['macOS']['bundleVersion'])

if arg == '--check':
    print(f'iOS   {ios_version} ({ios_build})')
    print(f'macOS {mac_version} ({mac_build})')
    sys.exit(0)

current = max(parse(ios_version), parse(mac_version))
if arg:
    new = parse(arg)
    if new <= current:
        raise SystemExit(f'Version {arg} must be higher than {".".join(map(str, current))}')
else:
    new = (current[0], current[1], current[2] + 1)
version = '.'.join(map(str, new))
ios_next, mac_next = ios_build + 1, mac_build + 1

spec.write_text(re.sub(r'(CURRENT_PROJECT_VERSION: )\d+', rf'\g<1>{ios_next}',
                re.sub(r'(MARKETING_VERSION: )\S+', rf'\g<1>{version}', spec_text)))
pbx_text = pbx.read_text()
pbx_text = re.sub(r'(MARKETING_VERSION = )[^;]+;', rf'\g<1>{version};', pbx_text)
pbx_text = re.sub(r'(CURRENT_PROJECT_VERSION = )\d+;', rf'\g<1>{ios_next};', pbx_text)
pbx.write_text(pbx_text)
tauri_text = tauri.read_text()
tauri_text = re.sub(r'("version": )"[^"]+"', rf'\g<1>"{version}"', tauri_text, count=1)
tauri_text = re.sub(r'("bundleVersion": )"\d+"', rf'\g<1>"{mac_next}"', tauri_text, count=1)
tauri.write_text(tauri_text)

print(f'iOS   {ios_version} ({ios_build}) -> {version} ({ios_next})')
print(f'macOS {mac_version} ({mac_build}) -> {version} ({mac_next})')
PY
