import json
import os
import pathlib
import uuid
import threading
import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, GLib, Gio
from .bridge import Bridge
from .prompts import parse_shortcut, shortcut_text
from .personalization import import_model
from .i18n import text as message
from .learning_settings import learning_choices
from .support_page import SupportPage


def config_path():
    base = pathlib.Path(os.environ.get("XDG_CONFIG_HOME", pathlib.Path.home() / ".config"))
    return base / "azookey-tree/settings.json"


def read_key():
    gi.require_version("Secret", "1")
    from gi.repository import Secret
    schema = Secret.Schema.new("org.azookey.Tree", Secret.SchemaFlags.NONE, {"service": Secret.SchemaAttributeType.STRING})
    return Secret.password_lookup_sync(schema, {"service": "openai-compatible"}, None) or ""


def save_key(value):
    gi.require_version("Secret", "1")
    from gi.repository import Secret
    schema = Secret.Schema.new("org.azookey.Tree", Secret.SchemaFlags.NONE, {"service": Secret.SchemaAttributeType.STRING})
    if not Secret.password_store_sync(schema, {"service": "openai-compatible"}, Secret.COLLECTION_DEFAULT,
                                      "azooKey Tree AI API key", value, None):
        raise ValueError("キーリングにAPIキーを保存できませんでした。")


