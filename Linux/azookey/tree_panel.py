import gi
import cairo
gi.require_version("Gtk", "3.0")
gi.require_version("PangoCairo", "1.0")
from gi.repository import Gtk, Gdk, GLib, Pango, PangoCairo


class TreePanel(Gtk.Window):
    """Non-focusable X11 candidate popup. Source indices come from Core."""

    def __init__(self, select):
        super().__init__(type=Gtk.WindowType.POPUP)
        self.set_accept_focus(False)
        self.set_focus_on_map(False)
        self.set_decorated(False)
        self.set_app_paintable(True)
        visual = self.get_screen().get_rgba_visual()
        if visual:
            self.set_visual(visual)
        self.get_style_context().add_class("azookey-tree")
        css = Gtk.CssProvider()
        css.load_from_data(b".azookey-tree, .azookey-tree scrolledwindow, .azookey-tree viewport { background: transparent; border: none; box-shadow: none; }")
        Gtk.StyleContext.add_provider_for_screen(self.get_screen(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        self.select = select
        self.snapshot = {}
        self.rectangles = []
        self.scroll = Gtk.ScrolledWindow()
        self.scroll.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.NEVER)
        self.add(self.scroll)
        self.canvas = Gtk.DrawingArea()
        self.canvas.add_events(Gdk.EventMask.BUTTON_PRESS_MASK)
        self.canvas.connect("draw", self.draw)
        self.canvas.connect("button-press-event", self.click)
        self.scroll.add(self.canvas)
        self.location = (0, 0, 0, 0)
        self.focus_key = None
        self.scroll_idle = None
        self.connect("destroy", self.cancel_scroll)

    def cancel_scroll(self, *_args):
        if self.scroll_idle:
            GLib.source_remove(self.scroll_idle)
            self.scroll_idle = None

    def update(self, snapshot):
        self.snapshot = snapshot
        nodes = snapshot.get("nodes", [])
        if not nodes:
            self.hide()
            return
        by_id = {node["id"]: node for node in nodes}
        columns = snapshot.get("columns", [])
        if not columns:
            self.hide()
            return
        self.rectangles = []
        x = 12
        for column in columns:
            column_width = 24
            for node_id in column:
                layout = self.canvas.create_pango_layout(by_id[node_id]["text"])
                layout.set_font_description(Pango.FontDescription("Sans 10"))
                column_width = max(column_width, min(160, layout.get_pixel_size()[0] + 12))
            for row, node_id in enumerate(column):
                node = by_id[node_id]
                self.rectangles.append(("node", node_id, x, 6 + row * 30, column_width, 24, node["text"], node["reading"]))
                terminals = node["terminals"]
                index = snapshot.get("selection") if snapshot.get("selection") in terminals else next(iter(terminals), None)
                if snapshot.get("showCandidateIndex") and index is not None:
                    number = index - snapshot.get("pageStart", 0) + 1
                    if 1 <= number <= 9:
                        self.rectangles.append(("select", index, x + column_width + 1, 8 + row * 30, 20, 20, str(number), ""))
            x += column_width + (22 if snapshot.get("showCandidateIndex") else 12)
        width = max(60, x)
        height = max(32, max(map(len, columns)) * 30 + 6)
        self.canvas.set_size_request(width, height)
        monitor = self.get_display().get_monitor_at_point(self.location[0], self.location[1])
        area = monitor.get_workarea() if monitor else self.get_screen().get_monitor_workarea(0)
        popup_width, popup_height = min(760, width, area.width), min(420, height, area.height)
        self.scroll.set_min_content_width(popup_width)
        self.scroll.set_min_content_height(popup_height)
        self.resize(popup_width, popup_height)
        self.show_all()
        self.position()
        self.canvas.queue_draw()
        focus = by_id.get(snapshot.get("focusedNode"))
        key = (snapshot.get("generation"), snapshot.get("selection"), snapshot.get("focusedNode"))
        if focus and key != self.focus_key:
            self.focus_key = key
            self.cancel_scroll()
            def reveal():
                self.scroll_idle = None
                for kind, index, x, _, width, *_ in self.rectangles:
                    if kind == "node" and index == focus["id"]:
                        self.scroll.get_hadjustment().clamp_page(max(0, x - 8), x + width + 22)
                        break
                return GLib.SOURCE_REMOVE
            self.scroll_idle = GLib.idle_add(reveal)

    def position(self):
        x, y, _, height = self.location
        monitor = self.get_display().get_monitor_at_point(x, y)
        area = monitor.get_workarea() if monitor else self.get_screen().get_monitor_workarea(0)
        width, popup_height = self.get_size()
        x = max(area.x, min(x, area.x + area.width - width))
        below = y + height
        y = below if below + popup_height <= area.y + area.height else y - popup_height
        self.move(x, max(area.y, min(y, area.y + area.height - popup_height)))

    def draw(self, widget, context):
        context.set_operator(cairo.OPERATOR_SOURCE)
        context.set_source_rgba(0, 0, 0, 0)
        context.paint()
        context.set_operator(cairo.OPERATOR_OVER)
        frames = {item[1]: item[2:6] for item in self.rectangles if item[0] == "node"}
        selected = set(self.snapshot.get("selectedPath", []))
        for node in self.snapshot.get("nodes", []):
            if node["id"] not in frames:
                continue
            x1, y1, width, height = frames.get(node.get("parent"), (4, 18, 0, 0))
            x2, y2, _, h2 = frames[node["id"]]
            start, end = (x1 + width, y1 + height / 2), (x2, y2 + h2 / 2)
            context.set_source_rgba(*((0.25, 0.45, 0.8, 1) if node["id"] in selected else (0.5, 0.5, 0.55, 0.55)))
            context.set_line_width(2 if node["id"] in selected else 0.75)
            middle = (start[0] + end[0]) / 2
            context.move_to(*start)
            context.curve_to(middle, start[1], middle, end[1], *end)
            context.stroke()
        context.set_source_rgb(0.5, 0.5, 0.55)
        context.arc(4, 18, 3, 0, 6.2832)
        context.fill()
        foreground = self.get_style_context().get_color(Gtk.StateFlags.NORMAL)
        found, base = self.get_style_context().lookup_color("theme_base_color")
        background = (base.red, base.green, base.blue) if found else (0.97, 0.97, 0.98)
        for kind, index, x, y, width, height, text, reading in self.rectangles:
            active = index in selected if kind == "node" else index == self.snapshot.get("selection")
            context.set_source_rgba(*((0.25, 0.45, 0.8, 1) if active else (*background, 0.5)))
            radius = 4
            context.new_sub_path()
            for cx, cy, start in ((x + width - radius, y + radius, -1.5708), (x + width - radius, y + height - radius, 0),
                                  (x + radius, y + height - radius, 1.5708), (x + radius, y + radius, 3.1416)):
                context.arc(cx, cy, radius, start, start + 1.5708)
            context.close_path()
            context.fill()
            if kind == "node" and index == self.snapshot.get("focusedNode"):
                context.set_source_rgba(1, 1, 1, 0.9)
                context.set_line_width(1.5)
                context.move_to(x + 6, y + height - 4)
                context.line_to(x + width - 6, y + height - 4)
                context.stroke()
            color = (1, 1, 1) if active else (foreground.red, foreground.green, foreground.blue)
            self.text(context, text, x + 4, y + 4, width - 8, 10 if kind == "node" else 9, color)
        return False

    @staticmethod
    def text(context, text, x, y, width, size, color):
        layout = PangoCairo.create_layout(context)
        layout.set_font_description(Pango.FontDescription(f"Sans {size}"))
        layout.set_width(int(width * Pango.SCALE))
        layout.set_ellipsize(Pango.EllipsizeMode.END)
        layout.set_alignment(Pango.Alignment.CENTER)
        layout.set_text(text, -1)
        context.set_source_rgb(*color)
        context.move_to(x, y)
        PangoCairo.show_layout(context, layout)

    def click(self, _widget, event):
        if event.button != 1:
            return False
        for kind, index, x, y, width, height, *_ in reversed(self.rectangles):
            if x <= event.x <= x + width and y <= event.y <= y + height:
                self.select(kind, index, True)
                return True
        return False
