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

    def start_ai(self, snapshot, scope, *, prompt=None, completion=None):
        # The provider is the only replacement for product behavior. No API
        # key is read and no network request is made.
        GLib.idle_add(lambda: completion("変更済み") or GLib.SOURCE_REMOVE)

    def do_process_key_event(self, keyval, keycode, state):
        # IBus may construct one Engine per input context. Real GTK button
        # callbacks belong to the original dialog's Engine, not the prompt IME.
        owner = type(self).dialog_owner or self
        if keyval == Gdk.KEY_F12:
            type(self).dialog_owner = self
            self.prompt("敬語に直す")
        elif keyval == Gdk.KEY_F11:
            if owner.transformation.dialog:
                owner.transformation.dialog.entry.emit("activate")
        elif keyval == Gdk.KEY_F10:
            if owner.transformation.dialog:
                owner.transformation.dialog.response(Gtk.ResponseType.OK)
        elif keyval == Gdk.KEY_F9:
            owner.transformation.close()
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
                "selection_ready": self.current_transform_selection() is not None,
                "dialog": dialog is not None,
                "dialog_active": bool(dialog and dialog.is_active()),
                "generated": bool(dialog and dialog.result),
                "visible": bool(dialog and dialog.get_visible()),
                "can_apply": bool(dialog and dialog.get_widget_for_response(Gtk.ResponseType.OK).get_sensitive()),
                "can_copy": bool(dialog and dialog.copy_button.get_sensitive()),
                "pending": owner.transformation.pending is not None,
            }
            self.update_auxiliary_text(IBus.Text.new_from_string(json.dumps(status)), True)
        else:
            return super().do_process_key_event(keyval, keycode, state)
        return True


engine_module.Engine = AITargetFixtureEngine
runpy.run_path(str(pathlib.Path(__file__).resolve().parents[1] / "ibus-azookey-tree.py"), run_name="__main__")
