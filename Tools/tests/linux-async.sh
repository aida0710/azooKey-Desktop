#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
# The synthetic converter asks the real bridge only which keys Core routes.
export AZOOKEY_REAL_BRIDGE="${AZOOKEY_BRIDGE:-$PWD/Linux/libexec/azookey-desktop-bridge}"
export AZOOKEY_BRIDGE="$PWD/Linux/tests/fixtures/delayed_bridge.py"
for AZOOKEY_TEST_DELAY in 0.25 2; do
    export AZOOKEY_TEST_DELAY
    for AZOOKEY_IBUS_TEST in Linux/tests/ibus_async_integration.py Linux/tests/ibus_native_keys.py; do
        export AZOOKEY_IBUS_TEST
        dbus-run-session -- xvfb-run -a bash Tools/tests/linux-desktop.sh
    done
done
