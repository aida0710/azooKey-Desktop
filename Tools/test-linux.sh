#!/bin/bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
[[ "$(uname -s)" == Linux ]] || { echo 'Run this script inside Ubuntu or Docker.' >&2; exit 2; }
bash Tools/tests/test-sync-upstream.sh
bash Tools/test-tree-model.sh
swift test --package-path Core
swift build --package-path Core --product azookey-desktop-bridge
export AZOOKEY_BRIDGE="$(swift build --package-path Core --show-bin-path)/azookey-desktop-bridge"
python3 -m unittest discover -s Linux/tests -v
dbus-run-session -- xvfb-run -a bash Tools/tests/linux-desktop.sh
