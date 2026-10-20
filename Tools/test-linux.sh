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
python3 Linux/tests/dictionary_exchange_integration.py -v
GDK_BACKEND=x11 xvfb-run -a python3 -m unittest Linux.tests.test_tree_panel Linux.tests.test_candidate_accessibility Linux.tests.test_candidate_details Linux.tests.test_candidate_navigation -v
dbus-run-session -- xvfb-run -a python3 -m unittest Linux.tests.test_support_diagnostics Linux.tests.test_ai_scope Linux.tests.test_settings_accessibility -v
GDK_BACKEND=x11 PYTHONPATH=Linux/tests xvfb-run -a python3 -m unittest Linux.tests.test_settings_window Linux.tests.test_user_dictionary_editor Linux.tests.test_user_dictionary_exchange_editor -v
dbus-run-session -- xvfb-run -a bash Tools/tests/linux-desktop.sh
AZOOKEY_IBUS_TEST=Linux/tests/ibus_settings_integration.py dbus-run-session -- xvfb-run -a bash Tools/tests/linux-desktop.sh
dbus-run-session -- xvfb-run -a env AZOOKEY_IBUS_TEST=Linux/tests/ibus_composition_editing.py bash Tools/tests/linux-desktop.sh
dbus-run-session -- xvfb-run -a env AZOOKEY_IBUS_TEST=Linux/tests/ibus_reconversion.py bash Tools/tests/linux-desktop.sh
bash Tools/tests/linux-async.sh
