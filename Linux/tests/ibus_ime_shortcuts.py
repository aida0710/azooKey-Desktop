"""Exercise shortcut entry through real IBus replies, Engine and Core."""
import json
import time

import gi
gi.require_version("IBus", "1.0")
from gi.repository import Gio, GLib, IBus
from ibus_support import crash_converter


WAIT_SECONDS = 10
# Poll only explicit replies/state, never infer conversion from elapsed time.
POLL_SECONDS = .005
CONTROL = IBus.ModifierType.CONTROL_MASK
SHIFT = IBus.ModifierType.SHIFT_MASK


def wait_for(predicate, message):
    deadline = time.monotonic() + WAIT_SECONDS
    while not predicate():
        assert time.monotonic() < deadline, message
        GLib.MainContext.default().iteration(False)
        time.sleep(POLL_SECONDS)
    while GLib.MainContext.default().pending():
        GLib.MainContext.default().iteration(False)


class Field:
    def __init__(self, bus, name):
        self.context = bus.create_input_context(name)
        self.context.set_capabilities(IBus.Capabilite.PREEDIT_TEXT | IBus.Capabilite.FOCUS
                                      | IBus.Capabilite.AUXILIARY_TEXT)
        self.document = "元本文"
        self.commits = []
        self.forwarded = []
        self.replies = []
        self.preedit = ""
        self.observation = None
        self.context.connect("commit-text", self.commit)
        self.context.connect("forward-key-event", lambda _c, *key: self.forwarded.append(key))
        self.context.connect("update-preedit-text", self.preedit_changed)
        self.context.connect("update-auxiliary-text", self.auxiliary_changed)

    def commit(self, _context, text):
        self.commits.append(text.get_text())
        self.document += text.get_text()

    def preedit_changed(self, _context, text, _cursor, visible):
        self.preedit = text.get_text() if visible else ""

    def auxiliary_changed(self, _context, text, _visible):
        if text.get_text().startswith("{"):
            self.observation = json.loads(text.get_text())

    def focus(self):
        self.context.focus_in()
        self.context.call_sync("SetEngine", GLib.Variant("(s)", ("azookey-tree",)),
                               Gio.DBusCallFlags.NONE, 5000, None)
        self.status(lambda value: value["ready"])

    def key(self, keyval, state=0):
        count = len(self.replies)

        def completed(context, response, _user_data):
            self.replies.append((keyval, bool(context.process_key_event_async_finish(response))))

        self.context.process_key_event_async(keyval, 38, state, -1, None, completed, None)
        wait_for(lambda: len(self.replies) == count + 1, "original key reply missing")
        return self.replies[-1][1]

    def status(self, predicate=lambda _value: True):
        def observed():
            self.observation = None
            self.key(IBus.KEY_F8)
            wait_for(lambda: self.observation is not None, "fixture status missing")
            return predicate(self.observation)
        wait_for(observed, "Core state did not reach the expected boundary")
        return self.observation

    def unicode(self, digits):
        assert self.key(ord("U"), CONTROL | SHIFT)
        self.status(lambda value: value["inputState"] == "unicodeInput" and value["preedit"] == "U+")
        for digit in digits:
            assert self.key(ord(digit))
        self.status(lambda value: value["preedit"] == "U+" + digits)


IBus.init()
bus = IBus.Bus()
assert bus.is_connected()
field = Field(bus, "azookey-ime-shortcut-original")
field.focus()

# The first Ctrl+S reaches Core and asks for review, never an external AI call.
assert field.key(ord("s"), CONTROL)
status = field.status(lambda value: value["review"])
assert status["coreRequests"] == ["predict"] and status["providerRequests"] == 0
assert field.key(IBus.KEY_Escape)
assert not field.status()["review"] and field.document == "元本文"
field.context.reset()
field.status(lambda value: value["ready"])

