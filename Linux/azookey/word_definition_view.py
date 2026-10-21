"""Nonfocusable, bounded dictionary summary and optional full meanings/examples."""
import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gio, Gtk, Pango

from .candidate_detail import CandidateDetail
from .candidate_navigation import CandidateNavigation
from .i18n import text as message
from .word_definition_provider import WORDNET_URL
from .word_definition_availability import has_definition

# Keep the default menu to a short definition; complete entries stay scrollable.
SUMMARY_CHARACTER_LIMIT = 96
SUMMARY_MAXIMUM_HEIGHT = 144
# Two measured body lines remain useful even when the entire popup must scroll.
SUMMARY_MINIMUM_LINES = 2
# Full entries grow only their independent card to roughly 330px with controls.
FULL_ENTRY_MAXIMUM_HEIGHT = 280
TERMINAL_DEFINITION_STATES = frozenset(("found", "notFound", "unavailable", "error"))


def definition_target_key(target):
    if target is None:
        return None
    # A fresh request generation may keep the same word in the same control.
    return (target.context, target.node_id, target.candidate_index, target.word, target.reading)


def definition_text(response, *, expanded=False, include_heading=True):
    if not response:
        return message("candidate.definition.chooseWord")
    word = response.get("word", "")
    heading = message("candidate.definition.word", word=word, reading=response.get("reading", "")) if include_heading else ""
    prefix = heading + "\n" if heading else ""
    status = response.get("status")
    if status != "found":
        key = status if status in ("loading", "unavailable", "error", "notFound") else "error"
        return prefix + message("candidate.definition." + key, word=word)
    senses = response.get("senses", [])
    if not senses:
        return prefix + message("candidate.definition.notFound", word=word)
    if not expanded:
        first = senses[0]["definitions"][0]
        return prefix + (first[:SUMMARY_CHARACTER_LIMIT] + "…" if len(first) > SUMMARY_CHARACTER_LIMIT else first)
    lines = [heading]
    if response.get("readingUnspecified"):
        lines.append(message("candidate.definition.readingNote"))
    for index, sense in enumerate(senses, 1):
        lines.append(f"{index}. " + "\n".join(sense["definitions"]))
        if sense.get("examples"):
            lines.append(message("candidate.definition.examples") + "\n" + "\n".join(sense["examples"]))
        if sense.get("synonyms"):
            lines.append(message("candidate.definition.synonyms") + "\n" + "、".join(sense["synonyms"]))
    lines += [response.get("copyright", ""), WORDNET_URL]
    return "\n".join(line for line in lines if line)


class WordDefinitionSource(Gtk.LinkButton):
    def __init__(self, is_current):
        super().__init__(uri=WORDNET_URL, label=message("candidate.definition.sourceShort"))
        self.is_current = is_current
        self.get_accessible().set_name(message("candidate.definition.source"))
        self.set_can_focus(False)
        self.set_focus_on_click(False)
        self.set_size_request(-1, CandidateNavigation.MINIMUM_CANDIDATE_HEIGHT)

    def do_activate_link(self):
        # A retired Gtk.Widget may lose connected handlers while AT retains its
        # object. Override the default action so it can never open an old link.
        if self.is_current(self):
            try:
                Gio.AppInfo.launch_default_for_uri(WORDNET_URL, None)
            except Exception:
                pass  # An explicitly requested source link must not interrupt typing.
        return True


