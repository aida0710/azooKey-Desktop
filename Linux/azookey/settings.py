import threading
import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, GLib, Gio
from .bridge import Bridge
from .prompts import parse_shortcut, shortcut_text
from .i18n import text as message
from .labeled_controls import label_control, StatusMessage
from .settings_pages import populate_settings_pages
from .settings_store import SettingsStore, config_path
from .settings_schema import input_defaults, validate_settings
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
        self.values = self.bridge.request("settings")["settings"]
        first_setup = not config_path().exists()
        self.settings_store = SettingsStore()
        loaded = self.settings_store.load(self.values)
        self.values = loaded.values
        self.settings_stamp = loaded.stamp
        self.backend_recovery_pending = False
        self.recovery_bar = None
        self.widgets = {}
        self.closed = False
        self.dictionary_editor = None
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12, margin=18)
        self.add(box)
        if loaded.problem:
            self.recovery_bar = SettingsRecoveryBar(loaded.problem, path=self.settings_store.path, restore=self.restore_settings)
            box.pack_start(self.recovery_bar, False, False, 0)
        book = Gtk.Notebook()
        box.pack_start(book, True, True, 0)
        populate_settings_pages(self, book)
        if first_setup:
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
        store = SettingsStore()
        opened = store.load(self.values)
        if opened.problem:
            self.message.set_text(message("settings.recovery_required"))
            return
        if opened.stamp != self.settings_stamp:
            self.message.set_text(message("settings.changed"))
            return
        service = UserDictionaryService(store, opened)

        def saved(_entries):
            if self.closed:
                return
            self.values = service.last_saved.values
            self.settings_stamp = service.last_saved.stamp
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
        values = self.settings_store.recovery_values(self.values)
        if use_defaults:
            values = input_defaults(values)
        try:
            saved = self.apply_settings(values, recover=True)
            self.refresh_widgets(saved.values)
            self.recovery_bar.hide()
            self.message.set_text(message("settings.restored", backup=saved.backup_path))
            if saved.backup_warning:
                self.message.set_text(message("settings.backup_warning"))
        except (ValueError, OSError, RuntimeError) as error:
            self.message.set_text(str(error))

    def refresh_widgets(self, values):
        for key, widget in self.widgets.items():
            if isinstance(widget, Gtk.CheckButton):
                widget.set_active(values[key])
            elif isinstance(widget, Gtk.ComboBoxText):
                widget.set_active_id(str(values[key]))
            else:
                widget.set_text(str(values[key]))
        self.refresh_dictionary_button()
        self.custom_table.get_buffer().set_text(values["customTable"])
        self.transform_shortcut.set_text(shortcut_text(values["transformShortcut"]))

    def apply_settings(self, values, *, recover=False):
        values = validate_settings(values)

        def apply_staged(staged):
            if self.backend_recovery_pending:
                self.restore_backend_settings()
            reply = self.bridge.request("configure", settings=values)
            if reply.get("error"):
                raise ValueError(message("settings.engine_rejected"))
            try:
                staged.replace(self.settings_store.path)
            except OSError as publication_error:
                try:
                    self.restore_backend_settings()
                except RuntimeError as recovery_error:
                    raise recovery_error from publication_error
                raise

        # Check conflicts and hold the writer lock before mutating Core.
        saved = self.settings_store.save_with_backend(
            values, apply_staged=apply_staged, expected_stamp=self.settings_stamp, recover=recover,
        )
        self.values = saved.values
        self.settings_stamp = saved.stamp
        return saved

    def restore_backend_settings(self):
        # Until Core confirms the old values, another save must not compound
        # an interrupted publication with a second unverified configuration.
        self.backend_recovery_pending = True
        try:
            reply = self.bridge.request("configure", settings=self.values)
            if reply.get("error"):
                raise ValueError(message("settings.engine_rejected"))
        except (ValueError, OSError, RuntimeError) as error:
            raise RuntimeError(message("settings.backend_recovery_failed")) from error
        self.backend_recovery_pending = False

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
        dialog = Gtk.FileChooserDialog(title=message("personalization.choose"), transient_for=self,
                                       action=Gtk.FileChooserAction.SELECT_FOLDER)
        dialog.add_buttons(message("personalization.cancel"), Gtk.ResponseType.CANCEL,
                           message("personalization.import"), Gtk.ResponseType.OK)
        response = dialog.run()
        source = dialog.get_filename()
        dialog.destroy()
        if response != Gtk.ResponseType.OK or source is None:
            return
        try:
            reply = self.bridge.request("import-personalization", importPath=source)
        except (OSError, RuntimeError, ValueError):
            reply = {}
        if reply.get("personalizationImported"):
            self.message.set_text(message("personalization.imported"))
            return
        # Core replaces "current" only after all four files are copied and checked.
        failure = reply.get("personalizationFailure") or {"reason": "placement"}
        self.message.set_text(message(f"personalization.failure.{failure['reason']}", file=failure.get("file")))

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

    def combo(self, parent, key, *, label, choices):
        combo = Gtk.ComboBoxText()
        label_control(parent, combo, label)
        for value, title in choices:
            combo.append(str(value), title)
        combo.set_active_id(str(self.values[key]))
        parent.pack_start(combo, False, False, 0)
        self.widgets[key] = combo

    def entry(self, parent, key, label):
        entry = Gtk.Entry(text=str(self.values[key]))
        label_control(parent, entry, label)
        parent.pack_start(entry, False, False, 0)
        self.widgets[key] = entry

    @staticmethod
    def text_area(parent, text, title):
        view = Gtk.TextView(monospace=True)
        label_control(parent, view, title)
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
            values["customTable"] = self.text(self.custom_table)
            values["transformShortcut"] = parse_shortcut(self.transform_shortcut.get_text())
            if values["transformShortcut"] is None:
                raise ValueError(message("ai.shortcut.required"))
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
