"""Real Core and Engine; only the AI provider and fixture controls are replaced."""
import json
import pathlib
import runpy
import sys

import gi
gi.require_version("Gdk", "3.0")
gi.require_version("Gtk", "3.0")
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from azookey import engine as engine_module
from gi.repository import Gdk, GLib, IBus


class IMEShortcutFixtureEngine(engine_module.Engine):
    __gtype_name__ = "AzooKeyIMEShortcutFixtureEngine"

    def __init__(self, *args, **kwargs):
        self.fixture_ready = False
        self.provider_requests = 0
        self.provider_failure = False
        self.core_requests = []
        super().__init__(*args, **kwargs)

    def load_settings(self, snapshot):
        if "settings" not in snapshot:
            return
        settings = {**snapshot["settings"], "live": False, "learning": "nothing",
                    "tree": False, "predictiveTyping": False, "typoCorrection": False,
                    "aiEnabled": True}
        self.configure_fixture(settings)

    def configure_fixture(self, settings):
        self.fixture_ready = False

        def configured(snapshot):
            assert not snapshot.get("error"), snapshot
            self.settings = settings
            self.input.settings = settings
            self.fixture_ready = True

        self.input.submit("configure", payload={"settings": settings}, completion=configured)

    def render(self, snapshot):
        if snapshot.get("request"):
            self.core_requests.append(snapshot["request"])
        super().render(snapshot)

    def start_ai(self, snapshot, scope, *, prompt=None, completion=None):
        # Fixed synthetic text only. No keychain, AI socket or alternate
        # conversion implementation participates in this fixture.
        self.provider_requests += 1
        self.ai_pending = True
        GLib.idle_add(
            self.finish_ai, [] if self.provider_failure else ["候補"],
            snapshot.get("generation", -1), snapshot.get("reading", ""), completion,
            self.input.generation, self.input.cancelled,
        )

    def do_process_key_event(self, keyval, keycode, state):
        if keyval == Gdk.KEY_F6:
            self.configure_fixture({**self.settings, "aiEnabled": not self.settings["aiEnabled"]})
        elif keyval == Gdk.KEY_F7:
            self.provider_failure = not self.provider_failure
        elif keyval == Gdk.KEY_F8:
            observation = {
                "ready": self.fixture_ready and not self.input.pending and not self.input.is_resetting,
                "aiEnabled": self.settings.get("aiEnabled"),
                "review": self.ai_review.confirmation is not None,
                "providerRequests": self.provider_requests,
                "providerFailure": self.provider_failure,
                "coreRequests": self.core_requests,
                "inputState": self.input.snapshot.get("inputState"),
                "preedit": self.input.snapshot.get("preedit", ""),
                "pendingAI": self.ai_pending,
            }
            self.update_auxiliary_text(IBus.Text.new_from_string(json.dumps(observation)), True)
        else:
            return super().do_process_key_event(keyval, keycode, state)
        return True


engine_module.Engine = IMEShortcutFixtureEngine
runpy.run_path(str(pathlib.Path(__file__).resolve().parents[1] / "ibus-azookey-tree.py"), run_name="__main__")
