import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, Gdk, Pango, PangoCairo


class TreePanel(Gtk.Window):
    """Non-focusable X11 candidate popup. Source indices come from Core."""

    def __init__(self, select):
        super().__init__(type=Gtk.WindowType.POPUP)
        self.set_accept_focus(False)
        self.set_focus_on_map(False)
        self.set_decorated(False)
        self.select = select
        self.snapshot = {}
        self.rectangles = []
        self.scroll = Gtk.ScrolledWindow()
        self.scroll.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        self.add(self.scroll)
        self.canvas = Gtk.DrawingArea()
        self.canvas.add_events(Gdk.EventMask.BUTTON_PRESS_MASK)
        self.canvas.connect("draw", self.draw)
        self.canvas.connect("button-press-event", self.click)
        self.scroll.add(self.canvas)
        self.location = (0, 0, 0, 0)

    def update(self, snapshot):
        self.snapshot = snapshot
        nodes = snapshot.get("nodes", [])
        if not nodes:
            self.hide()
            return
        by_id = {node["id"]: node for node in nodes}
        rows, terminal_rows = {}, {}
        next_row = 0

        def visit(node):
            nonlocal next_row
            first = next_row
            for index in node["terminals"]:
                terminal_rows[index] = next_row
                next_row += 1
            for child in node["children"]:
                visit(by_id[child])
            rows[node["id"]] = (first + max(first, next_row - 1)) / 2

        for node in nodes:
            if node.get("parent") is None:
                visit(node)
        self.rectangles = []
        for node in nodes:
            self.rectangles.append(("node", node["id"], 16 + node["depth"] * 210, 16 + rows[node["id"]] * 64, 150, 48, node["text"], node["reading"]))
            for index in node["terminals"]:
                self.rectangles.append(("select", index, 174 + node["depth"] * 210, 26 + terminal_rows[index] * 64, 30, 28, "↵", ""))
        width = max(240, (max(node["depth"] for node in nodes) + 1) * 210 + 16)
        height = max(80, next_row * 64 + 32)
        self.canvas.set_size_request(width, height)
        self.scroll.set_min_content_width(min(760, width))
        self.scroll.set_min_content_height(min(420, height))
        self.resize(min(760, width), min(420, height))
        self.show_all()
        self.position()
        self.canvas.queue_draw()

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
        context.set_source_rgb(0.97, 0.97, 0.98)
        context.paint()
        frames = {item[1]: item[2:6] for item in self.rectangles if item[0] == "node"}
        selected = set(self.snapshot.get("selectedPath", []))
        for node in self.snapshot.get("nodes", []):
            if node.get("parent") not in frames:
                continue
            x1, y1, width, height = frames[node["parent"]]
            x2, y2, _, h2 = frames[node["id"]]
            start, end = (x1 + width, y1 + height / 2), (x2, y2 + h2 / 2)
            context.set_source_rgb(*( (0.18, 0.38, 0.85) if node["id"] in selected else (0.7, 0.72, 0.78)))
            context.set_line_width(2 if node["id"] in selected else 1)
            middle = (start[0] + end[0]) / 2
            context.move_to(*start)
            context.curve_to(middle, start[1], middle, end[1], *end)
            context.stroke()
        for kind, index, x, y, width, height, text, reading in self.rectangles:
            active = index in selected if kind == "node" else index == self.snapshot.get("selection")
            context.set_source_rgb(*((0.84, 0.9, 1) if active else (1, 1, 1)))
            context.rectangle(x, y, width, height)
            context.fill_preserve()
            context.set_source_rgb(0.22, 0.4, 0.8) if active else context.set_source_rgb(0.8, 0.8, 0.83)
            context.set_line_width(2 if kind == "node" and index == self.snapshot.get("focusedNode") else 1)
            context.stroke()
            self.text(context, text, x + 5, y + 7, width - 10, 13)
            if reading:
                self.text(context, reading, x + 5, y + 29, width - 10, 8)
        return False

    @staticmethod
    def text(context, text, x, y, width, size):
        layout = PangoCairo.create_layout(context)
        layout.set_font_description(Pango.FontDescription(f"Sans {size}"))
        layout.set_width(int(width * Pango.SCALE))
        layout.set_ellipsize(Pango.EllipsizeMode.END)
        layout.set_alignment(Pango.Alignment.CENTER)
        layout.set_text(text, -1)
        context.set_source_rgb(0.1, 0.12, 0.18)
        context.move_to(x, y)
        PangoCairo.show_layout(context, layout)

    def click(self, _widget, event):
        if event.button != 1:
            return False
        for kind, index, x, y, width, height, *_ in reversed(self.rectangles):
            if x <= event.x <= x + width and y <= event.y <= y + height:
                self.select(kind, index, kind == "select" or event.type == Gdk.EventType._2BUTTON_PRESS)
                return True
        return False
