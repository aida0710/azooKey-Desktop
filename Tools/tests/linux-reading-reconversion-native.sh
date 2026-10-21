#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."

export AZOOKEY_REAL_BRIDGE="${AZOOKEY_BRIDGE:-$PWD/Linux/libexec/azookey-desktop-bridge}"
export AZOOKEY_BRIDGE="$PWD/Linux/tests/fixtures/recording_reading_bridge.py"
export AZOOKEY_ENGINE_MAIN=Linux/tests/fixtures/reading_engine_main.py
export AZOOKEY_IBUS_TEST=Linux/tests/ibus_reading_reconversion.py
export PYTHONPATH="$PWD/Linux:$PWD/Linux/tests${PYTHONPATH:+:$PYTHONPATH}"

# Keep native traffic and real-Core replies for inspection after daemon teardown.
EVIDENCE_ROOT="${AZOOKEY_RECONVERSION_ARTIFACTS:-$(mktemp -d)}"
mkdir -p "$EVIDENCE_ROOT"
EVIDENCE_ROOT="$(realpath "$EVIDENCE_ROOT")"
if [[ "$#" == 0 ]]; then
    set -- known focus private changed private-start undo unknown confirm-focus confirm-reset qt-confirm-reset
fi

TEST_STATUS=0
for AZOOKEY_RECONVERSION_CASE in "$@"; do
    case "$AZOOKEY_RECONVERSION_CASE" in
        known|focus|private|changed|private-start|undo|unknown|confirm-focus|confirm-reset|qt-confirm-reset) ;;
        *) printf 'Unknown reconversion case: %s\n' "$AZOOKEY_RECONVERSION_CASE" >&2; exit 2 ;;
    esac
    export AZOOKEY_RECONVERSION_CASE
    export AZOOKEY_NATIVE_ARTIFACTS="$EVIDENCE_ROOT/$AZOOKEY_RECONVERSION_CASE"
    # Refuse to replace a previous result, including a failed trial.
    mkdir "$AZOOKEY_NATIVE_ARTIFACTS"
    if ! dbus-run-session -- xvfb-run -a bash Tools/tests/linux-desktop.sh \
            > "$AZOOKEY_NATIVE_ARTIFACTS/session.log" 2>&1; then
        cat "$AZOOKEY_NATIVE_ARTIFACTS/session.log" >&2
        TEST_STATUS=1
    fi
done
printf 'Reconversion evidence: %s\n' "$EVIDENCE_ROOT"
exit "$TEST_STATUS"
