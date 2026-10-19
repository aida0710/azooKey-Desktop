#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
TEST_DATA="$(mktemp -d)"
export AZOOKEY_DATA_DIR="$TEST_DATA/data"
export GDK_BACKEND=x11
export NO_AT_BRIDGE=1
ibus-daemon --daemonize --xim --panel=disable --config=disable
python3 Linux/ibus-azookey-tree.py > "$TEST_DATA/engine.log" 2>&1 &
ENGINE_PID=$!
trap 'kill "$ENGINE_PID" 2>/dev/null || true; rm -rf "$TEST_DATA"' EXIT
for attempt in {1..50}; do
    if ibus engine azookey-tree >/dev/null 2>&1; then break; fi
    sleep 0.1
done
if ! python3 Linux/tests/ibus_integration.py; then
    # All text here is a fixed test fixture, never the user's document contents.
    cat "$TEST_DATA/engine.log" >&2
    exit 1
fi
if grep -Eq 'Traceback|Error' "$TEST_DATA/engine.log"; then
    cat "$TEST_DATA/engine.log" >&2
    exit 1
fi
