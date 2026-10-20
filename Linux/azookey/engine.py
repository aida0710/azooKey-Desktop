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
from .async_bridge import AsyncBridge
from .input_coordinator import InputCoordinator
from .keymap import translate
from .tree_panel import TreePanel
from .preedit_anchor import PreeditAnchor
from .settings import read_key
from .settings_store import SettingsStore
from .i18n import text
from .shell_surface import surface
from .prompts import PromptHistory, matches
from .prompt_dialog import PromptDialog
from .ai_scope import AIRequestConfiguration, AIRequestScope, MODIFIER_KEYS
from .ai_review import AISuggestionReview
from .i18n import text as message
from .settings_store import update_settings


class Engine(IBus.Engine):
    __gtype_name__ = "AzooKeyTreeEngine"

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.context_id = str(uuid.uuid4())
        self.bridge = AsyncBridge.acquire(GLib.idle_add)
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
        self.settings = {}
        self.settings_stamp = None
        self.pending_settings_stamp = None
        self.settings_store = SettingsStore()
        self.settings_problem_stamp = None
        self.selected_text = ""
        self.left = ""
        self.right = ""
        self.table = IBus.LookupTable.new(9, 0, True, True)
        self.table.set_orientation(IBus.Orientation.VERTICAL)
        self.input = InputCoordinator(
            self.bridge, self.context_id, render=self.render, forward=self.forward_key_event,
            recover=self.recover_composition, preview=self.preview_pending,
            schedule_timeout=GLib.timeout_add, remove_timeout=GLib.source_remove,
        )
        self.ai_review = AISuggestionReview(
            current_state=self.ai_review_state, send=self.start_ai, save_context=self.save_ai_context,
        )
        self.input.submit("settings", completion=self.load_settings)

    def ai_review_state(self):
        return {
            "snapshot": self.snapshot, "input_epoch": self.input.cancelled,
            "bridge_generation": self.input.generation, "focused": self.focused,
            "pending_input": any(pending.key is not None for pending in self.input.pending),
        }

    def make_ai_scope(self, target):
        return AIRequestScope(
            AIRequestConfiguration.from_settings(self.settings), target,
            before=self.left, after=self.right, include_context=self.settings.get("includeContext", False),
        )

    def save_ai_context(self, value):
        try:
            # Other screens may have changed conversion or dictionary settings.
            # Leave those for reload_settings and its Core acknowledgement.
            update_settings({"includeContext": value}, defaults=self.settings)
            self.settings = {**self.settings, "includeContext": value}
            self.input.settings = self.settings
            return True
        except (OSError, ValueError):
            return False

    def load_settings(self, snapshot):
        if "settings" in snapshot:
            self.settings = snapshot["settings"]
            self.input.settings = self.settings
            self.reload_settings()

    def reload_settings(self):
        if not self.settings:
            if not any(pending.operation == "settings" for pending in self.input.pending):
                self.input.submit("settings", completion=self.load_settings)
            return
        loaded = self.settings_store.load(self.settings)
        if loaded.problem:
            self.notify_settings_problem(loaded.problem)
            return
        self.settings_problem_stamp = None
        if loaded.stamp is None or loaded.stamp in (self.settings_stamp, self.pending_settings_stamp):
            return
        self.pending_settings_stamp = loaded.stamp

        def configured(snapshot):
            self.pending_settings_stamp = None
            if snapshot.get("error"):
                self.settings_store.reject(loaded)
                self.notify_settings_problem(self.settings_store.load(self.settings).problem)
                return
            self.settings = loaded.values
            self.input.settings = loaded.values
            self.settings_stamp = loaded.stamp

        self.input.submit(
            "configure", payload={"settings": loaded.values}, completion=configured,
            persist=lambda: self.settings_store.remember(loaded.values),
        )

    def notify_settings_problem(self, problem):
        # The user may have repaired the file while Core rejected an older
        # queued version. In that case there is no current problem to show.
        if problem is None:
            return
        if problem.stamp != self.settings_problem_stamp:
            self.settings_problem_stamp = problem.stamp
            notification = text("settings.input_continues")
            self.update_auxiliary_text(IBus.Text.new_from_string(notification), True)

    def request(self, operation, *, original_key=None, **values):
        if self.destroyed or self.private:
            return False
        self.ai_review.cancel()
        self.input.submit(operation, payload={
            "leftContext": self.left, "rightContext": self.right, "privateInput": self.sensitive, **values,
        }, key=original_key)
        return True

    def recover_composition(self, text=""):
        self.ai_review.cancel()
        self.pending_settings_stamp = None
        self.snapshot = {}
        self.anchor.update("", 0)
        self.update_preedit_text_with_mode(IBus.Text.new_from_string(""), 0, False, IBus.PreeditFocusMode.COMMIT)
        surface().hide(self)
        self.panel.hide()
        self.hide_preedit_text()
        self.hide_lookup_table()
        if text and self.focused and not self.private:
            self.commit_text(IBus.Text.new_from_string(text))

    def preview_pending(self, text, cursor):
        if not self.focused or self.private:
            return
        # IBus commits this visible text to the old input context on focus-out,
        # before notifying the engine. No asynchronous commit may follow it.
        self.update_preedit_text_with_mode(IBus.Text.new_from_string(text), cursor, bool(text), IBus.PreeditFocusMode.COMMIT)
        surface().hide(self)
        self.panel.hide()
        self.hide_lookup_table()

    def do_process_key_event(self, keyval, keycode, state):
        event = translate(keyval, state, Gdk.keyval_to_unicode(keyval))
        if self.private or not self.focused or self.input.recovering:
            return False
        if self.ai_review.confirmation and keyval in MODIFIER_KEYS:
            return False
        if self.ai_review.key(event):
            return True
        if (event and event["modifierFlags"] == 0 and not self.input.pending
                and keyval in (Gdk.KEY_Page_Up, Gdk.KEY_Page_Down)
                and self.settings.get("tree", True) and self.snapshot.get("nodes")):
            forward = keyval == Gdk.KEY_Page_Down
            if surface().scroll_details(self, forward) or self.panel.scroll_details(forward):
                return True
        original_key = (keyval, keycode, state)
        if event is None:
            if not self.input.pending:
                return False
            self.input.submit(None, key=original_key)
            return True
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
            return self.request("key", event=event, doubleTap=double_tap, original_key=original_key)
        except (OSError, RuntimeError, ValueError):
            self.input.recover_pending()
            # Returning False here can let synchronous clients apply this key
            # before the queued forward-key-event signals for earlier keys.
            self.forward_key_event(*original_key)
            return True

    def do_set_content_type(self, purpose, hints):
        self.private = purpose in (IBus.InputPurpose.PASSWORD, IBus.InputPurpose.PIN)
        self.sensitive = self.private or bool(hints & IBus.InputHints.PRIVATE)
        if self.sensitive:
            self.ai_review.cancel()
        if self.private:
            self.input.cancel()
            self.pending_settings_stamp = None
            self.recover_composition()

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
        if self.input.pending:
            return
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
        self.reload_settings()
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
        self.ai_review.cancel()
        self.focused = False
        surface().hide(self)
        self.input.cancel()
        self.pending_settings_stamp = None
        self.snapshot = {}
        self.left = self.right = self.selected_text = ""
        self.panel.hide()

    def do_reset(self):
        self.ai_review.cancel()
        self.input.cancel()
        self.pending_settings_stamp = None
        self.recover_composition()

    def do_disable(self):
        # IBus owns focus-out/reset preedit submission. Sending a second commit
        # here would duplicate text or target the next application.
        self.do_focus_out()

    def do_destroy(self):
        if self.destroyed:
            return
        self.destroyed = True
        self.ai_review.cancel()
        surface().hide(self)
        self.panel.destroy()
        self.input.close()
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
        if self.input.pending or not self.focused:
            return
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
        self.update_preedit_text_with_mode(IBus.Text.new_from_string(preedit), snapshot.get("cursor", 0),
                                          bool(preedit), IBus.PreeditFocusMode.COMMIT)
        snapshot = self.positioned_snapshot(snapshot)
        prediction = snapshot.get("prediction", "")
        selected = snapshot.get("selection")
        annotation = next((c.get("annotation", "") for c in snapshot.get("candidates", []) if c["index"] == selected), "")
        auxiliary = f"Tab: {prediction}" if prediction else annotation or ""
        if self.settings_problem_stamp is None:
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
                if self.settings.get("aiEnabled") and not self.sensitive:
                    scope = self.make_ai_scope(snapshot.get("reading") or "つづき")
                    self.ai_review.show(scope, snapshot, self.panel.location)

    def start_ai(self, snapshot, scope, *, prompt=None, completion=None):
        if self.ai_pending or self.sensitive or not self.settings.get("aiEnabled"):
            if completion:
                completion(None)
            return
        try:
            api_key = read_key()
        except (ValueError, GLib.Error):
            api_key = ""
        if not api_key:
            self.update_auxiliary_text(IBus.Text.new_from_string(message("ai.error.missing-key")), True)
            if completion:
                completion(None)
            return
        self.ai_pending = True
        reading = snapshot.get("reading", "")
        generation = snapshot.get("generation", -1)
        bridge_generation = self.input.generation
        focus_epoch = self.input.cancelled
        arguments = scope.bridge_arguments()

        def work():
            connection = None
            try:
                connection = Bridge(timeout=90)
                if prompt is not None:
                    result = connection.request("transform", apiKey=api_key, prompt=prompt, **arguments)
                else:
                    result = connection.request("ai", apiKey=api_key, **arguments)
                texts = result.get("suggestions", [])
                GLib.idle_add(self.finish_ai, texts, generation, reading, completion, bridge_generation, focus_epoch)
            except (OSError, RuntimeError, ValueError):
                GLib.idle_add(self.finish_ai, [], generation, reading, completion, bridge_generation, focus_epoch)
            finally:
                if connection:
                    connection.close()
        threading.Thread(target=work, daemon=True).start()

    def finish_ai(self, texts, generation, reading, completion, bridge_generation, focus_epoch):
        self.ai_pending = False
        if self.destroyed:
            return GLib.SOURCE_REMOVE
        if bridge_generation != self.input.generation or focus_epoch is not self.input.cancelled:
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
        self.ai_review.cancel()
        target = self.selected_text
        scope = self.make_ai_scope(target)
        expected_context = (self.left, self.right, target)
        snapshot = dict(self.snapshot)
        self.prompt_open = True
        dialog = PromptDialog(
            lambda prompt, selected_scope, completion: self.start_ai(snapshot, selected_scope, prompt=prompt, completion=completion),
            initial_prompt, scope=scope, on_context_changed=self.save_ai_context,
        )
        dialog.show_all()
        response = dialog.run()
        result = dialog.result
        dialog.destroy()
        self.prompt_open = False
        if response == Gtk.ResponseType.OK and result:
            self.pending_transform = (expected_context, result, time.monotonic() + 5)
            self.get_surrounding_text()
            GLib.idle_add(self.apply_pending_transform)
