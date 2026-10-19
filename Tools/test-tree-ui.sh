#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT="$ROOT/build/tree-ui-tests"
mkdir -p "$TEST_ROOT/Sources/Core" "$TEST_ROOT/Sources/azooKeyMac" "$TEST_ROOT/Tests/TreeUITests"
cat > "$TEST_ROOT/Package.swift" <<'SWIFT'
// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "TreeUITests", platforms: [.macOS(.v13)], targets: [
    .target(name: "Core"),
    .target(name: "azooKeyMac", dependencies: ["Core"]),
    .testTarget(name: "TreeUITests", dependencies: ["Core", "azooKeyMac"])
])
SWIFT
ln -sf "$ROOT/Core/Sources/Core/InputUtils/CandidateTree.swift" "$TEST_ROOT/Sources/Core/CandidateTree.swift"
printf '// UI module\n' > "$TEST_ROOT/Sources/azooKeyMac/Module.swift"
if [[ -f "$ROOT/azooKeyMac/InputController/CandidateWindow/CandidateTreeView.swift" ]]; then
    ln -sf "$ROOT/azooKeyMac/InputController/CandidateWindow/CandidateTreeView.swift" "$TEST_ROOT/Sources/azooKeyMac/CandidateTreeView.swift"
fi
ln -sf "$ROOT/azooKeyMacTests/CandidateTreeViewTests.swift" "$TEST_ROOT/Tests/TreeUITests/CandidateTreeViewTests.swift"
export CLANG_MODULE_CACHE_PATH="$ROOT/build/cache/modules"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/build/cache/modules"
swift test --package-path "$TEST_ROOT" --cache-path "$ROOT/build/spm-cache"
