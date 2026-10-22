#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
export PYTHONPATH="$PWD/Linux:$PWD/Linux/tests${PYTHONPATH:+:$PYTHONPATH}"
export GSETTINGS_BACKEND=memory GTK_IM_MODULE=gtk-im-context-simple
AZOOKEY_ENGINE_MAIN=Linux/tests/ibus_ime_shortcut_engine.py AZOOKEY_IBUS_TEST=Linux/tests/ibus_ime_shortcuts.py \
    dbus-run-session -- xvfb-run -a bash Tools/tests/linux-desktop.sh
