"""Render acknowledged reading candidates without publishing input effects."""
import logging

import gi

gi.require_version("IBus", "1.0")
gi.require_version("Gdk", "3.0")
gi.require_version("Atk", "1.0")
from gi.repository import Atk, Gdk, IBus

from .candidate_announcements import CandidateAnnouncements
from .preedit_anchor import PreeditAnchor
from .reading_candidate_display import ReadingCandidateDisplay
from .reading_protocol import ReadingNotice
from .shell_surface import surface
from .tree_panel import TreePanel


CANDIDATE_PAGE_SIZE = 9  # The native lookup and Core share number-key pages.
LOGGER = logging.getLogger(__name__)


class ReadingCandidateRenderer:
    def __init__(self, engine, *, select_candidate, panel=None, shell=None):
        self.engine = engine
        self.select_candidate = select_candidate
        self.display = ReadingCandidateDisplay(engine.context_id)
        self.panel = panel if panel is not None else TreePanel(self.choose)
        self.shell = shell if shell is not None else surface()
        self.anchor = PreeditAnchor(self.panel.measure)
        self._publication = None
        self.closed = False
        self.announcements = CandidateAnnouncements(
            lambda announcement: self.panel.get_accessible().emit("notification", announcement, Atk.Live.POLITE),
        )

    @property
    def snapshot(self):
        return self.display.snapshot

    @property
    def publishing(self):
        return self._publication is not None

    def input_changed(self, snapshot):
        self.anchor.update(snapshot.get("preedit", ""), snapshot.get("cursor", 0),
                           committed=bool(snapshot.get("commits")))

    def publish(self, snapshot, candidate_view):
        if self.closed:
            return
        frontend = self.engine.frontend
        if not frontend.focused or frontend.blocked or self.engine.private:
            self.end_context()
            return
        displayed = self.display.update(snapshot, candidate_view, reference=frontend.reference)
        self._present(displayed)

    def _present(self, snapshot):
        publication = object()
        self._publication = publication
        focus = self.engine.frontend.focus

        def current():
            frontend = self.engine.frontend
            return (self._publication is publication and not self.closed and not self.engine.private
                    and frontend.focused and not frontend.blocked and frontend.focus is focus)

        try:
            self._render(snapshot, current)
        except Exception:
            if self._publication is publication:
                self.display.suspend()
            raise
        finally:
            if self._publication is publication:
                self._publication = None

    def _render(self, snapshot, current):
        positioned = self._position(snapshot)
        if not current():
            return
        candidates = positioned.get("candidates", [])
        if not candidates:
            self._hide()
            return
        tree_enabled = self.engine.candidate_tree_enabled
        shell_tree = tree_enabled and self.shell.show(self.engine, positioned, self.panel.location)
        if not current():
            return
        if not shell_tree:
            self.shell.hide(self.engine)
        if shell_tree:
            self.announcements.reset()
            steps = (self.panel.dismiss, self.engine.hide_lookup_table)
        elif "Wayland" in type(Gdk.Display.get_default()).__name__ or not tree_enabled:
            steps = (self.panel.dismiss, lambda: self._lookup(positioned),
                     lambda: self.announcements.update(positioned))
        else:
            self.announcements.reset()
            steps = (self.engine.hide_lookup_table, lambda: self.panel.update(positioned))
        for display in steps:
            if not current():
                return
            display()

    def _lookup(self, snapshot):
        table = self.engine.table
        table.clear()
        for candidate in snapshot["candidates"]:
            table.append_candidate(IBus.Text.new_from_string(candidate["text"]))
        for index in range(CANDIDATE_PAGE_SIZE):
            label = str(index + 1) if snapshot.get("showCandidateIndex") else ""
            table.set_label(index, IBus.Text.new_from_string(label))
        selected = snapshot.get("selection")
        table.set_cursor_pos(selected if selected is not None else 0)
        table.set_cursor_visible(selected is not None)
        self.engine.update_lookup_table(table, True)

    def _position(self, snapshot):
        nodes = {node["id"]: node for node in snapshot.get("nodes", [])}
        words = [nodes[column[0]]["text"] for column in snapshot.get("columns", []) if column]
        geometry = self.anchor.geometry(words)
        self.panel.location = self.anchor.position if geometry else (self.anchor.location or (0, 0, 0, 0))
        self.panel.caret_location = self.anchor.location
        return {**snapshot, "wordGeometry": geometry}

    def locate(self, rectangle):
        self.anchor.locate(rectangle)
        if not self.closed and not self.publishing and self.display.active and not self.engine.frontend.pending:
            self._refresh()

    def choose(self, operation, index, submit):
        frontend = self.engine.frontend
        if (self.closed or self.publishing or not frontend.focused or frontend.blocked
                or frontend.pending or self.engine.private or type(submit) is not bool):
            return False
        retained = (frontend.candidate_view or {}).get("candidateReference")
        selection = self.display.selection(operation, index, generation=self.display.generation,
                                           reference=frontend.reference, retained_reference=retained)
        if selection is None:
            return False
        # Retire all duplicate pointer/AT actions before queuing the one formal
        # select or atomic commit-candidate operation through the input owner.
        self.suspend()
        return self.select_candidate(selection, submit=submit)

    def lookup_clicked(self, index):
        if type(index) is not int or not 0 <= index < CANDIDATE_PAGE_SIZE:
            return False
        start = self.snapshot.get("candidatePage", {}).get("start", 0)
        return self.choose("select", start + index, True)

    def suspend(self):
        self.display.suspend()
        self._publication = None
        self._clear_views((lambda: self.shell.suspend(self.engine), self.panel.suspend,
                           self.engine.hide_lookup_table))

    def renderer_lost(self):
        if self.closed or self.publishing or self.engine.frontend.pending:
            return
        self._refresh()

    def _refresh(self):
        try:
            self.publish(self.engine.frontend.snapshot, self.engine.frontend.candidate_view)
        except Exception:
            LOGGER.exception("Could not refresh reading candidates")
            try:
                self.engine.notice(ReadingNotice("reading_view_unavailable"))
            except Exception:
                LOGGER.exception("Could not report the reading display failure")

    def scroll_details(self, forward):
        return self.display.active and (self.shell.scroll_details(self.engine, forward)
                                       or self.panel.scroll_details(forward))

    def _hide(self):
        self._clear_views((lambda: self.shell.hide(self.engine), self.panel.dismiss, self.engine.hide_lookup_table))
        self.announcements.reset()

    def _clear_views(self, views):
        # Actions are already retired. One renderer cannot prevent the others
        # from clearing, nor can a cleanup error strand an original key reply.
        generation, focus = self.display.generation, self.engine.frontend.focus
        for clear in views:
            if self.display.generation != generation or self.engine.frontend.focus is not focus:
                return
            try:
                clear()
            except Exception:
                LOGGER.exception("Could not retire a reading candidate view")

    def dismiss(self):
        self._publication = None
        self.display.retire()
        self._hide()

    def end_context(self):
        self.anchor.update("", 0)
        self.dismiss()

    def close(self):
        if self.closed:
            return
        self.closed = True
        self.end_context()
        self.panel.destroy()
