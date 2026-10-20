"""Drive real X11 widget key events; record sync-client waiting separately."""
import ctypes
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time


WAIT_SECONDS = 20
POLL_SECONDS = .01
SHIFT, CONTROL = 0xFFE1, 0xFFE3
MUHENKAN, HENKAN, LEFT, HOME, RETURN, BACKSPACE = 0xFF22, 0xFF23, 0xFF51, 0xFF50, 0xFF0D, 0xFF08
ESCAPE = 0xFF1B


class NativeKeyboard:
    def __init__(self):
        self.x11 = ctypes.CDLL("libX11.so.6")
        self.xtest = ctypes.CDLL("libXtst.so.6")
        self.x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
        self.x11.XOpenDisplay.restype = ctypes.c_void_p
        self.x11.XKeysymToKeycode.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
        self.x11.XKeysymToKeycode.restype = ctypes.c_uint
        self.x11.XSetInputFocus.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_ulong]
        self.x11.XFlush.argtypes = [ctypes.c_void_p]
        self.x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
        self.xtest.XTestFakeKeyEvent.argtypes = [
            ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong,
        ]
        self.display = self.x11.XOpenDisplay(None)
        assert self.display

    def close(self):
        self.x11.XCloseDisplay(self.display)

    def focus(self, window):
        self.x11.XSetInputFocus(self.display, window, 1, 0)
        self.x11.XFlush(self.display)

    def key(self, keyval, *, modifier=None):
        sequence = [(modifier, True)] if modifier else []
        sequence += [(keyval, True), (keyval, False)]
        if modifier:
            sequence.append((modifier, False))
        for symbol, pressed in sequence:
            keycode = self.x11.XKeysymToKeycode(self.display, symbol)
            assert keycode, f"X11 keymap has no key for {symbol}"
            self.xtest.XTestFakeKeyEvent(self.display, keycode, int(pressed), 0)
        self.x11.XFlush(self.display)


def wait_for(path, process, predicate):
    deadline = time.monotonic() + WAIT_SECONDS
    observation = {}
    while time.monotonic() < deadline:
        assert process.poll() is None, f"native widget exited {process.returncode}"
        if path.exists():
            observation = json.loads(path.read_text())
            if predicate(observation):
                return observation
        time.sleep(POLL_SECONDS)
    summary = {key: value for key, value in observation.items() if key not in ("heartbeats", "events")}
    raise AssertionError(f"native widget observation timed out: {summary}; complete observation: {path}")


def run_toolkit(toolkit, directory):
    state = directory / f"{toolkit}.json"
    environment = {**os.environ, "GTK_IM_MODULE": "ibus", "QT_IM_MODULE": "ibus",
                   "QT_QPA_PLATFORM": "xcb"}
    # Preserve the toolkit's default IBus synchronous/asynchronous behavior.
    assert "IBUS_ENABLE_SYNC_MODE" not in environment
    with (directory / f"{toolkit}.log").open("w") as log:
        process = subprocess.Popen(
            ["python3", "Linux/tests/fixtures/native_key_editor.py", toolkit, str(state)],
            env=environment, stdout=log, stderr=log,
        )
        keyboard = None
        try:
            keyboard = NativeKeyboard()
            ready = wait_for(state, process, lambda value: len(value["heartbeats"]) >= 2)
            keyboard.focus(ready["window"])
            wait_for(state, process, lambda value: value["active"])
            keyboard.key(HENKAN)
            keyboard.key(ord("a"))
            positive = wait_for(state, process, lambda value: value["preedit"] == "a" and value["text"] == "")
            modules = sorted({
                line.split(maxsplit=5)[-1].strip()
                for line in Path(f"/proc/{process.pid}/maps").read_text().splitlines()
                if "/libim-ibus.so" in line or "/libibusplatforminputcontextplugin.so" in line
            })
            assert modules, "the editor must load a real IBus input module"
            if toolkit == "gtk4":
                assert any("/gtk-4.0/" in module for module in modules), modules
            keyboard.key(ESCAPE)
            wait_for(state, process, lambda value: value["preedit"] == "" and value["text"] == "")
            keyboard.key(MUHENKAN)
            keyboard.key(ord("a"), modifier=SHIFT)
            keyboard.key(LEFT)
            keyboard.key(ord("b"), modifier=SHIFT)
            english = wait_for(state, process, lambda value: value["text"] == "BA" and value["cursor"] == 1)
            keyboard.key(HOME, modifier=CONTROL)
            idle = wait_for(state, process, lambda value: value["cursor"] == 0)
            assert idle["text"] == "BA"
            keyboard.key(ord("a"), modifier=CONTROL)
            keyboard.key(BACKSPACE)
            wait_for(state, process, lambda value: value["text"] == "")
            keyboard.key(ord("p"))
            keyboard.key(ord("q"))
            keyboard.key(LEFT)
            wait_for(state, process, lambda value: value["text"] == "pq" and value["cursor"] == 1)
            keyboard.key(HENKAN)
            keyboard.key(ord("a"))
            keyboard.key(RETURN)
            keyboard.key(HOME, modifier=CONTROL)
            pending = wait_for(state, process, lambda value: value["text"] == "paq"
                               and value["cursor"] == 0 and value["preedit"] == "")
            if toolkit == "gtk4":
                inserted = [event["text"] for event in pending["events"] if event["event"] == "insert"]
            else:
                inserted = [
                    event.get("commit", event.get("text", ""))
                    for event in pending["events"]
                    if event["event"] in ("input-method", "key-press")
                ]
            for text in ("A", "B", "p", "q", "a"):
                assert inserted.count(text) == 1, (text, inserted)
            for stage, observation in (("positive", positive), ("english", english),
                                       ("idleHome", idle), ("pendingHome", pending)):
                (directory / f"{toolkit}-{stage}.json").write_text(json.dumps(observation, ensure_ascii=False))
            beats = [value for value in pending["heartbeats"] if value >= ready["heartbeats"][-1]]
            longest_gap = max(right - left for left, right in zip(beats, beats[1:]))
            return {
                "toolkit": toolkit, "inputDelivery": "PASS", "text": pending["text"], "cursor": pending["cursor"],
                "englishText": english["text"], "englishCursor": english["cursor"],
                "maxHeartbeatGapSeconds": longest_gap, "uiResponsiveWithin100ms": longest_gap <= .1,
                "heartbeatSamples": len(beats), "syncModeOverride": False,
                "processId": process.pid, "inputModules": modules,
            }
        finally:
            if keyboard is not None:
                keyboard.close()
            process.terminate()
            process.wait(timeout=5)
            if process.returncode not in (0, -15):
                print(log.name + ":\n" + Path(log.name).read_text())


artifact_path = os.environ.get("AZOOKEY_NATIVE_ARTIFACTS")
destination = Path(artifact_path or tempfile.mkdtemp(prefix="azookey-native-toolkit-"))
destination.mkdir(parents=True, exist_ok=True)
observations = [run_toolkit(name, destination) for name in ("gtk4", "qt")]
print(json.dumps({"delaySeconds": float(os.environ["AZOOKEY_TEST_DELAY"]), "observations": observations}))
