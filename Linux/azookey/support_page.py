"""Read-only setup guidance and Core's allowlisted diagnostic report."""
import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, Gio, GLib, Gtk

from .i18n import text as message
from .support_diagnostics import support_environment

GUIDE_URL = "https://github.com/aida0710/azooKey-Desktop/blob/main/docs/setup-and-recovery.md"
RELEASES_URL = "https://github.com/aida0710/azooKey-Desktop/releases"
ISSUES_URL = "https://github.com/aida0710/azooKey-Desktop/issues/new"
UPSTREAM_URL = "https://github.com/azooKey/azooKey-Desktop"
# This settings-only query must not leave an unresponsive engine blocking the UI.
STATUS_QUERY_TIMEOUT_MS = 300
# Keep about ten report lines visible while leaving space for copy controls.
REPORT_MINIMUM_HEIGHT = 190
# The Linux settings window is Japanese.
REPORT_LANGUAGE = "ja"


def renderer_registered():
    """The engine's RendererStatus, or None when no engine answers."""
    try:
        reply = Gio.bus_get_sync(Gio.BusType.SESSION, None).call_sync(
            "org.azookey.Tree", "/org/azookey/Tree", "org.azookey.Tree", "RendererStatus",
            None, GLib.VariantType.new("(b)"), Gio.DBusCallFlags.NO_AUTO_START,
            STATUS_QUERY_TIMEOUT_MS, None,
        )
        return reply.unpack()[0]
    except GLib.Error:
        return None


class SupportPage(Gtk.Box):
    def __init__(self, settings, bridge):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        self.settings = settings
        self.bridge = bridge
        for key in ("support.setup.linux", "support.recovery"):
            self.pack_start(Gtk.Label(label=message(key), xalign=0, wrap=True), False, False, 0)
        for key, url in (("support.guide", GUIDE_URL), ("support.releases", RELEASES_URL),
                         ("support.issues", ISSUES_URL), ("support.upstream", UPSTREAM_URL)):
            self.pack_start(Gtk.LinkButton.new_with_label(url, message(key)), False, False, 0)
        self.report = Gtk.TextView(editable=False, cursor_visible=False, wrap_mode=Gtk.WrapMode.WORD_CHAR)
        self.report.get_accessible().set_name(message("support.title"))
        scroll = Gtk.ScrolledWindow()
        scroll.set_min_content_height(REPORT_MINIMUM_HEIGHT)
        scroll.add(self.report)
        self.pack_start(scroll, True, True, 0)
        self.pack_start(Gtk.Label(label=message("support.privacy"), xalign=0, wrap=True), False, False, 0)
        actions = Gtk.Box(spacing=8)
        refresh = Gtk.Button(label=message("support.refresh"))
        refresh.connect("clicked", lambda _: self.refresh())
        copy = Gtk.Button(label=message("support.copy"))
        copy.connect("clicked", self.copy)
        actions.pack_start(refresh, False, False, 0)
        actions.pack_start(copy, False, False, 0)
        self.pack_start(actions, False, False, 0)
        self.notice = Gtk.Label(xalign=0)
        self.pack_start(self.notice, False, False, 0)
        self.refresh()

    def refresh(self):
        environment = support_environment(tree_enabled=self.settings().get("tree", True),
                                          renderer_registered=renderer_registered())
        reply = self.bridge.request("support-diagnostics", supportEnvironment=environment, language=REPORT_LANGUAGE)
        self.report_text = reply["supportDiagnostics"]
        self.report.get_buffer().set_text(self.report_text)
        self.notice.set_text("")

    def copy(self, _button):
        self.refresh()
        Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD).set_text(self.report_text, -1)
        self.notice.set_text(message("support.copied"))
