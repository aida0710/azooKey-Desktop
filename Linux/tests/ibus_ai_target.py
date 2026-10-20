#!/usr/bin/python3
"""Exercise original/other/shared IBus contexts with real GTK AT-SPI objects."""
import json
import os
import pathlib
import sys

os.environ.pop("NO_AT_BRIDGE", None)
os.environ["GTK_MODULES"] = "atk-bridge"
# An unknown module ID falls back to installed modules, including IBus.
os.environ["GTK_IM_MODULE"] = "gtk-im-context-simple"
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from focused_text_gtk import TextFields, wait_until
import gi
gi.require_version("IBus", "1.0")
from gi.repository import Gdk, Gio, GLib, IBus


# Synchronous SetEngine acknowledgement prevents the first test key from
# racing engine attachment. All other waits observe explicit state.
ENGINE_SWITCH_TIMEOUT_MS = 5000


class AITargetIntegration:
    def __init__(self):
        IBus.init()
        self.bus = IBus.Bus()
        self.fields = TextFields()
        self.status = None
        self.observed_statuses = []
        self.active = None
        self.selected_field = 0
        self.suppress_surrounding = False
        self.commits = []
        self.contexts = [self.make_context(name) for name in ("original-field", "other-field", "prompt-dialog")]

    def make_context(self, name):
        context = self.bus.create_input_context(name)
        context.set_capabilities(IBus.Capabilite.PREEDIT_TEXT | IBus.Capabilite.AUXILIARY_TEXT
                                 | IBus.Capabilite.FOCUS | IBus.Capabilite.SURROUNDING_TEXT)
        context.connect("require-surrounding-text", lambda received: self.publish_selection(received))
        context.connect("update-auxiliary-text", self.status_changed)
        context.connect("commit-text", self.committed)
        return context

    def status_changed(self, _context, text, _visible):
        try:
            self.status = json.loads(text.get_text())
            if self.status not in self.observed_statuses:
                self.observed_statuses.append(self.status)
        except ValueError:
            pass

    def committed(self, context, text):
        self.commits.append((context.get_object_path(), text.get_text()))
        if context is self.active:
            field = self.fields.fields[self.selected_field]
            start, end = field.get_selection_bounds()
            field.set_text(field.get_text()[:start] + text.get_text() + field.get_text()[end:])
            self.publish_selection(context)

    def publish_selection(self, context):
        if self.suppress_surrounding:
            return
        if context is self.contexts[2]:
            context.set_surrounding_text(IBus.Text.new_from_string("指示"), 2, 2)
            return
        field = self.fields.fields[self.selected_field]
        bounds = field.get_selection_bounds()
        start, end = bounds if bounds else (field.get_position(), field.get_position())
        context.set_surrounding_text(IBus.Text.new_from_string(field.get_text()), end, start)

    def focus(self, context_index, field_index=0):
        if self.active:
            self.active.focus_out()
        self.selected_field = field_index
        if context_index != 2:
            self.fields.focus(field_index)
        self.active = self.contexts[context_index]
        self.active.call_sync("FocusIn", None, Gio.DBusCallFlags.NONE, ENGINE_SWITCH_TIMEOUT_MS, None)
        current = self.active.get_engine()
        if current is None or current.get_name() != "azookey-tree":
            self.active.call_sync("SetEngine", GLib.Variant("(s)", ("azookey-tree",)),
                                  Gio.DBusCallFlags.NONE, ENGINE_SWITCH_TIMEOUT_MS, None)
        if context_index == 2:
            self.publish_selection(self.active)
        else:
            self.select_original()
        status = self.wait_status(lambda observed: observed["focus_identity"]
                                  and observed["focus_identity"][0] == self.active.get_object_path())
        assert status["has_focus_id"] and status["active_surrounding_text"]

    def select_original(self):
        # Mirror the application's caret/selection notifications. Its IBus
        # cache must observe edits and reselection between scenarios.
        field = self.fields.fields[self.selected_field]
        field.set_position(4)
        self.publish_selection(self.active)
        field.select_region(2, 4)
        self.publish_selection(self.active)

    def key(self, keyval):
        assert self.active.process_key_event(keyval, 0, 0)

    def wait_status(self, predicate):
        self.status = None

        def observed():
            if self.status and predicate(self.status):
                return True
            self.status = None
            self.key(Gdk.KEY_F8)
            return False
        try:
            wait_until(observed, "IBus engine did not reach the expected state")
        except AssertionError:
            print(json.dumps({"active": self.active.get_object_path(), "statuses": self.observed_statuses}), flush=True)
            raise
        return self.status

    def preview(self):
        for field in self.fields.fields:
            field.set_text("前 原文 後")
        self.focus(0)
        self.wait_status(lambda status: status["selection_ready"] and status["settings_ready"])
        self.key(Gdk.KEY_F12)
        self.wait_status(lambda status: status["dialog"])
        self.focus(2)
        self.key(Gdk.KEY_F11)
        self.wait_status(lambda status: status["generated"] and status["can_apply"])
        self.key(Gdk.KEY_F10)
        self.wait_status(lambda status: status["pending"] and not status["visible"])

    def reject_case(self, context_index, field_index):
        self.preview()
        before = len(self.commits)
        self.focus(context_index, field_index)
        status = self.wait_status(lambda observed: observed["visible"] and not observed["can_apply"])
        assert status["generated"] and status["can_copy"]
        assert len(self.commits) == before
        assert all(field.get_text() == "前 原文 後" for field in self.fields.fields)
        self.key(Gdk.KEY_F9)

    def reject_reset_before_surrounding(self):
        self.preview()
        before = len(self.commits)
        self.suppress_surrounding = True
        self.focus(0)
        self.active.call_sync("Reset", None, Gio.DBusCallFlags.NONE, ENGINE_SWITCH_TIMEOUT_MS, None)
        self.suppress_surrounding = False
        self.select_original()
        status = self.wait_status(lambda observed: observed["visible"] and not observed["can_apply"])
        assert status["generated"] and status["can_copy"] and len(self.commits) == before
        self.key(Gdk.KEY_F9)

    def run(self):
        self.preview()
        self.focus(0)
        self.wait_status(lambda status: not status["dialog"])
        wait_until(lambda: len(self.commits) == 1, "original input context did not receive the replacement")
        assert self.commits == [(self.contexts[0].get_object_path(), "変更済み")]
        assert self.fields.fields[0].get_text() == "前 変更済み 後"
        self.reject_case(1, 1)
        # GNOME-style shared input context: IBus identity and text match, but
        # the actual editable AT-SPI object is a different field.
        self.reject_case(0, 1)
        self.reject_reset_before_surrounding()
        print(json.dumps({"status": "PASS", "original_commits": 1, "other_context_commits": 0,
                          "shared_context_other_field_commits": 0, "rejected_preview_preserved": True,
                          "reset_before_delayed_surrounding_commits": 0,
                          "external_ai_requests": 0, "focus_ids": [context.get_object_path() for context in self.contexts]}))

    def close(self):
        for context in self.contexts:
            context.destroy()
        self.fields.close()


if __name__ == "__main__":
    fixture = AITargetIntegration()
    try:
        fixture.run()
    finally:
        fixture.close()
