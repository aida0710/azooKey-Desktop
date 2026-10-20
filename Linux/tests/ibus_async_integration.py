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


# A callback budget is deliberately much shorter than either injected delay.
CALLBACK_BUDGET_SECONDS = 0.1
WAIT_BUDGET_SECONDS = 12
POLL_INTERVAL_SECONDS = 0.005


def wait_until(predicate):
    deadline = time.monotonic() + WAIT_BUDGET_SECONDS
    while not predicate():
        if time.monotonic() > deadline:
            raise AssertionError("IBus fixture did not reach the expected state")
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
        self.preedit = ""
        self.document = ""
        self.cursor = 0
        self.timings = []
        self.context.connect("commit-text", self.commit)
        self.context.connect("update-preedit-text", self.update_preedit)
        self.context.connect("forward-key-event", self.forward_key)

    def forward_key(self, _context, keyval, keycode, state):
        self.forwarded.append((keyval, keycode, state & ~IBus.ModifierType.FORWARD_MASK))
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

    def key(self, keyval, state=0):
        start = time.monotonic()
        assert self.context.process_key_event(keyval, 38, state)
        duration = time.monotonic() - start
        self.timings.append(duration)
        assert duration < CALLBACK_BUDGET_SECONDS, f"key callback blocked for {duration:.3f}s"
        while GLib.MainContext.default().pending():
            GLib.MainContext.default().iteration(False)

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

    # Each key is accepted before the delayed converter can return. A second
    # Enter must be forwarded only after the first Enter committed the text.
    first.type("abc")
    first.key(IBus.KEY_Return)
    first.key(IBus.KEY_Return)
    wait_until(lambda: len(first.forwarded) == 1)
    assert first.commits == ["abc"], first.commits
    assert first.forwarded == [(IBus.KEY_Return, 38, 0)], first.forwarded

    # Cancellation and an application switch are handled while I/O is waiting.
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
    # forwards only the two unacknowledged keys. New input then works normally.
    second.type("d")
    second.key(IBus.KEY_Return)
    wait_until(lambda: second.commits == ["z", "c", "d"])
    second.type("hx")
    wait_until(lambda: len(second.forwarded) == 2)
    assert second.forwarded == [(ord("h"), 38, 0), (ord("x"), 38, 0)]
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
    timings = [value * 1000 for value in first.timings + second.timings]
    timings += [value * 1000 for field in regression_fields for value in field.timings]
    print(json.dumps({
        "injected_delay_seconds": float(os.environ["AZOOKEY_TEST_DELAY"]),
        "callback_samples": len(timings),
        "callback_p50_ms": round(statistics.median(timings), 3),
        "callback_p95_ms": round(sorted(timings)[int(len(timings) * 0.95)], 3),
        "callback_max_ms": round(max(timings), 3),
        "status": "PASS",
    }))
    second.context.focus_out()


def check_editing_during_delay(bus):
    """Exercise the independent review's regressions through real IBus signals."""
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
        wait_until(lambda: broken_settings.document == "na")
        assert [key[0] for key in broken_settings.forwarded] == [ord("n"), ord("a")]
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
        started = time.monotonic()
        field.context.process_key_event(keyval, 0, state)
        elapsed = time.monotonic() - started
        field.timings.append(elapsed)
        assert elapsed < CALLBACK_BUDGET_SECONDS
        while GLib.MainContext.default().pending():
            GLib.MainContext.default().iteration(False)

    for pending in (False, True):
        if pending:
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
