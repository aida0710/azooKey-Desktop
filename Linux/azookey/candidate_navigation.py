"""Full candidate selection, paging and explicit confirmation without taking focus."""
import json

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk, Pango
from .candidate_accessibility import CandidateAction
from .candidate_layout_preferences import DEFAULT_VISIBLE_CANDIDATE_ROWS, visible_candidate_rows
from .i18n import text as message


class CandidateNavigation(Gtk.Box):
    # The nine source number-key candidates scroll instead of extending offscreen.
    MAXIMUM_LIST_HEIGHT = 280
    ROW_SPACING = 3
    ROW_VERTICAL_INSET = 6
    ROW_BORDER_WIDTH = 1
    MINIMUM_CANDIDATE_HEIGHT = 44  # Keep sentence rows and confirmation easy to activate after compacting padding.
    # Menu rows fit more words without changing the live tree or readable type.
    COMPACT_MINIMUM_ROW_HEIGHT = 32
    COMPACT_ROW_VERTICAL_INSET = 2
    COMPACT_ROW_SPACING = 1
    COMPACT_MINIMUM_CONTROL_HEIGHT = 28  # Flat footer actions need less space than candidate words.
    # Composing Enter commits the marked reading, while this button explicitly selects a candidate.
    KEYBOARD_CONFIRM_STATES = frozenset(("selecting", "previewing", "replaceSuggestion"))

    def __init__(self, select, changed, preview, *, keep_preview=None):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        self.set_no_show_all(True)
        self.get_style_context().add_class("candidate-navigation")
        self.palette_css = Gtk.CssProvider()
        Gtk.StyleContext.add_provider_for_screen(
            self.get_screen(), self.palette_css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 1,
        )
        self.connect("destroy", self.destroy_navigation)
        self.select = select
        self.changed = changed
        self.preview = preview
        self.keep_preview = keep_preview
        self.expanded = True
        self.active = False
        self.minimal = False
        self.visible_rows = DEFAULT_VISIBLE_CANDIDATE_ROWS
        self.list_height_limit = self.MAXIMUM_LIST_HEIGHT
        self.expanded_on_update = None
        self.page = {}
        self.token = None
        self.submitted_token = None
        self.controls = {}
        self.row_buttons = []
        self.row_identity = None
        self.hovered_item = None
        self.hovered_button = None
        self.saved_scroll = None
        self.reveal_index = None
        self.scroll_idle = None
        self.header = Gtk.Box(spacing=4, margin_start=8, margin_end=8)
        self.header.set_no_show_all(True)
        self.status = Gtk.Label(xalign=0)
        self.status.set_no_show_all(True)
        self.status.get_style_context().add_class("candidate-secondary")
        self.status.set_ellipsize(Pango.EllipsizeMode.END)
        self.status.set_width_chars(1)
        self.header.pack_start(self.status, True, True, 0)
        self.pack_start(self.header, False, False, 0)
        self.rows = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=self.ROW_SPACING, margin_start=6, margin_end=6)
        self.scroll = Gtk.ScrolledWindow()
        self.scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        self.scroll.set_propagate_natural_height(True)
        self.scroll.add(self.rows)
        self.scroll.set_no_show_all(True)
        self.pack_start(self.scroll, False, False, 0)
        self.footer = Gtk.Box(spacing=6, margin_start=8, margin_end=8)
        self.footer.get_style_context().add_class("candidate-footer")
        self.footer.get_style_context().add_class("candidate-navigation")
        self.hint = Gtk.Label(label=message("candidate.selectHint"), xalign=0, wrap=True)
        self.hint.set_no_show_all(True)
        self.hint.set_line_wrap_mode(Pango.WrapMode.WORD_CHAR)
        self.hint.set_width_chars(1)
        self.hint.get_style_context().add_class("candidate-secondary")
        self.footer.pack_start(self.hint, True, True, 0)
        self.pack_start(self.footer, False, False, 0)

    @staticmethod
    def button(activate):
        button = CandidateAction(activate)
        button.get_style_context().remove_class("candidate-action")
        return button

    def apply_palette(self, palette):
        self.palette_css.load_from_data((
            f".candidate-navigation, .candidate-navigation viewport {{"
            f"background-color: {palette['background']}; color: {palette['text']}; }}"
            f".candidate-navigation button {{ background-image: none; box-shadow: none; transition-property: none;"
            f"background-color: {palette['surface']}; color: {palette['text']};"
            f"border: {self.ROW_BORDER_WIDTH}px solid {palette['border']}; border-radius: 7px; padding: 4px 7px; }}"
            f".candidate-navigation .candidate-row {{ padding: {self.ROW_VERTICAL_INSET}px 7px; border-color: transparent; }}"
            f".candidate-navigation button:disabled {{ opacity: 0.45; }}"
            f".candidate-navigation button:selected, .candidate-navigation .candidate-submit {{"
            f"background-color: {palette['selection']}; color: {palette['selectionText']};"
            f"border-color: {palette['selectionText']}; }}"
            f".candidate-navigation label {{ color: inherit; }}"
            f".candidate-navigation .candidate-secondary {{ color: {palette['secondaryText']}; }}"
            f".candidate-navigation button:selected .candidate-secondary {{ color: {palette['selectionText']}; }}"
            f".candidate-navigation.candidate-minimal .candidate-row {{"
            f"min-height: 0; padding: {self.COMPACT_ROW_VERTICAL_INSET}px 7px; border-radius: 3px; }}"
            f".candidate-navigation.candidate-minimal.candidate-footer button {{"
            f"min-height: 0; min-width: 0; background-color: transparent; border: none;"
            f"border-radius: 0; padding: 1px 4px; color: {palette['secondaryText']}; }}"
            f".candidate-navigation.candidate-minimal.candidate-footer .candidate-submit {{ color: {palette['text']}; }}"
            f".candidate-navigation.candidate-minimal.candidate-footer button:hover {{ color: {palette['text']}; }}"
        ).encode())

    def compact_list_height(self, font_size):
        layout = self.create_pango_layout("あ")
        attributes = Pango.AttrList()
        attributes.insert(Pango.attr_size_new_absolute(round(font_size * Pango.SCALE)))
        layout.set_attributes(attributes)
        row_height = max(self.COMPACT_MINIMUM_ROW_HEIGHT,
                         layout.get_pixel_size()[1] + 2 * (self.COMPACT_ROW_VERTICAL_INSET + self.ROW_BORDER_WIDTH))
        return self.visible_rows * row_height + (self.visible_rows - 1) * self.COMPACT_ROW_SPACING

    def update(self, snapshot, *, font_size, list_height, compact=False, minimal=False):
        if self.expanded_on_update is not None:
            self.expanded = self.expanded_on_update
            self.expanded_on_update = None
        presentation_changed = self.minimal != minimal
        self.minimal = minimal
        for widget in (self, self.footer):
            style = widget.get_style_context()
            if minimal:
                style.add_class("candidate-minimal")
            else:
                style.remove_class("candidate-minimal")
        self.rows.set_spacing(self.COMPACT_ROW_SPACING if minimal else self.ROW_SPACING)
        requested_rows = visible_candidate_rows(snapshot.get("candidateVisibleRows"))
        viewport_changed = minimal and self.visible_rows != requested_rows
        self.visible_rows = requested_rows
        self.active = True
        self.page = snapshot.get("candidatePage", {})
        previous_selection = self.token[2] if self.token else None
        selected_candidate = next((item for item in snapshot.get("candidates") or self.page.get("items", [])
                                   if item.get("index") == snapshot.get("selection")), None)
        self.keyboard_confirms_candidate = snapshot.get("inputState") in self.KEYBOARD_CONFIRM_STATES
        token = (snapshot.get("contextId"), snapshot.get("generation"), snapshot.get("selection"),
                 json.dumps(selected_candidate, sort_keys=True, ensure_ascii=False), snapshot.get("inputState"))
        if token != self.token or not self.controls or presentation_changed:
            self.token = token
            self.replace_controls()
        self.status.set_text(message("candidate.position", position=self.page.get("position") or "—",
                                     total=self.page.get("totalCount", 0)))
        self.toggle.set_label(message("candidate.closeList" if self.expanded else "candidate.openList"))
        self.confirm.set_sensitive(snapshot.get("selection") is not None and self.submitted_token != self.token)
        for button, key in ((self.previous, "previousIndex"), (self.next, "nextIndex")):
            button.set_sensitive(self.page.get(key) is not None)
        items = self.page.get("items", [])
        identity = json.dumps([snapshot.get("contextId"), items, snapshot.get("showCandidateIndex"), font_size, minimal],
                              sort_keys=True, ensure_ascii=False)
        if identity != self.row_identity:
            self.clear_rows()
            self.row_identity = identity
            self.saved_scroll = None
        if self.expanded and not self.row_buttons:
            for item in items:
                number = item["index"] - self.page.get("start", 0) + 1 if snapshot.get("showCandidateIndex") else None
                button = self.candidate_button(item, number=number, font_size=font_size)
                self.rows.pack_start(button, False, False, 0)
                self.row_buttons.append(button)
            if self.saved_scroll is None:
                self.reveal_index = snapshot.get("selection")
        if previous_selection != snapshot.get("selection") or viewport_changed:
            self.reveal_index = snapshot.get("selection")
        for item, button in zip(items, self.row_buttons):
            button.activation_token = self.token
            name = item["text"] + (f'（{item["reading"]}）' if item.get("reading") else "")
            description = message("candidate.select") + "\n" + item.get("detailDescription", item["text"])
            button.update_accessibility(name, selected=item["index"] == snapshot.get("selection"), description=description)
            button.selection_label.set_text(("✓" if minimal else "✓ " + message("candidate.selected")) if button.selected else "")
            if button.selected:
                button.set_state_flags(Gtk.StateFlags.SELECTED, False)
            else:
                button.unset_state_flags(Gtk.StateFlags.SELECTED)
        self.list_height_limit = min(list_height, self.compact_list_height(font_size)) if minimal else list_height
        self.scroll.set_min_content_height(0)
        self.scroll.set_max_content_height(self.list_height_limit)
        self.rows.show_all()
        self.header.show_all()
        self.footer.show_all()
        self.header.set_visible(not minimal)
        self.status.set_visible(not minimal and (not compact or self.expanded))
        self.hint.set_visible(not minimal and (not compact or self.expanded))
        has_pages = self.page.get("previousIndex") is not None or self.page.get("nextIndex") is not None
        self.previous.set_visible(self.expanded and has_pages)
        self.next.set_visible(self.expanded and has_pages)
        self.scroll.set_visible(self.expanded)
        self.set_visible(self.page.get("totalCount", 0) > 0 or snapshot.get("selection") is not None)
        self.schedule_scroll_position()

    def replace_controls(self):
        # An AT client can retain the old button or deliver an action later.
        # A new selection must never inherit that button's confirm action.
        self.retire_controls()
        page_controls = self.footer if self.minimal else self.header
        definitions = (
            ("toggle", "candidate.closeList", self.header),
            ("previous", "candidate.previousPage", page_controls),
            ("next", "candidate.nextPage", page_controls),
            ("confirm", "candidate.submit" if self.keyboard_confirms_candidate else "candidate.submitCandidate", self.footer),
        )
        for name, label, container in definitions:
            button = self.button(lambda source, name=name: self.activate_control(name, source))
            if self.minimal:
                button.set_relief(Gtk.ReliefStyle.NONE)
            button.set_label(message(label) + ("  ↵" if name == "confirm" and self.keyboard_confirms_candidate else ""))
            button.activation_token = self.token
            self.controls[name] = button
            setattr(self, name, button)
            if self.minimal and name == "confirm":
                container.pack_end(button, False, False, 0)
            else:
                container.pack_start(button, False, False, 0)
            if self.minimal and name in ("previous", "next"):
                button.set_no_show_all(True)
                button.set_label("‹" if name == "previous" else "›")
                button.set_size_request(self.COMPACT_MINIMUM_CONTROL_HEIGHT, self.COMPACT_MINIMUM_CONTROL_HEIGHT)
                button.get_accessible().set_name(message(label))
                button.set_tooltip_text(message(label))
        self.confirm.get_style_context().add_class("candidate-submit")
        self.confirm.set_size_request(-1, self.COMPACT_MINIMUM_CONTROL_HEIGHT if self.minimal else self.MINIMUM_CANDIDATE_HEIGHT)
        self.confirm.get_accessible().set_description(message("candidate.confirm"))

    def activate_control(self, name, source):
        if not self.active or self.controls.get(name) is not source:
            return
        if name == "confirm":
            if self.token[2] is None or self.submitted_token == self.token:
                return
            self.submitted_token = self.token
            source.set_sensitive(False)
            self.select("select", self.token[2], True)
        elif name == "toggle":
            self.toggle_list()
        else:
            self.move_page("previousIndex" if name == "previous" else "nextIndex")

    def candidate_button(self, item, *, number, font_size):
        button = self.button(lambda source: self.select_candidate(item, source))
        button.get_style_context().add_class("candidate-row")
        button.set_size_request(-1, self.COMPACT_MINIMUM_ROW_HEIGHT if self.minimal else self.MINIMUM_CANDIDATE_HEIGHT)
        content = Gtk.Box(spacing=7)
        button.number_label = Gtk.Label(label=str(number) if number is not None else "", yalign=0.5)
        button.number_label.get_style_context().add_class("candidate-secondary")
        button.number_label.set_no_show_all(number is None)
        content.pack_start(button.number_label, False, False, 0)
        button.text_label = Gtk.Label(label=item["text"], xalign=0, wrap=True)
        button.text_label.set_line_wrap_mode(Pango.WrapMode.WORD_CHAR)
        button.text_label.set_width_chars(1)
        attributes = Pango.AttrList()
        attributes.insert(Pango.attr_size_new_absolute(round(font_size * Pango.SCALE)))
        button.text_label.set_attributes(attributes)
        content.pack_start(button.text_label, True, True, 0)
        button.selection_label = Gtk.Label()
        button.selection_label.get_style_context().add_class("candidate-secondary")
        content.pack_start(button.selection_label, False, False, 0)
        button.add(content)
        button.set_tooltip_text(item.get("detailDescription", item["text"]))
        button.connect("enter-notify-event", lambda source, _event: self.preview_current(item, source))
        button.connect("leave-notify-event", self.leave_candidate)
        return button

    def leave_candidate(self, source, event):
        if self.keep_preview and self.keep_preview(source, event):
            return False
        return self.clear_preview(source)

    def toggle_list(self):
        self.expanded = not self.expanded
        if not self.expanded:
            self.clear_rows()
        self.changed()

    def move_page(self, key):
        index = self.page.get(key)
        if self.active and self.expanded and index is not None:
            self.select("select", index, False)

    def select_candidate(self, item, source):
        if self.active and self.expanded and source in self.row_buttons:
            self.select("select", item["index"], False)

    def preview_current(self, item, source):
        if self.active and self.expanded and source in self.row_buttons:
            self.hovered_button = source
            self.hovered_item = item
            self.preview(item)
        return False

    def clear_preview(self, source=None):
        if self.hovered_item is not None and (source is None or self.hovered_button is source):
            self.hovered_item = None
            self.hovered_button = None
            self.preview(None)
        return False

    def clear_rows(self):
        self.clear_preview()
        retired = self.row_buttons
        self.row_buttons = []
        for button in retired:
            button.destroy()

    def retire_controls(self):
        retired = list(self.controls.values())
        self.controls.clear()
        for button in retired:
            button.destroy()

    def collapse(self):
        self.expanded = False
        self.clear_rows()
        self.scroll.hide()

    def suspend(self):
        if self.active:
            self.saved_scroll = self.scroll.get_vadjustment().get_value()
        self.active = False
        self.cancel_scroll()
        self.reveal_index = None
        self.clear_rows()
        self.retire_controls()

    def dismiss(self, *, expanded_on_update=True):
        self.suspend()
        self.expanded = False
        self.expanded_on_update = expanded_on_update
        self.page = {}
        self.token = None
        self.row_identity = None
        self.saved_scroll = None
        self.reveal_index = None
        self.submitted_token = None

    def schedule_scroll_position(self):
        if (self.saved_scroll is None and self.reveal_index is None) or self.scroll_idle is not None:
            return
        def position_list():
            self.scroll_idle = None
            if not self.active:
                return GLib.SOURCE_REMOVE
            adjustment = self.scroll.get_vadjustment()
            if self.saved_scroll is not None:
                adjustment.set_value(self.saved_scroll)
            self.saved_scroll = None
            for item, button in zip(self.page.get("items", []), self.row_buttons):
                if item["index"] == self.reveal_index:
                    frame = button.get_allocation()
                    adjustment.clamp_page(frame.y, frame.y + min(frame.height, adjustment.get_page_size()))
                    break
            self.reveal_index = None
            return GLib.SOURCE_REMOVE
        self.scroll_idle = GLib.idle_add(position_list)

    def cancel_scroll(self):
        if self.scroll_idle is not None:
            GLib.source_remove(self.scroll_idle)
            self.scroll_idle = None

    def destroy_navigation(self, *_arguments):
        self.active = False
        self.row_buttons.clear()
        self.controls.clear()
        self.hovered_item = None
        self.hovered_button = None
        self.cancel_scroll()
        Gtk.StyleContext.remove_provider_for_screen(self.get_screen(), self.palette_css)
