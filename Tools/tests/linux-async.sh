#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
export AZOOKEY_BRIDGE="$PWD/Linux/tests/fixtures/delayed_bridge.py"
export AZOOKEY_IBUS_TEST=Linux/tests/ibus_async_integration.py
for AZOOKEY_TEST_DELAY in 0.25 2; do
    export AZOOKEY_TEST_DELAY
    dbus-run-session -- xvfb-run -a bash Tools/tests/linux-desktop.sh
done
