import gi
import cairo
import json
gi.require_version("Gtk", "3.0")
gi.require_version("PangoCairo", "1.0")
from gi.repository import Gtk, Gdk, GLib, Pango, PangoCairo

from .candidate_accessibility import CandidateAction
from .candidate_detail import CandidateDetail
from .i18n import text as message


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
        css.load_from_data(b"""
            .azookey-tree, .azookey-tree scrolledwindow, .azookey-tree viewport {
                background: transparent; border: none; box-shadow: none;
            }
            .azookey-tree .candidate-action {
                background: transparent; border: none; box-shadow: none;
                padding: 0; min-width: 0; min-height: 0;
            }
            .azookey-tree .candidate-detail, .azookey-tree .candidate-detail viewport {
                background: @theme_base_color; border: none;
            }
        """)
        Gtk.StyleContext.add_provider_for_screen(self.get_screen(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        self.select = select
        self.snapshot = {}
        self.candidate_identity = None
        self.rectangles = []
        self.scroll = Gtk.ScrolledWindow()
        self.scroll.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        self.content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.content.pack_start(self.scroll, True, True, 0)
        self.details = CandidateDetail()
        self.content.pack_start(self.details, False, False, 0)
        self.add(self.content)
        self.canvas = Gtk.DrawingArea()
        self.canvas.add_events(Gdk.EventMask.BUTTON_PRESS_MASK)
        self.canvas.connect("draw", self.draw)
        self.canvas.connect("button-press-event", self.click)
        self.canvas.set_has_tooltip(True)
        self.canvas.connect("query-tooltip", self.tooltip)
        self.surface = Gtk.Fixed()
        self.surface.put(self.canvas, 0, 0)
        self.scroll.add(self.surface)
        self.actions = {}
        self.location = (0, 0, 0, 0)
        self.focus_key = None
        self.scroll_idle = None
        self.connect("destroy", self.cancel_scroll)

    def cancel_scroll(self, *_args):
        if self.scroll_idle:
            GLib.source_remove(self.scroll_idle)
            self.scroll_idle = None

    def update(self, snapshot):
        identity = json.dumps([
            snapshot.get("contextId"), snapshot.get("reading"), snapshot.get("candidates", []),
            [{key: value for key, value in node.items() if key != "relativeScore"}
             for node in snapshot.get("nodes", [])],
        ], sort_keys=True, ensure_ascii=False)
        if identity != self.candidate_identity:
            self.clear_actions()
            self.candidate_identity = identity
        self.snapshot = snapshot
        nodes = snapshot.get("nodes", [])
        if not nodes:
            self.clear_actions()
            self.hide()
            return
        by_id = {node["id"]: node for node in nodes}
        columns = snapshot.get("columns", [])
        if not columns:
            self.clear_actions()
            self.hide()
            return
        self.rectangles = []
        geometry = snapshot.get("wordGeometry") or {}
        widths = geometry.get("widths", [])
        # Logical pixels are scaled by GTK; do not copy AppKit point measurements.
        base_size = 24 if snapshot.get("candidateTextSize") == "large" else 18
        scale = self.get_settings().get_property("gtk-xft-dpi") / (96 * Pango.SCALE)
        self.font_size = base_size * max(1, scale)
        row_height = int(self.font_size + 14)
        minimum_width = row_height if snapshot.get("showCandidateIndex") else self.font_size + 8
        aligned = len(widths) == len(columns) and all(w >= minimum_width for w in widths)
        self.aligned = aligned
        # The number sits below the score; its height must grow with the font.
        row_pitch = row_height + (row_height + 20 if snapshot.get("showCandidateIndex") and aligned else 20)
        x = 12
        for depth, column in enumerate(columns):
            # Other candidates may cover the entire sentence. They must never
            # change the chosen word's position or cover the following column.
            column_width = widths[depth] if aligned else max(self.font_size + 12, min(
                240, self.measure(by_id[column[0]]["text"], font_size=self.font_size) + 12))
            for row, node_id in enumerate(column):
                node = by_id[node_id]
                self.rectangles.append(("node", node_id, x, 6 + row * row_pitch, column_width, row_height, node["text"], node["reading"]))
                terminals = node["terminals"]
                index = snapshot.get("selection") if snapshot.get("selection") in terminals else next(iter(terminals), None)
                if snapshot.get("showCandidateIndex") and index is not None:
                    number = index - snapshot.get("pageStart", 0) + 1
                    if 1 <= number <= 9:
                        badge = (x + column_width - row_height, 22 + row * row_pitch + row_height, row_height, row_height) if aligned else (x + column_width + 1, 6 + row * row_pitch, row_height, row_height)
                        self.rectangles.append(("select", index, *badge, str(number), ""))
            x += column_width + (0 if aligned else (row_height + 2 if snapshot.get("showCandidateIndex") else 12))
        width = max(60, x)
        height = max(32, max(map(len, columns)) * row_pitch + 6)
        self.canvas.set_size_request(int(width + 0.5), height)
        self.surface.set_size_request(int(width + 0.5), height)
        monitor = self.get_display().get_monitor_at_point(self.location[0], self.location[1])
        area = monitor.get_workarea() if monitor else self.get_screen().get_monitor_workarea(0)
        if aligned and (self.location[0] - 12 < area.x or self.location[0] - 12 + width > area.x + area.width):
            # Clamping or scrolling would invalidate the document coordinates.
            # Use the ordinary compact popup when the span cannot fit onscreen.
            self.update({**snapshot, "wordGeometry": None})
            return
        # Keep a useful detail line below even for a one-character candidate.
        popup_width = int(min(max(320, width), 760 if not aligned else max(320, width), area.width) + 0.5)
        popup_height = min(420, height, max(1, area.height - CandidateDetail.MAXIMUM_HEIGHT))
        self.scroll.set_min_content_width(popup_width)
        self.scroll.set_min_content_height(popup_height)
        self.resize(popup_width, popup_height)
        self.update_actions()
        self.show_details(snapshot.get("focusedNode") if snapshot.get("focusedNode") is not None else columns[0][0])
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
                for kind, index, x, y, width, height, *_ in self.rectangles:
                    if kind == "node" and index == focus["id"]:
                        self.scroll.get_hadjustment().clamp_page(max(0, x - 8), x + width + 22)
                        self.scroll.get_vadjustment().clamp_page(max(0, y - 8), y + height + 16)
                        break
                return GLib.SOURCE_REMOVE
            self.scroll_idle = GLib.idle_add(reveal)

    def clear_actions(self):
        for button in self.actions.values():
            button.destroy()
        self.actions.clear()

    def update_actions(self):
        visible = {(item[0], item[1]) for item in self.rectangles}
        for identity in list(self.actions):
            if identity not in visible:
                self.actions.pop(identity).destroy()
        selected = set(self.snapshot.get("selectedPath", []))
        for kind, index, x, y, width, height, text, reading in self.rectangles:
            identity = (kind, index)
            button = self.actions.get(identity)
            if button is None:
                button = CandidateAction(lambda source, identity=identity: self.activate(identity, source))
                if kind == "node":
                    button.connect("enter-notify-event", lambda _button, _event, index=index: self.show_details(index))
                self.surface.put(button, int(x), int(y))
                self.actions[identity] = button
            self.surface.move(button, int(x), int(y))
            button.activation_token = (self.snapshot.get("contextId"), self.snapshot.get("generation"),
                                       self.snapshot.get("selection"))
            button.set_size_request(max(1, int(width)), max(1, int(height)))
            name = text if not reading else message("candidate.withReading", text=text, reading=reading)
            active = index in selected if kind == "node" else index == self.snapshot.get("selection")
            description = message("candidate.focusedConfirm" if kind == "node" and index == self.snapshot.get("focusedNode")
                                  else "candidate.confirm")
            if kind == "select":
                name = message("candidate.numberConfirm", number=index + 1)
            button.set_tooltip_text(name)
            button.update_accessibility(name, selected=active, description=description)

    def show_details(self, node_id):
        node = next((item for item in self.snapshot.get("nodes", []) if item["id"] == node_id), None)
        if node is None:
            self.details.update("", font_size=self.font_size, width=320)
            return False
        content = node["text"] + ("\n" + node["reading"] if node.get("reading") else "")
        width = self.scroll.get_min_content_width()
        self.details.update(content + "\n" + message("candidate.detailKeys"), font_size=self.font_size, width=width)
        return False

    def scroll_details(self, forward):
        if not self.get_visible():
            return False
        self.details.scroll_page(forward)
        return True

    def activate(self, identity, source):
        # Removed ATK objects may outlive a candidate update in the AT client.
        if self.get_visible() and self.actions.get(identity) is source:
            self.select(*identity, True)

    def position(self):
        x, y, _, height = self.location
        if getattr(self, "aligned", False):
            x -= 12
        monitor = self.get_display().get_monitor_at_point(x, y)
        area = monitor.get_workarea() if monitor else self.get_screen().get_monitor_workarea(0)
        width, popup_height = self.get_size()
        x = max(area.x, min(x, area.x + area.width - width))
        below = y + height
        y = below if below + popup_height <= area.y + area.height else y - popup_height
        self.move(x, max(area.y, min(y, area.y + area.height - popup_height)))

    def measure(self, text, *, font_size=None):
        # PreeditAnchor calibrates this reference font against the document caret.
        # Candidate preferences must not change that measurement mid-composition.
        document_reference_size = 40 / 3
        layout = self.canvas.create_pango_layout(text)
        font = Pango.FontDescription("Sans")
        font.set_absolute_size((font_size or document_reference_size) * Pango.SCALE)
        layout.set_font_description(font)
        return layout.get_pixel_size()[0]

    def draw(self, widget, context):
        context.set_operator(cairo.OPERATOR_SOURCE)
        context.set_source_rgba(0, 0, 0, 0)
        context.paint()
        context.set_operator(cairo.OPERATOR_OVER)
        foreground = self.get_style_context().get_color(Gtk.StateFlags.NORMAL)
        found, base = self.get_style_context().lookup_color("theme_base_color")
        background = (base.red, base.green, base.blue) if found else (0.97, 0.97, 0.98)
        canvas_width, canvas_height = self.canvas.get_size_request()
        context.set_source_rgb(*background)
        context.new_sub_path()
        for cx, cy, start in ((canvas_width - 6, 6, -1.5708), (canvas_width - 6, canvas_height - 6, 0),
                              (6, canvas_height - 6, 1.5708), (6, 6, 3.1416)):
            context.arc(cx, cy, 6, start, start + 1.5708)
        context.close_path()
        context.fill()
        frames = {item[1]: item[2:6] for item in self.rectangles if item[0] == "node"}
        selected = set(self.snapshot.get("selectedPath", []))
        scores = {node["id"]: node.get("relativeScore") for node in self.snapshot.get("nodes", [])}
        for node in self.snapshot.get("nodes", []):
            if node["id"] not in frames:
                continue
            x1, y1, width, height = frames.get(node.get("parent"), (4, 18, 0, 0))
            x2, y2, _, h2 = frames[node["id"]]
            start, end = (x1 + width, y1 + height / 2), (x2, y2 + h2 / 2)
            context.set_source_rgba(*(self.score_color(scores.get(node["id"])) if node["id"] in selected else (0.5, 0.5, 0.55, 0.55)))
            context.set_line_width(2 if node["id"] in selected else 0.75)
            middle = (start[0] + end[0]) / 2
            context.move_to(*start)
            context.curve_to(middle, start[1], middle, end[1], *end)
            context.stroke()
        context.set_source_rgb(0.5, 0.5, 0.55)
        context.arc(4, 18, 3, 0, 6.2832)
        context.fill()
        for kind, index, x, y, width, height, text, reading in self.rectangles:
            active = index in selected if kind == "node" else index == self.snapshot.get("selection")
            context.set_source_rgba(*(self.score_color(scores.get(index)) if active else (*background, 1)))
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
            inset = 2 if self.aligned else 4
            size = self.font_size if kind == "node" else max(14, self.font_size - 4)
            self.text(context, text, x + inset, y, width - inset * 2, size, color, self.aligned, height)
            if kind == "node":
                score = scores.get(index)
                self.text(context, str(score) if score is not None else "—",
                          x, y + height, width, 12, (foreground.red, foreground.green, foreground.blue),
                          False, 16)
        return False

    @staticmethod
    def score_color(score):
        return (0.83, 0.39, 0.06, 1) if score is not None and score < 75 else (0.25, 0.45, 0.8, 1)

    @staticmethod
    def fitted_layout(context, text, width, size):
        layout = PangoCairo.create_layout(context)
        font = Pango.FontDescription("Sans")
        layout.set_text(text, -1)
        font.set_absolute_size(size * Pango.SCALE)
        layout.set_font_description(font)
        layout.set_width(max(1, int(width * Pango.SCALE)))
        layout.set_ellipsize(Pango.EllipsizeMode.END)
        return layout

    @staticmethod
    def text(context, text, x, y, width, size, color, aligned=False, height=24):
        layout = TreePanel.fitted_layout(context, text, width, size)
        layout.set_alignment(Pango.Alignment.LEFT if aligned else Pango.Alignment.CENTER)
        context.set_source_rgb(*color)
        context.move_to(x, y + (height - layout.get_pixel_size()[1]) / 2)
        PangoCairo.show_layout(context, layout)

    def tooltip(self, _widget, x, y, _keyboard_mode, tooltip):
        nodes = {node["id"]: node for node in self.snapshot.get("nodes", [])}
        for kind, index, left, top, width, height, text, reading in self.rectangles:
            if kind == "node" and left <= x <= left + width and top <= y <= top + height + 12:
                score = nodes[index].get("relativeScore")
                detail = f"相対スコア {score}（取得候補内の評価。正解の確率ではありません）" if score is not None else "比較可能なスコアなし"
                tooltip.set_text(f"{text}（{reading}）\n{detail}")
                return True
        return False

    def click(self, _widget, event):
        if not self.get_visible() or event.button != 1:
            return False
        for kind, index, x, y, width, height, *_ in reversed(self.rectangles):
            if x <= event.x <= x + width and y <= event.y <= y + height:
                self.select(kind, index, True)
                return True
        return False
