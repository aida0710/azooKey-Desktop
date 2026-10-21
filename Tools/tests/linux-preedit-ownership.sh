#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
export PYTHONPATH="$PWD/Linux:$PWD/Linux/tests${PYTHONPATH:+:$PYTHONPATH}"
export AZOOKEY_ENGINE_MAIN=Linux/tests/fixtures/preedit_ownership_engine.py
export AZOOKEY_IBUS_TEST=Linux/tests/ibus_preedit_ownership.py
TEST_STATUS=0
for AZOOKEY_TEST_PREEDIT_ADAPTER in ordinary reading; do
    export AZOOKEY_TEST_PREEDIT_ADAPTER
    if [[ -n "${AZOOKEY_PREEDIT_ARTIFACTS:-}" ]]; then
        export AZOOKEY_PREEDIT_EVIDENCE="$AZOOKEY_PREEDIT_ARTIFACTS/$AZOOKEY_TEST_PREEDIT_ADAPTER.json"
    fi
    if ! dbus-run-session -- xvfb-run -a bash Tools/tests/linux-desktop.sh; then
        TEST_STATUS=1
    fi
done
exit "$TEST_STATUS"
