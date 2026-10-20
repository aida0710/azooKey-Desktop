"""Verify deferred delivery and context safety through an actual IBus daemon."""
import json
import os
import pathlib
import statistics
import time

import gi
gi.require_version("IBus", "1.0")
from gi.repository import IBus, GLib, Gio
from ibus_support import crash_converter


# The engine's main-loop query must stay responsive while original keys wait.
ENGINE_REPLY_BUDGET_SECONDS = 0.1
WAIT_BUDGET_SECONDS = 12
POLL_INTERVAL_SECONDS = 0.005


def wait_until(predicate, *, while_pending=None):
    deadline = time.monotonic() + WAIT_BUDGET_SECONDS
    while not predicate():
        if time.monotonic() > deadline:
            raise AssertionError("IBus fixture did not reach the expected state")
        if while_pending:
            while_pending()
        GLib.MainContext.default().iteration(False)
        time.sleep(POLL_INTERVAL_SECONDS)
    while GLib.MainContext.default().pending():
        GLib.MainContext.default().iteration(False)


class Field:
    def __init__(self, bus, name):
        self.context = bus.create_input_context(name)
        self.context.set_capabilities(IBus.Capabilite.PREEDIT_TEXT | IBus.Capabilite.FOCUS)
        self.commits = []
        self.forwarded = []
        self.native = []
        self.native_reply_timings = []
        self.key_reply_timings = []
        self.preedit = ""
        self.document = ""
        self.cursor = 0
        self.engine_response_timings = []
        self.engine_connection = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        self.context.connect("commit-text", self.commit)
        self.context.connect("update-preedit-text", self.update_preedit)
        self.context.connect("forward-key-event", self.forward_key)

    def forward_key(self, _context, keyval, keycode, state):
        self.forwarded.append((keyval, keycode, state & ~IBus.ModifierType.FORWARD_MASK))
        self.deliver_native(keyval, state)

    def deliver_native(self, keyval, state):
        if keyval == IBus.KEY_Left:
            self.cursor = max(0, self.cursor - 1)
        elif keyval == IBus.KEY_Right:
            self.cursor = min(len(self.document), self.cursor + 1)
        elif 32 <= keyval <= 126 and not state & (IBus.ModifierType.CONTROL_MASK | IBus.ModifierType.MOD1_MASK):
            self.insert(chr(keyval))

    def commit(self, _context, text):
        self.commits.append(text.get_text())
        self.insert(text.get_text())

    def insert(self, text):
        self.document = self.document[:self.cursor] + text + self.document[self.cursor:]
        self.cursor += len(text)

    def update_preedit(self, _context, text, _cursor, visible):
        self.preedit = text.get_text() if visible else ""

    def focus(self):
        self.context.focus_in()
        # set_engine() is fire-and-forget; GetEngine can still describe the
        # previous engine while replacement is pending. Await the method reply.
        self.context.call_sync("SetEngine", GLib.Variant("(s)", ("azookey-tree",)),
                               Gio.DBusCallFlags.NONE, 5000, None)
        wait_until(lambda: self.context.get_engine() is not None)

    def measure_engine_response(self):
        started = time.monotonic()
        # RendererStatus executes in ShellSurface.method on the engine's GLib
        # loop. GetEngine only queries IBus's cached descriptor in the daemon.
        self.engine_connection.call_sync(
            "org.azookey.Tree", "/org/azookey/Tree", "org.azookey.Tree", "RendererStatus",
            None, GLib.VariantType.new("(b)"), Gio.DBusCallFlags.NONE,
            int(WAIT_BUDGET_SECONDS * 1000), None,
        )
        duration = time.monotonic() - started
        self.engine_response_timings.append(duration)
        assert duration < ENGINE_REPLY_BUDGET_SECONDS, f"engine main-loop query blocked for {duration:.3f}s"

    def key(self, keyval, state=0, *, keycode=38):
        started = time.monotonic()
        replied = False
        reply_errors = []

        def completed(context, response, _user_data):
            nonlocal replied
            try:
                assert not replied, "an original key must complete only once"
                consumed = context.process_key_event_async_finish(response)
                duration = time.monotonic() - started
                self.key_reply_timings.append({
                    "keyval": keyval, "state": int(state), "consumed": consumed, "seconds": duration,
                })
                if not consumed:
                    # Deliver the saved original event after preceding commits,
                    # separately from engine-generated ForwardKeyEvent.
                    self.native.append((keyval, keycode, state))
                    self.native_reply_timings.append(duration)
                    self.deliver_native(keyval, state)
                replied = True
            except Exception as error:
                # GI reports callback exceptions without failing the caller.
                reply_errors.append(error)

        self.context.process_key_event_async(keyval, keycode, state, -1, None, completed, None)
        wait_until(lambda: replied or reply_errors, while_pending=self.measure_engine_response)
        if reply_errors:
            raise reply_errors[0]

    def type(self, text):
        for character in text:
            self.key(ord(character))

    def cancel(self):
        self.key(IBus.KEY_Escape)
        wait_until(lambda: self.preedit == "")