# Disabled AI returns the saved original event, without a synthetic forward.
field.key(IBus.KEY_F6)
field.status(lambda value: value["ready"] and not value["aiEnabled"])
assert not field.key(ord("s"), CONTROL)
assert not field.status()["review"] and not field.forwarded
field.key(IBus.KEY_F6)
field.status(lambda value: value["ready"] and value["aiEnabled"])

# Confirming the review invokes the mock provider, while Core applies its result.
assert field.key(ord("s"), CONTROL)
field.status(lambda value: value["review"])
assert field.key(ord("s"), CONTROL)
field.status(lambda value: value["providerRequests"] == 1 and value["inputState"] == "replaceSuggestion")
assert field.key(IBus.KEY_Return)
wait_for(lambda: field.commits == ["候補"], "mock candidate was not committed exactly once")
assert field.document == "元本文候補"

# Provider failure keeps the original field and its composition.
field.key(IBus.KEY_F7)
assert field.key(ord("a"))
wait_for(lambda: field.preedit == "あ", "normal composition missing")
assert field.key(ord("s"), CONTROL)
field.status(lambda value: value["review"])
assert field.key(ord("s"), CONTROL)
field.status(lambda value: value["providerRequests"] == 2 and not value["pendingAI"])
assert field.document == "元本文候補" and field.preedit == "あ"
assert field.key(IBus.KEY_Return)
wait_for(lambda: field.commits == ["候補", "あ"], "failed AI discarded the original composition")

field.unicode("41")
assert field.key(IBus.KEY_Return)
wait_for(lambda: field.commits == ["候補", "あ", "A"], "Unicode scalar did not commit once")
field.unicode("42")
assert field.key(IBus.KEY_Escape)
field.status(lambda value: value["inputState"] == "none")
assert field.document == "元本文候補あA"

# Reset and focus change must clear Core's U+ notation rather than commit it.
field.unicode("43")
field.context.reset()
field.status(lambda value: value["ready"])
assert field.document == "元本文候補あA"
field.unicode("44")
field.context.focus_out()
other = Field(bus, "azookey-ime-shortcut-other")
other.focus()
assert field.document == "元本文候補あA" and other.document == "元本文"
other.context.focus_out()
field.focus()

# A crashed real converter must not recover U+... as document text either.
field.unicode("45")
connection = Gio.bus_get_sync(Gio.BusType.SESSION, None)
crash_converter(connection, "azookey-desktop-bridge")
assert field.key(IBus.KEY_Return), "lost Unicode mode must not return Enter as a native newline"
field.status(lambda value: value["ready"])
assert field.document == "元本文候補あA" and other.document == "元本文"
assert not field.forwarded

# Ordinary kana still uses COMMIT focus recovery, once and only in its old field.
assert field.key(ord("a"))
wait_for(lambda: field.preedit == "あ", "kana after restart missing")
field.context.focus_out()
other.focus()
assert field.commits == ["候補", "あ", "A", "あ"] and other.commits == []

# PRIVATE permits normal Japanese input, but never offers or sends AI text.
other.context.set_content_type(IBus.InputPurpose.FREE_FORM, IBus.InputHints.PRIVATE)
assert other.key(ord("s"), CONTROL)
status = other.status(lambda value: value["ready"])
assert not status["review"] and status["providerRequests"] == 0
other.key(IBus.KEY_Escape)
assert other.document == "元本文"

# Password/PIN bypass both entry points before Core or the provider is invoked.
for purpose in (IBus.InputPurpose.PASSWORD, IBus.InputPurpose.PIN):
    other.context.set_content_type(purpose, IBus.InputHints.NONE)
    assert not other.key(ord("s"), CONTROL)
    assert not other.key(ord("U"), CONTROL | SHIFT)
assert other.document == "元本文" and not other.forwarded
other.context.focus_out()
print(json.dumps({"result": "PASS", "originalCommits": field.commits,
                  "otherCommits": other.commits, "forwarded": field.forwarded,
                  "originalReplies": field.replies, "otherReplies": other.replies}, ensure_ascii=False))
