"""AI replacements belong to one input field, selection, and unchanged text."""
from dataclasses import replace
import pathlib
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from azookey.ai_transform_target import AccessibleSelection, InputSelection, PendingTransformation, TransformationTarget
from azookey.focused_text import (
    ACCESSIBLE, ACTIVE, DEFUNCT, EDITABLE, FOCUSED, PASSWORD_TEXT, READ_ONLY, ROOT, SENSITIVE, SHOWING,
    AccessibilityUnavailable, FocusedTextReader, inspect_focused_text,
)


def selection_fixture():
    return InputSelection.capture(("/input/1", "gnome-shell"), "前 原文 後", cursor=4, anchor=2)


def accessible_fixture():
    return AccessibleSelection(bus_id="fixture-bus", identity=(":1.4", "/field/1"), window_identity=(":1.4", "/window/1"),
                               start=2, end=4, before="前 ", selected="原文", after=" 後")


class TransformationTargetTests(unittest.TestCase):
    def pending(self):
        return PendingTransformation(TransformationTarget(selection_fixture(), accessible_fixture()), "新しい本文")

    def test_only_the_original_field_and_selection_can_apply_once(self):
        pending = self.pending()
        self.assertEqual(pending.take(selection_fixture(), accessible_fixture()), "新しい本文")
        self.assertIsNone(pending.take(selection_fixture(), accessible_fixture()))

    def test_identical_text_in_a_different_field_or_window_never_applies(self):
        original = accessible_fixture()
        for changed in (
            replace(original, identity=(":1.4", "/field/2")),
            replace(original, identity=(":1.5", "/field/1")),
            replace(original, bus_id="restarted-bus"),
            replace(original, window_identity=(":1.4", "/window/2")),
            None,
        ):
            with self.subTest(changed=changed):
                pending = self.pending()
                self.assertIsNone(pending.take(selection_fixture(), changed))
                self.assertIsNone(pending.take(selection_fixture(), original), "a rejected permission cannot be replayed")

    def test_moved_selection_or_changed_text_in_the_same_field_never_applies(self):
        original = accessible_fixture()
        for changed in (
            replace(original, start=10, end=12), replace(original, selected="別文"),
            replace(original, before="別 "), replace(original, after=" 別"),
        ):
            with self.subTest(changed=changed):
                self.assertIsNone(self.pending().take(selection_fixture(), changed))
        input_selection = selection_fixture()
        for changed in (
            None, replace(input_selection, context_id=("/input/2", "gnome-shell")),
            replace(input_selection, cursor=2, anchor=4),
        ):
            with self.subTest(input_selection=changed):
                self.assertIsNone(self.pending().take(changed, original))

    def test_selection_capture_requires_known_context_and_valid_nonempty_offsets(self):
        for context, cursor, anchor in ((None, 4, 2), (("context",), -1, 2), (("context",), 20, 2), (("context",), 2, 2)):
            self.assertIsNone(InputSelection.capture(context, "前 原文 後", cursor=cursor, anchor=anchor))

    def test_non_bmp_and_combining_characters_preserve_exact_text_and_positions(self):
        original = InputSelection.capture(("context",), "前😀か\u3099後", cursor=4, anchor=1)
        accessible = replace(accessible_fixture(), start=1, end=4, before="前", selected="😀か\u3099", after="後")
        self.assertTrue(accessible.describes(original))
        self.assertFalse(replace(accessible, selected="😀が").describes(original))
        self.assertEqual(original.selected, "😀か\u3099")

    def test_ibus_paragraph_context_does_not_invent_absolute_accessibility_offsets(self):
        paragraph = selection_fixture()
        accessible = replace(accessible_fixture(), start=102, end=104, before="別の段落\n前 ", after=" 後\n次の段落")
        self.assertTrue(accessible.describes(paragraph))


