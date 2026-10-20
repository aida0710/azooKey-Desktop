import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gdk, Gtk
from .ai_preview import AITransformationPreview
from .ai_scope_view import AIRequestScopeView
from .i18n import text as message
from .labeled_controls import label_control, StatusMessage
from .prompts import PromptHistory, parse_shortcut, shortcut_text


class PromptDialog(Gtk.Dialog):
    # Show the reviewed target and destination above the existing prompt controls.
    DEFAULT_SIZE = (620, 660)

    def __init__(self, preview, initial_prompt="", *, scope, on_context_changed):
        super().__init__(title=message("ai.title"))
        self.set_default_size(*self.DEFAULT_SIZE)
        self.add_buttons(message("settings.cancel"), Gtk.ResponseType.CANCEL, message("ai.preview.apply"), Gtk.ResponseType.OK)
        self.set_response_sensitive(Gtk.ResponseType.OK, False)
        self.history = PromptHistory()
        self.preview = AITransformationPreview()
        self.target_available = True
        self.closed = False
        self.connect("destroy", self.destroyed)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        box.set_spacing(10)
        box.set_border_width(16)
        scroller = Gtk.ScrolledWindow()
        scroller.add(box)
        self.get_content_area().pack_start(scroller, True, True, 0)
        self.scope_view = AIRequestScopeView(scope, self.scope_changed)
        self.on_context_changed = on_context_changed
        box.add(self.scope_view)
        box.add(Gtk.Label(label=message("ai.scope.history"), xalign=0, wrap=True))
        self.entry = Gtk.Entry(text=initial_prompt, placeholder_text=message("ai.instruction-placeholder"))
        label_control(box, self.entry, message("ai.instruction"), mnemonic="I")
        box.add(self.entry)
        history = Gtk.ComboBoxText()
        self.items = self.history.load()
        history.append("", message("ai.history.choose"))
        for index, item in enumerate(self.items):
            history.append(str(index), ("★ " if item["pinned"] else "") + item["prompt"])
        history.set_active_id("")
        history.connect("changed", self.select_history)
        label_control(box, history, message("ai.history"), mnemonic="H")
        box.add(history)
        self.pin = Gtk.CheckButton(label=message("ai.pin"))
        box.add(self.pin)
        self.shortcut = Gtk.Entry(placeholder_text=message("ai.shortcut.placeholder"))
        label_control(box, self.shortcut, message("ai.shortcut.prompt"), mnemonic="S")
        box.add(self.shortcut)
        self.preview_button = Gtk.Button(label=message("ai.scope.preview"))
        box.add(self.preview_button)
        self.text = Gtk.TextView(editable=False, wrap_mode=Gtk.WrapMode.WORD_CHAR)
        label_control(box, self.text, message("ai.preview"))
        scroll = Gtk.ScrolledWindow(min_content_height=160)
        scroll.add(self.text)
        box.pack_start(scroll, True, True, 0)
        self.copy_button = Gtk.Button(label=message("ai.preview.copy"))
        self.copy_button.set_sensitive(False)
        self.copy_button.connect("clicked", self.copy_result)
        box.add(self.copy_button)
        self.target_message = StatusMessage()
        box.add(self.target_message)
        self.message = StatusMessage()
        box.add(self.message)
        self.preview_button.connect("clicked", lambda _: self.generate(preview))
        self.entry.connect("activate", lambda _: self.generate(preview))
        self.entry.connect("changed", self.invalidate)

    def destroyed(self, _dialog):
        self.closed = True
        self.preview.invalidate()

    @property
    def result(self):
        return self.preview.applicable_text

    def set_target_available(self, available):
        self.target_available = available
        self.set_response_sensitive(Gtk.ResponseType.OK, available and bool(self.result))
        self.target_message.set_text("" if available else message("ai.preview.target-changed"))

    def copy_result(self, _button):
        if self.result:
            Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD).set_text(self.result, -1)

    def invalidate(self, _entry):
        had_preview = self.preview.is_loading or self.preview.applicable_text is not None
        self.preview.invalidate()
        self.text.get_buffer().set_text("")
        self.set_response_sensitive(Gtk.ResponseType.OK, False)
        self.copy_button.set_sensitive(False)
        self.preview_button.set_sensitive(True)
        self.scope_view.context.set_sensitive(True)
        if had_preview:
            self.message.set_text(message("ai.scope.changed"))

    def scope_changed(self, scope):
        self.invalidate(None)
        if self.on_context_changed(scope.include_context) is False:
            self.message.set_text(message("ai.scope.include-error"))

    def select_history(self, combo):
        identifier = combo.get_active_id()
        if not identifier:
            return
        item = self.items[int(identifier)]
        self.entry.set_text(item["prompt"])
        self.pin.set_active(item["pinned"])
        self.shortcut.set_text(shortcut_text(item.get("shortcut")))

    def generate(self, preview):
        prompt = self.entry.get_text().strip()
        if not prompt or self.preview.is_loading:
            return
        try:
            self.history.save(prompt, self.pin.get_active(), parse_shortcut(self.shortcut.get_text()))
        except (ValueError, OSError) as error:
            self.message.set_text(str(error))
            return
        revision = self.preview.begin()
        self.text.get_buffer().set_text("")
        self.preview_button.set_sensitive(False)
        self.scope_view.context.set_sensitive(False)
        self.set_response_sensitive(Gtk.ResponseType.OK, False)
        self.copy_button.set_sensitive(False)
        self.message.set_text(message("ai.scope.generating"))

        def finish(text):
            if self.closed or not self.preview.complete(revision, text):
                return
            self.preview_button.set_sensitive(True)
            self.scope_view.context.set_sensitive(True)
            self.text.get_buffer().set_text(text or "")
            self.set_response_sensitive(Gtk.ResponseType.OK, self.target_available and bool(text))
            self.copy_button.set_sensitive(bool(text))
            self.message.set_text(message("ai.preview.ready" if text else "ai.preview.failed"))
        preview(prompt, self.scope_view.scope, finish)
