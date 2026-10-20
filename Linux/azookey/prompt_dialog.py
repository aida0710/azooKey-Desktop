import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk
from .ai_scope_view import AIRequestScopeView
from .i18n import text as message
from .prompts import PromptHistory, parse_shortcut, shortcut_text


class PromptDialog(Gtk.Dialog):
    # Show the reviewed target and destination above the existing prompt controls.
    DEFAULT_SIZE = (620, 660)

    def __init__(self, preview, initial_prompt="", *, scope, on_context_changed):
        super().__init__(title="いい感じ変換")
        self.set_default_size(*self.DEFAULT_SIZE)
        self.add_buttons("キャンセル", Gtk.ResponseType.CANCEL, "適用", Gtk.ResponseType.OK)
        self.set_response_sensitive(Gtk.ResponseType.OK, False)
        self.history = PromptHistory()
        self.result = None
        self.closed = False
        self.revision = 0
        self.connect("destroy", self.destroyed)
        box = self.get_content_area()
        box.set_spacing(10)
        box.set_border_width(16)
        self.scope_view = AIRequestScopeView(scope, self.scope_changed)
        self.on_context_changed = on_context_changed
        box.add(self.scope_view)
        box.add(Gtk.Label(label=message("ai.scope.history"), xalign=0, wrap=True))
        self.entry = Gtk.Entry(text=initial_prompt, placeholder_text="例：敬語に直す、英語へ翻訳する")
        box.add(self.entry)
        history = Gtk.ComboBoxText()
        self.items = self.history.load()
        history.append("", "履歴から選択")
        for index, item in enumerate(self.items):
            history.append(str(index), ("★ " if item["pinned"] else "") + item["prompt"])
        history.set_active_id("")
        history.connect("changed", self.select_history)
        box.add(history)
        self.pin = Gtk.CheckButton(label="ピン留めする")
        box.add(self.pin)
        self.shortcut = Gtk.Entry(placeholder_text="ピン留め用ショートカット（例：Ctrl+Alt+e）")
        box.add(self.shortcut)
        self.preview_button = Gtk.Button(label=message("ai.scope.preview"))
        box.add(self.preview_button)
        self.text = Gtk.TextView(editable=False, wrap_mode=Gtk.WrapMode.WORD_CHAR)
        scroll = Gtk.ScrolledWindow(min_content_height=160)
        scroll.add(self.text)
        box.pack_start(scroll, True, True, 0)
        self.message = Gtk.Label(xalign=0, wrap=True)
        box.add(self.message)
        self.preview_button.connect("clicked", lambda _: self.generate(preview))
        self.entry.connect("activate", lambda _: self.generate(preview))
        self.entry.connect("changed", self.invalidate)

    def destroyed(self, _dialog):
        self.closed = True

    def invalidate(self, _entry):
        self.revision += 1
        self.result = None
        self.set_response_sensitive(Gtk.ResponseType.OK, False)

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
        if not prompt:
            return
        try:
            self.history.save(prompt, self.pin.get_active(), parse_shortcut(self.shortcut.get_text()))
        except (ValueError, OSError) as error:
            self.message.set_text(str(error))
            return
        self.revision += 1
        revision = self.revision
        self.preview_button.set_sensitive(False)
        self.scope_view.context.set_sensitive(False)
        self.set_response_sensitive(Gtk.ResponseType.OK, False)
        self.message.set_text("生成中…")

        def finish(text):
            if self.closed:
                return
            self.preview_button.set_sensitive(True)
            self.scope_view.context.set_sensitive(True)
            if revision != self.revision:
                self.message.set_text(message("ai.scope.changed"))
                return
            self.result = text
            self.text.get_buffer().set_text(text or "")
            self.set_response_sensitive(Gtk.ResponseType.OK, bool(text))
            self.message.set_text("内容を確認して適用してください。" if text else "生成できませんでした。AI設定を確認してください。")
        preview(prompt, self.scope_view.scope, finish)
