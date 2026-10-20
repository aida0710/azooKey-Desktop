#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: $0 learned-candidates-report.json [iterations]" >&2
    exit 2
fi
BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/azookey-tree-benchmark.XXXXXX")"
trap 'rm -rf "$BUILD_ROOT"' EXIT
MODEL_ROOT="${AZOOKEY_TREE_MODEL_ROOT:-$REPO_ROOT/Core/Sources/Core/InputUtils}"
swiftc -O -o "$BUILD_ROOT/benchmark" \
    "$MODEL_ROOT/CandidateTree.swift" \
    "$MODEL_ROOT/CandidateCommitScope.swift" \
    "$MODEL_ROOT/CandidateCommitPreview.swift" \
    "$REPO_ROOT/Tools/tests/benchmark-candidate-tree.swift"
"$BUILD_ROOT/benchmark" "$1" "${2:-1000}"
