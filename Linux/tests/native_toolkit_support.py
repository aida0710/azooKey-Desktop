"""Send real X11 keys and read observations from isolated native widgets."""
import ctypes
import json
from pathlib import Path
import time


# Allow the delayed Core startup and two 2-second reconversion requests.
WAIT_SECONDS = 20
POLL_SECONDS = .01
SHIFT, CONTROL = 0xFFE1, 0xFFE3
MUHENKAN, HENKAN, LEFT, RIGHT = 0xFF22, 0xFF23, 0xFF51, 0xFF53
HOME, RETURN, BACKSPACE, ESCAPE, F10 = 0xFF50, 0xFF0D, 0xFF08, 0xFF1B, 0xFFC7


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

    def key(self, keyval, *, modifiers=()):
        sequence = [(modifier, True) for modifier in modifiers]
        sequence += [(keyval, True), (keyval, False)]
        sequence += [(modifier, False) for modifier in reversed(modifiers)]
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


def loaded_input_modules(process, toolkit):
    modules = sorted({
        line.split(maxsplit=5)[-1].strip()
        for line in Path(f"/proc/{process.pid}/maps").read_text().splitlines()
        if "/libim-ibus.so" in line or "/libibusplatforminputcontextplugin.so" in line
    })
    assert modules, "the editor must load a real IBus input module"
    if toolkit == "gtk4":
        assert any("/gtk-4.0/" in module for module in modules), modules
    return modules


def heartbeat_summary(ready, final):
    beats = [value for value in final["heartbeats"] if value >= ready["heartbeats"][-1]]
    longest_gap = max(right - left for left, right in zip(beats, beats[1:]))
    return {
        "maxHeartbeatGapSeconds": longest_gap,
        "uiResponsiveWithin100ms": longest_gap <= .1,
        "heartbeatSamples": len(beats),
    }