class AccessibilityFixture:
    """AT-SPI wire replies, including bitset states and bus/object identities."""
    application = (":1.4", "/application")
    window = (":1.4", "/window/1")
    field = (":1.4", "/field/1")
    second_field = (":1.4", "/field/2")
    second_window = (":1.4", "/window/2")

    def __init__(self):
        self.bus_id = "fixture-bus"
        self.role = 61  # Text.
        self.tree = {ROOT: [self.application], self.application: [self.window, self.second_window],
                     self.window: [self.field, self.second_field], self.second_window: []}
        self.states = {
            self.window: {ACTIVE}, self.second_window: set(),
            self.field: {EDITABLE, FOCUSED, SENSITIVE, SHOWING}, self.second_field: {EDITABLE, SENSITIVE, SHOWING},
        }
        self.content = "前 原文 後"
        self.selection = (2, 4)
        self.selection_count = 1
        self.calls = []
        self.closed = False

    def call(self, identity, interface, method, *, signature=None, arguments=()):
        self.calls.append((identity, interface, method, arguments))
        if interface == ACCESSIBLE:
            if method == "GetChildren":
                return (self.tree.get(identity, []),)
            if method == "GetState":
                states = self.states.get(identity, set())
                return ([sum(1 << (state % 32) for state in states if state // 32 == word) for word in range(2)],)
            if method == "GetRole":
                return (self.role,)
        if method == "GetNSelections":
            return (self.selection_count,)
        if method == "GetSelection":
            return self.selection
        if method == "Get":
            return (len(self.content),)
        if method == "GetText":
            return (self.content[arguments[0]:arguments[1]],)
        raise AssertionError((identity, interface, method))

    def close(self):
        self.closed = True


class FocusedTextTests(unittest.TestCase):
    def setUp(self):
        self.connection = AccessibilityFixture()
        self.reader = FocusedTextReader(self.connection)

    def test_active_editable_field_returns_its_real_identity_and_selection(self):
        self.assertEqual(self.reader.capture(selection_fixture()), accessible_fixture())

    def test_stale_focused_state_in_an_inactive_window_is_not_a_target(self):
        self.connection.states[self.connection.window].clear()
        self.connection.states[self.connection.second_window].add(ACTIVE)
        with self.assertRaises(AccessibilityUnavailable):
            self.reader.capture(selection_fixture())

    def test_two_focused_editable_objects_or_active_windows_are_ambiguous(self):
        self.connection.states[self.connection.second_field].add(FOCUSED)
        with self.assertRaises(AccessibilityUnavailable):
            self.reader.capture(selection_fixture())
        self.connection.states[self.connection.second_field].remove(FOCUSED)
        self.connection.states[self.connection.second_window].add(ACTIVE)
        with self.assertRaises(AccessibilityUnavailable):
            self.reader.capture(selection_fixture())

    def test_read_only_hidden_disabled_and_defunct_fields_are_not_targets(self):
        original = set(self.connection.states[self.connection.field])
        invalid_states = (original | {READ_ONLY}, original | {DEFUNCT}, original - {SENSITIVE}, original - {SHOWING})
        for states in invalid_states:
            with self.subTest(states=states), self.assertRaises(AccessibilityUnavailable):
                self.connection.states[self.connection.field] = states
                self.reader.capture(selection_fixture())

    def test_password_fields_are_rejected_without_reading_their_text(self):
        self.connection.role = PASSWORD_TEXT
        with self.assertRaises(AccessibilityUnavailable):
            self.reader.capture(selection_fixture())
        self.assertFalse(any(call[2] == "GetText" for call in self.connection.calls))

    def test_missing_multiple_invalid_or_different_selections_are_not_targets(self):
        for count, selection in ((0, (2, 4)), (2, (2, 4)), (1, (-1, 4)), (1, (2, 20)), (1, (2, 2)), (1, (1, 3))):
            with self.subTest(count=count, selection=selection), self.assertRaises(AccessibilityUnavailable):
                self.connection.selection_count, self.connection.selection = count, selection
                self.reader.capture(selection_fixture())

    def test_a_window_change_during_capture_is_rejected(self):
        windows = iter((self.connection.window, self.connection.second_window))
        with mock.patch.object(self.reader, "active_window", side_effect=lambda: next(windows)):
            with self.assertRaises(AccessibilityUnavailable):
                self.reader.capture(selection_fixture())

    def test_selection_changed_during_text_read_is_rejected(self):
        call = self.connection.call

        def changing_selection(identity, interface, method, **arguments):
            reply = call(identity, interface, method, **arguments)
            if method == "GetText":
                self.connection.selection = (1, 3)
            return reply

        with mock.patch.object(self.connection, "call", side_effect=changing_selection):
            with self.assertRaises(AccessibilityUnavailable):
                self.reader.capture(selection_fixture())

    def test_focus_changed_during_text_read_is_rejected(self):
        call = self.connection.call

        def moving_focus(identity, interface, method, **arguments):
            reply = call(identity, interface, method, **arguments)
            if method == "GetText":
                self.connection.states[self.connection.field].remove(FOCUSED)
                self.connection.states[self.connection.second_field].add(FOCUSED)
            return reply

        with mock.patch.object(self.connection, "call", side_effect=moving_focus):
            with self.assertRaises(AccessibilityUnavailable):
                self.reader.capture(selection_fixture())

    def test_text_read_is_limited_to_the_target_and_explicit_context_budget(self):
        self.connection.content = "前" * 500 + "原文" + "後" * 500
        self.connection.selection = (500, 502)
        selection = InputSelection.capture(("context",), self.connection.content, cursor=502, anchor=500)
        captured = self.reader.capture(selection)
        self.assertEqual(captured.selected, "原文")
        reads = [call for call in self.connection.calls if call[2] == "GetText"]
        self.assertEqual(reads[0][3], (400, 602))

    def test_missing_accessibility_or_excessive_tree_never_grants_permission(self):
        with mock.patch("azookey.focused_text.AccessibilityConnection", side_effect=AccessibilityUnavailable):
            self.assertIsNone(inspect_focused_text(selection_fixture()))
        with mock.patch("azookey.focused_text.MAXIMUM_VISITED_OBJECTS", 1):
            with self.assertRaises(AccessibilityUnavailable):
                self.reader.capture(selection_fixture())

    def test_each_verification_checks_uniqueness_again_and_closes_the_connection(self):
        self.connection.states[self.connection.second_field].add(FOCUSED)
        with mock.patch("azookey.focused_text.AccessibilityConnection", return_value=self.connection):
            self.assertIsNone(inspect_focused_text(selection_fixture()))
        self.assertTrue(self.connection.closed)


if __name__ == "__main__":
    unittest.main()
