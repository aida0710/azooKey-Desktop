import json
import pathlib
import subprocess
import threading
import time
import uuid
import gi
gi.require_version("IBus", "1.0")
gi.require_version("Gtk", "3.0")
from gi.repository import IBus, Gdk, GLib, Gtk
from .bridge import Bridge
from .keymap import translate
from .tree_panel import TreePanel
from .preedit_anchor import PreeditAnchor
from .settings import config_path, read_key
from .shell_surface import surface
from .prompts import PromptHistory, matches
from .prompt_dialog import PromptDialog


class Engine(IBus.Engine):
    __gtype_name__ = "AzooKeyTreeEngine"

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.context_id = str(uuid.uuid4())
        self.bridge = Bridge.acquire()
        self.bridge_generation = self.bridge.restarts
        self.panel = TreePanel(self.choose)
        self.anchor = PreeditAnchor(self.panel.measure)
        self.snapshot = {}
        self.private = False
        self.sensitive = False
        self.focused = False
        self.prompt_open = False
        self.ai_pending = False
        self.pending_transform = None
        self.last_language_key = (None, 0)
        self.destroyed = False
        self.settings = self.bridge.request("settings", context=self.context_id)["settings"]
        self.settings_stamp = None
        self.selected_text = ""
        self.left = ""
        self.right = ""
        self.table = IBus.LookupTable.new(9, 0, True, True)
        self.table.set_orientation(IBus.Orientation.VERTICAL)

    def reload_settings(self):
        path = config_path()
        if path.is_file():
            stamp = path.stat().st_mtime_ns
            if stamp != self.settings_stamp:
                settings = {**self.settings, **json.loads(path.read_text())}
                result = self.bridge.request("configure", context=self.context_id, settings=settings)
                if not result.get("error"):
                    self.settings = settings
                    self.settings_stamp = stamp

    def request(self, operation, **values):
        preserve = not (operation == "reset" and not values.get("submit", False))
        if operation == "key" and values.get("event", {}).get("keyCode") == 53:
            preserve = False
        try:
            self.bridge.ensure_running()
            if self.bridge_generation != self.bridge.restarts:
                self.recover_composition(preserve)
                self.bridge_generation = self.bridge.restarts
            result = self.bridge.request(operation, leftContext=self.left, rightContext=self.right,
                                         privateInput=self.sensitive, context=self.context_id, **values)
            self.render(result)
            return result.get("consumed", False)
        except (OSError, RuntimeError, ValueError):
            self.recover_composition(preserve)
            self.bridge.invalidate()
            return False

    def recover_composition(self, preserve=True):
        # No response has reached the application, so preserve exactly the last
        # visible preedit once; never replay an uncertain converter operation.
        text = self.snapshot.get("preedit", "")
        self.snapshot = {}
        self.anchor.update("", 0)
        if preserve and text and not self.private:
            self.commit_text(IBus.Text.new_from_string(text))
        surface().hide(self)
        self.panel.hide()
        self.hide_preedit_text()
        self.hide_lookup_table()

    def do_process_key_event(self, keyval, keycode, state):
        event = translate(keyval, state, Gdk.keyval_to_unicode(keyval))
        if event is None or self.private:
            return False
        try:
            self.reload_settings()
            double_tap = False
            if event["keyCode"] in (102, 104):
                previous, timestamp = self.last_language_key
                now = time.monotonic()
                double_tap = previous == event["keyCode"] and now - timestamp < 0.5
                self.last_language_key = (None, 0) if double_tap else (event["keyCode"], now)
            else:
                self.last_language_key = (None, 0)
            if self.selected_text and self.settings.get("aiEnabled") and not self.sensitive:
                for item in PromptHistory().load():
                    if item["pinned"] and matches(item.get("shortcut"), event):
                        self.prompt(item["prompt"])
                        return True
                if matches(self.settings.get("transformShortcut"), event):
                    self.prompt()
                    return True
                if double_tap:
                    self.prompt("english" if event["keyCode"] == 102 else "japanese")
                    return True
            return self.request("key", event=event, doubleTap=double_tap)
        except (OSError, RuntimeError, ValueError):
            self.recover_composition()
            return False

    def do_set_content_type(self, purpose, hints):
        self.private = purpose in (IBus.InputPurpose.PASSWORD, IBus.InputPurpose.PIN)
        self.sensitive = self.private or bool(hints & IBus.InputHints.PRIVATE)
        if self.private:
            self.request("reset", submit=False)

    def do_set_surrounding_text(self, text, cursor, anchor):
        value = text.get_text()
        self.left = value[:min(cursor, anchor)][-100:]
        self.right = value[max(cursor, anchor):][:100]
        self.selected_text = value[min(cursor, anchor):max(cursor, anchor)]
        self.apply_pending_transform()

    def apply_pending_transform(self):
        if not self.pending_transform or not self.focused:
            return GLib.SOURCE_REMOVE
        expected, result, deadline = self.pending_transform
        if time.monotonic() > deadline:
            self.pending_transform = None
        elif expected == (self.left, self.right, self.selected_text):
            self.pending_transform = None
            self.commit_text(IBus.Text.new_from_string(result))
        return GLib.SOURCE_REMOVE

    def do_set_cursor_location(self, x, y, width, height):
        self.anchor.locate((x, y, width, height))
        snapshot = self.positioned_snapshot(self.snapshot)
        if self.focused and self.settings.get("tree", True):
            surface().show(self, snapshot, self.panel.location)
        if self.panel.get_visible():
            self.panel.update(snapshot)

    def positioned_snapshot(self, snapshot):
        nodes = {node["id"]: node for node in snapshot.get("nodes", [])}
        words = [nodes[column[0]]["text"] for column in snapshot.get("columns", []) if column]
        geometry = self.anchor.geometry(words)
        self.panel.location = self.anchor.position if geometry else (self.anchor.location or (0, 0, 0, 0))
        return {**snapshot, "wordGeometry": geometry}

    def do_focus_in(self):
        self.focused = True
        self.anchor.update("", 0)
        self.get_surrounding_text()
        properties = IBus.PropList()
        properties.append(IBus.Property.new("InputMode", IBus.PropType.NORMAL, IBus.Text.new_from_string("あ"), "",
                                            IBus.Text.new_from_string("日本語 / 英数を切り替え"), True, True, IBus.PropState.UNCHECKED, None))
        properties.append(IBus.Property.new("setup", IBus.PropType.NORMAL, IBus.Text.new_from_string("設定…"), "", IBus.Text.new_from_string("azooKey Tree の設定"), True, True, IBus.PropState.UNCHECKED, None))
        self.register_properties(properties)

    def do_property_activate(self, name, _state):
        if name == "setup":
            subprocess.Popen(["/usr/bin/python3", str(pathlib.Path(__file__).resolve().parents[1] / "ibus-azookey-tree.py"), "--setup"])
        elif name == "InputMode":
            keyval = 0xFF22 if self.snapshot.get("language", "japanese") == "japanese" else 0xFF23
            self.request("key", event=translate(keyval, 0))

    def do_focus_out(self):
        self.focused = False
        surface().hide(self)
        if self.prompt_open:
            self.panel.hide()
            return
        # No composition is allowed to leak into the next input context.
        self.request("reset", submit=True)
        self.panel.hide()

    def do_reset(self):
        self.request("reset", submit=False)

    def do_disable(self):
        self.request("reset", submit=True)
        self.panel.hide()
        surface().hide(self)

    def do_destroy(self):
        if self.destroyed:
            return
        self.destroyed = True
        surface().hide(self)
        self.panel.destroy()
        try:
            self.bridge.request("close", context=self.context_id)
        except (OSError, RuntimeError, ValueError):
            pass
        Bridge.release()
        IBus.Engine.do_destroy(self)

    def do_candidate_clicked(self, index, button, state):
        if button == 1:
            page_start = self.table.get_cursor_pos() // self.table.get_page_size() * self.table.get_page_size()
            self.choose("select", page_start + index, True)

    def do_page_up(self):
        if self.snapshot.get("candidates"):
            self.choose("select", max(0, (self.snapshot.get("selection") or 0) - 9), False)

    def do_page_down(self):
        candidates = self.snapshot.get("candidates", [])
        if candidates:
            self.choose("select", min(len(candidates) - 1, (self.snapshot.get("selection") or 0) + 9), False)

    def do_cursor_up(self):
        self.request("key", event=translate(0xFF52, 0))

    def do_cursor_down(self):
        self.request("key", event=translate(0xFF54, 0))

    def choose(self, operation, index, submit):
        key = "node" if operation == "node" else "index"
        self.request(operation, **{key: index, "generation": self.snapshot.get("generation", -1), "submit": submit})

    def render(self, snapshot):
        self.snapshot = {**snapshot, "commits": [], "request": None}
        mode = "あ" if snapshot.get("language", "japanese") == "japanese" else "A"
        self.update_property(IBus.Property.new("InputMode", IBus.PropType.NORMAL, IBus.Text.new_from_string(mode), "",
                                              IBus.Text.new_from_string("日本語 / 英数を切り替え"), True, True, IBus.PropState.UNCHECKED, None))
        for text in snapshot.get("commits", []):
            self.commit_text(IBus.Text.new_from_string(text))
        preedit = snapshot.get("preedit", "")
        self.anchor.update(preedit, snapshot.get("cursor", 0), committed=bool(snapshot.get("commits")))
        self.update_preedit_text(IBus.Text.new_from_string(preedit), snapshot.get("cursor", 0), bool(preedit))
        snapshot = self.positioned_snapshot(snapshot)
        prediction = snapshot.get("prediction", "")
        selected = snapshot.get("selection")
        annotation = next((c.get("annotation", "") for c in snapshot.get("candidates", []) if c["index"] == selected), "")
        auxiliary = f"Tab: {prediction}" if prediction else annotation or ""
        self.update_auxiliary_text(IBus.Text.new_from_string(auxiliary), bool(auxiliary))
        self.table.clear()
        for candidate in snapshot.get("candidates", []):
            self.table.append_candidate(IBus.Text.new_from_string(candidate["text"]))
        if snapshot.get("candidates"):
            self.table.set_cursor_pos(snapshot.get("selection") or 0)
        is_wayland = "Wayland" in type(Gdk.Display.get_default()).__name__
        shell_tree = self.focused and self.settings.get("tree", True) and surface().show(self, snapshot, self.panel.location)
        if shell_tree:
            self.panel.hide()
            self.hide_lookup_table()
        elif is_wayland or not self.settings.get("tree", True):
            self.panel.hide()
            self.update_lookup_table(self.table, bool(snapshot.get("candidates")))
        else:
            self.hide_lookup_table()
            self.panel.update(snapshot)
        if snapshot.get("request") in ("replace", "predict", "prompt"):
            if snapshot["request"] == "prompt" and self.selected_text:
                self.prompt()
            else:
                self.start_ai(snapshot)

    def start_ai(self, snapshot, prompt=None, selected_target=None, completion=None):
        if self.ai_pending or self.sensitive or not self.settings.get("aiEnabled"):
            if completion:
                completion(None)
            return
        try:
            api_key = read_key()
        except (ValueError, GLib.Error):
            api_key = ""
        if not api_key:
            self.update_auxiliary_text(IBus.Text.new_from_string("設定でAPIキーを登録してください。"), True)
            if completion:
                completion(None)
            return
        self.ai_pending = True
        reading = snapshot.get("reading", "")
        generation = snapshot.get("generation", -1)
        bridge_generation = self.bridge.restarts
        context = ""
        if self.settings.get("includeContext"):
            context = f"Text before: {self.left}\nText after: {self.right}"

        def work():
            connection = None
            try:
                connection = Bridge(timeout=90)
                if selected_target is not None:
                    result = connection.request("transform", apiKey=api_key, prompt=f"{prompt}\n\n{selected_target}\n\n{context}")
                else:
                    target = reading if reading else "つづき"
                    result = connection.request("ai", apiKey=api_key, target=target, prompt=context)
                texts = result.get("suggestions", [])
                GLib.idle_add(self.finish_ai, texts, generation, reading, completion, bridge_generation)
            except (OSError, RuntimeError, ValueError):
                GLib.idle_add(self.finish_ai, [], generation, reading, completion, bridge_generation)
            finally:
                if connection:
                    connection.close()
        threading.Thread(target=work, daemon=True).start()

    def finish_ai(self, texts, generation, reading, completion, bridge_generation):
        self.ai_pending = False
        if self.destroyed:
            return GLib.SOURCE_REMOVE
        if bridge_generation != self.bridge.restarts:
            if completion:
                completion(None)
            return GLib.SOURCE_REMOVE
        if completion:
            completion(texts[0] if texts else None)
            return GLib.SOURCE_REMOVE
        if not texts:
            self.update_auxiliary_text(IBus.Text.new_from_string("AI変換に失敗しました。接続設定を確認してください。"), True)
        elif self.focused:
            self.request("suggestions", suggestions=texts, generation=generation, reading=reading)
        return GLib.SOURCE_REMOVE

    def prompt(self, initial_prompt=""):
        if self.prompt_open:
            return
        target = self.selected_text
        expected_context = (self.left, self.right, target)
        snapshot = dict(self.snapshot)
        self.prompt_open = True
        dialog = PromptDialog(lambda prompt, completion: self.start_ai(snapshot, prompt=prompt, selected_target=target,
                                                                       completion=completion), initial_prompt)
        dialog.show_all()
        response = dialog.run()
        result = dialog.result
        dialog.destroy()
        self.prompt_open = False
        if response == Gtk.ResponseType.OK and result:
            self.pending_transform = (expected_context, result, time.monotonic() + 5)
            self.get_surrounding_text()
            GLib.idle_add(self.apply_pending_transform)