def main():
    IBus.init()
    bus = IBus.Bus()
    assert bus.is_connected()
    first = Field(bus, "azookey-delay-first")
    second = Field(bus, "azookey-delay-second")
    first.focus()

    # Original replies can wait for conversion; the independent engine query
    # must remain responsive. A second Enter follows the first Enter's commit.
    first.type("abc")
    first.key(IBus.KEY_Return)
    first.key(IBus.KEY_Return)
    wait_until(lambda: len(first.native) == 1)
    assert first.commits == ["abc"], first.commits
    assert first.native == [(IBus.KEY_Return, 38, 0)], first.native
    assert first.forwarded == []

    # These sequential edits wait for their replies. ibus_native_keys.py
    # separately changes focus, resets and cancels before original replies.
    first.type("a")
    first.cancel()
    first.type("b")
    wait_until(lambda: first.preedit == "b")
    first.context.focus_out()
    second.focus()
    second.type("z")
    second.key(IBus.KEY_Return)
    wait_until(lambda: second.commits == ["z"])
    assert first.commits == ["abc", "b"], first.commits
    assert second.commits == ["z"], second.commits

    # Explicit reset uses IBus's documented COMMIT focus mode; Escape above is
    # cancellation. Both must leave no delayed converter effects to reappear.
    second.type("c")
    wait_until(lambda: second.preedit == "c")
    second.context.reset()
    wait_until(lambda: second.commits == ["z", "c"])
    assert second.preedit == ""

    # A nonresponding conversion recovers the last acknowledged text once and
    # returns the two original keys without reconstructing them.
    second.type("d")
    # Reset keeps the language, but its authoritative reply may still be
    # pending. Enter needs that reply to distinguish commit from native Enter.
    second.key(IBus.KEY_Return)
    wait_until(lambda: second.commits == ["z", "c", "d"])
    second.type("hx")
    assert second.native == [(ord("h"), 38, 0), (ord("x"), 38, 0)]
    assert second.forwarded == []
    assert second.document == "zcdhx"
    assert not second.context.process_key_event(ord("q"), 38, 0), "recovery must allow immediate application input"
    crash_converter(Gio.bus_get_sync(Gio.BusType.SESSION, None), "delayed_bridge.py")
    # The language key changes no document text and lets the test observe that
    # the reset barrier has completed without relying on a fixed sleep.
    wait_until(lambda: second.context.process_key_event(IBus.KEY_Henkan, 38, 0))
    second.type("y")
    second.key(IBus.KEY_Return)
    wait_until(lambda: second.commits == ["z", "c", "d", "y"])
    assert first.commits == ["abc", "b"]
    regression_fields = check_editing_during_delay(bus)
    regression_fields.append(check_modifier_presses(bus))
    fields = [first, second, *regression_fields]
    timings = [value * 1000 for field in fields for value in field.engine_response_timings]
    print(json.dumps({
        "injected_delay_seconds": float(os.environ["AZOOKEY_TEST_DELAY"]),
        "engine_response_samples": len(timings),
        "engine_response_p50_ms": round(statistics.median(timings), 3),
        "engine_response_p95_ms": round(sorted(timings)[int(len(timings) * 0.95)], 3),
        "engine_response_max_ms": round(max(timings), 3),
        "native_reply_seconds": first.native_reply_timings,
        "original_reply_timings": [
            reply for field in fields for reply in field.key_reply_timings
        ],
        "status": "PASS",
    }))
    second.context.focus_out()


