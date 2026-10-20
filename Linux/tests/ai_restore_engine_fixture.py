"""Exercise the shipped settings callbacks with controlled converter delivery."""
import ast
import collections
import pathlib
import types

from azookey.async_bridge import Reply
from azookey.input_coordinator import InputCoordinator
from azookey.settings_store import SettingsStore


tree = ast.parse((pathlib.Path(__file__).parents[1] / "azookey/engine.py").read_text())
engine = next(node for node in tree.body if isinstance(node, ast.ClassDef) and node.name == "Engine")
methods = [node for node in engine.body if isinstance(node, ast.FunctionDef)
           and node.name in ("load_settings", "reload_settings")]
namespace = {}
exec(compile(ast.Module(body=methods, type_ignores=[]), "Engine settings callbacks", "exec"), namespace)


class SettingsRuntime:
    """Retain old mock state until stop, then start a fresh actual coordinator."""
    def __init__(self, settings_path, *, bridge_factory, active_settings):
        self.settings_path = settings_path
        self.bridge_factory = bridge_factory
        self.active_settings = active_settings
        self.stopped = False
        self.pending = collections.deque()
        self.acknowledgements = []
        self.engine = None
        self.bridge = None

    def stop(self):
        self.stopped = True
        self.active_settings = None
        return {"stoppedProcesses": {"synthetic": "engine"}}

    def require_stopped(self):
        if not self.stopped:
            raise RuntimeError("The old engine is still running")

    def restart(self):
        self.require_stopped()
        self.stopped = False
        self.bridge = self.bridge_factory()
        self.engine = types.SimpleNamespace(
            settings={}, settings_store=SettingsStore(self.settings_path), settings_stamp=None,
            pending_settings_stamp=None, settings_problem_stamp=None,
            notify_settings_problem=lambda problem: (_ for _ in ()).throw(AssertionError(problem)),
        )
        self.engine.load_settings = types.MethodType(namespace["load_settings"], self.engine)
        self.engine.reload_settings = types.MethodType(namespace["reload_settings"], self.engine)
        self.engine.input = InputCoordinator(
            self, "restore-context", render=lambda _snapshot: None,
            forward=lambda *key: self.acknowledgements.append(key),
            recover=lambda *_args: None, preview=lambda *_args: None,
        )
        self.engine.input.submit("settings", completion=self.engine.load_settings)
        self.barrier()
        return {"restartedEnginePID": "synthetic", "startupAcknowledgements": len(self.acknowledgements)}

    def submit(self, request):
        self.pending.append(request)

    def barrier(self):
        # Native keys expose the same two-stage ordering as the runtime's
        # nonediting language keys, without importing GTK into a pure test.
        for sequence in range(2):
            key = (0xFFE1, len(self.acknowledgements) + sequence, 0)
            self.engine.input.submit(None, key=key)
            while key not in self.acknowledgements:
                request = self.pending.popleft()
                if request.cancelled.is_set():
                    continue
                snapshot = self.bridge.request(request.operation, **request.payload)
                if request.persist:
                    request.persist()
                request.complete(Reply(snapshot=snapshot))
        self.pending = collections.deque(request for request in self.pending if not request.cancelled.is_set())
        self.active_settings = self.engine.settings

    def close(self):
        if self.bridge is not None:
            self.bridge.close()
            self.bridge = None
