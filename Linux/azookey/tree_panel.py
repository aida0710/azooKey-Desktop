import gi
import cairo
import json
gi.require_version("Gtk", "3.0")
gi.require_version("Atk", "1.0")
gi.require_version("PangoCairo", "1.0")
from gi.repository import Atk, Gtk, Gdk, GLib, Pango, PangoCairo

from .candidate_accessibility import CandidateAction
from .candidate_announcements import CandidateAnnouncements
from .candidate_detail import CandidateDetail
from .candidate_navigation import CandidateNavigation
from .candidate_theme import CandidateTheme
from .candidate_score import SCORE_LINE_HEIGHT, draw_score_badge, score_presentation
from .i18n import text as message


CANDIDATE_ROW_GAP = 4  # Separate actions even when the score line is hidden.
MINIMUM_POPUP_WIDTH = 420  # Leave room for readable sentences and a separate confirm action.
COMPOSITION_MAXIMUM_HEIGHT = 132  # Fits three large-text lines before scrolling.
REMAINING_MAXIMUM_HEIGHT = 72  # Keep the unconsumed reading beside the commit preview.
TREE_MAXIMUM_HEIGHT = 240  # The optional tree shares the work area with the primary list.
PRIMARY_LIST_HEIGHT_SHARE = 3  # Prioritize sentences when several scrollable panes are open.
SUPPLEMENT_HEIGHT_SHARE = 2  # The tree and details each receive less room than the list.


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
        """)
        Gtk.StyleContext.add_provider_for_screen(self.get_screen(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        self.select = select
        self.snapshot = {}
        self.announcements = CandidateAnnouncements(
            lambda announcement: self.get_accessible().emit("notification", announcement, Atk.Live.POLITE),
        )
        self.candidate_identity = None
        self.rectangles = []
        self.scroll = Gtk.ScrolledWindow()
        self.scroll.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        self.scroll.set_no_show_all(True)
        self.content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8, margin_top=12, margin_bottom=12)
        self.content.get_style_context().add_class("candidate-content")
        self.composition_title = Gtk.Label(label=message("candidate.composition"), xalign=0,
                                           margin_start=12, margin_end=12)
        self.composition_title.get_style_context().add_class("candidate-secondary")
        self.content.pack_start(self.composition_title, False, False, 0)
        self.composition = CandidateDetail(minimum_height=44, maximum_height=COMPOSITION_MAXIMUM_HEIGHT)
        self.composition.get_accessible().set_name(message("candidate.composition"))
        self.content.pack_start(self.composition, False, False, 0)
        self.remaining = CandidateDetail(minimum_height=32, maximum_height=REMAINING_MAXIMUM_HEIGHT)
        self.remaining.get_accessible().set_name(message("candidate.announceRemaining", reading="").strip())
        self.remaining.set_no_show_all(True)
        self.content.pack_start(self.remaining, False, False, 0)
        self.navigation = CandidateNavigation(select, lambda: self.update(self.snapshot), self.show_candidate_details)
        self.content.pack_start(self.navigation, False, False, 0)
        self.disclosures = Gtk.Box(spacing=8, margin_start=12, margin_end=12)
        self.content.pack_start(self.disclosures, False, False, 0)
        self.content.pack_start(self.scroll, False, False, 0)
        self.details = CandidateDetail()
        self.details.set_no_show_all(True)
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
        self.scroll.set_propagate_natural_height(True)
        self.actions = {}
        self.hovered_action = None
        self.location = (0, 0, 0, 0)
        self.focus_key = None
        self.layout_diagnostics = {}
        self.placement_side = None
        self.scroll_idle = None
        self.tree_expanded = False
        self.details_expanded = False
        self.disclosure_actions = {}
        self.suspending = False
        self.panel_css = Gtk.CssProvider()
        Gtk.StyleContext.add_provider_for_screen(
            self.get_screen(), self.panel_css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 1,
        )
        self.connect("destroy", self.cancel_scroll)
        self.connect("destroy", lambda *_: Gtk.StyleContext.remove_provider_for_screen(self.get_screen(), self.panel_css))
        self.connect("hide", self.hidden)
        self.connect("size-allocate", lambda *_: self.position() if self.get_visible() else None)
        self.theme = CandidateTheme(self, changed=self.refresh_appearance)
        self.refresh_appearance()

    def hidden(self, *_args):
        if not self.suspending:
            self.reset_presentation()

    def suspend(self):
        """Hide pending conversion while retaining the user's list and page state."""
        self.cancel_scroll()
        self.clear_actions()
        self.retire_disclosures()
        self.navigation.suspend()
        self.suspending = True
        Gtk.Window.hide(self)
        self.suspending = False

    def dismiss(self):
        """End the interaction, including while a pending popup is already hidden."""
        self.reset_presentation()
        Gtk.Window.hide(self)

    def hide(self):
        self.dismiss()

    def reset_presentation(self):
        self.cancel_scroll()
        self.clear_actions()
        self.retire_disclosures()
        self.announcements.reset()
        self.navigation.dismiss()
        self.candidate_identity = None
        self.tree_expanded = False
        self.details_expanded = False
        self.focus_key = None
        self.placement_side = None
        self.layout_diagnostics = {}

    def refresh_appearance(self):
        palette = self.theme.palette
        self.panel_css.load_from_data((
            f".azookey-tree .candidate-content {{ background-color: {palette['background']};"
            f"color: {palette['text']}; border-radius: 10px; }}"
            f".azookey-tree .candidate-secondary {{ color: {palette['secondaryText']}; }}"
            f".azookey-tree .candidate-disclosure {{ background-image: none; box-shadow: none;"
            f"transition-property: none;"
            f"background-color: {palette['background']}; color: {palette['secondaryText']};"
            f"border: none; border-radius: 5px; padding: 4px 0; }}"
        ).encode())
        self.composition.apply_palette(palette)
        self.remaining.apply_palette(palette)
        self.details.apply_palette(self.theme.palette)
        self.navigation.apply_palette(self.theme.palette)
        self.canvas.queue_draw()

    def cancel_scroll(self, *_args):
        if self.scroll_idle:
            GLib.source_remove(self.scroll_idle)
            self.scroll_idle = None

    def update(self, snapshot):
        identity = json.dumps([
            snapshot.get("contextId"), snapshot.get("reading"), snapshot.get("candidates", []),
            [{key: value for key, value in node.items() if key not in ("relativeScore", "scorePresentation", "preview", "previewDescription")}
             for node in snapshot.get("nodes", [])],
        ], sort_keys=True, ensure_ascii=False)
        if identity != self.candidate_identity:
            self.clear_actions()
            self.navigation.clear_preview()
            if snapshot.get("contextId") != self.snapshot.get("contextId") or self.candidate_identity is None:
                self.tree_expanded = False
                self.details_expanded = False
            self.retire_disclosures()
            self.candidate_identity = identity
        elif (snapshot.get("selection") is not None and snapshot.get("selection") == self.snapshot.get("selection")
              and self.snapshot.get("focusedNode") is not None
              and snapshot.get("focusedNode") is not None
              and snapshot.get("focusedNode") != self.snapshot.get("focusedNode")):
            # A keyboard move within the same candidate must expose its word
            # target even when the user has not opened the optional tree yet.
            self.tree_expanded = True
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
        score_height = SCORE_LINE_HEIGHT if snapshot.get("showRelativeScores") else 0
        row_pitch = row_height + score_height + CANDIDATE_ROW_GAP + (row_height if snapshot.get("showCandidateIndex") and aligned else 0)
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
                        badge = (x + column_width - row_height, 6 + row * row_pitch + row_height + score_height, row_height, row_height) if aligned else (x + column_width + 1, 6 + row * row_pitch, row_height, row_height)
                        self.rectangles.append(("select", index, *badge, str(number), ""))
            x += column_width + (0 if aligned else (row_height + 2 if snapshot.get("showCandidateIndex") else 12))
        width = max(60, x)
        height = max(32, max(map(len, columns)) * row_pitch + 6)
        self.canvas.set_size_request(int(width + 0.5), height)
        self.surface.set_size_request(int(width + 0.5), height)
        monitor = self.get_display().get_monitor_at_point(self.location[0], self.location[1])
        area = monitor.get_workarea() if monitor else self.get_screen().get_monitor_workarea(0)
        if aligned and (self.location[0] - 12 < area.x or self.location[0] - 12 + max(MINIMUM_POPUP_WIDTH, width) > area.x + area.width):
            # Clamping or scrolling would invalidate the document coordinates.
            # Use the ordinary compact popup when the span cannot fit onscreen.
            self.update({**snapshot, "wordGeometry": None, "layoutReason": "outside-workarea"})
            return
        # Keep a useful detail line below even for a one-character candidate.
        popup_width = int(min(max(MINIMUM_POPUP_WIDTH, width), 760 if not aligned else max(MINIMUM_POPUP_WIDTH, width), area.width) + 0.5)
        list_height = min(CandidateNavigation.MAXIMUM_LIST_HEIGHT, area.height // 3)
        self.navigation.update(snapshot, font_size=self.font_size, list_height=list_height)
        self.update_composition(popup_width)
        self.update_disclosures()
        self.scroll.set_min_content_width(popup_width)
        if self.tree_expanded:
            self.update_actions()
            self.surface.show_all()
            self.scroll.get_child().show()
        self.refresh_details()
        self.details.get_child().show_all()
        self.show_all()
        self.scroll.set_visible(self.tree_expanded)
        self.details.set_visible(self.details_expanded)
        self.fit_content_height(width=popup_width, available_height=area.height)
        self.resize(popup_width, 1)
        self.announcements.update(snapshot)
        self.position()
        self.canvas.queue_draw()
        focus = by_id.get(snapshot.get("focusedNode"))
        key = (snapshot.get("generation"), snapshot.get("selection"), snapshot.get("focusedNode"))
        if self.tree_expanded and focus and key != self.focus_key:
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

    def update_composition(self, width):
        selection = self.snapshot.get("selection")
        candidate = next((item for item in self.snapshot.get("candidates", []) if item.get("index") == selection), None)
        candidate = candidate or self.numbered_candidate(selection)
        preview = next((node["preview"] for node in self.snapshot.get("nodes", [])
                        if node.get("preview") and node["preview"].get("candidateIndex") == selection), {})
        commit_text = (candidate or preview).get("text", self.snapshot.get("preedit", ""))
        self.composition.update(commit_text, font_size=self.font_size + 2, width=width)
        scope = (candidate or {}).get("commitScope") or preview.get("scope") or {}
        remaining = scope.get("remainingReading", "")
        self.remaining.update(message("candidate.announceRemaining", reading=remaining) if remaining else "",
                              font_size=self.font_size, width=width)
        self.remaining.get_child().show_all()
        self.remaining.set_visible(bool(remaining))

    def fit_content_height(self, *, width, available_height):
        # Share the remaining work area between scrollable content. Long full
        # sentences and remaining readings never increase the popup offscreen.
        controls = (self.composition_title, self.navigation.header, self.navigation.footer, self.disclosures)
        control_height = sum(widget.get_preferred_height_for_width(width)[1] for widget in controls if widget.get_visible())
        visible_children = sum(child.get_visible() for child in self.content.get_children())
        control_height += self.content.get_margin_top() + self.content.get_margin_bottom()
        control_height += max(0, visible_children - 1) * self.content.get_spacing()
        control_height += 2 * self.navigation.get_spacing()
        panes = [(self.composition, 1, COMPOSITION_MAXIMUM_HEIGHT), (self.remaining, 1, REMAINING_MAXIMUM_HEIGHT),
                 (self.navigation.scroll, PRIMARY_LIST_HEIGHT_SHARE, CandidateNavigation.MAXIMUM_LIST_HEIGHT),
                 (self.scroll, SUPPLEMENT_HEIGHT_SHARE, TREE_MAXIMUM_HEIGHT),
                 (self.details, SUPPLEMENT_HEIGHT_SHARE, CandidateDetail.MAXIMUM_HEIGHT)]
        panes = [pane for pane in panes if pane[0].get_visible()]
        weight = sum(pane[1] for pane in panes)
        available = max(weight, available_height - control_height)
        for pane, share, maximum in panes:
            pane.set_min_content_height(0)
            limit = min(maximum, max(1, available * share // weight))
            pane.set_max_content_height(limit)
            natural_height = pane.get_child().get_preferred_height_for_width(width)[1]
            pane.set_min_content_height(min(limit, natural_height))
        # GTK scrollbars have their own minimum sizes, separate from content.
        # Reduce supplementary panes first if those minima exceed the budget.
        for pane in (self.scroll, self.details, self.navigation.scroll, self.composition, self.remaining):
            overflow = self.content.get_preferred_height_for_width(width)[0] - available_height
            if overflow <= 0:
                break
            if pane.get_visible():
                limit = max(0, pane.get_min_content_height() - overflow)
                pane.set_min_content_height(limit)
                pane.set_max_content_height(max(1, limit))

    def update_disclosures(self):
        for name, expanded, open_key, close_key in (
            ("tree", self.tree_expanded, "candidate.openTree", "candidate.closeTree"),
            ("details", self.details_expanded, "candidate.openDetails", "candidate.closeDetails"),
        ):
            if name not in self.disclosure_actions:
                button = CandidateNavigation.button(lambda source, name=name: self.toggle_disclosure(name, source))
                button.get_style_context().add_class("candidate-disclosure")
                self.disclosures.pack_start(button, False, False, 0)
                self.disclosure_actions[name] = button
            self.disclosure_actions[name].set_label(("▾ " if expanded else "▸ ") + message(close_key if expanded else open_key))

    def toggle_disclosure(self, name, source):
        if not self.get_visible() or self.disclosure_actions.get(name) is not source:
            return
        if name == "tree":
            self.tree_expanded = not self.tree_expanded
            self.clear_actions()
            self.focus_key = None
        else:
            self.details_expanded = not self.details_expanded
        self.update(self.snapshot)

    def retire_disclosures(self):
        retired = list(self.disclosure_actions.values())
        self.disclosure_actions.clear()
        for button in retired:
            button.destroy()

    def clear_actions(self):
        self.hovered_action = None
        retired = list(self.actions.values())
        self.actions.clear()
        for button in retired:
            button.destroy()

    def update_actions(self):
        visible = {(item[0], item[1]) for item in self.rectangles}
        for identity in list(self.actions):
            if identity not in visible:
                self.actions.pop(identity).destroy()
                if self.hovered_action == identity:
                    self.hovered_action = None
        selected = set(self.snapshot.get("selectedPath", []))
        for kind, index, x, y, width, height, text, reading in self.rectangles:
            identity = (kind, index)
            button = self.actions.get(identity)
            if button is None:
                button = CandidateAction(lambda source, identity=identity: self.activate(identity, source))
                button.connect("enter-notify-event", lambda source, _event, identity=identity:
                               self.hover_action(identity, source))
                button.connect("leave-notify-event", lambda source, _event, identity=identity:
                               self.leave_action(identity, source))
                self.surface.put(button, int(x), int(y))
                self.actions[identity] = button
            self.surface.move(button, int(x), int(y))
            button.activation_token = (self.snapshot.get("contextId"), self.snapshot.get("generation"),
                                       self.snapshot.get("selection"))
            button.set_size_request(max(1, int(width)), max(1, int(height)))
            name = text if not reading else message("candidate.withReading", text=text, reading=reading)
            active = index in selected if kind == "node" else index == self.snapshot.get("selection")
            description = message("candidate.focusedSelect" if kind == "node" and index == self.snapshot.get("focusedNode")
                                  else "candidate.select")
            if kind == "node":
                node = next(item for item in self.snapshot["nodes"] if item["id"] == index)
                if node.get("previewDescription"):
                    description += "\n" + node["previewDescription"]
                if presentation := score_presentation(self.snapshot, node):
                    description += "\n" + presentation["detailDescription"]
            if kind == "select":
                name = message("candidate.numberSelect", number=text)
                item = self.numbered_candidate(index)
                if item and item.get("detailDescription"):
                    description += "\n" + item["detailDescription"]
            button.set_tooltip_text(name + "\n" + description)
            button.update_accessibility(name, selected=active, description=description)

    def hover_action(self, identity, source):
        if self.get_visible() and self.tree_expanded and self.actions.get(identity) is source:
            self.hovered_action = identity
            self.refresh_details()
        return False

    def leave_action(self, identity, source):
        if self.actions.get(identity) is source and self.hovered_action == identity:
            self.hovered_action = None
            self.refresh_details()
        return False

    def refresh_details(self):
        if self.navigation.expanded and self.navigation.hovered_item:
            return self.show_candidate_details(self.navigation.hovered_item)
        if self.hovered_action in self.actions:
            kind, index = self.hovered_action
            return self.show_details(index) if kind == "node" else self.show_number_details(index)
        columns = self.snapshot.get("columns", [])
        node_id = self.snapshot.get("focusedNode")
        return self.show_details(node_id if node_id is not None else (columns[0][0] if columns else None))

    def show_details(self, node_id):
        node = next((item for item in self.snapshot.get("nodes", []) if item["id"] == node_id), None)
        if node is None:
            self.details.update("", font_size=self.font_size, width=320)
            return False
        content = node["text"] + ("\n" + node["reading"] if node.get("reading") else "")
        if node.get("previewDescription"):
            content += "\n" + node["previewDescription"]
        if presentation := score_presentation(self.snapshot, node):
            content += "\n" + presentation["detailDescription"]
        width = self.scroll.get_min_content_width()
        self.details.update(content + "\n" + message("candidate.detailKeys"), font_size=self.font_size, width=width)
        return False

    def show_candidate_details(self, item):
        if item is None:
            return self.refresh_details()
        content = item.get("detailDescription", item["text"])
        self.details.update(content, font_size=self.font_size, width=self.scroll.get_min_content_width())
        return False

    def numbered_candidate(self, index):
        return next((item for item in self.snapshot.get("candidatePage", {}).get("items", [])
                     if item["index"] == index), None)

    def show_number_details(self, index):
        # A shared word can preview a longer candidate than its adjacent number.
        item = self.numbered_candidate(index)
        return self.show_candidate_details(item or {"text": ""})

    def scroll_details(self, forward):
        if not self.get_visible():
            return False
        if not self.details_expanded:
            self.details_expanded = True
            self.update(self.snapshot)
        self.details.scroll_page(forward)
        return True

    def activate(self, identity, source):
        # Removed ATK objects may outlive a candidate update in the AT client.
        if self.get_visible() and self.tree_expanded and self.actions.get(identity) is source:
            self.select(*identity, False)

    def position(self):
        x, y, _, height = self.location
        if getattr(self, "aligned", False):
            x -= 12
        monitor = self.get_display().get_monitor_at_point(x, y)
        area = monitor.get_workarea() if monitor else self.get_screen().get_monitor_workarea(0)
        width, popup_height = self.get_size()
        x = max(area.x, min(x, area.x + area.width - width))
        below = y + height
        fits_above = y - popup_height >= area.y
        above = fits_above and (self.placement_side == "above" or below + popup_height > area.y + area.height)
        self.placement_side = "above" if above else "below"
        y = max(area.y, min(y - popup_height if above else below, area.y + area.height - popup_height))
        self.move(x, y)
        self.layout_diagnostics = {
            "renderer": "gtk", "source": "ibus-caret",
            "mode": "aligned" if self.aligned else "compact",
            "reason": self.snapshot.get("layoutReason", "estimated-inline" if self.aligned else "unavailable-or-narrow"),
            "cursor": self.location, "workArea": [area.x, area.y, area.width, area.height],
            "popup": [x, y, width, popup_height],
        }

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
        background = self.theme.rgb("background")
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
        nodes = {node["id"]: node for node in self.snapshot.get("nodes", [])}
        for node in self.snapshot.get("nodes", []):
            if node["id"] not in frames:
                continue
            x1, y1, width, height = frames.get(node.get("parent"), (4, 18, 0, 0))
            x2, y2, _, h2 = frames[node["id"]]
            start, end = (x1 + width, y1 + height / 2), (x2, y2 + h2 / 2)
            active = node["id"] in selected
            context.set_source_rgb(*self.theme.rgb("text" if active else "border"))
            context.set_line_width(3 if active else 1)
            context.set_dash([] if active else [2, 3])
            middle = (start[0] + end[0]) / 2
            context.move_to(*start)
            context.curve_to(middle, start[1], middle, end[1], *end)
            context.stroke()
        context.set_dash([])
        context.set_source_rgb(*self.theme.rgb("text"))
        context.arc(4, 18, 3, 0, 6.2832)
        context.fill()
        for kind, index, x, y, width, height, text, reading in self.rectangles:
            active = index in selected if kind == "node" else index == self.snapshot.get("selection")
            context.set_source_rgb(*self.theme.rgb("selection" if active else "surface"))
            radius = 4
            context.new_sub_path()
            for cx, cy, start in ((x + width - radius, y + radius, -1.5708), (x + width - radius, y + height - radius, 0),
                                  (x + radius, y + height - radius, 1.5708), (x + radius, y + radius, 3.1416)):
                context.arc(cx, cy, radius, start, start + 1.5708)
            context.close_path()
            context.fill_preserve()
            if active:
                context.set_source_rgb(*self.theme.rgb("text"))
                context.set_line_width(3 if self.theme.high_contrast else 2)
                context.stroke()
            else:
                context.new_path()
            if kind == "node" and index == self.snapshot.get("focusedNode"):
                context.set_source_rgb(*self.theme.rgb("selectionText" if active else "text"))
                context.set_line_width(2)
                context.move_to(x + 6, y + height - 4)
                context.line_to(x + width - 6, y + height - 4)
                context.stroke()
            color = self.theme.rgb("selectionText" if active else "text")
            inset = 2 if self.aligned else 4
            size = self.font_size if kind == "node" else max(14, self.font_size - 4)
            self.text(context, text, x + inset, y, width - inset * 2, size, color, self.aligned, height)
            if kind == "node":
                node = nodes[index]
                if presentation := score_presentation(self.snapshot, node):
                    draw_score_badge(context, presentation, (x, y, width, height),
                                     score=node.get("relativeScore"), theme=self.theme)
        return False

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
                presentation = score_presentation(self.snapshot, nodes[index])
                detail = "\n" + presentation["detailDescription"] if presentation else ""
                tooltip.set_text(f"{text}（{reading}）{detail}")
                return True
        return False

    def click(self, _widget, event):
        if not self.get_visible() or not self.tree_expanded or event.button != 1:
            return False
        for kind, index, x, y, width, height, *_ in reversed(self.rectangles):
            if x <= event.x <= x + width and y <= event.y <= y + height:
                self.select(kind, index, False)
                return True
        return False
