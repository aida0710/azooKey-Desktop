"""Compare input activation paths after a failed TextEdit conversion."""

import getpass
import json
import os
import time

# Diagnostic input needs only the preedit, before potentially slow conversion.
PREEDIT_WAIT_SECONDS = 3
POLL_INTERVAL_SECONDS = 0.25


def diagnose_input(evidence, input_source, send_keys):
    document = evidence.directory / "helpers/TextEditDocument"
    evidence.run("bootstrap-manager", ["launchctl", "managername"])
    evidence.run("preferences-current-host", ["defaults", "-currentHost", "read", "com.apple.HIToolbox"])
    observations = []

    def type_and_read(name):
        evidence.run(name + "-clear", [document, "clear"])
        evidence.run(name + "-type", [send_keys, "nihongo"])
        deadline = time.monotonic() + PREEDIT_WAIT_SECONDS
        text = None
        attempt = 0
        while time.monotonic() < deadline:
            completed = evidence.run(f"{name}-read-{attempt}", [document, "read"])
            if completed.returncode == 0:
                text = json.loads(completed.stdout)["text"]
                if text:
                    break
            time.sleep(POLL_INTERVAL_SECONDS)
            attempt += 1
        observations.append({"name": name, "text": text})
        evidence.screenshot(name)

    # A known system IME distinguishes event injection problems from this package.
    listing = evidence.run("diagnostic-sources", [input_source, "list"])
    if listing.returncode == 0:
        japanese = next((source for source in json.loads(listing.stdout)
                         if source["id"] == "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese"), None)
        if japanese:
            evidence.run("diagnostic-select-system-japanese", [input_source, "select", japanese["id"]])
            type_and_read("diagnostic-system-japanese")

    source = "dev.ensan.inputmethod.azooKeyMac.Japanese"
    gui_command = ["sudo", "launchctl", "asuser", str(os.getuid()), "sudo", "-u", getpass.getuser()]
    evidence.run("bootstrap-gui-manager", [*gui_command, "launchctl", "managername"])
    evidence.run("diagnostic-select-gui", [*gui_command, input_source, "select", source])
    type_and_read("diagnostic-gui-selection")

    # Reactivation recreates the editor's active input context without injecting text.
    evidence.run("diagnostic-activate-finder", ["open", "-a", "Finder"])
    evidence.run("diagnostic-activate-editor", ["open", "-a", "TextEdit"])
    evidence.run("diagnostic-select-reactivated", [input_source, "select", source])
    type_and_read("diagnostic-reactivated-editor")
    evidence.write_json("input-diagnostics.json", observations)
