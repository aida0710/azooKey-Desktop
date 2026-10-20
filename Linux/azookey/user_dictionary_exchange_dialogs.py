"""GTK file choosers and the read-only dictionary import confirmation."""

import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, Pango

from .user_dictionary_exchange_service import IMPORT_ENCODINGS, IMPORT_FORMATS


# Keep confirmation controls visible while long comments remain scrollable.
PREVIEW_WIDTH = 900
PREVIEW_HEIGHT = 500
PREVIEW_LIST_HEIGHT = 200
PREVIEW_DETAILS_HEIGHT = 100


class UserDictionaryFileDialogs:
    def __init__(self, parent, *, message):
        self._parent = parent
        self._message = message

    def _chooser(self, *, title, action, accept):
        dialog = Gtk.FileChooserDialog(
            title=self._message(title), transient_for=self._parent, action=action, modal=True,
        )
        dialog.set_local_only(True)
        dialog.add_button(self._message("cancel"), Gtk.ResponseType.CANCEL)
        dialog.add_button(self._message(accept), Gtk.ResponseType.ACCEPT)
        return dialog

    def _options(self):
        grid = Gtk.Grid(column_spacing=12, row_spacing=8, margin=12)
        choices = []
        for row, key, values in ((0, "format", IMPORT_FORMATS), (1, "encoding", IMPORT_ENCODINGS)):
            label = Gtk.Label(label=self._message("import." + key), xalign=0)
            choice = Gtk.ComboBoxText()
            for value in values:
                choice.append(value, self._message(f"import.{key}.{value}"))
            choice.set_active(0)
            choice.get_accessible().set_name(self._message("import." + key))
            label.set_mnemonic_widget(choice)
            grid.attach(label, 0, row, 1, 1)
            grid.attach(choice, 1, row, 1, 1)
            choices.append(choice)
        help_label = Gtk.Label(label=self._message("import.format_help"), xalign=0, wrap=True, max_width_chars=64)
        grid.attach(help_label, 0, 2, 2, 1)
        return grid, choices

    def choose_import(self):
        dialog = self._chooser(title="import.title", action=Gtk.FileChooserAction.OPEN, accept="import.preview")
        options, choices = self._options()
        dialog.set_extra_widget(options)
        options.show_all()
        try:
            if dialog.run() != Gtk.ResponseType.ACCEPT:
                return None
            path = dialog.get_filename()
            if path is None:
                return None
            return {"path": path, "format_name": choices[0].get_active_id(), "encoding": choices[1].get_active_id()}
        finally:
            dialog.destroy()

    def choose_export(self):
        dialog = self._chooser(title="export.title", action=Gtk.FileChooserAction.SAVE, accept="export.write")
        dialog.set_current_name(self._message("export.filename"))
        dialog.set_do_overwrite_confirmation(True)
        try:
            return dialog.get_filename() if dialog.run() == Gtk.ResponseType.ACCEPT else None
        finally:
            dialog.destroy()

    def confirm_import(self, preview):
        dialog = UserDictionaryImportPreviewDialog(preview, parent=self._parent, message=self._message)
        try:
            return dialog.run() == Gtk.ResponseType.APPLY and preview.count("addition") > 0
        finally:
            dialog.destroy()


class UserDictionaryImportPreviewDialog(Gtk.Dialog):
    def __init__(self, preview, *, parent, message):
        super().__init__(
            title=message("import.preview"), transient_for=parent, modal=True, destroy_with_parent=True,
        )
        self.preview = preview
        self._message = message
        self.set_default_size(PREVIEW_WIDTH, PREVIEW_HEIGHT)
        self.add_button(message("cancel"), Gtk.ResponseType.CANCEL)
        self.apply_button = self.add_button(message("import.apply"), Gtk.ResponseType.APPLY)
        self.apply_button.set_sensitive(preview.count("addition") > 0)
        content = self.get_content_area()
        content.set_spacing(12)
        content.set_border_width(16)
        self.counts_label = Gtk.Label(
            label=message(
                "import.counts", additions=preview.count("addition"), duplicates=preview.count("duplicate"),
                conflicts=preview.count("conflict"), excluded=preview.count("excluded"),
            ),
            xalign=0, wrap=True,
        )
        content.pack_start(self.counts_label, False, False, 0)
        for notice in preview.notices:
            content.pack_start(
                Gtk.Label(label=message("import.notice." + notice), xalign=0, wrap=True), False, False, 0,
            )
        content.pack_start(Gtk.Label(label=message("import.draft_help"), xalign=0, wrap=True), False, False, 0)
        self._build_rows(content)
        self.details = Gtk.TextView(editable=False, cursor_visible=False, wrap_mode=Gtk.WrapMode.WORD_CHAR)
        self.details.get_accessible().set_name(message("import.selected_detail"))
        scroller = Gtk.ScrolledWindow(min_content_height=PREVIEW_DETAILS_HEIGHT)
        scroller.add(self.details)
        content.pack_start(scroller, False, False, 0)
        self.show_all()
        if len(self.rows):
            self.tree.get_selection().select_path(Gtk.TreePath.new_first())

    def _build_rows(self, content):
        self.rows = Gtk.ListStore(int, str, str, str, str, str, str)
        for index, row in enumerate(self.preview.rows):
            source = self._message(
                "import.source_line" if row.source_line is not None else "import.source_item",
                number=row.source_line if row.source_line is not None else row.source_index,
            )
            entry = row.entry
            self.rows.append([
                index, source, entry.word if entry else "", entry.reading if entry else "",
                (entry.hint or "") if entry else "", self._message("import.outcome." + row.outcome), self._reason(row),
            ])
        self.tree = Gtk.TreeView(model=self.rows)
        self.tree.get_accessible().set_name(self._message("import.preview"))
        for index, key in enumerate(("import.source", "word", "reading", "hint", "import.outcome", "import.reason"), start=1):
            renderer = Gtk.CellRendererText(ellipsize=Pango.EllipsizeMode.END, single_paragraph_mode=True)
            column = Gtk.TreeViewColumn(self._message(key), renderer, text=index)
            column.set_resizable(True)
            column.set_expand(True)
            self.tree.append_column(column)
        self.tree.get_selection().connect("changed", self._selection_changed)
        scroller = Gtk.ScrolledWindow(min_content_height=PREVIEW_LIST_HEIGHT)
        scroller.add(self.tree)
        content.pack_start(scroller, True, True, 0)

    def _reason(self, row):
        if row.validation_issues:
            return "\n".join(
                self._message(issue.field) + "：" + self._message(
                    f"validation.{issue.field}.{issue.code}", fallback="validation.unknown",
                )
                for issue in row.validation_issues
            )
        return self._message("import.problem." + row.problem) if row.problem else ""

    def _selection_changed(self, selection):
        rows, iterator = selection.get_selected()
        if iterator is None:
            self.details.get_buffer().set_text("")
            return
        row = self.preview.rows[rows[iterator][0]]
        entry = row.entry
        fields = [
            ("word", entry.word if entry else ""), ("reading", entry.reading if entry else ""),
            ("hint", (entry.hint or "") if entry else ""),
        ]
        if row.part_of_speech is not None:
            fields.append(("import.part_of_speech", row.part_of_speech))
        if self._reason(row):
            fields.append(("import.reason", self._reason(row)))
        self.details.get_buffer().set_text("\n".join(self._message(key) + "：" + value for key, value in fields))
