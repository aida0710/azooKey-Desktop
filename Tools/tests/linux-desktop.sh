#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
TEST_DATA="$(mktemp -d)"
export AZOOKEY_DATA_DIR="$TEST_DATA/data"
export GDK_BACKEND=x11
export NO_AT_BRIDGE=1
ibus-daemon --xim --panel=disable --config=disable > "$TEST_DATA/engine.log" 2>&1 &
DAEMON_PID=$!
ENGINE_PID=""
trap 'if [[ -n "$ENGINE_PID" ]]; then kill "$ENGINE_PID" 2>/dev/null || true; fi; kill "$DAEMON_PID" 2>/dev/null || true; rm -rf "$TEST_DATA"' EXIT
if [[ "${AZOOKEY_INSTALLED_TEST:-0}" != 1 ]]; then
    # Source-tree tests register a transient component. Installed-package tests
    # must use IBus activation from the installed XML; starting both creates
    # two converters competing for the renderer's bus name.
    for attempt in {1..50}; do
        if ibus address >/dev/null 2>&1; then break; fi
        sleep 0.1
    done
    python3 "${AZOOKEY_ENGINE_MAIN:-Linux/ibus-azookey-tree.py}" >> "$TEST_DATA/engine.log" 2>&1 &
    ENGINE_PID=$!
fi
for attempt in {1..50}; do
    if ibus engine azookey-tree >/dev/null 2>&1; then break; fi
    sleep 0.1
done
if ! python3 "${AZOOKEY_IBUS_TEST:-Linux/tests/ibus_integration.py}"; then
    # All text here is a fixed test fixture, never the user's document contents.
    cat "$TEST_DATA/engine.log" >&2
    exit 1
fi
if grep -Eq 'Traceback|(^| )([A-Za-z]+Error):' "$TEST_DATA/engine.log"; then
    cat "$TEST_DATA/engine.log" >&2
    exit 1
fi
