#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
export AZOOKEY_REAL_BRIDGE="${AZOOKEY_BRIDGE:-$PWD/Linux/libexec/azookey-desktop-bridge}"
export AZOOKEY_BRIDGE="$PWD/Linux/tests/fixtures/delayed_reconversion_bridge.py"
FAILURE_DIRECTORY="$(mktemp -d)"
trap 'rm -rf "$FAILURE_DIRECTORY"' EXIT
export AZOOKEY_TEST_RECONVERSION_FAILURE_FILE="$FAILURE_DIRECTORY/fail-confirmation"
export AZOOKEY_IBUS_TEST=Linux/tests/ibus_reconversion_native.py
for AZOOKEY_TEST_DELAY in 0.25 2; do
    export AZOOKEY_TEST_DELAY
    dbus-run-session -- xvfb-run -a bash Tools/tests/linux-desktop.sh
done
