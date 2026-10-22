"""The selected-text AI prompt. Core decides what is sent and which preview
is current; the dialog shows Core's answers and reports the user's input."""
import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gdk, Gtk
from .ai_error_messages import ai_error_message
from .ai_scope_view import AIRequestScopeView
from .i18n import text as message
from .labeled_controls import label_control, StatusMessage


class PromptDialog(Gtk.Dialog):
    # Show the reviewed target and destination above the existing prompt controls.
    DEFAULT_SIZE = (620, 660)

    def __init__(self, opened, initial_prompt="", *, request_preview, invalidate_preview, on_context_changed):
        """`opened` is Core's reply to `ai-transform-open`."""
        super().__init__(title=message("ai.title"))
        self.set_default_size(*self.DEFAULT_SIZE)
        self.add_buttons(message("settings.cancel"), Gtk.ResponseType.CANCEL, message("ai.preview.apply"), Gtk.ResponseType.OK)
        self.set_response_sensitive(Gtk.ResponseType.OK, False)
        self.request_preview = request_preview
        self.invalidate_preview = invalidate_preview
        self.on_context_changed = on_context_changed
        # Core's current preview: copyable, and applicable when the target is.
        self.result = None
        self.loading = False
        # Counts edits so a reply to an older instruction is not shown.
        self.edits = 0
        self.target_available = True
        self.closed = False
        self.connect("destroy", self.destroyed)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        box.set_spacing(10)
        box.set_border_width(16)
        scroller = Gtk.ScrolledWindow()
        scroller.add(box)
        self.get_content_area().pack_start(scroller, True, True, 0)
        self.scope_view = AIRequestScopeView(
            target=opened["target"], destination=opened.get("destination"),
            include_context=opened["includeContext"], on_context_changed=self.scope_changed,
        )
        box.add(self.scope_view)
        box.add(Gtk.Label(label=message("ai.scope.history"), xalign=0, wrap=True))
        self.entry = Gtk.Entry(text=initial_prompt, placeholder_text=message("ai.instruction-placeholder"))
        label_control(box, self.entry, message("ai.instruction"), mnemonic="I")
        box.add(self.entry)
        self.history = Gtk.ComboBoxText()
        self.items = opened["history"]
        self.history.append("", message("ai.history.choose"))
        for index, item in enumerate(self.items):
            self.history.append(str(index), ("★ " if item["pinned"] else "") + item["prompt"])
        self.history.set_active_id("")
        self.history.connect("changed", self.select_history)
        label_control(box, self.history, message("ai.history"), mnemonic="H")
        box.add(self.history)
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
        self.preview_button.connect("clicked", lambda _: self.generate())
        self.entry.connect("activate", lambda _: self.generate())
        self.entry.connect("changed", self.invalidate)

    def destroyed(self, _dialog):
        self.closed = True

    def set_target_available(self, available):
        self.target_available = available
        self.set_response_sensitive(Gtk.ResponseType.OK, available and bool(self.result))
        self.target_message.set_text("" if available else message("ai.preview.target-changed"))

    def copy_result(self, _button):
        if self.result:
            Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD).set_text(self.result, -1)

    def invalidate(self, _entry):
        had_preview = self.loading or self.result is not None
        self.edits += 1
        self.loading = False
        self.result = None
        self.text.get_buffer().set_text("")
        self.set_response_sensitive(Gtk.ResponseType.OK, False)
        self.copy_button.set_sensitive(False)
        self.preview_button.set_sensitive(True)
        self.scope_view.context.set_sensitive(True)
        if had_preview:
            self.message.set_text(message("ai.scope.changed"))
        # Sent even without a visible preview: Core may have started one
        # whose reply has not arrived yet.
        self.invalidate_preview()

    def scope_changed(self, included):
        self.invalidate(None)
        if self.on_context_changed(included) is False:
            self.message.set_text(message("ai.scope.include-error"))

    def select_history(self, combo):
        identifier = combo.get_active_id()
        if not identifier:
            return
        item = self.items[int(identifier)]
        self.entry.set_text(item["prompt"])
        self.pin.set_active(item["pinned"])
        self.shortcut.set_text(item["shortcutText"])

    def generate(self):
        if self.closed:
            return
        self.request_preview(self.entry.get_text(), self.pin.get_active(), self.shortcut.get_text(),
                             self.scope_view.include_context)

    def preview_started(self):
        self.loading = True
        self.result = None
        self.text.get_buffer().set_text("")
        self.preview_button.set_sensitive(False)
        self.scope_view.context.set_sensitive(False)
        self.set_response_sensitive(Gtk.ResponseType.OK, False)
        self.copy_button.set_sensitive(False)
        self.message.set_text(message("ai.scope.generating"))

    def preview_finished(self, text):
        self.loading = False
        self.result = text or None
        self.preview_button.set_sensitive(True)
        self.scope_view.context.set_sensitive(True)
        self.text.get_buffer().set_text(text or "")
        self.set_response_sensitive(Gtk.ResponseType.OK, self.target_available and bool(text))
        self.copy_button.set_sensitive(bool(text))
        self.message.set_text(message("ai.preview.ready" if text else "ai.preview.failed"))

    def history_failed(self, code):
        self.message.set_text(ai_error_message(code))
