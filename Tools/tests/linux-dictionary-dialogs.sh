#!/bin/bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
# AT registration and key listeners must never share the desktop user's bus.
DIALOG_TEST_DIRECTORY=$(mktemp -d)
trap 'rm -rf "$DIALOG_TEST_DIRECTORY"' EXIT
export XDG_RUNTIME_DIR="$DIALOG_TEST_DIRECTORY/runtime"
mkdir -m 700 "$XDG_RUNTIME_DIR"
export GDK_BACKEND=x11 GSETTINGS_BACKEND=memory GTK_MODULES=gail:atk-bridge
export GTK_IM_MODULE=gtk-im-context-simple
unset NO_AT_BRIDGE AT_SPI_BUS_ADDRESS
# The bus-activated AT registry needs DISPLAY for its native key listener.
xvfb-run -a dbus-run-session -- python3 -m unittest discover -s Linux/tests -p '*_dialog_atspi.py' -v
