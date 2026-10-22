#!/usr/bin/python3
"""Real Engine/focus/AT-SPI integration with a deterministic, offline AI provider."""
import json
import os
import pathlib
import runpy
import sys

# The desktop test launcher disables AT-SPI for ordinary input tests. This
# fixture is run only with its own private D-Bus and XDG_RUNTIME_DIR.
os.environ.pop("NO_AT_BRIDGE", None)
os.environ["GTK_MODULES"] = "atk-bridge"
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from azookey import engine as engine_module
from gi.repository import Gdk, GLib, Gtk, IBus


class AITargetFixtureEngine(engine_module.Engine):
    __gtype_name__ = "AzooKeyAITargetFixtureEngine"
    dialog_owner = None

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.hold_ai_reply = False
        self.held_ai_reply = None
        self.hold_target_reply = False
        self.held_target_reply = None
        self.target_reads_without_surrounding = 0
        self.transformation.inspect = self.inspect_target

    def load_settings(self, snapshot):
        # Core prepares no request while AI is disabled. The provider below
        # stays offline, so enabling AI sends nothing outside this fixture.
        if "settings" not in snapshot:
            return
        settings = {**snapshot["settings"], "aiEnabled": True}

        def configured(reply):
            assert not reply.get("error"), reply
            self.settings = settings
            self.input.settings = settings
            self.refresh_shortcuts()

        self.input.submit("configure", payload={"settings": settings}, completion=configured)

    def inspect_target(self, context_characters, completion):
        from azookey.selected_text_transform import SelectedTextTransformation
        if self.transformation.pending and not self.has_transform_surrounding_update:
            self.target_reads_without_surrounding += 1

        def inspected(accessible):
            # Only callback delivery is gated; the reader and target checks
            # remain real so Reset races do not depend on machine speed.
            if self.hold_target_reply:
                self.held_target_reply = (completion, accessible)
            else:
                completion(accessible)
        SelectedTextTransformation.inspect(context_characters, inspected)

    def do_destroy(self):
        print(json.dumps({"event": "engine-destroy", "engine": self.context_id}), flush=True)
        super().do_destroy()

    def do_reset(self):
        print(json.dumps({"event": "reset", "engine": self.context_id, "focus": self.focus_identity}), flush=True)
        super().do_reset()

    def do_focus_in_id(self, object_path, client):
        print(json.dumps({"event": "focus-in", "engine": self.context_id, "context": object_path, "client": client}), flush=True)
        super().do_focus_in_id(object_path, client)

    def do_focus_out_id(self, object_path):
        print(json.dumps({"event": "focus-out", "engine": self.context_id, "context": object_path}), flush=True)
        super().do_focus_out_id(object_path)

    def start_ai(self, snapshot, request, *, prompt=None, completion=None):
        # The provider is the only replacement for product behavior. No API
        # key is read and no network request is made. Product completion still
        # verifies the captured bridge generation and input focus epoch; Core
        # still decides what was sent and whether the result may be applied.
        self.ai_pending = True
        reply = (["変更済み"], snapshot.get("generation", -1), snapshot.get("reading", ""),
                 completion, self.input.generation, self.input.cancelled)
        if self.hold_ai_reply:
            self.held_ai_reply = reply
        else:
            GLib.idle_add(self.finish_ai, *reply)

    def do_process_key_event(self, keyval, keycode, state):
        # IBus may construct one Engine per input context. Real GTK button
        # callbacks belong to the original dialog's Engine, not the prompt IME.
        owner = type(self).dialog_owner or self
        if keyval == Gdk.KEY_F12:
            type(self).dialog_owner = self
            self.target_reads_without_surrounding = 0
            self.prompt("敬語に直す")
        elif keyval == Gdk.KEY_F11:
            if owner.transformation.dialog:
                owner.transformation.dialog.entry.emit("activate")
        elif keyval == Gdk.KEY_F10:
            if owner.transformation.dialog:
                owner.transformation.dialog.response(Gtk.ResponseType.OK)
        elif keyval == Gdk.KEY_F9:
            owner.transformation.close()
        elif keyval == Gdk.KEY_F5:
            owner.hold_ai_reply = True
        elif keyval == Gdk.KEY_F6:
            reply, owner.held_ai_reply = owner.held_ai_reply, None
            owner.hold_ai_reply = False
            if reply:
                GLib.idle_add(owner.finish_ai, *reply)
        elif keyval == Gdk.KEY_F4:
            owner.hold_target_reply = True
        elif keyval == Gdk.KEY_F3:
            reply, owner.held_target_reply = owner.held_target_reply, None
            owner.hold_target_reply = False
            if reply:
                completion, accessible = reply
                completion(accessible)
        elif keyval == Gdk.KEY_F7:
            dialog = owner.transformation.dialog
            if dialog:
                # This isolated Xvfb fixture has no window manager. Exercise
                # GTK's real activation notification, not a mocked property.
                dialog.get_window().focus(Gdk.CURRENT_TIME)
                dialog.entry.grab_focus()
        elif keyval == Gdk.KEY_F8:
            dialog = owner.transformation.dialog
            status = {
                "focus_identity": self.focus_identity,
                "has_focus_id": self.get_property("has-focus-id"),
                "active_surrounding_text": self.get_property("active-surrounding-text"),
                "settings_ready": "aiModel" in self.settings,
                "selection_ready": self.has_fresh_selection(),
                "dialog": dialog is not None,
                "dialog_active": bool(dialog and dialog.is_active()),
                "generated": bool(dialog and dialog.result),
                "visible": bool(dialog and dialog.get_visible()),
                "can_apply": bool(dialog and dialog.get_widget_for_response(Gtk.ResponseType.OK).get_sensitive()),
                "can_copy": bool(dialog and dialog.copy_button.get_sensitive()),
                "pending": owner.transformation.pending,
                "ai_reply_held": owner.held_ai_reply is not None,
                "ai_input_epoch_changed": bool(owner.held_ai_reply
                                               and owner.held_ai_reply[-1] is not owner.input.cancelled),
                "target_reply_held": owner.held_target_reply is not None,
                "surrounding_updated": owner.has_transform_surrounding_update,
                "target_reads_without_surrounding": owner.target_reads_without_surrounding,
            }
            self.update_auxiliary_text(IBus.Text.new_from_string(json.dumps(status)), True)
        else:
            return super().do_process_key_event(keyval, keycode, state)
        return True


engine_module.Engine = AITargetFixtureEngine
runpy.run_path(str(pathlib.Path(__file__).resolve().parents[1] / "ibus-azookey-tree.py"), run_name="__main__")
