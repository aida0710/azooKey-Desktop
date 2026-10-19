#!/bin/bash
set -euo pipefail

# Compile the actual model and its actual Core tests without downloading the
# conversion engine. The complete Core suite is still run before release.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$REPO_ROOT/build/tree-model-tests"
mkdir -p "$TEST_ROOT/Sources/Core" "$TEST_ROOT/Tests/CoreTests" "$REPO_ROOT/build/cache/modules"
cat > "$TEST_ROOT/Package.swift" <<'SWIFT'
// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "TreeModelTests",
    targets: [.target(name: "Core"), .testTarget(name: "CoreTests", dependencies: ["Core"])]
)
SWIFT
printf '// Test module for the dependency-free tree model.\n' > "$TEST_ROOT/Sources/Core/Module.swift"
if [[ -f "$REPO_ROOT/Core/Sources/Core/InputUtils/CandidateTree.swift" ]]; then
    ln -sf "$REPO_ROOT/Core/Sources/Core/InputUtils/CandidateTree.swift" "$TEST_ROOT/Sources/Core/CandidateTree.swift"
fi
ln -sf "$REPO_ROOT/Core/Tests/CoreTests/InputUtilsTests/CandidateTreeTests.swift" "$TEST_ROOT/Tests/CoreTests/CandidateTreeTests.swift"
export CLANG_MODULE_CACHE_PATH="$REPO_ROOT/build/cache/modules"
export SWIFTPM_MODULECACHE_OVERRIDE="$REPO_ROOT/build/cache/modules"
swift test --package-path "$TEST_ROOT" --cache-path "$REPO_ROOT/build/spm-cache" --filter candidateTree