class WordDefinitionView(Gtk.Box):
    def __init__(self, changed):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        self.set_no_show_all(True)
        self.changed = changed
        self.expanded = False
        self.response = None
        self.retained_response = None
        self.retained_target_key = None
        self.active = False
        self.target_identity = None
        self.header = Gtk.Box(spacing=4, margin_start=8, margin_end=8, margin_bottom=8)
        self.word_heading = Gtk.Label(xalign=0)
        self.word_heading.set_margin_start(CandidateDetail.HORIZONTAL_MARGIN)
        self.word_heading.set_margin_end(CandidateDetail.HORIZONTAL_MARGIN)
        self.word_heading.set_ellipsize(Pango.EllipsizeMode.END)
        self.word_heading.set_width_chars(1)
        self.word_heading.set_can_focus(False)
        self.word_heading.get_style_context().add_class("candidate-secondary")
        self.toggle = None
        self.source = None
        self.replace_actions()
        self.summary = CandidateDetail(minimum_height=0, maximum_height=SUMMARY_MAXIMUM_HEIGHT)
        self.details = CandidateDetail(minimum_height=0)
        self.pack_start(self.word_heading, False, False, 0)
        self.pack_start(self.summary, False, False, 0)
        self.pack_start(self.details, False, False, 0)
        self.pack_start(self.header, False, False, 0)
        for widget in (self.header, self.word_heading, self.summary, self.details):
            widget.set_no_show_all(True)

    def replace_actions(self):
        for child in self.header.get_children():
            child.destroy()
        self.toggle = CandidateNavigation.button(lambda source: self.toggle_details(source))
        self.toggle.get_style_context().add_class("candidate-disclosure")
        self.toggle.set_size_request(-1, CandidateNavigation.MINIMUM_CANDIDATE_HEIGHT)
        self.header.pack_start(self.toggle, False, False, 0)
        self.source = WordDefinitionSource(lambda source: source is self.source and self.active and source.get_mapped()
                                           and self.response and self.response.get("status") == "found")
        self.header.pack_end(self.source, False, False, 0)

    def update(self, response, *, active, font_size, width, target_identity=None):
        if target_identity != self.target_identity:
            self.target_identity = target_identity
            self.replace_actions()
        target_key = definition_target_key(target_identity)
        if (active and response and response.get("status") == "loading" and self.retained_response
                and target_key is not None and target_key == self.retained_target_key
                and (response.get("word"), response.get("reading")) ==
                (self.retained_response.get("word"), self.retained_response.get("reading"))):
            # Shrinking to a loading caption can clamp the outer scroll before
            # the same result returns. Retain all visible content and controls.
            response = self.retained_response
        elif active and response and response.get("status") in TERMINAL_DEFINITION_STATES:
            self.retained_response = response
            self.retained_target_key = target_key
        else:
            self.retained_response = None
            self.retained_target_key = None
        self.response = response
        self.active = active
        self.font_size = font_size
        toggle_key = "candidate.definition.closeFull" if self.expanded else "candidate.definition.openFull"
        self.toggle.set_label(("▾ " if self.expanded else "▸ ") + message(toggle_key))
        self.toggle.get_accessible().set_name(message(toggle_key))
        heading = (response or {}).get("word", "")
        self.word_heading.set_text(heading)
        attributes = Pango.AttrList()
        attributes.insert(Pango.attr_size_new_absolute(round(font_size * Pango.SCALE)))
        self.word_heading.set_attributes(attributes)
        self.summary.update(definition_text(response, include_heading=False), font_size=font_size, width=width)
        self.details.update(definition_text(response, expanded=True), font_size=font_size, width=width)
        # The header opts out of its parent's show_all to keep live input compact.
        self.toggle.show_all()
        self.summary.get_child().show_all()
        self.details.get_child().show_all()
        active = active and has_definition(response)
        self.set_visible(active)
        self.header.set_visible(active)
        self.word_heading.set_visible(active and not self.expanded and bool(response))
        self.summary.set_visible(active and not self.expanded)
        self.details.set_visible(active and self.expanded)
        found = bool(response and response.get("status") == "found")
        self.toggle.set_sensitive(found)
        self.source.set_visible(active and found)
        controls = [child for child in self.header.get_children() if child.get_visible()]
        controls_width = sum(child.get_preferred_width()[1] for child in controls)
        controls_width += max(0, len(controls) - 1) * self.header.get_spacing()
        # System text scaling also enlarges these native buttons. Wrap only
        # the controls, never move the dictionary below the candidate column.
        header_width = width - self.header.get_margin_start() - self.header.get_margin_end()
        self.header.set_orientation(Gtk.Orientation.VERTICAL if controls_width > header_width else Gtk.Orientation.HORIZONTAL)

    def fit_height(self, *, width, available_height):
        pane = self.details if self.expanded else self.summary
        controls = (self.header, self.word_heading)
        controls_height = sum(widget.get_preferred_height_for_width(width)[1]
                              for widget in controls if widget.get_visible())
        visible_children = sum(widget.get_visible() for widget in self.get_children())
        controls_height += max(0, visible_children - 1) * self.get_spacing()
        line = self.summary.label.create_pango_layout("あ")
        line.set_attributes(self.word_heading.get_attributes())
        minimum_body = SUMMARY_MINIMUM_LINES * line.get_pixel_size()[1]
        # A short work area scrolls the card rather than crushing a meaning into
        # a few pixels. The dictionary's own viewport handles long entries.
        limit = max(minimum_body, available_height - controls_height)
        limit = min(FULL_ENTRY_MAXIMUM_HEIGHT if self.expanded else SUMMARY_MAXIMUM_HEIGHT, limit)
        pane.set_min_content_height(0)
        pane.set_max_content_height(max(1, limit))
        natural_height = pane.get_child().get_preferred_height_for_width(width)[1]
        pane.set_min_content_height(min(limit, natural_height))

    def toggle_details(self, source):
        if source is self.toggle and self.active and self.get_mapped() and self.response and self.response.get("status") == "found":
            self.expanded = not self.expanded
            self.changed()

    def reset(self):
        self.expanded = False
        self.active = False
        self.response = None
        self.retained_response = None
        self.retained_target_key = None
        self.target_identity = None
        self.replace_actions()

    def apply_palette(self, palette):
        self.summary.apply_palette(palette)
        self.details.apply_palette(palette)
