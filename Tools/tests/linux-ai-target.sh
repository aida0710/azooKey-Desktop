#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
export XDG_RUNTIME_DIR="$(mktemp -d)"
chmod 700 "$XDG_RUNTIME_DIR"
trap 'rm -rf "$XDG_RUNTIME_DIR"' EXIT
export GDK_BACKEND=x11 GSETTINGS_BACKEND=memory GTK_IM_MODULE=simple GTK_MODULES=atk-bridge
export PYTHONPATH="$PWD/Linux:$PWD/Linux/tests${PYTHONPATH:+:$PYTHONPATH}"
unset WAYLAND_DISPLAY NO_AT_BRIDGE
NO_AT_BRIDGE=1 dbus-run-session -- xvfb-run -a python3 -m unittest test_selected_text_transform test_selected_text_dialog_focus test_selected_text_focus_return -v
dbus-run-session -- xvfb-run -a python3 Linux/tests/focused_text_gtk.py
AZOOKEY_ENGINE_MAIN=Linux/tests/ibus_ai_target_engine.py AZOOKEY_IBUS_TEST=Linux/tests/ibus_ai_target.py \
    dbus-run-session -- xvfb-run -a bash Tools/tests/linux-desktop.sh