def check_editing_during_delay(bus):
    """Exercise acknowledged editing with a delayed backend through real IBus."""
    conversion = Field(bus, "azookey-delay-escape")
    conversion.focus()
    conversion.type("kana")
    conversion.key(IBus.KEY_space)
    conversion.key(IBus.KEY_Escape)
    wait_until(lambda: conversion.preedit == "kana")
    conversion.context.focus_out()
    wait_until(lambda: conversion.commits == ["kana"])

    editing = Field(bus, "azookey-delay-control-backspace")
    editing.focus()
    editing.type("ab")
    editing.key(ord("h"), IBus.ModifierType.CONTROL_MASK)
    editing.context.focus_out()
    wait_until(lambda: editing.commits == ["a"])

    english = Field(bus, "azookey-delay-native-caret")
    english.focus()
    english.key(IBus.KEY_Muhenkan)
    english.type("a")
    english.key(IBus.KEY_Left)
    english.type("b")
    english.context.focus_out()
    wait_until(lambda: english.document == "ba")

    suggestion = Field(bus, "azookey-delay-ai-edit")
    suggestion.focus()
    suggestion.type("a")
    wait_until(lambda: suggestion.preedit == "a")
    suggestion.key(IBus.KEY_F7)
    wait_until(lambda: suggestion.preedit == "人工知能の候補")
    suggestion.type("a")
    suggestion.context.focus_out()
    wait_until(lambda: suggestion.commits == ["にほんごa"])

    broken_settings = Field(bus, "azookey-delay-settings-error")
    broken_settings.focus()
    broken_settings.type("n")
    settings_path = pathlib.Path(os.environ["XDG_CONFIG_HOME"]) / "azookey-tree/settings.json"
    settings_path.parent.mkdir(parents=True, exist_ok=True)
    settings_path.write_text("{synthetic invalid JSON")
    try:
        broken_settings.type("a")
        broken_settings.key(IBus.KEY_Return)
        wait_until(lambda: broken_settings.commits == ["na"])
        assert broken_settings.forwarded == []
    finally:
        settings_path.unlink()
        broken_settings.context.focus_out()
    # Delayed responses must not change any field after it lost focus.
    assert conversion.commits == ["kana"]
    assert editing.commits == ["a"]
    assert english.document == "ba"
    assert suggestion.commits == ["にほんごa"]
    return [conversion, editing, english, suggestion, broken_settings]


def check_modifier_presses(bus):
    """Include physical modifier events, not only masks on a later arrow."""
    field = Field(bus, "azookey-delay-physical-modifiers")
    field.focus()
    modifiers = (
        (IBus.KEY_Shift_L, IBus.ModifierType.SHIFT_MASK),
        (IBus.KEY_Control_L, IBus.ModifierType.CONTROL_MASK),
        (IBus.KEY_Alt_L, IBus.ModifierType.MOD1_MASK),
        (IBus.KEY_Super_L, IBus.ModifierType.SUPER_MASK),
    )

    def modifier(keyval, state):
        # A modifier can be returned immediately when idle, or ordered behind
        # pending input. Neither path may commit or insert document text.
        field.key(keyval, state, keycode=0)

    for composing in (False, True):
        if composing:
            field.type("abc")
        for keyval, mask in modifiers:
            modifier(keyval, 0)
            modifier(keyval, mask | IBus.ModifierType.RELEASE_MASK)
        assert field.commits == [], field.commits
        assert not any(32 <= key[0] <= 126 for key in field.forwarded), field.forwarded
    modifier(IBus.KEY_Shift_L, 0)
    field.key(IBus.KEY_Left, IBus.ModifierType.SHIFT_MASK)
    modifier(IBus.KEY_Shift_L, IBus.ModifierType.SHIFT_MASK | IBus.ModifierType.RELEASE_MASK)
    field.key(IBus.KEY_Return)
    wait_until(lambda: field.commits == ["abc"])
    assert field.document == "abc", field.document
    field.context.focus_out()
    return field


if __name__ == "__main__":
    main()
