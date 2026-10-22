"""Read the identity and selection of an active, editable AT-SPI text object."""
import time
import threading
from collections import deque

from .ai_transform_target import AccessibleSelection, CONTEXT_CHARACTERS


ACCESSIBLE = "org.a11y.atspi.Accessible"
TEXT = "org.a11y.atspi.Text"
ROOT = ("org.a11y.atspi.Registry", "/org/a11y/atspi/accessible/root")
# AT-SPI state indices, from atspi-constants.h.
ACTIVE, DEFUNCT, EDITABLE, FOCUSED, SENSITIVE, SHOWING, READ_ONLY = 1, 6, 7, 12, 24, 25, 43
PASSWORD_TEXT = 40
# These bounds fail closed; they never turn a slow/partial query into approval.
QUERY_TIMEOUT_SECONDS = 2
MAXIMUM_VISITED_OBJECTS = 512


class AccessibilityUnavailable(Exception):
    pass


class AccessibilityConnection:
    """Private read-only D-Bus calls; construct and use this on a worker."""

    def __init__(self):
        from gi.repository import Gio, GLib
        self.Gio, self.GLib = Gio, GLib
        self.deadline = time.monotonic() + QUERY_TIMEOUT_SECONDS
        self.cancellable = Gio.Cancellable()
        self.expiry = threading.Timer(QUERY_TIMEOUT_SECONDS, self.cancellable.cancel)
        self.expiry.daemon = True
        self.expiry.start()
        try:
            session = Gio.bus_get_sync(Gio.BusType.SESSION, self.cancellable)
            address = session.call_sync(
                "org.a11y.Bus", "/org/a11y/bus", "org.a11y.Bus", "GetAddress",
                None, None, Gio.DBusCallFlags.NONE, self.remaining_ms(), self.cancellable,
            ).unpack()[0]
            self.connection = Gio.DBusConnection.new_for_address_sync(
                address, Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION,
                None, self.cancellable,
            )
            self.bus_id = self.connection.get_guid()
        except (GLib.Error, AccessibilityUnavailable) as error:
            self.expiry.cancel()
            raise AccessibilityUnavailable() from error

    def remaining_ms(self):
        remaining = int((self.deadline - time.monotonic()) * 1000)
        if remaining <= 0:
            raise AccessibilityUnavailable()
        return remaining

    def call(self, identity, interface, method, *, signature=None, arguments=()):
        try:
            parameters = self.GLib.Variant(signature, arguments) if signature else None
            return self.connection.call_sync(
                *identity, interface, method, parameters, None,
                self.Gio.DBusCallFlags.NONE, self.remaining_ms(), self.cancellable,
            ).unpack()
        except self.GLib.Error as error:
            raise AccessibilityUnavailable() from error

    def close(self):
        self.expiry.cancel()
        try:
            self.connection.close_sync(None)
        except self.GLib.Error:
            pass


class FocusedTextReader:
    def __init__(self, connection):
        self.connection = connection

    def states(self, identity):
        words = self.connection.call(identity, ACCESSIBLE, "GetState")[0]
        return {index for index in range(len(words) * 32) if words[index // 32] & (1 << (index % 32))}

    def children(self, identity):
        return [tuple(child) for child in self.connection.call(identity, ACCESSIBLE, "GetChildren")[0]]

    def active_window(self):
        windows = [
            window for application in self.children(ROOT) for window in self.children(application)
            if ACTIVE in self.states(window)
        ]
        if len(windows) != 1:
            raise AccessibilityUnavailable()
        return windows[0]

    def capture(self, selection):
        window = self.active_window()
        queue = deque([window])
        visited, focused = set(), []
        while queue:
            identity = queue.popleft()
            if identity in visited:
                continue
            visited.add(identity)
            if len(visited) > MAXIMUM_VISITED_OBJECTS:
                raise AccessibilityUnavailable()
            states = self.states(identity)
            if FOCUSED in states and EDITABLE in states:
                focused.append(identity)
            if DEFUNCT not in states:
                queue.extend(self.children(identity))
        if len(focused) != 1:
            raise AccessibilityUnavailable()
        captured = self.read_selection(focused[0], window)
        if not captured.describes(selection):
            raise AccessibilityUnavailable()
        return captured

    def read_selection(self, identity, window):
        if not self.connection.bus_id or not identity[0].startswith(":"):
            raise AccessibilityUnavailable()
        states = self.states(identity)
        if not {EDITABLE, FOCUSED, SENSITIVE, SHOWING}.issubset(states) or {DEFUNCT, READ_ONLY} & states:
            raise AccessibilityUnavailable()
        if self.active_window() != window:
            raise AccessibilityUnavailable()
        if self.connection.call(identity, ACCESSIBLE, "GetRole")[0] == PASSWORD_TEXT:
            raise AccessibilityUnavailable()
        start, end = self.selection_range(identity)
        if start < 0 or end <= start:
            raise AccessibilityUnavailable()
        count = self.connection.call(
            identity, "org.freedesktop.DBus.Properties", "Get",
            signature="(ss)", arguments=(TEXT, "CharacterCount"),
        )[0]
        if end > count:
            raise AccessibilityUnavailable()
        first = max(0, start - CONTEXT_CHARACTERS)
        content = self.connection.call(
            identity, TEXT, "GetText", signature="(ii)", arguments=(first, min(count, end + CONTEXT_CHARACTERS)),
        )[0]
        selection_end = end - first
        if len(content) < selection_end:
            raise AccessibilityUnavailable()
        # A text query can dispatch application work. Recheck the selection
        # and active/editable state before accepting that query's old range.
        if self.selection_range(identity) != (start, end) or self.active_window() != window:
            raise AccessibilityUnavailable()
        current_states = self.states(identity)
        if not {EDITABLE, FOCUSED, SENSITIVE, SHOWING}.issubset(current_states) or {DEFUNCT, READ_ONLY} & current_states:
            raise AccessibilityUnavailable()
        return AccessibleSelection(
            bus_id=self.connection.bus_id, identity=identity, window_identity=window,
            start=start, end=end, before=content[:start - first],
            selected=content[start - first:selection_end], after=content[selection_end:],
        )

    def selection_range(self, identity):
        if self.connection.call(identity, TEXT, "GetNSelections")[0] != 1:
            raise AccessibilityUnavailable()
        return self.connection.call(identity, TEXT, "GetSelection", signature="(i)", arguments=(0,))


def inspect_focused_text(selection):
    connection = None
    try:
        connection = AccessibilityConnection()
        # Re-enumerate the active window on every explicit check. A stale
        # FOCUSED flag on the old object is not proof of a unique current target.
        return FocusedTextReader(connection).capture(selection)
    except (AccessibilityUnavailable, ImportError, ValueError, TypeError, IndexError):
        return None
    finally:
        if connection:
            connection.close()
