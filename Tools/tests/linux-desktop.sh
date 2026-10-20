#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
TEST_DATA="$(mktemp -d)"
export AZOOKEY_DATA_DIR="$TEST_DATA/data"
export XDG_CONFIG_HOME="$TEST_DATA/config"
export XDG_CACHE_HOME="$TEST_DATA/cache"
export IBUS_ADDRESS_FILE="$TEST_DATA/ibus-address"
export GDK_BACKEND=x11
export NO_AT_BRIDGE=1
# Allow five seconds for each local daemon/source startup.
STARTUP_POLL_ATTEMPTS=50
STARTUP_POLL_SECONDS=0.1
if [[ "${AZOOKEY_INSTALLED_TEST:-0}" != 1 ]]; then
    # The installed component can otherwise start before source registration
    # and silently make this test exercise a different engine build.
    export IBUS_COMPONENT_PATH="$TEST_DATA/components"
    mkdir -p "$IBUS_COMPONENT_PATH"
fi
ibus-daemon --xim --cache=none --panel=disable --config=disable > "$TEST_DATA/engine.log" 2>&1 &
DAEMON_PID=$!
ENGINE_PID=""
trap 'if [[ -n "$ENGINE_PID" ]]; then kill "$ENGINE_PID" 2>/dev/null || true; fi; kill "$DAEMON_PID" 2>/dev/null || true; rm -rf "$TEST_DATA"' EXIT
if [[ "${AZOOKEY_INSTALLED_TEST:-0}" != 1 ]]; then
    # Source-tree tests register a transient component. Installed-package tests
    # must use IBus activation from the installed XML; starting both creates
    # two converters competing for the renderer's bus name.
    BUS_READY=0
    for ((attempt = 0; attempt < STARTUP_POLL_ATTEMPTS; attempt++)); do
        # `ibus address` also exits zero with an empty address before startup.
        if [[ -s "$IBUS_ADDRESS_FILE" ]] && [[ "$(ibus address 2>/dev/null)" == unix:* ]]; then BUS_READY=1; break; fi
        sleep "$STARTUP_POLL_SECONDS"
    done
    if [[ "$BUS_READY" != 1 ]]; then
        cat "$TEST_DATA/engine.log" >&2
        exit 1
    fi
    python3 "${AZOOKEY_ENGINE_MAIN:-Linux/ibus-azookey-tree.py}" >> "$TEST_DATA/engine.log" 2>&1 &
    ENGINE_PID=$!
fi
ENGINE_READY=0
for ((attempt = 0; attempt < STARTUP_POLL_ATTEMPTS; attempt++)); do
    if [[ -n "$ENGINE_PID" ]] && ! kill -0 "$ENGINE_PID" 2>/dev/null; then
        cat "$TEST_DATA/engine.log" >&2
        exit 1
    fi
    # Setting an engine with layout="default" may return nonzero after the
    # engine switch succeeded. Check the selected engine, not that exit code.
    ibus engine azookey-tree >/dev/null 2>&1 || true
    if [[ "$(ibus engine 2>/dev/null)" == azookey-tree ]]; then ENGINE_READY=1; break; fi
    sleep "$STARTUP_POLL_SECONDS"
done
if [[ "$ENGINE_READY" != 1 ]]; then
    cat "$TEST_DATA/engine.log" >&2
    exit 1
fi
if ! python3 "${AZOOKEY_IBUS_TEST:-Linux/tests/ibus_integration.py}"; then
    # All text here is a fixed test fixture, never the user's document contents.
    cat "$TEST_DATA/engine.log" >&2
    exit 1
fi
if [[ -n "$ENGINE_PID" ]]; then
    python3 Linux/tests/verify_engine_source.py "$ENGINE_PID" "${AZOOKEY_ENGINE_MAIN:-Linux/ibus-azookey-tree.py}"
fi
if grep -Eq 'Traceback|(^| )([A-Za-z]+Error):' "$TEST_DATA/engine.log"; then
    cat "$TEST_DATA/engine.log" >&2
    exit 1
fi
