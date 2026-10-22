import gi
import cairo
import json
import math
gi.require_version("Gtk", "3.0")
gi.require_version("Atk", "1.0")
gi.require_version("PangoCairo", "1.0")
from gi.repository import Atk, Gtk, Gdk, GLib, Pango, PangoCairo

from .candidate_accessibility import CandidateAction
from .candidate_announcements import CandidateAnnouncements
from .candidate_detail import CandidateDetail
from .candidate_navigation import CandidateNavigation
from .ibus_coordinates import logical_cursor_rectangle
from .candidate_theme import CandidateTheme
from .candidate_score import draw_score_badge
from .i18n import text as message


COMPOSITION_MAXIMUM_HEIGHT = 132  # Fits three large-text lines before scrolling.
REMAINING_MAXIMUM_HEIGHT = 72  # Keep the unconsumed reading beside the commit preview.
TREE_MAXIMUM_HEIGHT = 240  # The optional tree shares the work area with the primary list.
PRIMARY_LIST_HEIGHT_SHARE = 3  # Prioritize sentences when several scrollable panes are open.
SUPPLEMENT_HEIGHT_SHARE = 2  # The tree and details each receive less room than the list.
# PreeditAnchor calibrates this reference font against the document caret.
DOCUMENT_REFERENCE_FONT_SIZE = 40 / 3
LINE_HEIGHT_SAMPLE = "あg"  # A kana and a descender give the tallest candidate line.
NODE_CORNER_RADIUS = 4
FOCUS_UNDERLINE_INSET = 6


def rectangle(x, y, width, height):
    return {"x": x, "y": y, "width": width, "height": height}


