"""Nonfocusable, bounded dictionary summary and optional full meanings/examples."""
import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gio, Gtk

from .candidate_detail import CandidateDetail
from .candidate_navigation import CandidateNavigation
from .i18n import text as message
from .word_definition_provider import WORDNET_URL

# Keep the default menu to a short definition; complete entries stay scrollable.
SUMMARY_CHARACTER_LIMIT = 96
SUMMARY_MAXIMUM_HEIGHT = 96


def definition_text(response, *, expanded=False):
    if not response:
        return message("candidate.definition.chooseWord")
    word = response.get("word", "")
    heading = message("candidate.definition.word", word=word, reading=response.get("reading", ""))
    status = response.get("status")
    if status != "found":
        key = status if status in ("loading", "unavailable", "error", "notFound") else "error"
        return heading + "\n" + message("candidate.definition." + key, word=word)
    senses = response.get("senses", [])
    if not senses:
        return heading + "\n" + message("candidate.definition.notFound", word=word)
    if not expanded:
        first = senses[0]["definitions"][0]
        return heading + "\n" + (first[:SUMMARY_CHARACTER_LIMIT] + "…" if len(first) > SUMMARY_CHARACTER_LIMIT else first)
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
        self.last_definition = None
        self.active = False
        self.target_identity = None
        self.header = Gtk.Box(spacing=4)
        self.toggle = None
        self.source = None
        self.replace_actions()
        self.summary = CandidateDetail(minimum_height=0, maximum_height=SUMMARY_MAXIMUM_HEIGHT)
        self.details = CandidateDetail(minimum_height=0)
        self.pack_start(self.header, False, False, 0)
        self.pack_start(self.summary, False, False, 0)
        self.pack_start(self.details, False, False, 0)
        for widget in (self.header, self.summary, self.details):
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
        full_response = response
        if (response and response.get("status") == "loading" and self.last_definition
                and (response.get("word"), response.get("reading")) == (self.last_definition.get("word"), self.last_definition.get("reading"))):
            # A new generation of the same word can reuse the visible text while
            # its cached result is delivered, without resetting the reading position.
            full_response = self.last_definition
        elif response and response.get("status") == "found":
            self.last_definition = response
        else:
            self.last_definition = None
        self.response = response
        self.active = active
        self.toggle.set_label(("▾ " if self.expanded else "▸ ") + message("candidate.definition.title"))
        self.toggle.get_accessible().set_name(message("candidate.definition.close" if self.expanded else "candidate.definition.open"))
        self.summary.update(definition_text(response), font_size=font_size, width=width)
        self.details.update(definition_text(full_response, expanded=True), font_size=font_size, width=width)
        # The header opts out of its parent's show_all to keep live input compact.
        self.toggle.show_all()
        self.summary.get_child().show_all()
        self.details.get_child().show_all()
        self.set_visible(active)
        self.header.set_visible(active)
        self.summary.set_visible(active and not self.expanded)
        self.details.set_visible(active and self.expanded)
        found = bool(response and response.get("status") == "found")
        self.toggle.set_sensitive(found)
        self.source.set_visible(active and found)

    def toggle_details(self, source):
        if source is self.toggle and self.active and self.get_mapped() and self.response and self.response.get("status") == "found":
            self.expanded = not self.expanded
            self.changed()

    def reset(self):
        self.expanded = False
        self.active = False
        self.response = None
        self.last_definition = None
        self.target_identity = None
        self.replace_actions()

    def apply_palette(self, palette):
        self.summary.apply_palette(palette)
        self.details.apply_palette(palette)
