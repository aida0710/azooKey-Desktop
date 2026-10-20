#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BUNDLE="$ROOT/build/macos-app/.build/arm64-apple-macosx/debug/azooKeyMacStandalonePackageTests.xctest"

if [[ ! -d "$TEST_BUNDLE" ]]; then
    echo "The macOS test bundle was not built; no crash replay is available."
    exit 0
fi

# A framework trap can kill XCTest before it flushes a useful diagnostic.
# The second case passes alone, so preserve the complete input-test sequence.
xcrun lldb --batch \
    -o 'settings set target.disable-aslr false' \
    -o 'breakpoint set --name objc_exception_throw' \
    -o run \
    -o 'thread backtrace all' \
    -o 'expression --language objc --object-description -- (NSException *)$x0' \
    -k 'thread backtrace all' \
    -- "$(xcrun -f xctest)" \
    -XCTest azooKeyMacTests.AISuggestionInputTests \
    "$TEST_BUNDLE"
