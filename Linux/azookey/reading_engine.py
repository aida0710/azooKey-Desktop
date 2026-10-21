"""Explicit development IBus adapter for independent reading and candidate workers."""
import logging
import time

import gi
gi.require_version("IBus", "1.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, GLib, IBus

from .i18n import text
from .input_preview import is_native_key
from .keymap import translate
from .native_key_dispatch import dispatch_native_key
from .reading_candidate_renderer import CANDIDATE_PAGE_SIZE, ReadingCandidateRenderer
from .reading_frontend import ReadingFrontend
from .reading_protocol import ReadingNotice
from .reading_settings_bootstrap import ReadingSettingsBootstrap


LANGUAGE_DOUBLE_TAP_SECONDS = 0.5  # Preserve the existing desktop language-key gesture.
SURROUNDING_CONTEXT_LIMIT = 100  # Use the same bounded context as the ordinary IBus adapter.
LOGGER = logging.getLogger(__name__)


class ReadingEngine(IBus.Engine):
    __gtype_name__ = "AzooKeyReadingDevelopmentEngine"

    def __init__(self, *args, **kwargs):
        kwargs.update(has_focus_id=True, active_surrounding_text=True)
        super().__init__(*args, **kwargs)
        self.native_key_reply = None
        self.native_key_passthrough = False
        self.destroyed = False
        self.private = False
        self.sensitive = False
        self.focus_identity = None
        self.last_language_key = (None, 0)
        self.left = self.right = ""
        self.context_changed = False
        self.table = IBus.LookupTable.new(CANDIDATE_PAGE_SIZE, 0, True, True)
        self.table.set_orientation(IBus.Orientation.VERTICAL)
        self.settings_bootstrap = ReadingSettingsBootstrap()
        self.renderer = None
        self.frontend = ReadingFrontend(
            GLib.idle_add, render_input=self.render_input,
            render_candidates=self.render_candidates, notify=self.notice,
            settings_provider=self.load_settings,
        )
        self.renderer = ReadingCandidateRenderer(self, select_candidate=self.frontend.select_candidate)

    @property
    def context_id(self):
        return self.frontend.context

    @property
    def focused(self):
        return self.frontend.focused

    @property
    def snapshot(self):
        return self.renderer.snapshot

    @property
    def panel(self):
        return self.renderer.panel

    @property
    def candidate_tree_enabled(self):
        return bool((self.frontend.coordinator.settings or {}).get("tree", False))

    def load_settings(self, defaults):
        values = self.settings_bootstrap.load(defaults)
        if self.settings_bootstrap.problem is not None:
            try:
                self.notice(ReadingNotice("reading_settings_recovery"))
            except Exception:
                LOGGER.exception("Could not display settings recovery notice")
        return values

    def do_service_method_call(self, connection, sender, object_path, interface,
                               method, parameters, invocation):
        dispatch_native_key(self, (connection, sender, object_path, interface, method, parameters, invocation))

    def do_process_key_event(self, keyval, keycode, state):
        if (self.native_key_passthrough or self.destroyed or self.private
                or not self.frontend.focused or self.native_key_reply is None):
            return False
        if (not state and keyval in (0xFF55, 0xFF56) and not self.frontend.pending
                and self.renderer.scroll_details(keyval == 0xFF56)):
            return True
        event = translate(keyval, state, Gdk.keyval_to_unicode(keyval))
        if event is None:
            if self.frontend.pending:
                self.frontend.barrier(self.native_key_reply.defer())
                return True
            return False
        if not self.frontend.pending and is_native_key(event, self.frontend.snapshot):
            return False
        if self.context_changed and not self.frontend.pending and not self.frontend.snapshot.get("preedit"):
            self.frontend.focus_in(self.surroundings())
            self.context_changed = False
        previous, timestamp = self.last_language_key
        now = time.monotonic()
        language_key = event["keyCode"] in (102, 104)
        double_tap = language_key and previous == event["keyCode"] and now - timestamp < LANGUAGE_DOUBLE_TAP_SECONDS
        self.last_language_key = ((event["keyCode"], now) if language_key and not double_tap else (None, 0))
        self.renderer.suspend()
        self.frontend.key(event, self.native_key_reply.defer(), double_tap=double_tap)
        return True

    def surroundings(self):
        return {"leftContext": self.left, "rightContext": self.right, "privateInput": self.sensitive}

    def do_focus_in(self):
        self.activate(None)

    def do_focus_in_id(self, object_path, client):
        self.activate((object_path, client))

    def activate(self, identity):
        if self.frontend.focused and self.focus_identity == identity:
            return
        self.focus_identity = identity
        self.get_surrounding_text()
        self.frontend.focus_in(self.surroundings())
        self.context_changed = False

    def do_focus_out(self):
        self.frontend.focus_out()
        if not self.frontend.focused:
            self.focus_identity = None
            self.left = self.right = ""
            self.last_language_key = (None, 0)

    def do_focus_out_id(self, _object_path):
        self.do_focus_out()

    def do_reset(self):
        self.frontend.reset()

    def do_disable(self):
        self.do_focus_out()

    def do_set_surrounding_text(self, value, cursor, anchor):
        IBus.Engine.do_set_surrounding_text(self, value, cursor, anchor)
        content = value.get_text()
        self.left = content[:min(cursor, anchor)][-SURROUNDING_CONTEXT_LIMIT:]
        self.right = content[max(cursor, anchor):][:SURROUNDING_CONTEXT_LIMIT]
        self.context_changed = True

    def do_set_content_type(self, purpose, hints):
        private = purpose in (IBus.InputPurpose.PASSWORD, IBus.InputPurpose.PIN)
        sensitive = private or bool(hints & IBus.InputHints.PRIVATE)
        if (private, sensitive) == (self.private, self.sensitive):
            return
        self.private, self.sensitive = private, sensitive
        if self.frontend.focused:
            # Do not let a pending candidate or learning request retain the old
            # privacy authority when the client changes its content type.
            self.frontend.reset()
            self.frontend.focus_in(self.surroundings())
        self.context_changed = False

    def render_input(self, snapshot):
        for committed in snapshot.get("commits", []):
            self.commit_text(IBus.Text.new_from_string(committed))
        preedit = snapshot.get("preedit", "")
        if self.renderer is not None:
            self.renderer.input_changed(snapshot)
        focus_mode = (IBus.PreeditFocusMode.CLEAR if snapshot.get("inputState") == "unicodeInput"
                      else IBus.PreeditFocusMode.COMMIT)
        self.update_preedit_text_with_mode(
            IBus.Text.new_from_string(preedit), snapshot.get("cursor", 0), bool(preedit), focus_mode,
        )

    def render_candidates(self, snapshot, candidate_view):
        if self.renderer is not None:
            self.renderer.publish(snapshot, candidate_view)

    def choose(self, operation, index, submit):
        return self.renderer.choose(operation, index, submit)

    def candidate_renderer_lost(self):
        self.renderer.renderer_lost()

    def do_set_cursor_location(self, x, y, width, height):
        self.renderer.locate((x, y, width, height))

    def do_candidate_clicked(self, index, button, state):
        if button == 1:
            self.renderer.lookup_clicked(index)

    def move_candidate(self, offset):
        candidates = self.snapshot.get("candidates", [])
        if candidates:
            index = min(len(candidates) - 1, max(0, (self.snapshot.get("selection") or 0) + offset))
            self.choose("select", index, False)

    def do_page_up(self):
        self.move_candidate(-CANDIDATE_PAGE_SIZE)

    def do_page_down(self):
        self.move_candidate(CANDIDATE_PAGE_SIZE)

    def do_cursor_up(self):
        self.move_candidate(-1)

    def do_cursor_down(self):
        self.move_candidate(1 if self.snapshot.get("selection") is not None else 0)

    def notice(self, notice):
        if notice.code == "candidate_learning_completed":
            return
        settings_messages = {
            "reading_settings_unsupported": "reading.settingsUnsupported",
            "reading_settings_unavailable": "reading.settingsUnavailable",
            "reading_settings_recovery": "reading.settingsRecovery",
        }
        if notice.code in settings_messages:
            key = settings_messages[notice.code]
        elif notice.code == "reading_view_unavailable":
            key = "reading.displayUnavailable"
        else:
            key = "reading.resetRequired" if self.frontend.blocked else "reading.operationUnavailable"
        self.update_auxiliary_text(IBus.Text.new_from_string(text(key)), True)

    def close_worker(self):
        try:
            self.frontend.close()
        finally:
            if self.renderer is not None:
                self.renderer.close()

    def do_destroy(self):
        if self.destroyed:
            return
        self.destroyed = True
        self.close_worker()
        IBus.Engine.do_destroy(self)
