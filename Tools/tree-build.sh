#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-0.1.0}"
BACKEND="${2:-metal}"
case "$BACKEND" in
    metal) SUFFIX=''; COMPILATION_CONDITION=Zenzai ;;
    cpu) SUFFIX='-cpu'; COMPILATION_CONDITION=ZenzaiCPU ;;
    *) echo 'Usage: tree-build.sh MAJOR.MINOR.PATCH [metal|cpu]' >&2; exit 2 ;;
esac
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Version must be MAJOR.MINOR.PATCH' >&2; exit 2; }
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo 'This package currently requires an Apple Silicon Mac.' >&2; exit 2; }
python3 "$ROOT/Tools/fetch-models.py" --verify-only
# Xcode generates Bundle.module accessors that search Contents/Resources.
# Separate build directories keep the CPU and Metal compiler conditions isolated.
# Both variants use the same dependency graph and framework; ZenzaiCPU selects
# the converter's CPU device list and disables GPU offloading at compile time.
DERIVED_DATA="$ROOT/build/tree-xcode-$BACKEND"
xcodebuild -project "$ROOT/azooKeyMac.xcodeproj" -scheme azooKeyMac \
    -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" -skipPackagePluginValidation -jobs 4 \
    ARCHS=arm64 MACOSX_DEPLOYMENT_TARGET=14.0 \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' \
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS=\$(inherited) $COMPILATION_CONDITION" build
PRODUCTS="$DERIVED_DATA/Build/Products/Release"
STAGE="$(mktemp -d "$ROOT/build/tree-package.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/azooKeyMac.app"
ditto "$PRODUCTS/azooKeyMac.app" "$APP"
mkdir -p "$APP/Contents/Frameworks"
if [[ ! -d "$APP/Contents/Frameworks/llama.framework" ]]; then
    FRAMEWORKS=()
    while IFS= read -r -d '' framework; do
        FRAMEWORKS+=("$framework")
    done < <(find "$PRODUCTS" -type d -name llama.framework -prune -print0)
    [[ ${#FRAMEWORKS[@]} == 1 ]] || { echo 'Expected one built llama.framework' >&2; exit 1; }
    ditto "${FRAMEWORKS[0]}" "$APP/Contents/Frameworks/llama.framework"
fi
cp "$ROOT"/build/models/* "$APP/Contents/Resources/"
python3 "$ROOT/Tools/collect-licenses.py" "$DERIVED_DATA/SourcePackages/checkouts" "$APP/Contents/Resources/Licenses"
python3 - "$ROOT" "$APP" "$VERSION" "$BACKEND" <<'PY'
import pathlib, plistlib, shutil, subprocess, sys
root, app, version = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
resources = app / 'Contents/Resources'
for localization in (root / 'azooKeyMac').glob('*.lproj'):
    destination = resources / localization.name
    shutil.copytree(localization, destination, dirs_exist_ok=True)
    strings = destination / 'InfoPlist.strings'
    if strings.exists():
        strings.write_text(strings.read_text().replace('CFBundleName = "azooKey";', 'CFBundleName = "azooKey Tree";'))
with (app / 'Contents/Info.plist').open('rb') as source:
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
            AzooKeyStandaloneStorage=True,
            AzooKeyInferenceBackend=sys.argv[4],
            CFBundleShortVersionString=version, CFBundleVersion=version, LSMinimumSystemVersion='14.0')
with (app / 'Contents/Info.plist').open('wb') as target: plistlib.dump(info, target)
with (root / 'azooKeyMac/azooKeyMac.entitlements').open('rb') as source: entitlements = substitute(plistlib.load(source))
# Ad-hoc signing cannot authorize the upstream team's shared container.
# Keep the app sandbox and use its own data container instead.
entitlements.pop('com.apple.security.application-groups', None)
with (app.parent / 'entitlements.plist').open('wb') as target: plistlib.dump(entitlements, target)
binary = str(app / 'Contents/MacOS/azooKeyMac')
lines = subprocess.check_output(['otool', '-l', binary], text=True).splitlines()
rpaths = []
for i, line in enumerate(lines):
    if line.strip() == 'cmd LC_RPATH':
        rpath = lines[i+2].strip().split('path ', 1)[1].split(' (offset', 1)[0]
        rpaths.append(rpath)
        if rpath.startswith(str(root)):
            subprocess.run(['install_name_tool', '-delete_rpath', rpath, binary], check=True)
if '@executable_path/../Frameworks' not in rpaths:
    subprocess.run(['install_name_tool', '-add_rpath', '@executable_path/../Frameworks', binary], check=True)
PY
codesign --force --sign - "$APP/Contents/Frameworks/llama.framework"
codesign --force --sign - --entitlements "$STAGE/entitlements.plist" "$APP"
codesign --verify --deep --strict "$APP"
mkdir -p "$ROOT/build/dist"
DESTINATION="$ROOT/build/dist/azookey-tree-$VERSION-arm64$SUFFIX.zip"
ditto -c -k --keepParent "$APP" "$DESTINATION"
(cd "$(dirname "$DESTINATION")" && shasum -a 256 "$(basename "$DESTINATION")") > "$DESTINATION.sha256"
echo "Built ad-hoc signed, unnotarized package: $DESTINATION"
