#!/bin/bash
set -euo pipefail
# Staging directories must be readable by the desktop user after root installs them.
umask 022
cd "$(dirname "${BASH_SOURCE[0]}")/.."
[[ "$(uname -s)" == Linux ]] || { echo 'Build in the Ubuntu Docker image.' >&2; exit 2; }
VERSION="${1:?Pass MAJOR.MINOR.PATCH}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 2
[[ "${AZOOKEY_CPU_TRAIT:-0}" == 1 ]] || { echo 'Use the Zenzai CPU image.' >&2; exit 2; }
MODEL_DIR="${AZOOKEY_RESOURCES:?Verified model directory is required}"
ARCH="$(dpkg --print-architecture)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
DEST="$STAGE/opt/azookey-tree"
mkdir -p "$DEST/libexec" "$DEST/models" "$STAGE/usr/bin" "$STAGE/usr/share/ibus/component" \
    "$STAGE/usr/share/applications" "$STAGE/usr/share/gnome-shell/extensions" "$STAGE/DEBIAN"
swift build --package-path Core --configuration release --product azookey-desktop-bridge \
    --jobs 4 --traits ZenzaiCPU -Xlinker -L/opt/azookey/lib -Xlinker -lggml \
    -Xlinker -rpath -Xlinker /opt/azookey/lib
BIN="$(swift build --package-path Core --configuration release --show-bin-path)"
cp "$BIN/azookey-desktop-bridge" "$DEST/libexec/"
cp -a "$BIN/"*.resources "$DEST/libexec/"
# Bundle the Swift and llama runtimes; Ubuntu supplies its normal system libraries.
cp -a /usr/lib/swift/linux/*.so* /opt/azookey/lib/*.so* "$DEST/libexec/"
cp -a Linux/azookey Linux/ibus-azookey-tree.py "$DEST/"
find "$DEST" -type d -name __pycache__ -exec rm -rf '{}' +
cp -a "$MODEL_DIR/." "$DEST/models/"
cp -a Linux/gnome-extension "$STAGE/usr/share/gnome-shell/extensions/azookey-tree@aida0710"
cat > "$STAGE/usr/bin/ibus-azookey-tree" <<'LAUNCH'
#!/bin/sh
export LD_LIBRARY_PATH="/opt/azookey-tree/libexec${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export AZOOKEY_RESOURCES=/opt/azookey-tree/models
exec /usr/bin/python3 /opt/azookey-tree/ibus-azookey-tree.py "$@"
LAUNCH
chmod 755 "$STAGE/usr/bin/ibus-azookey-tree"
cat > "$STAGE/usr/share/ibus/component/azookey-tree.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<component>
  <name>org.freedesktop.IBus.AzooKeyTree</name>
  <description>azooKey Tree Japanese input method</description>
  <exec>/usr/bin/ibus-azookey-tree --ibus</exec>
  <version>1</version><license>MIT</license><author>azooKey contributors</author>
  <homepage>https://github.com/aida0710/azooKey-Desktop</homepage>
  <engines><engine><name>azookey-tree</name><longname>azooKey Tree</longname>
    <description>Japanese input with tree candidates</description><language>ja</language>
    <license>MIT</license><author>azooKey contributors</author><layout>default</layout>
    <symbol>あ</symbol><setup>/usr/bin/ibus-azookey-tree --setup</setup>
  </engine></engines>
</component>
XML
cat > "$STAGE/usr/share/applications/azookey-tree.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=azooKey Tree Settings
Name[ja]=azooKey Tree 設定
Exec=ibus-azookey-tree --setup
Icon=input-keyboard
Categories=Settings;
Terminal=false
DESKTOP
cat > "$STAGE/DEBIAN/control" <<CONTROL
Package: azookey-tree
Version: $VERSION
Architecture: $ARCH
Maintainer: azooKey Tree contributors <noreply@github.com>
Depends: ibus (>= 1.5), ibus-gtk, ibus-gtk3, ibus-gtk4, python3, python3-gi, python3-gi-cairo, python3-cairo, gir1.2-ibus-1.0, gir1.2-gtk-3.0, gir1.2-secret-1, libssl3t64, libcurl4t64, libgomp1, libatomic1, libicu74, zlib1g, libstdc++6
Recommends: fonts-noto-cjk, gnome-shell (>= 46), gnome-shell (<< 47)
Section: utils
Priority: optional
Homepage: https://github.com/aida0710/azooKey-Desktop
Description: Japanese input with azooKey Zenzai and tree candidates
 Ubuntu 24.04 IBus frontend, settings and GNOME 46 Wayland renderer.
CONTROL
python3 Tools/collect-licenses.py Core/.build/checkouts "$DEST/licenses"
printf '%s\n' "version=$VERSION" "architecture=$ARCH" "source=${AZOOKEY_BUILD_COMMIT:-unknown}" > "$DEST/build-info.txt"
# cp -a preserves a checkout's restrictive modes; these are public package assets.
chmod -R a+rX "$STAGE/opt" "$STAGE/usr"
OUTPUT="${AZOOKEY_OUTPUT_DIR:-build/dist}"
mkdir -p "$OUTPUT"
PACKAGE="$OUTPUT/azookey-tree_${VERSION}_${ARCH}.deb"
dpkg-deb --root-owner-group --build "$STAGE" "$PACKAGE"
python3 Tools/tests/check-linux-package.py "$PACKAGE"
(cd "$(dirname "$PACKAGE")" && sha256sum "$(basename "$PACKAGE")") > "$PACKAGE.sha256"
echo "Built $PACKAGE"
