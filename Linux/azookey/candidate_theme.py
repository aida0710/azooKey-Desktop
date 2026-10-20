"""Follow the desktop appearance without rebuilding candidate identities."""

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gio

from .candidate_palette_data import PALETTES


def appearance_name(*, color_scheme, theme_name, prefer_dark, high_contrast, dark_background):
    theme = theme_name.lower()
    contrast = high_contrast or "highcontrast" in theme.replace("-", "")
    if color_scheme in ("prefer-dark", "prefer-light"):
        dark = color_scheme == "prefer-dark"
    else:
        dark = prefer_dark or "dark" in theme or "inverse" in theme or dark_background
    return ("highContrastDark" if dark else "highContrastLight") if contrast else ("dark" if dark else "light")


def score_role(score):
    # Preserve the existing relative-score threshold; an unevaluated node is neutral.
    if score is None:
        return "scoreUnknown"
    return "scoreLow" if score < 75 else "scoreHigh"


class CandidateTheme:
    def __init__(self, widget, *, changed):
        self.widget = widget
        self.changed = changed
        self.settings = widget.get_settings()
        self.interface = self.desktop_settings("org.gnome.desktop.interface")
        self.accessibility = self.desktop_settings("org.gnome.desktop.a11y.interface")
        self.connections = []
        self.mode = None
        self.observe(self.settings, "notify::gtk-theme-name")
        self.observe(self.settings, "notify::gtk-application-prefer-dark-theme")
        self.observe(widget, "style-updated")
        if self.interface:
            self.observe(self.interface, "changed::color-scheme")
        if self.accessibility:
            self.observe(self.accessibility, "changed::high-contrast")
        widget.connect("destroy", self.destroy)
        self.refresh(notify=False)

    @staticmethod
    def desktop_settings(schema_id):
        source = Gio.SettingsSchemaSource.get_default()
        schema = source.lookup(schema_id, True) if source else None
        return Gio.Settings.new_full(schema, None, None) if schema else None

    def observe(self, source, signal):
        self.connections.append((source, source.connect(signal, lambda *_: self.refresh())))

    def refresh(self, *, notify=True):
        found, base = self.widget.get_style_context().lookup_color("theme_base_color")
        mode = appearance_name(
            color_scheme=self.interface.get_string("color-scheme") if self.interface else "default",
            theme_name=self.settings.get_property("gtk-theme-name"),
            prefer_dark=self.settings.get_property("gtk-application-prefer-dark-theme"),
            high_contrast=self.accessibility.get_boolean("high-contrast") if self.accessibility else False,
            dark_background=found and (base.red + base.green + base.blue) < 1.5,
        )
        if mode == self.mode:
            return
        self.mode = mode
        self.palette = PALETTES[mode]
        self.colors = {role: tuple(int(color[index:index + 2], 16) / 255 for index in (1, 3, 5))
                       for role, color in self.palette.items()}
        if notify:
            self.changed()

    @property
    def high_contrast(self):
        return self.mode.startswith("highContrast")

    def rgb(self, role):
        return self.colors[role]

    def destroy(self, *_arguments):
        for source, connection in self.connections:
            source.disconnect(connection)
        self.connections.clear()
