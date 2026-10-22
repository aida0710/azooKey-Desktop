import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from azookey.input_coordinator import InputCoordinator
from azookey.keymap import translate
from azookey.reconversion import ReconversionCoordinator, surrounding_context
from test_input_coordinator import ManualWorker


class ReconversionFixture:
    def setUp(self):
        self.worker = ManualWorker()
        self.effects = []
        self.timers = {}
        self.document = surrounding_context("前日本語後", 4, 1, can_replace=True, sensitive=False)
        self.inputs = InputCoordinator(
            self.worker, "same-field", render=lambda snapshot: self.effects.append(("render", snapshot)),
            forward=lambda *key: self.effects.append(("forward", key)), recover=self.recover,
            preview=lambda *_: None,
        )
        self.coordinator = ReconversionCoordinator(
            self.inputs, context=lambda: self.document,
            delete=lambda offset, count: self.effects.append(("delete", offset, count)),
            status=lambda text: self.effects.append(("status", text)),
            replay=lambda *key, key_reply=None: self.effects.append(("replay", key)),
            forward=lambda *key: self.effects.append(("forward", key)),
            schedule_timeout=self.schedule, remove_timeout=self.timers.pop,
        )
        self.plan = {
            "token": "one-use", "offset": -3, "count": 3, "text": "日本語", "reading": "にほんご",
            "removedContext": surrounding_context("前後", 1, 1, can_replace=True, sensitive=False),
        }

    def schedule(self, milliseconds, callback):
        self.timers[1] = callback
        return 1

    def recover(self, text):
        text, recovery = self.coordinator.take_recovery(text)
        self.effects.append(("recover", text))
        return lambda: self.coordinator.finish_recovery(recovery, allow_native=True)

    def prepare(self):
        self.coordinator.start(undo=False)
        self.worker.respond(0, {"reconversion": self.plan})

    def acknowledge(self):
        self.document = surrounding_context("前後", 1, 1, can_replace=True, sensitive=False)
        self.coordinator.surrounding_changed()

    def confirm_with_buffered_enter(self):
        self.prepare()
        self.coordinator.process(translate(0xFF0D, 0), (0xFF0D, 0, 0))
        self.acknowledge()
        self.effects.clear()

    def assert_changed_confirmation_is_discarded(self):
        self.assertFalse(self.coordinator.active)
        self.assertFalse(self.inputs.snapshot.get("preedit"))
        self.assertFalse(any(effect[0] in ("replay", "forward") for effect in self.effects))
        self.assertFalse(any(effect[0] == "recover" and effect[1] for effect in self.effects))
        self.assertFalse(any(effect[0] == "render" and effect[1].get("preedit") for effect in self.effects))
        self.assertIn(("status", "文字や入力位置が変わったため再変換を中止しました"), self.effects)
