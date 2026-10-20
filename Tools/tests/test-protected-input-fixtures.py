#!/usr/bin/python3
"""Widget checks only; real IME, privacy transport and Orca require VM trials."""
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

from protected_fixture_state import FIELD_LABELS, READ_ONLY_TEXT


# Wait for an observed focus/text change, including a cold toolkit startup.
OBSERVATION_TIMEOUT_SECONDS = 10
OBSERVATION_POLL_SECONDS = 0.02
FIXTURE_DIRECTORY = Path(__file__).resolve().parent


class ProtectedFixtureChecks:
    def setUp(self):
        if not shutil.which("xdotool"):
            self.skipTest("xdotool and an X11 display are required")
        self.check_toolkit()
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.output = Path(self.directory.name) / "state.json"
        self.events = Path(self.directory.name) / "events.jsonl"
        self.error_log = (Path(self.directory.name) / "stderr.log").open("w+")
        self.addCleanup(self.error_log.close)
        self.process = subprocess.Popen(
            [
                sys.executable, str(FIXTURE_DIRECTORY / self.fixture),
                "--output", str(self.output), "--events", str(self.events),
            ],
            stdout=self.error_log, stderr=subprocess.STDOUT,
        )
        self.addCleanup(self.stop_fixture)
        self.wait_for_state(lambda state: len(state["fields"]) == len(FIELD_LABELS))
        windows = subprocess.check_output(
            ["xdotool", "search", "--onlyvisible", "--name", self.window_title], text=True,
        ).splitlines()
        self.assertEqual(len(windows), 1)
        subprocess.run(["xdotool", "windowfocus", "--sync", windows[0]], check=True)
        self.wait_for_state(lambda state: self.focused_id(state) == "normal")

    def stop_fixture(self):
        if self.process.poll() is None:
            self.process.terminate()
            self.process.wait(timeout=OBSERVATION_TIMEOUT_SECONDS)

    def wait_for_state(self, condition):
        deadline = time.monotonic() + OBSERVATION_TIMEOUT_SECONDS
        state = None
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                self.error_log.seek(0)
                self.fail(f"Fixture exited: {self.error_log.read()}")
            if self.output.exists():
                state = json.loads(self.output.read_text())
                if condition(state):
                    return state
            time.sleep(OBSERVATION_POLL_SECONDS)
        self.error_log.seek(0)
        self.fail(f"Condition was not observed: {state}; stderr: {self.error_log.read()}")

    @staticmethod
    def focused_id(state):
        fields = [field["id"] for field in state["fields"] if field["focused"]]
        return fields[0] if len(fields) == 1 else None

    def key(self, name):
        subprocess.run(["xdotool", "key", "--clearmodifiers", name], check=True)

    def test_tab_navigation_preserves_protected_attributes_and_read_only_text(self):
        expected_texts = {}
        for field_id in FIELD_LABELS:
            state = self.wait_for_state(lambda state: self.focused_id(state) == field_id)
            field = next(field for field in state["fields"] if field["id"] == field_id)
            self.assertEqual(field["label"], FIELD_LABELS[field_id])
            self.assertEqual(field["attributes"]["editable"], field_id != "read-only")
            self.check_attributes(field)
            subprocess.run(["xdotool", "type", "--clearmodifiers", "TEST123"], check=True)
            if field_id == "read-only":
                # Moving away provides an observed native event after the keys.
                self.key("shift+Tab")
                state = self.wait_for_state(lambda state: self.focused_id(state) == "private")
                expected_texts[field_id] = READ_ONLY_TEXT
            else:
                expected_texts[field_id] = "TEST123"
                state = self.wait_for_state(lambda state: next(
                    item["text"] for item in state["fields"] if item["id"] == field_id
                ) == "TEST123")
                self.key("Tab")
            for field in state["fields"]:
                if field["id"] in expected_texts:
                    self.assertEqual(field["text"], expected_texts[field["id"]])
        observations = [json.loads(line) for line in self.events.read_text().splitlines()]
        self.assertTrue(any(event["event"] == self.native_event for event in observations))
        self.assertEqual(self.output.stat().st_mode & 0o777, 0o600)


class GTKProtectedFixtureTests(ProtectedFixtureChecks, unittest.TestCase):
    fixture = "gtk-protected-editor.py"
    window_title = "^azooKey protected input — GTK4$"
    native_event = "inserted-text"

    def check_toolkit(self):
        try:
            import gi
            gi.require_version("Gtk", "4.0")
        except (ImportError, ValueError):
            self.skipTest("GTK4 introspection is required")

    def check_attributes(self, field):
        attributes = field["attributes"]
        expected_purpose = {"password": "password", "pin": "pin"}.get(field["id"], "free-form")
        self.assertEqual(attributes["inputPurpose"], expected_purpose)
        self.assertEqual(attributes["visibleText"], field["id"] not in ("password", "pin"))
        self.assertEqual(attributes["privateHint"], field["id"] == "private")


class QtProtectedFixtureTests(ProtectedFixtureChecks, unittest.TestCase):
    fixture = "qt-protected-editor.py"
    window_title = "^azooKey protected input — Qt$"
    native_event = "key-press"

    def check_toolkit(self):
        if importlib.util.find_spec("PyQt6") is None:
            self.skipTest("PyQt6 is required")

    def check_attributes(self, field):
        from PyQt6.QtCore import Qt
        attributes = field["attributes"]
        self.assertEqual(
            attributes["echoMode"], "Password" if field["id"] in ("password", "pin") else "Normal"
        )
        if field["id"] == "private":
            self.assertTrue(attributes["sensitiveDataHint"])
        if field["id"] == "pin":
            self.assertTrue(attributes["inputHints"] & Qt.InputMethodHint.ImhDigitsOnly.value)


if __name__ == "__main__":
    unittest.main()
