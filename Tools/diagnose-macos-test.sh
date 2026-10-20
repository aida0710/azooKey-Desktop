#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BUNDLE="$ROOT/build/macos-app/.build/arm64-apple-macosx/debug/azooKeyMacStandalonePackageTests.xctest"

if [[ ! -d "$TEST_BUNDLE" ]]; then
    echo "The macOS test bundle was not built; no crash replay is available."
    exit 0
fi

# A framework trap can kill XCTest before it flushes a useful diagnostic.
# Reproduce only the first controller-boundary case under the debugger.
xcrun lldb --batch \
    -o 'settings set target.disable-aslr false' \
    -o 'breakpoint set --name objc_exception_throw' \
    -o run \
    -o 'expression --language objc --object-description -- (NSException *)$x0' \
    -o 'thread backtrace all' \
    -k 'thread backtrace all' \
    -- "$(xcrun -f xctest)" \
    -XCTest azooKeyMacTests.AISuggestionInputTests/testEmptyReplacementRequestLeavesEnterToTheApplication \
    "$TEST_BUNDLE"
