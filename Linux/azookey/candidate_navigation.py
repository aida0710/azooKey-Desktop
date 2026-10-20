"""Bounded full-candidate pages with non-focusing pointer and AT actions."""
import json

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, Pango
from .candidate_accessibility import CandidateAction
from .i18n import text as message


class CandidateNavigation(Gtk.Box):
    # Nine number-key candidates fit in a bounded scrolling list.
    MAXIMUM_LIST_HEIGHT = 240

    def __init__(self, select, changed, preview):
        super().__init__(orientation=Gtk.Orientation.VERTICAL)
        self.set_no_show_all(True)
        self.get_style_context().add_class("candidate-navigation")
        self.palette_css = Gtk.CssProvider()
        Gtk.StyleContext.add_provider_for_screen(
            self.get_screen(), self.palette_css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 1,
        )
        self.connect("destroy", lambda *_: Gtk.StyleContext.remove_provider_for_screen(
            self.get_screen(), self.palette_css,
        ))
        self.select = select
        self.changed = changed
        self.preview = preview
        self.expanded = False
        self.page = {}
        self.token = None
        self.row_buttons = []
        self.row_identity = None
        self.hovered_item = None
        self.hovered_button = None
        self.header = Gtk.Box(spacing=6)
        self.status = Gtk.Label(xalign=0)
        self.status.set_ellipsize(Pango.EllipsizeMode.END)
        self.status.set_width_chars(1)
        self.header.pack_start(self.status, True, True, 0)
        self.toggle = self.button(lambda _button: self.toggle_list())
        self.previous = self.button(lambda _button: self.move_page("previousIndex"))
        self.next = self.button(lambda _button: self.move_page("nextIndex"))
        for button in (self.toggle, self.previous, self.next):
            self.header.pack_start(button, False, False, 0)
        self.pack_start(self.header, False, False, 0)
        self.rows = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.scroll = Gtk.ScrolledWindow()
        self.scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        self.scroll.add(self.rows)
        self.scroll.set_no_show_all(True)
        self.pack_start(self.scroll, False, False, 0)

    @staticmethod
    def button(activate):
        button = CandidateAction(activate)
        button.get_style_context().remove_class("candidate-action")
        return button

    def apply_palette(self, palette):
        # Keep the list in the same contrast mode as the immediately redrawn tree.
        self.palette_css.load_from_data((
            f".candidate-navigation, .candidate-navigation viewport {{"
            f"background-color: {palette['background']}; color: {palette['text']}; }}"
            f".candidate-navigation button {{ background-image: none; box-shadow: none; transition-property: none;"
            f"background-color: {palette['surface']}; color: {palette['text']};"
            f"border: 1px solid {palette['border']}; }}"
            f".candidate-navigation button:selected {{ background-color: {palette['selection']};"
            f"color: {palette['selectionText']}; border-color: {palette['text']}; }}"
            f".candidate-navigation label {{ color: inherit; }}"
        ).encode())

    def update(self, snapshot, *, font_size, list_height):
        self.page = snapshot.get("candidatePage", {})
        self.token = (snapshot.get("contextId"), snapshot.get("generation"), snapshot.get("selection"))
        self.status.set_text(message("candidate.position", position=self.page.get("position") or "—",
                                     total=self.page.get("totalCount", 0)))
        self.toggle.set_label(message("candidate.closeList" if self.expanded else "candidate.openList"))
        for button, key, label in ((self.previous, "previousIndex", "candidate.previousPage"),
                                   (self.next, "nextIndex", "candidate.nextPage")):
            button.set_label(message(label))
            button.set_sensitive(self.page.get(key) is not None)
            button.activation_token = self.token
        items = self.page.get("items", [])
        identity = json.dumps([snapshot.get("contextId"), items, snapshot.get("showCandidateIndex"), font_size],
                              sort_keys=True, ensure_ascii=False)
        if identity != self.row_identity:
            self.row_identity = identity
            self.clear_preview()
            for child in self.rows.get_children():
                child.destroy()
            self.row_buttons = []
            for offset, item in enumerate(items):
                button = self.candidate_button(item, number=offset + 1 if snapshot.get("showCandidateIndex") else None,
                                               font_size=font_size)
                self.rows.pack_start(button, False, False, 0)
                self.row_buttons.append(button)
        for item, button in zip(items, self.row_buttons):
            button.activation_token = self.token
            name = item["text"] + (f'（{item["reading"]}）' if item.get("reading") else "")
            button.update_accessibility(name, selected=item["index"] == snapshot.get("selection"),
                                        description=item.get("detailDescription", message("candidate.confirm")))
            if button.selected:
                button.set_state_flags(Gtk.StateFlags.SELECTED, False)
            else:
                button.unset_state_flags(Gtk.StateFlags.SELECTED)
        self.scroll.set_min_content_height(min(list_height, len(self.row_buttons) * (round(font_size) + 16)))
        self.rows.show_all()
        self.header.show_all()
        self.previous.set_visible(self.expanded)
        self.next.set_visible(self.expanded)
        self.scroll.set_visible(self.expanded)
        self.set_visible(self.page.get("totalCount", 0) > 0)

    def candidate_button(self, item, *, number, font_size):
        button = self.button(lambda source: self.submit(item, source))
        prefix = f"{number}. " if number else ""
        label = Gtk.Label(label=prefix + item["text"], xalign=0)
        label.set_ellipsize(Pango.EllipsizeMode.END)
        label.set_width_chars(1)
        attributes = Pango.AttrList()
        attributes.insert(Pango.attr_size_new_absolute(round(font_size * Pango.SCALE)))
        label.set_attributes(attributes)
        button.add(label)
        button.set_tooltip_text(item.get("detailDescription", item["text"]))
        button.connect("enter-notify-event", lambda source, _event: self.preview_current(item, source))
        button.connect("leave-notify-event", lambda source, _event: self.clear_preview(source))
        return button

    def toggle_list(self):
        self.expanded = not self.expanded
        if not self.expanded:
            self.clear_preview()
        self.changed()

    def move_page(self, key):
        index = self.page.get(key)
        if self.expanded and index is not None:
            self.select("select", index, False)

    def submit(self, item, source):
        if self.expanded and source in self.row_buttons:
            self.select("select", item["index"], True)

    def preview_current(self, item, source):
        if self.expanded and source in self.row_buttons:
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

    def collapse(self):
        self.expanded = False
        self.clear_preview()
        self.scroll.hide()
