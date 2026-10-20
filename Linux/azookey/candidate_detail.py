"""Scrollable full candidate text without stealing the document's focus."""

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, Pango

from .i18n import text as message


class CandidateDetail(Gtk.ScrolledWindow):
    # Keeps the tree and the source document visible beside long dictionary entries.
    MAXIMUM_HEIGHT = 160

    def __init__(self):
        super().__init__()
        self.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        self.set_can_focus(False)
        self.get_style_context().add_class("candidate-detail")
        self.set_min_content_height(80)
        self.set_max_content_height(self.MAXIMUM_HEIGHT)
        self.set_propagate_natural_height(True)
        self.label = Gtk.Label(xalign=0, yalign=0, wrap=True, margin=8)
        self.label.set_line_wrap_mode(Pango.WrapMode.WORD_CHAR)
        self.label.set_selectable(False)
        self.label.get_accessible().set_name(message("candidate.detail"))
        self.add(self.label)
        self.displayed_text = ""
        self.palette_css = Gtk.CssProvider()
        for widget in (self, self.get_child(), self.label):
            widget.get_style_context().add_provider(self.palette_css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 1)

    def apply_palette(self, palette):
        # A wildcard background also paints GTK's undershoot nodes on top of
        # the scrolled text. Color only the viewport and its actual label.
        self.palette_css.load_from_data((
            f"scrolledwindow.candidate-detail, viewport {{ background-color: {palette['background']}; border: none; }}"
            f"label {{ color: {palette['text']}; }}"
        ).encode())

    def update(self, text, *, font_size, width):
        attributes = Pango.AttrList()
        attributes.insert(Pango.attr_size_new_absolute(int(font_size * Pango.SCALE)))
        self.label.set_attributes(attributes)
        self.label.set_size_request(max(1, width - 16), -1)
        self.label.set_text(text)
        if text != self.displayed_text:
            self.displayed_text = text
            self.get_vadjustment().set_value(0)

    def scroll_page(self, forward):
        adjustment = self.get_vadjustment()
        step = max(1, adjustment.get_page_size() - 16)
        limit = max(0, adjustment.get_upper() - adjustment.get_page_size())
        adjustment.set_value(max(0, min(limit, adjustment.get_value() + (step if forward else -step))))
