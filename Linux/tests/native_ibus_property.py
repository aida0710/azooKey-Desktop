"""Invoke an observed engine's public property action without moving focus."""
import json
import re
import subprocess
import time


# This public method accepts the menu action; Core completion remains asynchronous.
PROPERTY_CALL_TIMEOUT_MS = 5000


def activate_focused_property(directory, name):
    from gi.repository import Gio, GLib

    observed = (directory / "ibus-events.log").read_text()
    focus = list(re.finditer(
        r'method call [^\n]*path=(\S+); interface=org.freedesktop.IBus.Engine; member=FocusInId\n'
        r'\s+string "([^"]+)"\n\s+string "([^"]+)"', observed,
    ))
    assert focus, "the real widget must establish an IBus focus identity"
    engine_path, context_path, client = focus[-1].groups()
    assert client != "fake", "property activation must target the real widget"
    senders = re.findall(
        r'signal [^\n]*sender=(\S+) [^\n]*path=' + re.escape(engine_path)
        + r'; interface=org.freedesktop.IBus.Engine;', observed,
    )
    assert senders, "the focused engine's D-Bus connection must be observed"
    address = subprocess.check_output(["ibus", "address"], text=True).strip()
    started = time.monotonic()
    connection = Gio.DBusConnection.new_for_address_sync(
        address, Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION,
        None, None,
    )
    try:
        response = connection.call_sync(
            senders[-1], engine_path, "org.freedesktop.IBus.Engine", "PropertyActivate",
            GLib.Variant("(su)", (name, 0)), GLib.VariantType.new("()"),
            Gio.DBusCallFlags.NONE, PROPERTY_CALL_TIMEOUT_MS, None,
        )
    finally:
        connection.close_sync(None)
    activation = {
        "property": name, "client": client, "context": context_path,
        "engine": engine_path, "destination": senders[-1],
        "startedMonotonic": started, "completedMonotonic": time.monotonic(),
        "reply": response.unpack(),
    }
    (directory / "property-activation.json").write_text(json.dumps(activation, indent=2) + "\n")
    return activation