class SettingsWindow(Gtk.Window):
    def __init__(self):
        super().__init__(title="azooKey Tree 設定")
        self.set_default_size(620, 620)
        self.bridge = Bridge()
        self.values = self.bridge.request("settings")["settings"]
        first_setup = not config_path().exists()
        if config_path().is_file():
            self.values.update(json.loads(config_path().read_text()))
        self.widgets = {}
        self.closed = False
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12, margin=18)
        self.add(box)
        book = Gtk.Notebook()
        box.pack_start(book, True, True, 0)
        basic = self.page(book, "入力・変換")
        for key, label in [("tree", "木構造の候補ウィンドウ"), ("live", "ライブ変換"),
                           ("halfSpace", "スペースを半角にする"), ("backslash", "円記号の代わりにバックスラッシュ"),
                           ("optionDirect", "Altキーで全角英数を直接入力")]:
            button = Gtk.CheckButton(label=label, active=self.values[key])
            basic.pack_start(button, False, False, 0)
            self.widgets[key] = button
        self.combo(basic, "candidateTextSize", message("candidate.textSize"),
                   [("standard", message("candidate.textSize.standard")), ("large", message("candidate.textSize.large"))])
        self.combo(basic, "inputStyle", "入力配列", [("default", "ローマ字"), ("defaultAZIK", "AZIK"), ("defaultKanaJIS", "かな JIS"), ("defaultKanaUS", "かな US"), ("custom", "カスタム")])
        self.combo(basic, "learning", message("learning.title"), learning_choices())
        basic.pack_start(Gtk.Label(label=message("learning.retention"), xalign=0, wrap=True), False, False, 0)
        self.combo(basic, "punctuation", "句読点", [(1, "、。"), (2, "，。"), (3, "、．"), (4, "，．")])
        self.combo(basic, "personalization", "個人化", [("off", "オフ"), ("soft", "弱"), ("normal", "標準"), ("hard", "強")])
        personal = Gtk.Button(label="Tunerの個人化モデルを読み込む…")
        personal.connect("clicked", self.import_personalization)
        basic.pack_start(personal, False, False, 0)
        self.entry(basic, "profile", "変換プロファイル")
        self.entry(basic, "inferenceLimit", "推論回数 (1–100)")
        reset = Gtk.Button(label=message("learning.reset.action"))
        reset.connect("clicked", self.reset_learning)
        basic.pack_start(reset, False, False, 0)
        dictionary = self.page(book, "辞書・入力表")
        dictionary.pack_start(Gtk.Label(label="ユーザー辞書：1行ごとに「読み<Tab>単語<Tab>ヒント」", xalign=0), False, False, 0)
        text = "\n".join("\t".join([item["reading"], item["word"], item.get("hint") or ""]) for item in self.values["userDictionary"]["items"])
        self.dictionary = self.text_area(dictionary, text)
        dictionary.pack_start(Gtk.Label(label="カスタム入力表（TSV）", xalign=0), False, False, 0)
        self.custom_table = self.text_area(dictionary, self.values["customTable"])
        ai = self.page(book, "AI・詳細")
        for key, label in [("aiEnabled", "OpenAI互換APIを使用"), ("includeContext", "AI変換に周辺テキストを含める"),
                           ("predictiveTyping", "予測入力（開発中）"), ("typoCorrection", "入力訂正（開発中）"), ("debug", "デバッグ候補")]:
            widget = Gtk.CheckButton(label=label, active=self.values[key])
            ai.pack_start(widget, False, False, 0)
            self.widgets[key] = widget
        self.entry(ai, "aiModel", "モデル")
        self.entry(ai, "aiEndpoint", "エンドポイント")
        ai.pack_start(Gtk.Label(label="いい感じ変換のショートカット", xalign=0), False, False, 0)
        self.transform_shortcut = Gtk.Entry(text=shortcut_text(self.values["transformShortcut"]))
        ai.pack_start(self.transform_shortcut, False, False, 0)
        self.api_key = Gtk.Entry(visibility=False, placeholder_text="APIキー（空欄なら変更しません）")
        ai.pack_start(self.api_key, False, False, 0)
        ai.pack_start(Gtk.Label(label="APIキーはデスクトップのキーリングへ保存します。", xalign=0), False, False, 0)
        download = Gtk.Button(label="入力訂正モデルをダウンロード")
        download.connect("clicked", self.download_weights)
        ai.pack_start(download, False, False, 0)
        support = self.page(book, message("support.title"))
        support.pack_start(SupportPage(lambda: self.values), True, True, 0)
        if first_setup:
            support_index = book.get_n_pages() - 1
            book.get_nth_page(support_index).show_all()
            book.set_current_page(support_index)
        self.message = Gtk.Label(xalign=0, wrap=True)
        box.pack_start(self.message, False, False, 0)
        save = Gtk.Button(label="保存")
        save.connect("clicked", self.save)
        box.pack_start(save, False, False, 0)
        self.connect("destroy", self.destroyed)

    def destroyed(self, _window):
        self.closed = True
        self.bridge.close()
        Gtk.main_quit()

    def reset_learning(self, _button):
        dialog = Gtk.MessageDialog(transient_for=self, modal=True, message_type=Gtk.MessageType.QUESTION,
                                   buttons=Gtk.ButtonsType.NONE, text=message("learning.reset.title"))
        dialog.add_buttons(message("settings.cancel"), Gtk.ResponseType.CANCEL,
                           message("learning.reset.confirm"), Gtk.ResponseType.OK)
        dialog.set_default_response(Gtk.ResponseType.CANCEL)
        dialog.format_secondary_text(message("learning.reset.explanation"))
        response = dialog.run()
        dialog.destroy()
        if response == Gtk.ResponseType.OK:
            try:
                reply = Gio.DBus.session.call_sync("org.azookey.Tree", "/org/azookey/Tree", "org.azookey.Tree",
                                                   "ResetLearning", None, GLib.VariantType.new("(b)"),
                                                   Gio.DBusCallFlags.NONE, 5000, None)
                success = reply.unpack()[0]
            except GLib.Error:
                success = False
            if not success:
                success = not self.bridge.request("reset-learning").get("error")
            self.message.set_text(message("learning.reset.completed" if success else "learning.reset.failed"))

    def import_personalization(self, _button):
        dialog = Gtk.FileChooserDialog(title="lm_*.marisa の4ファイルがあるフォルダーを選択", transient_for=self,
                                       action=Gtk.FileChooserAction.SELECT_FOLDER)
        dialog.add_buttons("キャンセル", Gtk.ResponseType.CANCEL, "読み込む", Gtk.ResponseType.OK)
        response = dialog.run()
        source = dialog.get_filename()
        dialog.destroy()
        if response == Gtk.ResponseType.OK:
            try:
                import_model(source)
                self.message.set_text("個人化モデルを読み込みました。強度を選び「保存」で反映してください。")
            except (OSError, ValueError) as error:
                self.message.set_text(str(error))

    def download_weights(self, button):
        button.set_sensitive(False)
        self.message.set_text("入力訂正モデルをダウンロードしています…")
        def finish(success):
            if not self.closed:
                button.set_sensitive(True)
                self.message.set_text("入力訂正モデルを検証して保存しました。" if success else "ダウンロードまたは検証に失敗しました。")
            return GLib.SOURCE_REMOVE
        def work():
            connection = None
            try:
                connection = Bridge(timeout=1800)
                result = connection.request("download-typo-weights")
                GLib.idle_add(finish, not result.get("error"))
            except (ValueError, OSError, RuntimeError):
                GLib.idle_add(finish, False)
            finally:
                if connection:
                    connection.close()
        threading.Thread(target=work, daemon=True).start()

    @staticmethod
    def page(book, title):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10, margin=12)
        scroller = Gtk.ScrolledWindow()
        scroller.add(box)
        book.append_page(scroller, Gtk.Label(label=title))
        return box

    def combo(self, parent, key, label, choices):
        parent.pack_start(Gtk.Label(label=label, xalign=0), False, False, 0)
        combo = Gtk.ComboBoxText()
        for value, title in choices:
            combo.append(str(value), title)
        combo.set_active_id(str(self.values[key]))
        parent.pack_start(combo, False, False, 0)
        self.widgets[key] = combo

    def entry(self, parent, key, label):
        parent.pack_start(Gtk.Label(label=label, xalign=0), False, False, 0)
        entry = Gtk.Entry(text=str(self.values[key]))
        parent.pack_start(entry, False, False, 0)
        self.widgets[key] = entry

    @staticmethod
    def text_area(parent, text):
        view = Gtk.TextView(monospace=True)
        view.get_buffer().set_text(text)
        scroller = Gtk.ScrolledWindow(min_content_height=140)
        scroller.add(view)
        parent.pack_start(scroller, True, True, 0)
        return view

    @staticmethod
    def text(view):
        buffer = view.get_buffer()
        return buffer.get_text(buffer.get_start_iter(), buffer.get_end_iter(), True)

    def save(self, _button):
        try:
            values = dict(self.values)
            for key, widget in self.widgets.items():
                if isinstance(widget, Gtk.CheckButton):
                    values[key] = widget.get_active()
                elif isinstance(widget, Gtk.ComboBoxText):
                    values[key] = widget.get_active_id()
                else:
                    values[key] = widget.get_text()
            for key in ("punctuation", "inferenceLimit"):
                values[key] = int(values[key])
            items = []
            for line in self.text(self.dictionary).splitlines():
                if not line.strip():
                    continue
                fields = line.split("\t")
                if len(fields) not in (2, 3) or not all(fields[:2]):
                    raise ValueError("辞書は読み・単語・任意のヒントをタブで区切ってください。")
                items.append({"id": str(uuid.uuid4()), "reading": fields[0], "word": fields[1], "hint": fields[2] if len(fields) == 3 else ""})
            values["userDictionary"] = {"items": items}
            values["customTable"] = self.text(self.custom_table)
            values["transformShortcut"] = parse_shortcut(self.transform_shortcut.get_text())
            if values["transformShortcut"] is None:
                raise ValueError("いい感じ変換のショートカットを指定してください。")
            result = self.bridge.request("configure", settings=values)
            if result.get("error"):
                raise ValueError("設定を保存できません。推論回数・URL・カスタム入力表を確認してください。")
            path = config_path()
            path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            temporary = path.with_suffix(".tmp")
            with os.fdopen(os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as stream:
                json.dump(values, stream, ensure_ascii=False)
            temporary.replace(path)
            self.values = values
            self.message.set_text("保存しました。次の入力から反映します。")
            if self.api_key.get_text():
                try:
                    save_key(self.api_key.get_text())
                    self.api_key.set_text("")
                except (ValueError, GLib.Error):
                    self.message.set_text("設定は保存済みですが、APIキーの保存に失敗しました。キーリングを確認してください。")
        except (ValueError, OSError, RuntimeError, GLib.Error) as error:
            self.message.set_text(str(error))


def run():
    window = SettingsWindow()
    window.show_all()
    Gtk.main()
