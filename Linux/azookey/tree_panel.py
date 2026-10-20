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
from .word_definition_target import word_definition_target
from .word_definition_lookup import WordDefinitionLookup, word_definition_worker
from .word_definition_view import WordDefinitionView
from .word_definition_layout import (
    CANDIDATE_PREFERRED_WIDTH, STANDARD_FONT_SIZE, pointer_in_definition_corridor,
    pointer_in_rectangle, word_definition_columns,
)
from .candidate_navigation import CandidateNavigation
from .candidate_placement import COLUMN_START_INSET, popup_placement
from .ibus_coordinates import logical_cursor_rectangle
from .candidate_theme import CandidateTheme
from .candidate_score import SCORE_LINE_HEIGHT, draw_score_badge, score_presentation
from .i18n import text as message


CANDIDATE_ROW_GAP = 4  # Separate actions even when the score line is hidden.
MINIMUM_POPUP_WIDTH = 420  # Leave room for readable sentences and a separate confirm action.
MINIMUM_LIVE_WIDTH = 240  # The live tree has no permanent full-sentence list beside it.
MINIMUM_NODE_SIZE = 44  # A node and its displayed badge share one pointer/AT action.
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
        self.connect("draw", self.clear_background)
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
        self.presentation_mode = None
        self.candidate_numbers = {}
        self.rectangles = []
        self.scroll = Gtk.ScrolledWindow()
        self.scroll.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        self.scroll.set_no_show_all(True)
        self.content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6, margin_top=8, margin_bottom=8)
        self.content.get_style_context().add_class("candidate-content")
        self.composition_title = Gtk.Label(label=message("candidate.composition"), xalign=0,
                                           margin_start=8, margin_end=8)
        self.composition_title.get_style_context().add_class("candidate-secondary")
        self.composition_title.set_no_show_all(True)
        self.content.pack_start(self.composition_title, False, False, 0)
        self.composition = CandidateDetail(minimum_height=44, maximum_height=COMPOSITION_MAXIMUM_HEIGHT)
        self.composition.set_no_show_all(True)
        self.composition.get_accessible().set_name(message("candidate.composition"))
        self.content.pack_start(self.composition, False, False, 0)
        self.remaining = CandidateDetail(minimum_height=32, maximum_height=REMAINING_MAXIMUM_HEIGHT)
        self.remaining.get_accessible().set_name(message("candidate.announceRemaining", reading="").strip())
        self.remaining.set_no_show_all(True)
        self.content.pack_start(self.remaining, False, False, 0)
        self.navigation = CandidateNavigation(select, lambda: self.update(self.snapshot), self.show_candidate_details,
                                              keep_preview=self.keep_definition_preview)
        self.content.pack_start(self.navigation, False, False, 0)
        self.disclosures = Gtk.Box(spacing=6, margin_start=8, margin_end=8)
        self.disclosures.set_no_show_all(True)
        self.content.pack_start(self.disclosures, False, False, 0)
        self.content.pack_start(self.scroll, False, False, 0)
        self.details = CandidateDetail()
        self.details.set_no_show_all(True)
        self.content.pack_start(self.details, False, False, 0)
        # A taller entry may scroll the whole card. Keep confirmation at the
        # bottom of the left column so that it remains reachable at that end.
        self.navigation.remove(self.navigation.footer)
        self.navigation.footer.get_style_context().add_class("candidate-navigation")
        self.content.pack_end(self.navigation.footer, False, False, 0)
        self.definitions = WordDefinitionView(lambda: self.update(self.snapshot))
        self.definition_column = Gtk.EventBox(visible_window=False)
        self.definition_column.set_can_focus(False)
        self.definition_column.set_valign(Gtk.Align.START)
        self.definition_column.set_no_show_all(True)
        self.definition_column.set_margin_bottom(8)
        self.definition_column.add(self.definitions)
        self.definition_column.get_style_context().add_class("candidate-content")
        self.card = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        self.card.pack_start(self.content, False, False, 0)
        self.card.pack_start(self.definition_column, False, False, 0)
        self.candidate_width = MINIMUM_POPUP_WIDTH
        self.definition_width = 0
        self.popup_content_width = MINIMUM_POPUP_WIDTH
        self.definition_pointer_active = False
        self.definition_pointer_token = None
        self.definition_lookup = WordDefinitionLookup(word_definition_worker(), self.definition_changed)
        self.definition_layout_idle = None
        self.definition_relayout_required = False
        self.candidate_metrics = None
        for widget in (self.navigation.header, self.navigation.footer, self.definitions.header):
            widget.connect("style-updated", self.candidate_metrics_changed)
        self.connect("destroy", self.destroy_definitions)
        # If a very short work area cannot hold the fixed controls, the entire
        # popup remains scrollable instead of covering the document caret.
        self.viewport = Gtk.ScrolledWindow()
        self.viewport.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        self.viewport.set_can_focus(False)
        self.viewport.set_propagate_natural_width(False)
        self.viewport.set_propagate_natural_height(False)
        self.viewport.add(self.card)
        self.add(self.viewport)
        for widget in (self, self.definition_column):
            widget.add_events(Gdk.EventMask.POINTER_MOTION_MASK | Gdk.EventMask.LEAVE_NOTIFY_MASK)
            widget.connect("motion-notify-event", self.definition_pointer_moved)
            widget.connect("leave-notify-event", self.definition_pointer_moved)
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
        self.caret_location = None
        self.focus_key = None
        self.layout_diagnostics = {}
        self.placement_side = None
        self.scroll_idle = None
        self.tree_expanded = False
        self.details_expanded = False
        self.options_expanded = False
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
        screen = self.get_screen()
        monitors_changed = screen.connect("monitors-changed", self.display_geometry_changed)
        self.connect("destroy", lambda *_: screen.disconnect(monitors_changed))

    def clear_background(self, _widget, context):
        # Only the individual cards paint a background; expose the desktop in
        # their gap and below the shorter card after any resize or disclosure.
        context.save()
        context.set_operator(cairo.OPERATOR_SOURCE)
        context.set_source_rgba(0, 0, 0, 0)
        context.paint()
        context.restore()
        return False

    def display_geometry_changed(self, *_args):
        # X11 updates its global window scale before this monitor notification.
        # Pending input must remain suspended until the corresponding reply.
        if self.get_visible():
            self.update(self.snapshot)

    def hidden(self, *_args):
        if not self.suspending:
            self.reset_presentation()

    def suspend(self):
        """Hide pending conversion while retaining the user's list and page state."""
        self.cancel_scroll()
        self.definition_pointer_active = False
        self.definition_lookup.invalidate()
        self.definitions.replace_actions()
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
        self.definition_pointer_active = False
        self.definition_pointer_token = None
        self.candidate_metrics = None
        self.definition_relayout_required = False
        self.definition_lookup.invalidate()
        self.definitions.reset()
        self.cancel_scroll()
        self.clear_actions()
        self.retire_disclosures()
        self.announcements.reset()
        self.navigation.dismiss()
        self.candidate_identity = None
        self.presentation_mode = None
        self.candidate_numbers = {}
        self.tree_expanded = False
        self.details_expanded = False
        self.options_expanded = False
        self.focus_key = None
        self.placement_side = None
        self.layout_diagnostics = {}
        self.reset_popup_scroll()

    def reset_popup_scroll(self):
        self.viewport.get_hadjustment().set_value(0)
        self.viewport.get_vadjustment().set_value(0)

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
        self.definitions.apply_palette(self.theme.palette)
        self.navigation.apply_palette(self.theme.palette)
        self.canvas.queue_draw()

    def cancel_scroll(self, *_args):
        if self.scroll_idle:
            GLib.source_remove(self.scroll_idle)
            self.scroll_idle = None

    def update(self, snapshot):
        # The engine uses this renderer only when tree display is enabled.
        mode = "live" if snapshot.get("inputState") == "composing" else "menu"
        pointer_token = (snapshot.get("contextId"), snapshot.get("generation"), snapshot.get("selection"),
                         snapshot.get("focusedNode"), mode)
        if self.definition_pointer_active and pointer_token != self.definition_pointer_token:
            self.definition_pointer_active = False
            self.navigation.clear_preview()
        self.definition_pointer_token = pointer_token
        identity = json.dumps([
            snapshot.get("contextId"), snapshot.get("reading"), snapshot.get("candidates", []),
            [{key: value for key, value in node.items() if key not in ("relativeScore", "scorePresentation", "preview", "previewDescription")}
             for node in snapshot.get("nodes", [])],
        ], sort_keys=True, ensure_ascii=False)
        if identity != self.candidate_identity or mode != self.presentation_mode:
            self.clear_actions()
            self.navigation.clear_preview()
            self.definition_pointer_active = False
            self.navigation.dismiss(expanded_on_update=mode != "live")
            self.tree_expanded = mode == "live"
            self.details_expanded = False
            self.options_expanded = False
            self.definitions.reset()
            self.definition_lookup.invalidate()
            self.retire_disclosures()
            self.candidate_identity = identity
            self.presentation_mode = mode
            self.focus_key = None
            self.reset_popup_scroll()
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
        widths = [width / self.ibus_coordinate_scale for width in geometry.get("widths", [])]
        # Logical pixels are scaled by GTK; do not copy AppKit point measurements.
        base_size = 24 if snapshot.get("candidateTextSize") == "large" else 18
        scale = self.get_settings().get_property("gtk-xft-dpi") / (96 * Pango.SCALE)
        self.font_size = base_size * max(1, scale)
        self.word_height = int(self.font_size + 14)
        self.number_font_size = max(12, self.font_size * 2 / 3)
        self.candidate_numbers = {}
        if snapshot.get("showCandidateIndex") or mode == "live":
            visible_nodes = {node_id for column in columns for node_id in column}
            for node in nodes:
                if node["id"] not in visible_nodes:
                    continue
                # Shared nodes can terminate a shorter candidate than the
                # descendant Core will select. Only its preview gives that ID.
                index = (node.get("preview") or {}).get("candidateIndex")
                if index is not None:
                    number = index - snapshot.get("pageStart", 0) + 1
                    if 1 <= number <= 9:
                        self.candidate_numbers[node["id"]] = number
        self.number_height = int(self.number_font_size + 6) if self.candidate_numbers else 0
        minimum_width = max(MINIMUM_NODE_SIZE, self.font_size + 8)
        aligned = len(widths) == len(columns) and all(w >= minimum_width for w in widths)
        self.aligned = aligned
        score_height = SCORE_LINE_HEIGHT if snapshot.get("showRelativeScores") else 0
        row_height = max(MINIMUM_NODE_SIZE, self.word_height + score_height + self.number_height)
        row_pitch = row_height + CANDIDATE_ROW_GAP
        x = COLUMN_START_INSET
        for depth, column in enumerate(columns):
            # Other candidates may cover the entire sentence. They must never
            # change the chosen word's position or cover the following column.
            column_width = widths[depth] if aligned else max(minimum_width, min(
                240, self.measure(by_id[column[0]]["text"], font_size=self.font_size) + 12))
            for row, node_id in enumerate(column):
                node = by_id[node_id]
                self.rectangles.append(("node", node_id, x, 6 + row * row_pitch, column_width, row_height, node["text"], node["reading"]))
            x += column_width + (0 if aligned else 12)
        width = max(60, x)
        height = max(32, max(map(len, columns)) * row_pitch + 6)
        self.canvas.set_size_request(int(width + 0.5), height)
        self.surface.set_size_request(int(width + 0.5), height)
        area = self.work_area()
        live = mode == "live"
        minimum_popup_width = MINIMUM_LIVE_WIDTH if live and not self.navigation.expanded else MINIMUM_POPUP_WIDTH
        aligned_x = self.column_anchor_x - COLUMN_START_INSET
        candidate_width = int(min(max(minimum_popup_width, width),
                                  760 if not aligned else max(minimum_popup_width, width), area.width) + 0.5)
        if not live:
            # Dictionary disclosure and long tree nodes never widen the candidate card.
            candidate_width = round(CANDIDATE_PREFERRED_WIDTH * self.font_size / STANDARD_FONT_SIZE)
        columns_layout = (word_definition_columns(candidate_width=candidate_width, font_size=self.font_size,
                                                  available_width=area.width) if not live else None)
        self.candidate_width = columns_layout.candidate_width if columns_layout else candidate_width
        self.definition_width = columns_layout.definition_width if columns_layout else 0
        self.popup_content_width = columns_layout.width if columns_layout else candidate_width
        if aligned and (aligned_x < area.x or aligned_x + self.popup_content_width > area.x + area.width
                        or width > self.candidate_width):
            # Clamping or scrolling would invalidate the document coordinates.
            # Use the ordinary compact popup when the span cannot fit onscreen.
            self.update({**snapshot, "wordGeometry": None, "layoutReason": "outside-workarea"})
            return
        popup_width = min(area.width, self.popup_content_width)
        self.content.set_size_request(self.candidate_width, -1)
        self.content.set_valign(Gtk.Align.FILL if live else Gtk.Align.START)
        self.definition_column.set_size_request(self.definition_width, -1)
        self.card.set_spacing(columns_layout.gap if columns_layout else 0)
        list_height = min(CandidateNavigation.MAXIMUM_LIST_HEIGHT, area.height // 3) if live else area.height
        self.navigation.update(snapshot, font_size=self.font_size, list_height=list_height, compact=live, minimal=not live)
        show_menu = not live or self.navigation.expanded
        show_composition = show_menu and (live or self.details_expanded)
        self.composition_title.set_visible(show_composition)
        self.composition.set_visible(show_composition)
        self.disclosures.set_visible(show_menu and (live or self.options_expanded or self.tree_expanded or self.details_expanded))
        self.content.reorder_child(self.scroll, 5 if show_menu else 0)
        self.update_composition(self.candidate_width)
        self.update_disclosures()
        self.scroll.set_min_content_width(self.candidate_width)
        if self.tree_expanded:
            self.update_actions()
            self.surface.show_all()
            self.scroll.get_child().show()
        self.refresh_details()
        self.details.get_child().show_all()
        self.viewport.show_all()
        self.navigation.footer.set_visible(self.navigation.get_visible())
        self.scroll.set_visible(self.tree_expanded)
        self.details.set_visible(self.details_expanded)
        self.update_definition_view(width=self.definition_width, active=not live)
        self.definition_column.set_visible(not live)
        self.fit_content_height(width=popup_width, available_height=area.height)
        requested_height = (self.card.get_preferred_height_for_width(self.popup_content_width)[1]
                            + self.horizontal_scrollbar_height(popup_width))
        placement = popup_placement(
            cursor=self.current_caret, work_area=(area.x, area.y, area.width, area.height),
            popup_size=(popup_width, requested_height), preferred_side=self.placement_side,
            column_anchor_x=self.column_anchor_x if self.aligned else None,
        )
        if placement is None:
            self.suspend()
            return
        if self.aligned and placement.side in ("left", "right"):
            self.update({**snapshot, "wordGeometry": None, "layoutReason": "outside-workarea"})
            return
        self.placement_side = placement.side
        if placement.height < requested_height:
            self.fit_content_height(width=placement.width, available_height=placement.height)
        self.limit_viewport(width=placement.width, height=placement.height)
        self.resize(placement.width, placement.height)
        self.show()
        self.announcements.update(snapshot)
        self.position()
        self.canvas.queue_draw()
        focus = by_id.get(snapshot.get("focusedNode"))
        key = (snapshot.get("contextId"), snapshot.get("selection"), snapshot.get("focusedNode"))
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
        self.candidate_metrics = self.measure_candidate_metrics()

    def update_composition(self, width):
        title_key = ("candidate.composition" if self.navigation.keyboard_confirms_candidate else "candidate.proposal")
        self.composition_title.set_text(message(title_key))
        self.composition.get_accessible().set_name(message(title_key))
        selection = self.snapshot.get("selection")
        candidate = next((item for item in self.snapshot.get("candidates", []) if item.get("index") == selection), None)
        candidate = candidate or self.numbered_candidate(selection)
        preview = next((node["preview"] for node in self.snapshot.get("nodes", [])
                        if node.get("preview") and node["preview"].get("candidateIndex") == selection), {})
        commit_text = (candidate or preview).get("text", self.snapshot.get("preedit", ""))
        self.composition.update(commit_text, font_size=self.font_size + 2, width=width)
        self.composition.get_child().show_all()
        scope = (candidate or {}).get("commitScope") or preview.get("scope") or {}
        remaining = scope.get("remainingReading", "")
        self.remaining.update(message("candidate.announceRemaining", reading=remaining) if remaining else "",
                              font_size=self.font_size, width=width)
        self.remaining.get_child().show_all()
        self.remaining.set_visible(bool(remaining))

    def fit_content_height(self, *, width, available_height):
        available_height -= self.horizontal_scrollbar_height(width)
        self.fit_candidate_height(width=self.candidate_width, available_height=available_height)
        if self.definition_column.get_visible():
            offset = self.content.get_margin_top()
            for child in self.content.get_children():
                if child is self.navigation:
                    break
                if child.get_visible():
                    offset += child.get_preferred_height_for_width(self.candidate_width)[1] + self.content.get_spacing()
            self.definition_column.set_margin_top(offset)
            self.definitions.fit_height(width=self.definition_width,
                                        available_height=available_height - offset - self.definition_column.get_margin_bottom())

    def fit_candidate_height(self, *, width, available_height):
        # Share the remaining work area between scrollable content. Long full
        # sentences and remaining readings never increase the popup offscreen.
        controls = (self.composition_title, self.navigation.header, self.navigation.footer, self.disclosures)
        control_height = sum(widget.get_preferred_height_for_width(width)[1] for widget in controls if widget.get_visible())
        visible_children = sum(child.get_visible() for child in self.content.get_children())
        control_height += self.content.get_margin_top() + self.content.get_margin_bottom()
        control_height += max(0, visible_children - 1) * self.content.get_spacing()
        navigation_children = sum(child.get_visible() for child in self.navigation.get_children())
        control_height += max(0, navigation_children - 1) * self.navigation.get_spacing()
        panes = [(self.composition, 1, COMPOSITION_MAXIMUM_HEIGHT), (self.remaining, 1, REMAINING_MAXIMUM_HEIGHT),
                 (self.navigation.scroll, PRIMARY_LIST_HEIGHT_SHARE, self.navigation.list_height_limit),
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
            self.disclosure_actions[name].show()
        if self.presentation_mode == "menu":
            if "options" not in self.disclosure_actions:
                button = CandidateNavigation.button(lambda source: self.toggle_disclosure("options", source))
                button.set_size_request(MINIMUM_NODE_SIZE, MINIMUM_NODE_SIZE)
                button.get_style_context().add_class("candidate-disclosure")
                self.navigation.footer.pack_start(button, False, False, 0)
                self.disclosure_actions["options"] = button
            options = self.disclosure_actions["options"]
            options.set_label("⋯")
            options.update_accessibility(message("candidate.closeOptions" if self.options_expanded else "candidate.openOptions"),
                                         selected=self.options_expanded, description=message("candidate.openOptions"))
            options.set_tooltip_text(message("candidate.openOptions"))
            options.show()

    def toggle_disclosure(self, name, source):
        if not self.get_visible() or self.disclosure_actions.get(name) is not source:
            return
        if name == "options":
            self.options_expanded = not self.options_expanded
            if not self.options_expanded:
                self.tree_expanded = False
                self.details_expanded = False
                self.clear_actions()
                self.focus_key = None
                self.retire_disclosures()
        elif name == "tree":
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
            active = index in selected
            description = message("candidate.focusedSelect" if index == self.snapshot.get("focusedNode")
                                  else "candidate.select")
            node = next(item for item in self.snapshot["nodes"] if item["id"] == index)
            if node.get("previewDescription"):
                description += "\n" + node["previewDescription"]
            if presentation := score_presentation(self.snapshot, node):
                description += "\n" + presentation["detailDescription"]
            if index in self.candidate_numbers:
                description += "\n" + message("candidate.numberBadge", number=self.candidate_numbers[index])
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

    def screen_rectangle(self, widget):
        offset = widget.translate_coordinates(self, 0, 0)
        if offset is None:
            return (0, 0, 0, 0)
        x, y = self.get_position()
        return (x + offset[0], y + offset[1], widget.get_allocated_width(), widget.get_allocated_height())

    def keep_definition_preview(self, source, event):
        if (self.presentation_mode != "menu" or not self.definition_column.get_mapped()
                or source is not self.navigation.hovered_button or source not in self.navigation.row_buttons):
            return False
        pointer = (event.x_root, event.y_root)
        inside = (pointer_in_rectangle(pointer, self.screen_rectangle(self.viewport))
                  and pointer_in_definition_corridor(pointer=pointer, row=self.screen_rectangle(source),
                                                    definition=self.screen_rectangle(self.definition_column)))
        self.definition_pointer_active = inside
        return inside

    def definition_pointer_moved(self, _widget, event):
        if not self.definition_pointer_active:
            return False
        source = self.navigation.hovered_button
        pointer = (event.x_root, event.y_root)
        if source in self.navigation.row_buttons and pointer_in_rectangle(pointer, self.screen_rectangle(source)):
            self.definition_pointer_active = False
        elif source not in self.navigation.row_buttons or not self.keep_definition_preview(source, event):
            self.definition_pointer_active = False
            self.navigation.clear_preview()
        return False

    def refresh_details(self):
        if self.navigation.expanded and self.navigation.hovered_item:
            return self.show_candidate_details(self.navigation.hovered_item)
        if self.hovered_action in self.actions:
            return self.show_details(self.hovered_action[1])
        columns = self.snapshot.get("columns", [])
        node_id = self.snapshot.get("focusedNode")
        return self.show_details(node_id if node_id is not None else (columns[0][0] if columns else None))

    def show_details(self, node_id):
        self.request_definition(node_id=node_id)
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
            self.definition_pointer_active = False
            return self.refresh_details()
        self.request_definition(candidate_index=item.get("index"))
        content = item.get("detailDescription", item["text"])
        self.details.update(content, font_size=self.font_size, width=self.scroll.get_min_content_width())
        return False

    def request_definition(self, *, node_id=None, candidate_index=None):
        target = (word_definition_target(self.snapshot, node_id=node_id, candidate_index=candidate_index)
                  if self.presentation_mode == "menu" else None)
        self.definition_lookup.update(target)

    def update_definition_view(self, *, width, active):
        self.definitions.update(self.definition_lookup.result, active=active,
                                font_size=self.font_size, width=width, target_identity=self.definition_lookup.target)

    def definition_changed(self, _response):
        self.definition_relayout_required = True
        self.queue_definition_layout()

    def measure_candidate_metrics(self):
        return (self.candidate_identity, self.presentation_mode, self.candidate_width, self.definition_width,
                self.get_settings().get_property("gtk-xft-dpi"),
                tuple(self.content.get_preferred_height_for_width(self.candidate_width)),
                tuple(self.definitions.get_preferred_height_for_width(max(1, self.definition_width))))

    def candidate_metrics_changed(self, *_args):
        if self.get_visible() and self.presentation_mode == "menu":
            self.queue_definition_layout()

    def queue_definition_layout(self):
        if self.definition_layout_idle is not None:
            return
        def layout():
            self.definition_layout_idle = None
            changed = self.definition_relayout_required or self.measure_candidate_metrics() != self.candidate_metrics
            self.definition_relayout_required = False
            # Native styles can finish changing after update() measured them.
            # Self-generated style notifications with identical dimensions do
            # not create a second rendering loop.
            if self.get_visible() and self.presentation_mode == "menu" and changed:
                self.update(self.snapshot)
            return GLib.SOURCE_REMOVE
        self.definition_layout_idle = GLib.idle_add(layout)

    def destroy_definitions(self, *_args):
        self.definition_lookup.invalidate()
        if self.definition_layout_idle is not None:
            GLib.source_remove(self.definition_layout_idle)
        self.definition_layout_idle = None

    def numbered_candidate(self, index):
        return next((item for item in self.snapshot.get("candidatePage", {}).get("items", [])
                     if item["index"] == index), None)

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

    @property
    def ibus_coordinate_scale(self):
        # IBus X11 cursor rectangles use device pixels. GDK work areas and
        # windows use application pixels, with one scale for the whole X screen.
        # GNOME's ShellCursor and Wayland-relative rectangles have another owner.
        return self.get_scale_factor() if "X11" in type(self.get_display()).__name__ else 1

    @property
    def column_anchor_x(self):
        return self.location[0] / self.ibus_coordinate_scale

    @property
    def current_caret(self):
        # Word alignment uses the composition start; exclusion uses the actual
        # IBus insertion caret, including after that estimated geometry expires.
        return logical_cursor_rectangle(
            self.caret_location or self.location, scale_factor=self.ibus_coordinate_scale)

    def work_area(self):
        monitor = self.get_display().get_monitor_at_point(*self.current_caret[:2])
        return monitor.get_workarea() if monitor else self.get_screen().get_monitor_workarea(0)

    def horizontal_scrollbar_height(self, width):
        if self.popup_content_width <= width:
            return 0
        return self.viewport.get_hscrollbar().get_preferred_height()[1]

    def limit_viewport(self, *, width, height):
        # Size the entire viewport, not just its content. GTK then reserves its
        # real theme scrollbar sizes inside the work-area rectangle.
        self.viewport.set_min_content_width(0)
        self.viewport.set_max_content_width(width)
        self.viewport.set_min_content_height(0)
        self.viewport.set_max_content_height(height)
        self.viewport.set_size_request(width, height)

    def position(self):
        area = self.work_area()
        width, popup_height = self.get_size()
        placement = popup_placement(
            cursor=self.current_caret, work_area=(area.x, area.y, area.width, area.height),
            popup_size=(width, popup_height), preferred_side=self.placement_side,
            column_anchor_x=self.column_anchor_x if self.aligned else None,
        )
        if placement is None:
            self.suspend()
            return
        if self.aligned and placement.side in ("left", "right"):
            # A sideways popup no longer follows the document's word positions.
            self.update({**self.snapshot, "wordGeometry": None, "layoutReason": "outside-workarea"})
            return
        self.placement_side = placement.side
        if (placement.width, placement.height) != (width, popup_height):
            self.fit_content_height(width=placement.width, available_height=placement.height)
            self.limit_viewport(width=placement.width, height=placement.height)
            self.resize(placement.width, placement.height)
        self.move(placement.x, placement.y)
        self.layout_diagnostics = {
            "renderer": "gtk", "source": "ibus-caret",
            "mode": "aligned" if self.aligned else "compact",
            "reason": self.snapshot.get("layoutReason", "estimated-inline" if self.aligned else "unavailable-or-narrow"),
            "cursor": self.current_caret, "workArea": [area.x, area.y, area.width, area.height],
            "popup": [placement.x, placement.y, width, popup_height],
            "side": placement.side,
            "coordinateSpace": "gtk-logical",
            "ibusCursor": self.caret_location or self.location,
            "ibusCoordinateScale": self.ibus_coordinate_scale,
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
            active = index in selected
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
            if index == self.snapshot.get("focusedNode"):
                context.set_source_rgb(*self.theme.rgb("selectionText" if active else "text"))
                context.set_line_width(2)
                context.move_to(x + 6, y + self.word_height - 4)
                context.line_to(x + width - 6, y + self.word_height - 4)
                context.stroke()
            color = self.theme.rgb("selectionText" if active else "text")
            inset = 2 if self.aligned else 4
            self.text(context, text, x + inset, y, width - inset * 2, self.font_size, color,
                      self.aligned, self.word_height)
            node = nodes[index]
            if presentation := score_presentation(self.snapshot, node):
                draw_score_badge(context, presentation, (x, y, width, self.word_height),
                                 score=node.get("relativeScore"), theme=self.theme)
            if index in self.candidate_numbers:
                self.text(context, str(self.candidate_numbers[index]), x + 6, y + height - self.number_height,
                          width - 12, self.number_font_size, color, True, self.number_height)
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
