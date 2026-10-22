"""A native toolkit case starts only after the real input context is focused."""
from pathlib import Path
import tempfile
import unittest

from native_ibus_observer import has_native_focus


def focus_in(client, context="/org/freedesktop/IBus/InputContext_2"):
    return (
        "method call time=1 sender=org.freedesktop.DBus -> destination=(null destination) "
        "serial=12 path=/org/freedesktop/IBus/Engine/1; "
        "interface=org.freedesktop.IBus.Engine; member=FocusInId\n"
        f'   string "{context}"\n   string "{client}"\n'
    )


FOCUS_OUT = (
    "method call time=2 sender=org.freedesktop.DBus -> destination=(null destination) "
    "serial=13 path=/org/freedesktop/IBus/Engine/1; "
    "interface=org.freedesktop.IBus.Engine; member=FocusOutId\n"
    '   string "/org/freedesktop/IBus/InputContext_2"\n'
)


class NativeIBusFocusTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.observed = self.directory / "ibus-events.log"

    def test_widget_focus_without_native_context_is_not_ready(self):
        for observation in ("", focus_in("fake")):
            with self.subTest(observation=observation):
                self.observed.write_text(observation)
                self.assertFalse(has_native_focus(self.directory, "gtk4"))

    def test_only_the_requested_toolkit_context_is_ready(self):
        for toolkit, client in (("gtk4", "gtk4-im:python3"), ("qt", "QIBusInputContext")):
            with self.subTest(toolkit=toolkit):
                self.observed.write_text(focus_in(client))
                self.assertTrue(has_native_focus(self.directory, toolkit))
                other = "qt" if toolkit == "gtk4" else "gtk4"
                self.assertFalse(has_native_focus(self.directory, other))

    def test_focus_out_invalidates_the_previous_native_context(self):
        self.observed.write_text(focus_in("gtk4-im:python3") + FOCUS_OUT)
        self.assertFalse(has_native_focus(self.directory, "gtk4"))

    def test_switching_back_to_the_fake_context_is_not_ready(self):
        self.observed.write_text(focus_in("gtk4-im:python3") + FOCUS_OUT + focus_in("fake"))
        self.assertFalse(has_native_focus(self.directory, "gtk4"))

    def test_an_incomplete_focus_notification_is_not_ready(self):
        complete = focus_in("gtk4-im:python3")
        self.observed.write_text(complete.rsplit("\n", 2)[0] + "\n")
        self.assertFalse(has_native_focus(self.directory, "gtk4"))

    def test_unrelated_engine_events_keep_the_current_native_focus(self):
        self.observed.write_text(focus_in("gtk4-im:python3") + (
            "signal time=2 sender=:1.6 -> destination=(null destination) serial=14 "
            "path=/org/freedesktop/IBus/Engine/1; interface=org.freedesktop.IBus.Engine; "
            "member=HideLookupTable\n"
        ))
        self.assertTrue(has_native_focus(self.directory, "gtk4"))


if __name__ == "__main__":
    unittest.main()
