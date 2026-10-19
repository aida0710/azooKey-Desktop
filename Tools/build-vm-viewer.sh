#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLATFORM="${1:?Pass macos or ubuntu}"
[[ "$PLATFORM" == macos || "$PLATFORM" == ubuntu ]] || exit 2
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || exit 2
VM_ROOT="${AZOOKEY_VM_HOME:-$(dirname "$ROOT")/azookey-vm}/azookey-$PLATFORM"
APP="$ROOT/build/VMViewer-$PLATFORM.app"
mkdir -p "$APP/Contents/MacOS" "$ROOT/build/cache/modules"
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$ROOT/build/cache/modules" \
    -target arm64-apple-macos14.0 -framework AppKit -framework Virtualization \
    "$ROOT/Tools/VMViewer/main.swift" -o "$APP/Contents/MacOS/VMViewer"
python3 - "$APP" "$VM_ROOT" "$PLATFORM" <<'PY'
import pathlib, plistlib, re, subprocess, sys
app, directory, platform = sys.argv[1:]
root = pathlib.Path(app) / 'Contents'
mac = '02:aa:00:00:00:01'
if platform == 'ubuntu':
    network = subprocess.check_output(['tar', '-xOf', str(pathlib.Path(directory) / 'cidata.iso'), 'network-config'], text=True)
    mac = re.search(r'macaddress: [\x27\x22]?([0-9a-f:]{17})', network).group(1)
with (root / 'Info.plist').open('wb') as stream:
    plistlib.dump({'CFBundleIdentifier': 'org.azookey.testvm.' + platform, 'CFBundleName': 'azooKey Test VM ' + platform,
                  'CFBundleExecutable': 'VMViewer', 'CFBundlePackageType': 'APPL', 'LSMinimumSystemVersion': '14.0',
                  'VMDirectory': directory, 'VMPlatform': platform, 'VMMACAddress': mac}, stream)
with (pathlib.Path(app).parent / 'VMViewer.entitlements.plist').open('wb') as stream:
    plistlib.dump({'com.apple.security.virtualization': True}, stream)
(root / 'entitlements.plist').unlink(missing_ok=True)
PY
codesign --force --sign - --entitlements "$ROOT/build/VMViewer.entitlements.plist" "$APP"
echo "Built $APP. Shut down the Lima instance before opening this app."
