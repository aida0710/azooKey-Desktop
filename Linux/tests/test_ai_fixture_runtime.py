"""Recovery must identify the installed engine before switching or stopping it."""
import pathlib
import sys
import types
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(pathlib.Path(__file__).parents[2] / "Tools/tests"))
from ai_fixture_runtime import COMPONENT_NAME, ENGINE_NAME, ENGINE_SERVICE, FALLBACK_ENGINE, InstalledRuntime


class FixtureRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.runtime = InstalledRuntime.__new__(InstalledRuntime)
        self.runtime.installed_root = pathlib.Path("/fixture/installed")
        self.runtime.bus = Mock()
        self.runtime.bus.get_global_engine.return_value.get_name.return_value = ENGINE_NAME
        self.runtime.bus.name_has_owner.return_value = True
        self.runtime.GLib = types.SimpleNamespace(
            Variant=lambda _signature, values: values,
            VariantType=types.SimpleNamespace(new=lambda signature: signature),
        )
        self.runtime.Gio = types.SimpleNamespace(DBusCallFlags=types.SimpleNamespace(NONE=0))
        self.runtime.session_connection = Mock()
        self.owner_names = iter((":1.8", ":1.8"))
        self.session_requests = []
        self.runtime.session_connection.call_sync.side_effect = self.session_reply

    def session_reply(self, _name, _path, _interface, method, arguments, *_options):
        self.session_requests.append((method, arguments[0]))
        if method == "NameHasOwner":
            reply = True
        elif method == "GetNameOwner":
            reply = next(self.owner_names)
        elif method == "GetConnectionUnixProcessID":
            reply = 123
        else:
            self.fail(f"Unexpected session bus request: {method}")
        return types.SimpleNamespace(unpack=lambda: (reply,))

    def assert_stop_refused(self, reason):
        with patch("ai_fixture_runtime.stop_installed_processes") as stop_processes:
            with self.assertRaisesRegex(RuntimeError, reason):
                self.runtime.stop()
            stop_processes.assert_not_called()
        self.runtime.bus.set_global_engine.assert_not_called()
        self.runtime.bus.get_connection.assert_not_called()

    def test_process_identity_comes_from_the_same_session_service_owner(self):
        self.assertEqual(self.runtime.engine_pid(), 123)
        self.assertIn(("NameHasOwner", ENGINE_SERVICE), self.session_requests)
        self.assertIn(("GetConnectionUnixProcessID", ":1.8"), self.session_requests)
        self.assertNotIn(("GetConnectionUnixProcessID", COMPONENT_NAME), self.session_requests)
        self.runtime.bus.get_connection.assert_not_called()

    def test_a_service_owner_change_refuses_to_stop_any_process(self):
        self.owner_names = iter((":1.8", ":1.9"))
        self.assert_stop_refused("changed owner")

    def test_an_active_engine_without_an_owner_is_left_running(self):
        with patch.object(self.runtime, "engine_pid", return_value=None):
            self.assert_stop_refused("could not be identified")

    def test_a_source_registered_engine_is_left_running(self):
        self.runtime.bus.name_has_owner.return_value = False
        self.assert_stop_refused("could not be identified")

    def test_a_different_entrypoint_is_left_running(self):
        for selected_engine in (ENGINE_NAME, FALLBACK_ENGINE):
            with self.subTest(selected_engine=selected_engine):
                self.runtime.bus.get_global_engine.return_value.get_name.return_value = selected_engine
                with patch.object(self.runtime, "engine_pid", return_value=123), \
                        patch("ai_fixture_runtime.installed_processes", return_value={}):
                    self.assert_stop_refused("different engine source")

    def test_a_registered_component_without_a_service_is_left_running(self):
        self.runtime.bus.get_global_engine.return_value.get_name.return_value = FALLBACK_ENGINE
        with patch.object(self.runtime, "engine_pid", return_value=None):
            self.assert_stop_refused("no identifiable engine")

    def test_recovery_can_resume_with_the_fallback_engine_and_no_service(self):
        self.runtime.bus.get_global_engine.return_value.get_name.return_value = FALLBACK_ENGINE
        self.runtime.bus.name_has_owner.return_value = False
        with patch.object(self.runtime, "engine_pid", return_value=None), \
                patch("ai_fixture_runtime.require_stopped"), \
                patch("ai_fixture_runtime.stop_installed_processes", return_value={}) as stop_processes:
            self.assertEqual(self.runtime.stop(), {"stoppedProcesses": {}})
            stop_processes.assert_called_once_with(self.runtime.installed_root)
        self.runtime.bus.set_global_engine.assert_called_once_with(FALLBACK_ENGINE)


if __name__ == "__main__":
    unittest.main()
