"""Observe real GTK dialogs through a separate AT client and native X11 keys."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

import gi
gi.require_version("Atspi", "2.0")
from gi.repository import Atspi, GLib

from native_toolkit_support import NativeKeyboard

# Deadlines report an unresponsive fixture; they do not release GTK or AT calls.
OBSERVATION_TIMEOUT_SECONDS = 5
POLL_INTERVAL_SECONDS = .01
CONTROL_MODIFIER_MASK = 4
PRESSED_AND_RELEASED = 3
SOURCE_ROOT = Path(os.environ.get("AZOOKEY_TEST_PRODUCT_ROOT", Path(__file__).resolve().parents[1]))


def descendants(accessible):
    yield accessible
    for index in range(accessible.get_child_count()):
        child = accessible.get_child_at_index(index)
        if child is not None:
            yield from descendants(child)


class GtkDialogAtspiTestCase(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="azookey-dialog-atspi-")
        self.addCleanup(self.temporary.cleanup)
        artifact_root = os.environ.get("AZOOKEY_TEST_ARTIFACT_DIRECTORY")
        self.directory = Path(artifact_root or self.temporary.name) / self._testMethodName
        self.directory.mkdir(parents=True, exist_ok=False)
        self.observation_path = self.directory / "widget.json"
        self.events = []
        self.key_events = []
        self.addCleanup(self.save_trial)
        self.listener = Atspi.DeviceListener.new(self.observe_key)
        self.addCleanup(self.remove_listener)
        mode = Atspi.KeyListenerSyncType.SYNCHRONOUS | Atspi.KeyListenerSyncType.CANCONSUME
        for mask in (0, CONTROL_MODIFIER_MASK):
            # AT-SPI 2.52's registry returns FALSE even after registering. Prove
            # readiness with actual key delivery before activating any chooser.
            registered = Atspi.register_keystroke_listener(
                self.listener, [], mask, PRESSED_AND_RELEASED, mode)
            self.events.append({"registerListener": mask, "returned": registered})
        self.log = (self.directory / "widget.log").open("w")
        self.addCleanup(self.log.close)
        self.process = subprocess.Popen(
            [sys.executable, str(Path(__file__).with_name(self.fixture_name)),
             str(self.observation_path), "--source-root", str(SOURCE_ROOT)],
            stdout=self.log, stderr=subprocess.STDOUT,
        )
        self.addCleanup(self.stop_widget)
        self.keyboard = NativeKeyboard()
        self.addCleanup(self.keyboard.close)
        self.wait_for(lambda: self.observation() is not None, "editor-ready")

    def stop_widget(self):
        self.process.terminate()
        try:
            self.process.wait(timeout=OBSERVATION_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()

    def remove_listener(self):
        for mask in (0, CONTROL_MODIFIER_MASK):
            Atspi.deregister_keystroke_listener(self.listener, [], mask, PRESSED_AND_RELEASED)

    def save_trial(self):
        (self.directory / "trial.json").write_text(json.dumps({
            "source": {path: hashlib.sha256((SOURCE_ROOT / path).read_bytes()).hexdigest() for path in self.product_paths},
            "events": self.events, "keys": self.key_events,
        }, ensure_ascii=False, indent=2) + "\n")

    def observe_key(self, event):
        self.key_events.append({"type": int(event.type), "keyval": event.id,
                                "modifiers": event.modifiers, "text": event.event_string})
        return False

    def observation(self):
        if self.observation_path.exists():
            return json.loads(self.observation_path.read_text())
        return None

    def wait_for(self, predicate, stage):
        deadline = time.monotonic() + OBSERVATION_TIMEOUT_SECONDS
        context = GLib.MainContext.default()
        while time.monotonic() < deadline:
            while context.pending():
                context.iteration(False)
            self.assertIsNone(self.process.poll(), "GTK fixture exited before " + stage)
            if predicate():
                self.events.append({"stage": stage, "at": time.time(), "widget": self.observation()})
                return
            time.sleep(POLL_INTERVAL_SECONDS)
        self.events.append({"failedStage": stage, "at": time.time(), "widget": self.observation()})
        self.fail("GTK/AT-SPI observation did not complete: " + stage)

    def application(self):
        desktop = Atspi.get_desktop(0)
        for index in range(desktop.get_child_count()):
            application = desktop.get_child_at_index(index)
            if application.get_process_id() == self.process.pid:
                return application
        return None

    def activate(self, root, name):
        matches = [item for item in descendants(root)
                   if item.get_name() == name and item.get_state_set().contains(Atspi.StateType.SHOWING)
                   and item.get_action_iface() is not None and item.get_action_iface().get_n_actions()]
        self.assertEqual(len(matches), 1, name)
        self.assertTrue(matches[0].get_action_iface().do_action(0))
        self.events.append({"atAction": name, "at": time.time()})

    def send_key(self, keyval, *, modifiers=()):
        previous_count = len(self.key_events)
        self.keyboard.key(keyval, modifiers=modifiers)
        self.wait_for(lambda: any(event["keyval"] == keyval
                                  and event["type"] == int(Atspi.EventType.KEY_RELEASED_EVENT)
                                  for event in self.key_events[previous_count:]),
                      "at-key-release-" + str(keyval))

    def focus_window(self, window):
        def is_viewable():
            visible = subprocess.run(
                ["xdotool", "search", "--onlyvisible", "--pid", str(self.process.pid)],
                check=False, capture_output=True, text=True,
            )
            return str(window) in visible.stdout.splitlines()

        self.wait_for(is_viewable, "x11-window-viewable-" + str(window))
        self.keyboard.focus(window)
