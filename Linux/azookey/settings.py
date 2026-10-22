import threading
import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, GLib, Gio
from .bridge import Bridge
from .personalization import import_model
from .i18n import text as message
from .labeled_controls import StatusMessage
from . import settings_client
from .settings_pages import populate_settings_pages
from .settings_recovery import SettingsRecoveryBar, confirm_restore
from .user_dictionary_editor import UserDictionaryEditor
from .user_dictionary_service import UserDictionaryService


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
        self.schema = settings_client.schema(self.bridge)
        opened = settings_client.load(self.bridge)
        self.values = opened.values
        self.settings_stamp = opened.stamp
        self.recovery_bar = None
        self.widgets = {}
        self.controls = {}
        self.closed = False
        self.dictionary_editor = None
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12, margin=18)
        self.add(box)
        if opened.problem:
            self.recovery_bar = SettingsRecoveryBar(
                settings_client.problem_text(opened.problem), path=opened.path, restore=self.restore_settings,
            )
            box.pack_start(self.recovery_bar, False, False, 0)
        book = Gtk.Notebook()
        box.pack_start(book, True, True, 0)
        populate_settings_pages(self, book)
        if not opened.exists:
            support_index = book.get_n_pages() - 1
            book.get_nth_page(support_index).show_all()
            book.set_current_page(support_index)
        self.message = StatusMessage()
        box.pack_start(self.message, False, False, 0)
        save = Gtk.Button(label=message("settings.save"))
        save.connect("clicked", self.save)
        box.pack_start(save, False, False, 0)
        self.connect("destroy", self.destroyed)
        self.connect("delete-event", self.close_requested)
        if self.recovery_bar:
            self.set_focus(self.recovery_bar.restore_button)

    def destroyed(self, _window):
        self.closed = True
        if self.dictionary_editor is not None and not self.dictionary_editor.closed:
            self.dictionary_editor.close()
        self.bridge.close()
        if Gtk.main_level():
            Gtk.main_quit()

    def close_requested(self, _window, _event):
        if self.dictionary_editor is None or self.dictionary_editor.closed:
            return False
        self.dictionary_editor.present()
        return True

    def refresh_dictionary_button(self):
        count = len(self.values["userDictionary"]["items"])
        self.dictionary_button.set_label(message("settings.dictionary_edit", count=count))

    def edit_dictionary(self, _button):
        if self.dictionary_editor is not None and not self.dictionary_editor.closed:
            self.dictionary_editor.present()
            return
        try:
            opened = settings_client.load(self.bridge)
        except (ValueError, OSError, RuntimeError) as error:
            self.message.set_text(str(error))
            return
        if opened.problem:
            self.message.set_text(message("settings.recovery_required"))
            return
        if opened.stamp != self.settings_stamp:
            self.message.set_text(message("settings.changed"))
            return
        service = UserDictionaryService(opened)

        def saved(_entries):
            if self.closed:
                return
            self.accept_saved(service.last_saved)
            self.refresh_dictionary_button()
            key = "settings.backup_warning" if service.last_saved.backup_warning else "settings.dictionary_saved"
            self.message.set_text(message(key))

        self.dictionary_editor = UserDictionaryEditor(
            opened.values["userDictionary"]["items"], validate=service.validate,
            save=service.save, parent=self, on_saved=saved,
        )
        self.dictionary_editor.set_modal(True)
        self.dictionary_editor.show_all()

    def restore_settings(self, use_defaults):
        if not confirm_restore(self):
            return
        try:
            saved = settings_client.recover(self.bridge, expected_stamp=self.settings_stamp, use_defaults=use_defaults)
        except (ValueError, OSError, RuntimeError) as error:
            self.message.set_text(str(error))
            return
        self.accept_saved(saved)
        self.refresh_widgets(saved.values)
        self.recovery_bar.hide()
        self.message.set_text(message("settings.restored", backup=saved.recovered_path))
        if saved.backup_warning:
            self.message.set_text(message("settings.backup_warning"))

    def refresh_widgets(self, values):
        for key, control in self.controls.items():
            control.show(values[key])
        self.refresh_dictionary_button()

    def apply_settings(self, values):
        """Core validates, applies and saves; a refusal arrives as ValueError."""
        saved = settings_client.save(self.bridge, values, expected_stamp=self.settings_stamp)
        self.accept_saved(saved)
        return saved

    def accept_saved(self, saved):
        self.values = saved.values
        self.settings_stamp = saved.stamp

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
                reply = Gio.bus_get_sync(Gio.BusType.SESSION, None).call_sync("org.azookey.Tree", "/org/azookey/Tree", "org.azookey.Tree",
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

    def save(self, _button):
        try:
            values = dict(self.values)
            for key, control in self.controls.items():
                values[key] = control.read()
            saved = self.apply_settings(values)
            self.message.set_text(message("settings.backup_warning" if saved.backup_warning else "settings.saved"))
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
