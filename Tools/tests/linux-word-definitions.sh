#!/bin/bash
# Run in the project's Ubuntu image; GTK needs an isolated display and session bus.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
python3 -m unittest Linux.tests.test_word_definitions -v
GDK_BACKEND=x11 GSETTINGS_BACKEND=memory dbus-run-session -- xvfb-run -a \
    python3 -m unittest Linux.tests.test_word_definitions_gtk Linux.tests.test_word_definitions_surface -v
gjs -m Linux/tests/word_definitions_gjs.js
