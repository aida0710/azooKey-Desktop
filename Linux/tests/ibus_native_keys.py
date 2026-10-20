"""Verify original native replies, ordering and cancellation on real IBus."""
import json
import os
import time

import gi
gi.require_version("IBus", "1.0")
from gi.repository import Gio, GLib, IBus
from ibus_support import crash_converter


from ibus_native_field import Field, RESPONSIVE_SECONDS, wait_for


IBus.init()
bus = IBus.Bus()
assert bus.is_connected()
control = IBus.ModifierType.CONTROL_MASK
shift = IBus.ModifierType.SHIFT_MASK

field = Field(bus, "azookey-native-original")
field.focus()
field.send(IBus.KEY_Home, control)
wait_for(lambda: len(field.replies) == 1)
assert not field.replies[0]["consumed"] and not field.forwarded

field.send(IBus.KEY_Muhenkan)
field.send(ord("A"), shift)
field.send(IBus.KEY_Left)
field.send(ord("B"), shift)
wait_for(lambda: len(field.replies) == 5)
assert field.document == "BA" and field.cursor == 1, field.document
assert not field.commits and not field.forwarded
assert [reply["consumed"] for reply in field.replies[1:]] == [True, False, False, False]

field.send(IBus.KEY_Henkan)
field.send(ord("a"))
field.send(IBus.KEY_Return)
field.send(IBus.KEY_Control_L)
field.send(IBus.KEY_Home, control)
field.send(IBus.KEY_Home, control | IBus.ModifierType.RELEASE_MASK)
field.send(IBus.KEY_Control_L, control | IBus.ModifierType.RELEASE_MASK)
# The daemon and both endpoints' main loops remain available while a native
# reply waits for preceding work. This is separate from reply latency.
start = time.monotonic()
assert field.context.get_engine().get_name() == "azookey-tree"
bus_query_seconds = time.monotonic() - start
assert bus_query_seconds < RESPONSIVE_SECONDS, bus_query_seconds
wait_for(lambda: len(field.replies) == 12)
assert field.commits == ["a"] and field.document == "BaA" and field.cursor == 0
assert not field.replies[-1]["consumed"] and not field.forwarded
assert [reply["keyval"] for reply in field.replies[-3:]] == [
    IBus.KEY_Home, IBus.KEY_Home, IBus.KEY_Control_L,
]

field.context.focus_out()
old = Field(bus, "azookey-native-focus-old")
new = Field(bus, "azookey-native-focus-new")
old.focus()
old.send(IBus.KEY_Muhenkan)
old.send(ord("A"), shift)
wait_for(lambda: old.preedit == "A")
old.context.focus_out()
new.focus()
wait_for(lambda: len(old.replies) == 2)
assert old.commits == ["A"] and old.replies[-1]["consumed"]
assert not old.forwarded and not new.commits and new.document == ""

new.send(IBus.KEY_Henkan)
new.send(ord("a"))
new.send(IBus.KEY_Return)
new.send(IBus.KEY_Home, control)
new.send(ord("b"))
wait_for(lambda: new.preedit == "ab")
new.context.focus_out()
old.focus()
wait_for(lambda: len(new.replies) == 5)
assert new.commits == ["ab"] and not new.forwarded
assert all(reply["consumed"] for reply in new.replies)
old.context.focus_out()
new.focus()
new.replies.clear()
new.commits.clear()

new.send(IBus.KEY_Muhenkan)
new.send(ord("A"), shift)
wait_for(lambda: new.preedit == "A")
new.context.reset()
wait_for(lambda: len(new.replies) == 2)
assert new.commits == ["A"] and new.replies[-1]["consumed"]
assert not new.forwarded
new.send(IBus.KEY_Henkan)
wait_for(lambda: len(new.replies) == 3)
document_before_failure, cursor_before_failure = new.document, new.cursor
delivery_count = len(new.deliveries)
new.send(ord("h"))
new.send(IBus.KEY_Return)
new.send(IBus.KEY_Home, control)
wait_for(lambda: len(new.replies) == 6)
assert not new.replies[-1]["consumed"]
assert all(key[0] != IBus.KEY_Home for key in new.forwarded)
failure_deliveries = new.deliveries[delivery_count:]
assert [event["keyval"] for event in failure_deliveries] == [ord("h"), IBus.KEY_Return, IBus.KEY_Home]
assert new.document == (document_before_failure[:cursor_before_failure]
                        + "h\n" + document_before_failure[cursor_before_failure:])
assert new.cursor == 0
reply_count = len(new.replies)
crash_converter(Gio.bus_get_sync(Gio.BusType.SESSION, None), "delayed_bridge.py")
new.send(IBus.KEY_Henkan)
wait_for(lambda: len(new.replies) == reply_count + 1)
assert not old.forwarded and old.commits == ["A"] and len(old.replies) == 2
print(json.dumps({
    "status": "PASS", "delaySeconds": float(os.environ["AZOOKEY_TEST_DELAY"]),
    "nativeReplyUsesOriginalEvent": True, "duplicateReplies": 0,
    "daemonQueryWhileWaitingSeconds": bus_query_seconds, "replies": field.replies,
    "failureDeliveries": failure_deliveries,
}))