class TreePanel(Gtk.Window):
    """Non-focusable X11 candidate popup. Core decides what it shows and where.

    `request_layout(request, completion)` sends a `candidate-layout` request to
    Core and later calls `completion` with its result, or None on failure.
    """

    def __init__(self, select, request_layout):
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
        self.request_layout = request_layout
        self.snapshot = {}
        self.display = {}
        # The canvas keeps drawing the snapshot its layout belongs to while
        # Core lays out a newer one.
        self.drawn_snapshot = {}
        self.drawn_display = {}
        self.layout = None
        self.placement = None
        self.layout_generation = 0
        self.announcements = CandidateAnnouncements(
            lambda announcement: self.get_accessible().emit("notification", announcement, Atk.Live.POLITE),
        )
        self.candidate_identity = None
        self.presentation_mode = None
        self.tree_expanded_for = None
        self.candidate_numbers = {}
        self.rectangles = []
        self.aligned = False
        self.font_size = 0
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
        self.navigation = CandidateNavigation(select, lambda: self.update(self.snapshot), self.show_candidate_details)
        self.content.pack_start(self.navigation, False, False, 0)
        self.disclosures = Gtk.Box(spacing=6, margin_start=8, margin_end=8)
        self.disclosures.set_no_show_all(True)
        self.content.pack_start(self.disclosures, False, False, 0)
        self.content.pack_start(self.scroll, False, False, 0)
        self.details = CandidateDetail()
        self.details.set_no_show_all(True)
        self.content.pack_start(self.details, False, False, 0)
        # If a very short work area cannot hold the fixed controls, the entire
        # popup remains scrollable instead of covering the document caret.
        self.viewport = Gtk.ScrolledWindow()
        self.viewport.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        self.viewport.set_can_focus(False)
        self.viewport.set_propagate_natural_width(True)
        self.viewport.set_propagate_natural_height(True)
        self.viewport.add(self.content)
        self.add(self.viewport)
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
        self.retire_layout()
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

    def retire_layout(self):
        # A Core reply for an older snapshot or a hidden popup is ignored.
        self.layout_generation += 1
        self.placement = None

    def reset_presentation(self):
        self.retire_layout()
        self.cancel_scroll()
        self.clear_actions()
        self.retire_disclosures()
        self.announcements.reset()
        self.navigation.dismiss()
        self.candidate_identity = None
        self.presentation_mode = None
        self.tree_expanded_for = None
        self.candidate_numbers = {}
        self.tree_expanded = False
        self.details_expanded = False
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
        self.navigation.apply_palette(self.theme.palette)
        self.canvas.queue_draw()

    def cancel_scroll(self, *_args):
        if self.scroll_idle:
            GLib.source_remove(self.scroll_idle)
            self.scroll_idle = None

    def update(self, snapshot):
        # The engine uses this renderer only when tree display is enabled.
        display = snapshot.get("candidateDisplay") or {}
        mode = display.get("mode", "hidden")
        if mode == "hidden":
            self.snapshot = snapshot
            self.display = display
            self.clear_actions()
            self.hide()
            return
        identity = json.dumps([
            snapshot.get("contextId"), snapshot.get("reading"), snapshot.get("candidates", []),
            [{key: value for key, value in node.items() if key not in ("relativeScore", "scorePresentation", "preview", "previewDescription")}
             for node in snapshot.get("nodes", [])],
        ], sort_keys=True, ensure_ascii=False)
        if identity != self.candidate_identity or mode != self.presentation_mode:
            self.clear_actions()
            self.navigation.clear_preview()
            self.navigation.dismiss(expanded_on_update=mode == "list")
            self.tree_expanded = mode == "tree"
            self.details_expanded = False
            self.retire_disclosures()
            self.candidate_identity = identity
            self.presentation_mode = mode
            self.focus_key = None
            self.reset_popup_scroll()
        expansion = (snapshot.get("contextId"), snapshot.get("generation"))
        if display.get("expandTree") and expansion != self.tree_expanded_for:
            # Core asks once per reply; redrawing the same reply keeps the user's choice.
            self.tree_expanded = True
            self.tree_expanded_for = expansion
        self.snapshot = snapshot
        self.display = display
        self.candidate_numbers = {node["id"]: node["number"] for node in display.get("nodes", [])
                                  if node.get("number") is not None}
        self.retire_layout()
        # Shown controls belong to the previous snapshot until Core replies.
        self.navigation.hold()
        self.request_core_layout()

    def request_core_layout(self, *, popup_height=None, measured_width=None):
        generation = self.layout_generation

        def apply(layout):
            if generation != self.layout_generation:
                return
            if layout is None:
                self.suspend()
            elif popup_height is None:
                self.apply_tree_layout(layout)
            else:
                self.apply_placement(layout, measured_width=measured_width, requested_height=popup_height)

        self.request_layout(self.layout_request(popup_height), apply)

    def layout_request(self, popup_height):
        nodes = {node["id"]: node for node in self.snapshot.get("nodes", [])}
        base_size = self.display["baseFontSize"]
        geometry = self.snapshot.get("wordGeometry") or {}
        document_widths = [width / self.ibus_coordinate_scale for width in geometry.get("widths", [])]
        area = self.work_area()
        caret = self.current_caret
        list_shown = self.display["mode"] == "list" or self.navigation.expanded
        return {
            "mode": "list" if list_shown else "tree",
            "textSize": self.snapshot.get("candidateTextSize", "standard"),
            "textScale": self.get_settings().get_property("gtk-xft-dpi") / (96 * Pango.SCALE),
            "measuredFontSize": base_size,
            "lineHeight": self.measure_height(LINE_HEIGHT_SAMPLE, font_size=base_size),
            "columns": [{"nodes": [{"id": node_id, "parent": nodes[node_id].get("parent")} for node_id in column],
                         "textWidth": self.measure(nodes[column[0]]["text"], font_size=base_size)}
                        for column in self.display["columns"]],
            "documentWordWidths": document_widths or None,
            "columnAnchorX": self.column_anchor_x if document_widths else None,
            "showScores": bool(self.snapshot.get("showRelativeScores")),
            "showNumbers": bool(self.display.get("showsNumbers")),
            "cursor": rectangle(*caret),
            "workArea": rectangle(area.x, area.y, area.width, area.height),
            "popupHeight": popup_height,
            "preferredSide": self.placement_side,
        }

    def apply_tree_layout(self, layout):
        tree = layout["tree"]
        self.layout = layout
        self.drawn_snapshot = self.snapshot
        self.drawn_display = self.display
        self.aligned = tree["aligned"]
        self.font_size = tree["metrics"]["fontSize"]
        nodes = {node["id"]: node for node in self.snapshot.get("nodes", [])}
        self.rectangles = []
        for node in tree["nodes"]:
            frame = node["frame"]
            source = nodes[node["id"]]
            self.rectangles.append(("node", node["id"], frame["x"], frame["y"], frame["width"], frame["height"],
                                    source["text"], source["reading"]))
        width = math.ceil(tree["contentSize"]["width"])
        height = math.ceil(tree["contentSize"]["height"])
        self.canvas.set_size_request(width, height)
        self.surface.set_size_request(width, height)
        popup_width = int(layout["popupWidth"])
        area = self.work_area()
        tree_only = self.display["mode"] == "tree"
        list_height = min(CandidateNavigation.MAXIMUM_LIST_HEIGHT, area.height // 3)
        self.navigation.update(self.snapshot, font_size=self.font_size, list_height=list_height, compact=tree_only)
        show_menu = not tree_only or self.navigation.expanded
        self.composition_title.set_visible(show_menu)
        self.composition.set_visible(show_menu)
        self.disclosures.set_visible(show_menu)
        self.content.reorder_child(self.scroll, 5 if show_menu else 0)
        self.update_composition(popup_width)
        self.update_disclosures()
        self.scroll.set_min_content_width(popup_width)
        if self.tree_expanded:
            self.update_actions()
            self.surface.show_all()
            self.scroll.get_child().show()
        self.refresh_details()
        self.details.get_child().show_all()
        self.viewport.show_all()
        self.scroll.set_visible(self.tree_expanded)
        self.details.set_visible(self.details_expanded)
        self.fit_content_height(width=popup_width, available_height=area.height)
        requested_height = self.content.get_preferred_height_for_width(popup_width)[1]
        self.request_core_layout(popup_height=requested_height, measured_width=popup_width)

    def apply_placement(self, layout, *, measured_width, requested_height):
        if int(layout["popupWidth"]) != measured_width:
            # Core gave up document alignment for a sideways popup; measure
            # the popup again at its new width before placing it.
            self.apply_tree_layout(layout)
            return
        placement = layout.get("placement")
        if placement is None:
            self.suspend()
            return
        self.layout = layout
        self.placement = placement
        self.placement_side = placement["side"]
        width, height = int(placement["width"]), int(placement["height"])
        if height < requested_height:
            self.fit_content_height(width=width, available_height=height)
        self.limit_viewport(width=width, height=height)
        self.resize(width, height)
        self.show()
        self.announcements.update(self.snapshot)
        self.position()
        self.canvas.queue_draw()
        self.reveal_focus()

    def reveal_focus(self):
        focus = self.snapshot.get("focusedNode")
        key = (self.snapshot.get("contextId"), self.snapshot.get("selection"), focus)
        if not self.tree_expanded or focus is None or key == self.focus_key:
            return
        self.focus_key = key
        self.cancel_scroll()

        def reveal():
            self.scroll_idle = None
            for kind, index, x, y, width, height, *_ in self.rectangles:
                if kind == "node" and index == focus:
                    self.scroll.get_hadjustment().clamp_page(max(0, x - 8), x + width + 22)
                    self.scroll.get_vadjustment().clamp_page(max(0, y - 8), y + height + 16)
                    break
            return GLib.SOURCE_REMOVE
        self.scroll_idle = GLib.idle_add(reveal)

    def update_composition(self, width):
        listing = self.display.get("list") or {}
        title = listing.get("title", message("candidate.proposal"))
        self.composition_title.set_text(title)
        self.composition.get_accessible().set_name(title)
        self.composition.update(listing.get("commitText", self.snapshot.get("preedit", "")),
                                font_size=self.font_size + 2, width=width)
        self.composition.get_child().show_all()
        remaining = listing.get("remainingText") or ""
        self.remaining.update(remaining, font_size=self.font_size, width=width)
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
            self.disclosure_actions[name].show()

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

    def displayed_node(self, node_id):
        return next((node for node in self.drawn_display.get("nodes", []) if node["id"] == node_id), None)

    def update_actions(self):
        visible = {(item[0], item[1]) for item in self.rectangles}
        for identity in list(self.actions):
            if identity not in visible:
                self.actions.pop(identity).destroy()
                if self.hovered_action == identity:
                    self.hovered_action = None
        for kind, index, x, y, width, height, *_ in self.rectangles:
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
            button.activation_token = (self.drawn_snapshot.get("contextId"), self.drawn_snapshot.get("generation"),
                                       self.drawn_snapshot.get("selection"))
            button.set_size_request(max(1, int(width)), max(1, int(height)))
            node = self.displayed_node(index)
            button.set_tooltip_text(node["accessibleName"] + "\n" + node["accessibleDescription"])
            button.update_accessibility(node["accessibleName"], selected=node["selected"],
                                        description=node["accessibleDescription"])

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
            return self.show_details(self.hovered_action[1])
        return self.show_details(self.display.get("detailNode"))

    def show_details(self, node_id):
        node = self.displayed_node(node_id)
        width = self.scroll.get_min_content_width()
        self.details.update(node["detailText"] if node else "", font_size=self.font_size, width=width)
        return False

    def show_candidate_details(self, item):
        if item is None:
            return self.refresh_details()
        self.details.update(item["detailText"], font_size=self.font_size, width=self.scroll.get_min_content_width())
        return False

    def scroll_details(self, forward):
        if not self.get_visible():
            return False
        if not self.details_expanded:
            self.details_expanded = True
            self.update(self.snapshot)
        self.details.scroll_page(forward)
        return True

    @property
    def shows_current_layout(self):
        # Selecting from a layout of an older snapshot could target another candidate.
        return self.get_visible() and self.placement is not None

    def activate(self, identity, source):
        # Removed ATK objects may outlive a candidate update in the AT client.
        if self.shows_current_layout and self.tree_expanded and self.actions.get(identity) is source:
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

    def limit_viewport(self, *, width, height):
        self.viewport.set_min_content_width(0)
        self.viewport.set_max_content_width(width)
        self.viewport.set_min_content_width(width)
        self.viewport.set_min_content_height(0)
        self.viewport.set_max_content_height(height)
        natural_height = self.content.get_preferred_height_for_width(width)[1]
        self.viewport.set_min_content_height(min(height, natural_height))

    def position(self):
        placement = self.placement
        if placement is None:
            return
        width, height = int(placement["width"]), int(placement["height"])
        if self.get_size() != (width, height):
            # Keep Core's size when GTK allocates the popup differently.
            self.fit_content_height(width=width, available_height=height)
            self.limit_viewport(width=width, height=height)
            self.resize(width, height)
        area = self.work_area()
        self.move(int(placement["x"]), int(placement["y"]))
        tree = self.layout["tree"]
        self.layout_diagnostics = {
            "renderer": "gtk", "source": "ibus-caret",
            "mode": "aligned" if tree["aligned"] else "compact",
            "reason": tree["reason"],
            "cursor": self.current_caret, "workArea": [area.x, area.y, area.width, area.height],
            "popup": [int(placement["x"]), int(placement["y"]), width, height],
            "side": placement["side"],
            "coordinateSpace": "gtk-logical",
            "ibusCursor": self.caret_location or self.location,
            "ibusCoordinateScale": self.ibus_coordinate_scale,
        }

    def text_layout(self, text, font_size):
        layout = self.canvas.create_pango_layout(text)
        font = Pango.FontDescription("Sans")
        font.set_absolute_size(font_size * Pango.SCALE)
        layout.set_font_description(font)
        return layout

    def measure(self, text, *, font_size=None):
        # Candidate preferences must not change PreeditAnchor's reference
        # measurement mid-composition, so it uses the document size by default.
        return self.text_layout(text, font_size or DOCUMENT_REFERENCE_FONT_SIZE).get_pixel_size()[0]

    def measure_height(self, text, *, font_size):
        return self.text_layout(text, font_size).get_pixel_size()[1]

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
        if not self.layout:
            return False
        tree = self.layout["tree"]
        displayed = {node["id"]: node for node in self.drawn_display.get("nodes", [])}
        for edge in tree["edges"]:
            active = displayed.get(edge["node"], {}).get("selected", False)
            context.set_source_rgb(*self.theme.rgb("text" if active else "border"))
            context.set_line_width(3 if active else 1)
            context.set_dash([] if active else [2, 3])
            start, end = edge["start"], edge["end"]
            middle = (start["x"] + end["x"]) / 2
            context.move_to(start["x"], start["y"])
            context.curve_to(middle, start["y"], middle, end["y"], end["x"], end["y"])
            context.stroke()
        context.set_dash([])
        context.set_source_rgb(*self.theme.rgb("text"))
        context.arc(tree["rootAnchor"]["x"], tree["rootAnchor"]["y"], 3, 0, 6.2832)
        context.fill()
        sources = {node["id"]: node for node in self.drawn_snapshot.get("nodes", [])}
        for node in tree["nodes"]:
            self.draw_node(context, node, displayed[node["id"]], sources[node["id"]])
        return False

    def draw_node(self, context, layout, displayed, source):
        tree = self.layout["tree"]
        metrics = tree["metrics"]
        frame, text_frame = layout["frame"], layout["textFrame"]
        x, y, width, height = frame["x"], frame["y"], frame["width"], frame["height"]
        active = displayed["selected"]
        context.set_source_rgb(*self.theme.rgb("selection" if active else "surface"))
        radius = NODE_CORNER_RADIUS
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
        if displayed["focused"]:
            underline = text_frame["y"] + text_frame["height"] - 4
            context.set_source_rgb(*self.theme.rgb("selectionText" if active else "text"))
            context.set_line_width(2)
            context.move_to(x + FOCUS_UNDERLINE_INSET, underline)
            context.line_to(x + width - FOCUS_UNDERLINE_INSET, underline)
            context.stroke()
        color = self.theme.rgb("selectionText" if active else "text")
        self.text(context, source["text"], text_frame, metrics["fontSize"], color,
                  aligned=tree["textAlignment"] == "leading")
        if layout.get("scoreFrame") and source.get("scorePresentation"):
            draw_score_badge(context, source["scorePresentation"], layout["scoreFrame"],
                             metrics=metrics, theme=self.theme)
        if layout.get("numberFrame") and displayed.get("number") is not None:
            self.text(context, str(displayed["number"]), layout["numberFrame"], metrics["numberFontSize"],
                      color, aligned=True)

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
    def text(context, text, frame, size, color, *, aligned):
        layout = TreePanel.fitted_layout(context, text, frame["width"], size)
        layout.set_alignment(Pango.Alignment.LEFT if aligned else Pango.Alignment.CENTER)
        context.set_source_rgb(*color)
        context.move_to(frame["x"], frame["y"] + (frame["height"] - layout.get_pixel_size()[1]) / 2)
        PangoCairo.show_layout(context, layout)

    def tooltip(self, _widget, x, y, _keyboard_mode, tooltip):
        sources = {node["id"]: node for node in self.drawn_snapshot.get("nodes", [])}
        for kind, index, left, top, width, height, *_ in self.rectangles:
            if kind == "node" and left <= x <= left + width and top <= y <= top + height:
                presentation = sources[index].get("scorePresentation") or {}
                tooltip.set_text("\n".join(filter(None, [self.displayed_node(index)["accessibleName"],
                                                         presentation.get("detailDescription")])))
                return True
        return False

    def click(self, _widget, event):
        if not self.shows_current_layout or not self.tree_expanded or event.button != 1:
            return False
        for kind, index, x, y, width, height, *_ in reversed(self.rectangles):
            if x <= event.x <= x + width and y <= event.y <= y + height:
                self.select(kind, index, False)
                return True
        return False
