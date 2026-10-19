#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-0.1.0}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Version must be MAJOR.MINOR.PATCH' >&2; exit 2; }
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo 'This package currently requires an Apple Silicon Mac.' >&2; exit 2; }
python3 "$ROOT/Tools/fetch-models.py" --verify-only
bash "$ROOT/Tools/test-macos-app.sh" build -c release -j 4
PRODUCTS="$(swift build --package-path "$ROOT/build/macos-app" -c release --show-bin-path)"
STAGE="$(mktemp -d "$ROOT/build/tree-package.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/azooKeyMac.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$PRODUCTS/azooKeyMac" "$APP/Contents/MacOS/azooKeyMac"
ditto "$PRODUCTS/llama.framework" "$APP/Contents/Frameworks/llama.framework"
for resource in "$PRODUCTS"/*.bundle; do
    ditto "$resource" "$APP/Contents/Resources/$(basename "$resource")"
done
cp "$ROOT"/azooKeyMac/*.tiff "$APP/Contents/Resources/"
cp "$ROOT"/build/models/* "$APP/Contents/Resources/"
python3 "$ROOT/Tools/collect-licenses.py" "$ROOT/build/macos-app/.build/checkouts" "$APP/Contents/Resources/Licenses"
python3 - "$ROOT" "$APP" "$VERSION" <<'PY'
import json, pathlib, plistlib, shutil, subprocess, sys
root, app, version = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
resources = app / 'Contents/Resources'
for localization in (root / 'azooKeyMac').glob('*.lproj'):
    destination = resources / localization.name
    shutil.copytree(localization, destination)
    strings = destination / 'InfoPlist.strings'
    if strings.exists():
        strings.write_text(strings.read_text().replace('CFBundleName = "azooKey";', 'CFBundleName = "azooKey Tree";'))
# Reuse the upstream catalog's exact PNGs without requiring an Xcode archive.
icons = root / 'azooKeyMac/Assets.xcassets/AppIcon.appiconset'
iconset = app.parent / 'AppIcon.iconset'
iconset.mkdir()
for item in json.loads((icons / 'Contents.json').read_text())['images']:
    suffix = '@2x' if item['scale'] == '2x' else ''
    shutil.copyfile(icons / item['filename'], iconset / f"icon_{item['size']}{suffix}.png")
subprocess.run(['iconutil', '-c', 'icns', str(iconset), '-o', str(resources / 'AppIcon.icns')], check=True)
with (root / 'azooKeyMac/Info.plist').open('rb') as source:
    info = plistlib.load(source)
def substitute(value):
    if isinstance(value, str):
        return value.replace('$(PRODUCT_MODULE_NAME)', 'azooKeyMac').replace('$(PRODUCT_BUNDLE_IDENTIFIER)', 'dev.ensan.inputmethod.azooKeyMac')
    if isinstance(value, list): return [substitute(item) for item in value]
    if isinstance(value, dict): return {key: substitute(item) for key, item in value.items()}
    return value
info = substitute(info)
info.update(CFBundleIdentifier='dev.ensan.inputmethod.azooKeyMac', CFBundleExecutable='azooKeyMac',
            CFBundleName='azooKey Tree', CFBundleDisplayName='azooKey Tree', CFBundlePackageType='APPL',
            CFBundleIconFile='AppIcon.icns', CFBundleDevelopmentRegion='en',
            CFBundleShortVersionString=version, CFBundleVersion=version, LSMinimumSystemVersion='14.0')
with (app / 'Contents/Info.plist').open('wb') as target: plistlib.dump(info, target)
with (root / 'azooKeyMac/azooKeyMac.entitlements').open('rb') as source: entitlements = substitute(plistlib.load(source))
with (app.parent / 'entitlements.plist').open('wb') as target: plistlib.dump(entitlements, target)
binary = str(app / 'Contents/MacOS/azooKeyMac')
lines = subprocess.check_output(['otool', '-l', binary], text=True).splitlines()
for i, line in enumerate(lines):
    if line.strip() == 'cmd LC_RPATH':
        rpath = lines[i+2].strip().split('path ', 1)[1].split(' (offset', 1)[0]
        if rpath.startswith(str(root)):
            subprocess.run(['install_name_tool', '-delete_rpath', rpath, binary], check=True)
subprocess.run(['install_name_tool', '-add_rpath', '@executable_path/../Frameworks', binary], check=True)
PY
codesign --force --sign - "$APP/Contents/Frameworks/llama.framework"
codesign --force --sign - --entitlements "$STAGE/entitlements.plist" "$APP"
codesign --verify --deep --strict "$APP"
mkdir -p "$ROOT/build/dist"
DESTINATION="$ROOT/build/dist/azookey-tree-$VERSION-arm64.zip"
ditto -c -k --keepParent "$APP" "$DESTINATION"
shasum -a 256 "$DESTINATION" > "$DESTINATION.sha256"
echo "Built ad-hoc signed, unnotarized package: $DESTINATION"
