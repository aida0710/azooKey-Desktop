#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BACKEND="${AZOOKEY_INFERENCE_BACKEND:-metal}"
case "$BACKEND" in
    metal) CORE_TRAIT=Zenzai ;;
    cpu) CORE_TRAIT=ZenzaiCPU ;;
    *) echo 'AZOOKEY_INFERENCE_BACKEND must be metal or cpu' >&2; exit 2 ;;
esac
PACKAGE="$ROOT/build/macos-app"
mkdir -p "$PACKAGE/Sources/azooKeyMac" "$PACKAGE/Tests/azooKeyMacTests"
cat > "$PACKAGE/Package.swift" <<SWIFT
// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "azooKeyMacStandalone", platforms: [.macOS(.v13)],
    dependencies: [.package(path: "../../Core", traits: ["$CORE_TRAIT"])], targets: [
        .executableTarget(name: "azooKeyMac", dependencies: [.product(name: "Core", package: "Core")],
            swiftSettings: [.swiftLanguageMode(.v5), .interoperabilityMode(.Cxx)]),
        .testTarget(name: "azooKeyMacTests", dependencies: ["azooKeyMac", .product(name: "Core", package: "Core")],
            swiftSettings: [.swiftLanguageMode(.v5), .interoperabilityMode(.Cxx)])
    ])
SWIFT
# Remove links to deleted sources when reusing the standalone test package.
find "$PACKAGE/Sources/azooKeyMac" "$PACKAGE/Tests/azooKeyMacTests" -type l -delete
while IFS= read -r -d '' source; do
    ln -sf "$source" "$PACKAGE/Sources/azooKeyMac/$(basename "$source")"
done < <(find "$ROOT/azooKeyMac" -name '*.swift' -print0)
while IFS= read -r -d '' source; do
    ln -sf "$source" "$PACKAGE/Tests/azooKeyMacTests/$(basename "$source")"
done < <(find "$ROOT/azooKeyMacTests" -name '*.swift' -print0)
export CLANG_MODULE_CACHE_PATH="$ROOT/build/cache/modules"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/build/cache/modules"
swift "${1:-test}" --package-path "$PACKAGE" --cache-path "$ROOT/build/spm-cache" "${@:2}"
