#!/bin/bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
[[ "$(uname -s)" == Linux ]] || { echo 'Run this script inside Ubuntu or Docker.' >&2; exit 2; }
bash Tools/tests/test-sync-upstream.sh
bash Tools/tests/test-docker-preflight.sh
bash Tools/test-tree-model.sh
SWIFT_OPTIONS=()
if [[ "${AZOOKEY_CPU_TRAIT:-0}" == 1 ]]; then
    SWIFT_OPTIONS+=(--traits ZenzaiCPU -Xlinker -L/opt/azookey/lib -Xlinker -lggml -Xlinker -rpath -Xlinker /opt/azookey/lib)
fi
swift test --package-path Core "${SWIFT_OPTIONS[@]}"
swift build --package-path Core --product azookey-desktop-bridge "${SWIFT_OPTIONS[@]}"
export AZOOKEY_BRIDGE="$(swift build --package-path Core --show-bin-path)/azookey-desktop-bridge"
python3 -m unittest discover -s Linux/tests -v
dbus-run-session -- xvfb-run -a python3 -m unittest Linux.tests.test_ai_scope -v
xvfb-run -a python3 Linux/tests/test_tree_panel.py -v
dbus-run-session -- xvfb-run -a bash Tools/tests/linux-desktop.sh
dbus-run-session -- xvfb-run -a env AZOOKEY_IBUS_TEST=Linux/tests/ibus_composition_editing.py bash Tools/tests/linux-desktop.sh
bash Tools/tests/linux-async.sh
