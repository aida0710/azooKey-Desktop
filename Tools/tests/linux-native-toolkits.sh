#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
export PYTHONPATH="$PWD/Linux:$PWD/Linux/tests${PYTHONPATH:+:$PYTHONPATH}"

export AZOOKEY_REAL_BRIDGE="${AZOOKEY_BRIDGE:-$PWD/Linux/libexec/azookey-desktop-bridge}"
TEST_DIRECTORY="$(mktemp -d)"
trap 'rm -rf "$TEST_DIRECTORY"' EXIT
EVIDENCE_DIRECTORY="${AZOOKEY_TOOLKIT_ARTIFACTS:-$TEST_DIRECTORY/evidence}"
mkdir -p "$EVIDENCE_DIRECTORY"

run_case() {
    export AZOOKEY_TEST_TOOLKIT="$1"
    export AZOOKEY_TEST_SCENARIO="$2"
    export AZOOKEY_TEST_ACTIVATION="$3"
    export AZOOKEY_NATIVE_ARTIFACTS="$EVIDENCE_DIRECTORY/$AZOOKEY_TEST_DELAY-$1-$2-$3"
    # Each case owns its input context, bus, history and runtime sockets.
    mkdir "$AZOOKEY_NATIVE_ARTIFACTS"
    export XDG_RUNTIME_DIR="$TEST_DIRECTORY/runtime-$AZOOKEY_TEST_DELAY-$1-$2-$3"
    mkdir -m 700 "$XDG_RUNTIME_DIR"
    export AZOOKEY_TEST_RECONVERSION_FAILURE_FILE="$XDG_RUNTIME_DIR/fail-confirmation"
    export AZOOKEY_TEST_RECONVERSION_TRACE="$AZOOKEY_NATIVE_ARTIFACTS/operations.jsonl"
    export AZOOKEY_BRIDGE="$PWD/Linux/tests/fixtures/delayed_reconversion_bridge.py"
    export AZOOKEY_IBUS_TEST=Linux/tests/ibus_reconversion_toolkits.py
    if [[ "$2" == normal ]]; then
        export AZOOKEY_BRIDGE="$PWD/Linux/tests/fixtures/delayed_bridge.py"
        export AZOOKEY_IBUS_TEST=Linux/tests/ibus_native_toolkits.py
    fi
    dbus-run-session -- xvfb-run -a bash Tools/tests/linux-desktop.sh
}

for AZOOKEY_TEST_DELAY in 0.25 2; do
    export AZOOKEY_TEST_DELAY
    # The normal-input fixture checks both toolkits in the same daemon.
    run_case both normal key
    for activation in key property-enter property-edit property-escape; do
        run_case gtk4 undo "$activation"
        run_case qt undo "$activation"
        run_case qt selection "$activation"
    done
    run_case qt reading key
done
