"""A GTK draft editor with explicit, asynchronous dictionary saving."""

import json
from pathlib import Path
import threading

import gi
gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk, Pango

from .user_dictionary_exchange_dialogs import UserDictionaryFileDialogs
from .user_dictionary_exchange_service import UserDictionaryExchangeService
from .user_dictionary_model import (
    DictionaryExchangeError, DictionaryFileOutcome, DictionarySaveOutcome,
    UserDictionaryModel, matches_dictionary_query, save_dictionary,
)


_CATALOG = json.loads(
    Path(__file__).with_name("locales").joinpath("user_dictionary.ja.json").read_text(encoding="utf-8")
)
# The list stays usable beside a complete, wrapping editor for the selected item.
WINDOW_WIDTH = 760
WINDOW_HEIGHT = 560
LIST_HEIGHT = 180
HINT_HEIGHT = 64
# GtkTreeModelSort's unsorted mode keeps its current order rather than restoring it.
REGISTRATION_ORDER_COLUMN = 5


def _message(key, *, fallback=None, **values):
    template = _CATALOG[key] if key in _CATALOG or fallback is None else _CATALOG[fallback]
    return template.format(**values)


class UserDictionaryEditor(Gtk.Window):
    """Edit entries without reading settings or owning the persistence transaction.

    validate(entries) returns DictionaryValidationIssue objects from the Core
    validator. save(entries) returns None only after persistence and activation,
    or raises DictionarySaveError with a public failure stage. Both run on the
    same worker and must not access GTK. on_saved(entries) runs on the GTK thread
    after success and only updates the parent view's in-memory state.
    """

    def __init__(
        self, entries, *, validate, save, parent=None, on_saved=None, exchange_service=None, file_dialogs=None,
    ):
        super().__init__(title=_message("title"))
        self.set_default_size(WINDOW_WIDTH, WINDOW_HEIGHT)
        if parent is not None:
            self.set_transient_for(parent)
        self.model = UserDictionaryModel(entries)
        self._validate = validate
        self._save = save
        self._on_saved = on_saved
        self._exchange_service = exchange_service if exchange_service is not None else UserDictionaryExchangeService()
        self._file_dialogs = file_dialogs if file_dialogs is not None else UserDictionaryFileDialogs(self, message=_message)
        self._selected_id = None
        self._loading_form = False
        self._updating_rows = False
        self._query = ""
        self.closed = False
        self.connect("delete-event", self._request_close)
        self.connect("destroy", self._destroyed)
        self._build_widgets()
        self._refresh_rows()

    def _build_widgets(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12, margin=16)
        self.add(box)
        box.pack_start(Gtk.Label(label=_message("instructions"), xalign=0, wrap=True), False, False, 0)
        search = Gtk.Box(spacing=8)
        self.search_entry = Gtk.SearchEntry(hexpand=True, placeholder_text=_message("search"))
        self.search_entry.get_accessible().set_name(_message("search"))
        self.search_entry.connect("changed", self._query_changed)
        search.pack_start(self.search_entry, True, True, 0)
        self.reset_sort_button = Gtk.Button(label=_message("sort_original"))
        self.reset_sort_button.connect("clicked", self._reset_sort)
        search.pack_start(self.reset_sort_button, False, False, 0)
        box.pack_start(search, False, False, 0)
        self.filter_label = Gtk.Label(xalign=0, wrap=True)
        box.pack_start(self.filter_label, False, False, 0)
        self.rows = Gtk.ListStore(str, str, str, str, str, int)
        self.filtered_rows = self.rows.filter_new()
        self.filtered_rows.set_visible_func(self._row_matches_query)
        self.sorted_rows = Gtk.TreeModelSort(model=self.filtered_rows)
        self.sorted_rows.set_sort_column_id(REGISTRATION_ORDER_COLUMN, Gtk.SortType.ASCENDING)
        self.tree = Gtk.TreeView(model=self.sorted_rows)
        self.tree.get_accessible().set_name(_message("title"))
        for index, key in enumerate(("word", "reading", "hint", "issues"), start=1):
            renderer = Gtk.CellRendererText(ellipsize=Pango.EllipsizeMode.END)
            column = Gtk.TreeViewColumn(_message(key), renderer, text=index)
            column.set_expand(True)
            column.set_resizable(True)
            if key != "issues":
                column.set_sort_column_id(index)
            self.tree.append_column(column)
        self.tree.get_selection().connect("changed", self._selection_changed)
        scroller = Gtk.ScrolledWindow(min_content_height=LIST_HEIGHT)
        scroller.add(self.tree)
        box.pack_start(scroller, True, True, 0)
        actions = Gtk.Box(spacing=8)
        self.add_button = Gtk.Button(label=_message("add"))
        self.add_button.connect("clicked", self._add)
        actions.pack_start(self.add_button, False, False, 0)
        self.remove_button = Gtk.Button(label=_message("remove"))
        self.remove_button.connect("clicked", self._remove)
        actions.pack_start(self.remove_button, False, False, 0)
        self.import_button = Gtk.Button(label=_message("import.title"))
        self.import_button.connect("clicked", self._file_clicked, "import")
        actions.pack_start(self.import_button, False, False, 0)
        self.export_button = Gtk.Button(label=_message("export.title"))
        self.export_button.connect("clicked", self._file_clicked, "export")
        actions.pack_start(self.export_button, False, False, 0)
        box.pack_start(actions, False, False, 0)
        self.form = self._build_form()
        box.pack_start(self.form, False, False, 0)
        self.issue_label = Gtk.Label(xalign=0, wrap=True, selectable=True)
        box.pack_start(self.issue_label, False, False, 0)
        self.status_label = Gtk.Label(xalign=0, wrap=True)
        box.pack_start(self.status_label, False, False, 0)
        footer = Gtk.Box(spacing=8, halign=Gtk.Align.END)
        self.cancel_button = Gtk.Button(label=_message("cancel"))
        self.cancel_button.connect("clicked", self._cancel)
        footer.pack_start(self.cancel_button, False, False, 0)
        self.save_button = Gtk.Button(label=_message("save"))
        self.save_button.connect("clicked", self._save_clicked)
        footer.pack_start(self.save_button, False, False, 0)
        box.pack_start(footer, False, False, 0)

    def _build_form(self):
        grid = Gtk.Grid(column_spacing=12, row_spacing=8)
        self.fields = {}
        for row, key in enumerate(("word", "reading")):
            label = Gtk.Label(label=_message(key), xalign=0)
            entry = Gtk.Entry(hexpand=True)
            entry.get_accessible().set_name(_message(key))
            label.set_mnemonic_widget(entry)
            entry.connect("changed", self._entry_changed, key)
            grid.attach(label, 0, row, 1, 1)
            grid.attach(entry, 1, row, 1, 1)
            self.fields[key] = entry
        label = Gtk.Label(label=_message("hint"), xalign=0, valign=Gtk.Align.START)
        self.hint = Gtk.TextView(wrap_mode=Gtk.WrapMode.WORD_CHAR)
        self.hint.get_accessible().set_name(_message("hint"))
        label.set_mnemonic_widget(self.hint)
        self.hint.get_buffer().connect("changed", self._hint_changed)
        scroller = Gtk.ScrolledWindow(min_content_height=HINT_HEIGHT, hexpand=True)
        scroller.add(self.hint)
        grid.attach(label, 0, 2, 1, 1)
        grid.attach(scroller, 1, 2, 1, 1)
        return grid

    def _issue_text(self, issue):
        return _message(f"validation.{issue.field}.{issue.code}", fallback="validation.unknown")

    def _row_matches_query(self, rows, iterator, _context=None):
        row = rows[iterator]
        return matches_dictionary_query(
            {"word": row[1], "reading": row[2], "hint": row[3]}, self._query,
        )

    def _select_visible_entry(self, entry_id, *, fallback=True):
        selection = self.tree.get_selection()
        rows, iterator = selection.get_selected()
        if iterator is not None and entry_id and rows[iterator][0].lower() == entry_id.lower():
            self.tree.scroll_to_cell(rows.get_path(iterator), None, False, 0, 0)
            return
        selection.unselect_all()
        for row in self.sorted_rows:
            if entry_id and row[0].lower() == entry_id.lower():
                selection.select_iter(row.iter)
                self.tree.scroll_to_cell(row.path, None, False, 0, 0)
                return
        if fallback and len(self.sorted_rows):
            selection.select_path(Gtk.TreePath.new_first())

    def _query_changed(self, entry):
        self._query = entry.get_text()
        self._updating_rows = True
        try:
            self.filtered_rows.refilter()
            self._select_visible_entry(self._selected_id)
        finally:
            self._updating_rows = False
        self._selection_changed(self.tree.get_selection())

    def _reset_sort(self, _button):
        self.sorted_rows.set_sort_column_id(REGISTRATION_ORDER_COLUMN, Gtk.SortType.ASCENDING)

    def _refresh_rows(self, selected_id=None):
        selected_id = selected_id or self._selected_id
        self._updating_rows = True
        try:
            self.rows.clear()
            for index, entry in enumerate(self.model.entries):
                reasons = [self._issue_text(issue) for issue in self.model.issues_for(entry["id"])]
                self.rows.append([
                    entry["id"], entry["word"], entry["reading"], entry["hint"] or "", "\n".join(reasons), index,
                ])
            self._select_visible_entry(selected_id)
        finally:
            self._updating_rows = False
        self._selection_changed(self.tree.get_selection())

    def _selection_changed(self, selection):
        if self._updating_rows:
            return
        rows, iterator = selection.get_selected()
        selected_id = rows[iterator][0] if iterator is not None else None
        if selected_id != self._selected_id:
            self._selected_id = selected_id
            entry = self.model.entry(selected_id) if selected_id else {}
            self._loading_form = True
            try:
                for key, field in self.fields.items():
                    field.set_text(entry.get(key) or "")
                self.hint.get_buffer().set_text(entry.get("hint") or "")
            finally:
                self._loading_form = False
        self._refresh_feedback()

    def _refresh_feedback(self):
        editable = self.model.can_close
        self.tree.set_sensitive(editable)
        self.search_entry.set_sensitive(editable)
        self.reset_sort_button.set_sensitive(editable)
        self.add_button.set_sensitive(editable)
        self.import_button.set_sensitive(editable and not self.model.needs_recovery)
        self.export_button.set_sensitive(editable)
        self.remove_button.set_sensitive(editable and self._selected_id is not None)
        self.form.set_sensitive(editable and self._selected_id is not None)
        self.save_button.set_sensitive(editable and not self.model.needs_recovery)
        self.cancel_button.set_sensitive(editable)
        count = _message("filtered_count", visible=len(self.filtered_rows), total=len(self.rows))
        if self._selected_id and self.tree.get_selection().get_selected()[1] is None:
            count += "\n" + _message("editing_hidden")
        self.filter_label.set_text(count)
        issues = []
        row_numbers = {entry["id"].lower(): index for index, entry in enumerate(self.model.entries, start=1)}
        # The table marks every invalid row; the selected row exposes full reasons
        # without letting many invalid entries make the window taller than the screen.
        selected_issues = self.model.issues_for(self._selected_id) if self._selected_id else ()
        for issue in selected_issues:
            values = {
                "field": _CATALOG.get(issue.field, _message("field_unknown")),
                "reason": self._issue_text(issue),
            }
            row = row_numbers.get(issue.entry_id.lower())
            issues.append(_message("row_issue", row=row, **values) if row else _message("unknown_row_issue", **values))
        self.issue_label.set_text("\n".join(issues))
        if self.model.file_operation:
            status = _message("exchange.working." + self.model.file_operation)
        elif self.model.is_saving:
            status = _message("saving")
        elif self.model.exchange_failure:
            status = _message(
                "exchange.failure." + self.model.exchange_failure, fallback="exchange.failure.importFailed",
            )
        elif self.model.did_export:
            status = _message("export.done_unsaved" if self.model.has_changes else "export.done")
        elif self.model.needs_recovery:
            status = _message("failure.rollback")
        elif self.model.failure_stage:
            status = _CATALOG.get(f"failure.{self.model.failure_stage}", _message("failure.unknown"))
        elif self.model.issues:
            status = _message("invalid", count=len(self.model.issues))
        elif self.model.has_changes:
            status = _message("unsaved")
        else:
            status = _message("unchanged" if self.model.entries else "empty")
        if self.model.needs_recovery and status != _message("failure.rollback"):
            status = _message("failure.rollback") + "\n" + status
        self.status_label.set_text(status)

    def _edit(self, field, value):
        if self._loading_form or self._selected_id is None or not self.model.can_close:
            return
        self.model.update(self._selected_id, **{field: value})
        self._updating_rows = True
        try:
            for row in self.rows:
                if row[0] == self._selected_id:
                    entry = self.model.entry(self._selected_id)
                    self.rows.set(row.iter, [1, 2, 3, 4], [entry["word"], entry["reading"], entry["hint"] or "", ""])
                    break
            # Filtering or sorting may move the row during a keystroke. Keep the
            # form bound to its UUID until the user explicitly selects another.
            self._select_visible_entry(self._selected_id, fallback=False)
        finally:
            self._updating_rows = False
        self._refresh_feedback()

    def _entry_changed(self, entry, field):
        self._edit(field, entry.get_text())

    def _hint_changed(self, buffer):
        self._edit("hint", buffer.get_text(buffer.get_start_iter(), buffer.get_end_iter(), True))

    def _add(self, _button):
        if not self.model.can_close:
            return
        self.search_entry.set_text("")
        self._refresh_rows(self.model.add())
        self.fields["word"].grab_focus()

    def _remove(self, _button):
        if not self.model.can_close or self._selected_id is None:
            return
        self.model.remove(self._selected_id)
        self._refresh_rows()

    def _cancel(self, _button=None):
        if not self.model.can_close:
            return
        self.model.discard()
        self.destroy()

    def _request_close(self, _window, _event):
        self._cancel()
        return True

    def _destroyed(self, _window):
        self.closed = True

    def _file_clicked(self, _button, operation):
        if self.closed or not self.model.can_close or (operation == "import" and self.model.needs_recovery):
            return
        failure_code = "importFailed" if operation == "import" else "exportFailed"
        try:
            selection = (
                self._file_dialogs.choose_import() if operation == "import" else self._file_dialogs.choose_export()
            )
        except Exception:
            self.model.exchange_failure = failure_code
            self._refresh_feedback()
            return
        if selection is None:
            return
        request = self.model.begin_file_operation(operation)
        if request is None:
            return
        self._refresh_feedback()

        def work():
            try:
                if operation == "import":
                    preview = self._exchange_service.preview(
                        selection["path"], format_name=selection["format_name"],
                        encoding=selection["encoding"], entries=request.snapshot(),
                    )
                    outcome = DictionaryFileOutcome(preview=preview)
                elif self._exchange_service.export(request.snapshot(), destination=selection) is None:
                    outcome = DictionaryFileOutcome(exported=True)
                else:
                    outcome = DictionaryFileOutcome(failure_code=failure_code)
            except DictionaryExchangeError as error:
                outcome = DictionaryFileOutcome(failure_code=error.code)
            except Exception:
                outcome = DictionaryFileOutcome(failure_code=failure_code)
            GLib.idle_add(self._finish_file, request, outcome)

        try:
            threading.Thread(target=work, name="azookey-dictionary-" + operation, daemon=False).start()
        except RuntimeError:
            self._finish_file(request, DictionaryFileOutcome(failure_code=failure_code))

    def _finish_file(self, request, outcome):
        if self.closed or not self.model.finish_file_operation(request, outcome):
            return GLib.SOURCE_REMOVE
        self._refresh_feedback()
        preview = self.model.import_preview
        if preview is None:
            return GLib.SOURCE_REMOVE
        selected_id = None
        try:
            confirmed = self._file_dialogs.confirm_import(preview)
        except Exception:
            self.model.cancel_import()
            self.model.exchange_failure = "importFailed"
        else:
            if confirmed and preview.count("addition"):
                if self.model.apply_import():
                    selected_id = preview.entries_after_import[len(preview.original_entries)].id
                    self.search_entry.set_text("")
            else:
                self.model.cancel_import()
        self._refresh_rows(selected_id)
        return GLib.SOURCE_REMOVE

    def _save_clicked(self, _button):
        if self.closed:
            return
        request = self.model.begin_save()
        if request is None:
            return
        self._refresh_feedback()

        def work():
            outcome = save_dictionary(request, validate=self._validate, save=self._save)
            GLib.idle_add(self._finish_save, request, outcome)

        try:
            # An explicit save transaction must finish even if the parent window exits.
            threading.Thread(target=work, name="azookey-dictionary-save", daemon=False).start()
        except RuntimeError:
            self._finish_save(request, DictionarySaveOutcome(failure_stage="unknown"))

    def _finish_save(self, request, outcome):
        if self.closed or not self.model.finish_save(request, outcome):
            return GLib.SOURCE_REMOVE
        if outcome.saved:
            try:
                if self._on_saved is not None:
                    self._on_saved(request.snapshot())
            except Exception:
                self._refresh_feedback()
                self.status_label.set_text(_message("saved_refresh_failed"))
                return GLib.SOURCE_REMOVE
            self.destroy()
        else:
            selected_id = outcome.issues[0].entry_id if outcome.issues else None
            if outcome.issues:
                self.search_entry.set_text("")
            self._refresh_rows(selected_id)
        return GLib.SOURCE_REMOVE
