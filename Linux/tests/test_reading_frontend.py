"""An input owner, never a candidate arrival, can change the document."""
from copy import deepcopy
from types import SimpleNamespace
import unittest

from azookey.reading_frontend import ReadingFrontend
from azookey.reading_protocol import ReadingCandidates, ReadingInput, ReadingNotice
from reading_candidate_view_fixture import candidate_view


class ManualReadingCoordinator:
    def __init__(self, _dispatch, **callbacks):
        self.callbacks = callbacks
        self.operations = []
        self.epoch = 0
        self.reference = None
        self.closed = False
        self.dictionary_refreshes = 0

    def refresh_dictionary(self):
        self.dictionary_refreshes += 1

    def open_context(self, context, callback):
        self.context = context
        callback({})

    def focus_in(self, context, surroundings, callback):
        self.epoch += 1
        self.reference = {"context": context, "readingProcessGeneration": "reader", "focusEpoch": self.epoch}
        self.surroundings = deepcopy(surroundings)
        callback({"reference": self.reference})

    def key(self, context, event, **ownership):
        self.operations.append(SimpleNamespace(operation="key", event=event, reference=deepcopy(self.reference), **ownership))

    def barrier(self, context, **ownership):
        self.operations.append(SimpleNamespace(operation="barrier", reference=deepcopy(self.reference), **ownership))

    def select(self, context, selection, **ownership):
        self.operations.append(SimpleNamespace(operation="select", selection=deepcopy(selection),
                                               reference=deepcopy(self.reference), **ownership))

    def commit_candidate(self, context, selection, **ownership):
        self.operations.append(SimpleNamespace(operation="commit-candidate", selection=deepcopy(selection),
                                               reference=deepcopy(self.reference), **ownership))

    def reset(self, context, **ownership):
        self.operations.append(SimpleNamespace(operation="reset", reference=deepcopy(self.reference), **ownership))

    def focus_out(self, context, **ownership):
        self.operations.append(SimpleNamespace(operation="focus-out", reference=deepcopy(self.reference), **ownership))

    def deliver(self, operation, snapshot, view=None):
        return self.callbacks["publish_input"](ReadingInput(
            self.context, operation.token, operation.reference, snapshot, candidate_view=view))

    def finish(self, operation, consumed=True):
        operation.finish(operation.token, consumed)

    def close(self):
        self.closed = True
        for operation in self.operations:
            self.finish(operation)


def reading_snapshot(text="あ", *, revision=1, commits=()):
    return {"preedit": text, "reading": text, "cursor": len(text), "readingCursor": len(text),
            "compositionRevision": revision, "generation": revision, "inputState": "composing" if text else "none",
            "commits": list(commits), "consumed": True}


class ReadingFrontendTests(unittest.TestCase):
    def setUp(self):
        self.effects = []
        self.coordinators = []

        def create(*args, **kwargs):
            coordinator = ManualReadingCoordinator(*args, **kwargs)
            self.coordinators.append(coordinator)
            return coordinator

        self.frontend = ReadingFrontend(
            lambda callback, *args: callback(*args),
            render_input=lambda value: self.effects.append(("input", deepcopy(value))),
            render_candidates=lambda snapshot, batch: self.effects.append(("candidates", deepcopy(snapshot), deepcopy(batch))),
            notify=lambda notice: self.effects.append(("notice", notice)),
            coordinator_factory=create,
        )
        self.frontend.focus_in({"leftContext": "", "rightContext": "", "privateInput": False})
        self.addCleanup(self.frontend.close)

    @property
    def coordinator(self):
        return self.coordinators[-1]

    def key(self):
        self.frontend.key({"keyCode": 0, "characters": "a"}, lambda consumed: self.effects.append(("reply", consumed)))
        return self.coordinator.operations[-1]

    def test_explicit_restart_keeps_the_settings_provider_and_finishes_old_input_once(self):
        provider = lambda defaults: defaults
        self.frontend.settings_provider = provider
        operation = self.key()
        self.frontend.blocked = True
        self.frontend.reset()
        self.assertTrue(operation.token.finished)
        self.assertIs(self.coordinator.callbacks["settings_provider"], provider)
        self.assertEqual(self.coordinator.dictionary_refreshes, 1)
        self.assertEqual([effect for effect in self.effects if effect[0] == "reply"], [("reply", True)])
        self.assertTrue(self.frontend.focused)

    def publish_reading(self, text="あ", *, revision=1):
        operation = self.key()
        self.assertTrue(self.coordinator.deliver(operation, reading_snapshot(text, revision=revision)))
        self.coordinator.finish(operation)
        return operation

    def candidates(self, *, revision=1, reference=None):
        reference = reference or self.frontend.reference
        batch = {
            "authority": {**reference, "compositionRevision": revision, "settingsRevision": 0, "requestID": "request"},
            "workerGeneration": "converter", "batchID": "batch",
            "candidates": [{"candidateID": "real-id", "text": "亜"}],
        }
        return ReadingCandidates(self.frontend.context, deepcopy(reference), batch, candidate_view=candidate_view(batch))

    def test_input_effects_precede_the_original_reply_and_finish_only_once(self):
        operation = self.key()
        self.assertEqual(self.effects, [])
        snapshot = reading_snapshot()
        self.assertTrue(self.coordinator.deliver(operation, snapshot))
        self.coordinator.finish(operation)
        self.coordinator.finish(operation)
        self.assertEqual([effect[0] for effect in self.effects], ["input", "candidates", "reply"])
        self.assertEqual(self.effects[-1], ("reply", True))
        self.assertEqual(self.frontend.pending, set())

    def test_candidate_arrival_changes_only_the_candidate_view(self):
        self.publish_reading()
        self.effects.clear()
        value = self.candidates()
        self.assertTrue(self.frontend._publish_candidates(value))
        self.assertEqual(self.effects, [("candidates", self.frontend.snapshot, value.candidate_view)])
        self.assertEqual(self.frontend.snapshot["preedit"], "あ")
        self.assertEqual(self.frontend.batch, value.batch)
        self.assertEqual(self.frontend.candidate_view, value.candidate_view)

    def retained_selection(self):
        self.publish_reading()
        value = self.candidates()
        self.frontend._publish_candidates(value)
        return {"batch": deepcopy(value.candidate_view["candidateReference"]), "candidateID": "real-id"}

    def test_pointer_select_and_atomic_commit_keep_the_real_id_without_synthesizing_keys(self):
        selection = self.retained_selection()
        self.effects.clear()
        start = len(self.coordinator.operations)
        self.assertTrue(self.frontend.select_candidate(selection, submit=False))
        selected = self.coordinator.operations[-1]
        self.assertEqual(selected.operation, "select")
        self.assertEqual(selected.selection, selection)
        self.assertEqual(self.effects, [])
        self.assertFalse(self.frontend.select_candidate(selection, submit=True))
        self.coordinator.finish(selected)
        self.assertTrue(self.frontend.select_candidate(selection, submit=True))
        committed = self.coordinator.operations[-1]
        self.assertEqual(committed.operation, "commit-candidate")
        self.assertEqual(committed.selection, selection)
        self.assertFalse(self.frontend.select_candidate(selection, submit=True))
        self.coordinator.deliver(committed, reading_snapshot("", revision=2, commits=("亜",)))
        self.coordinator.finish(committed)
        self.coordinator.finish(committed)
        self.assertEqual([item.operation for item in self.coordinator.operations[start:]], ["select", "commit-candidate"])
        self.assertEqual([value[1]["commits"] for value in self.effects if value[0] == "input"], [["亜"]])
        self.assertFalse(any(value[0] == "reply" for value in self.effects))
        self.assertFalse(self.frontend.select_candidate(selection, submit=True))
        self.assertEqual(self.frontend.pending, set())

    def test_old_unknown_or_pending_candidate_actions_cannot_enqueue_input(self):
        selection = self.retained_selection()
        old_count = len(self.coordinator.operations)
        for field, replacement in (("candidateID", "unknown"), ("batch", {})):
            self.assertFalse(self.frontend.select_candidate({**selection, field: replacement}, submit=True))
        self.assertFalse(self.frontend.select_candidate(selection, submit=1))
        self.frontend.candidate_view["candidateReference"]["authority"]["requestID"] = "next"
        self.assertFalse(self.frontend.select_candidate(selection, submit=True))
        self.assertEqual(len(self.coordinator.operations), old_count)
        self.frontend.candidate_view["candidateReference"] = deepcopy(selection["batch"])
        key = self.key()
        self.assertFalse(self.frontend.select_candidate(selection, submit=True))
        self.coordinator.finish(key)
        self.frontend.focus_out()
        self.frontend.focus_in({"leftContext": "other", "rightContext": "", "privateInput": False})
        self.assertFalse(self.frontend.select_candidate(selection, submit=True))

    def test_a_formal_selection_publishes_its_view_before_finishing_the_original_key(self):
        self.publish_reading()
        value = self.candidates()
        self.frontend._publish_candidates(value)
        self.effects.clear()
        operation = self.key()
        snapshot = {**reading_snapshot(), "inputState": "selecting", "selection": 0}
        view = candidate_view(value.batch, selection=0, show_indices=True)
        self.coordinator.deliver(operation, snapshot, view)
        self.coordinator.finish(operation)
        self.assertEqual([effect[0] for effect in self.effects], ["input", "candidates", "reply"])
        self.assertEqual(self.effects[1][2], view)
        self.assertEqual(self.frontend.candidate_view, view)

    def test_a_retired_view_is_cleared_without_changing_an_input_reply(self):
        self.publish_reading()
        value = self.candidates()
        self.frontend._publish_candidates(value)
        self.effects.clear()
        operation = self.key()
        self.coordinator.deliver(operation, reading_snapshot())
        self.coordinator.finish(operation)
        self.assertIsNone(self.frontend.candidate_view)
        self.assertEqual(self.effects[-2], ("candidates", self.frontend.snapshot, None))
        self.assertEqual(self.effects[-1], ("reply", True))

    def test_new_formal_input_retires_an_older_candidate_view(self):
        self.publish_reading()
        old = self.candidates()
        self.frontend._publish_candidates(old)
        self.publish_reading("あい", revision=2)
        self.assertIsNone(self.frontend.batch)
        before = list(self.effects)
        self.assertFalse(self.frontend._publish_candidates(old))
        self.assertEqual(self.effects, before)

    def test_focus_out_never_submits_the_text_ibus_already_owns(self):
        operation = self.publish_reading()
        self.effects.clear()
        self.frontend.focus_out()
        self.assertEqual(self.effects, [("candidates", {}, None)])
        self.assertFalse(self.coordinator.deliver(operation, reading_snapshot("", commits=("あ",))))
        self.assertEqual(self.effects, [("candidates", {}, None)])

    def test_old_input_and_candidates_cannot_change_a_new_field(self):
        operation = self.key()
        old_reference = deepcopy(self.frontend.reference)
        self.frontend.focus_out()
        self.frontend.focus_in({"leftContext": "次の欄", "rightContext": "", "privateInput": False})
        self.effects.clear()
        self.assertFalse(self.coordinator.deliver(operation, reading_snapshot("", commits=("旧欄",))))
        self.assertFalse(self.frontend._publish_candidates(self.candidates(reference=old_reference)))
        self.assertEqual(self.effects, [])
        self.coordinator.finish(operation)
        self.assertEqual(self.effects, [("reply", True)])

    def test_partial_commit_preserves_the_formal_suffix_and_does_not_replay_learning(self):
        operation = self.key()
        snapshot = reading_snapshot("ほんご", revision=2, commits=("ni",))
        snapshot["candidateCompletions"] = [{"candidateID": "selected"}]
        self.coordinator.deliver(operation, snapshot)
        self.coordinator.finish(operation)
        self.assertEqual(self.effects[0], ("input", snapshot))
        self.assertEqual(self.frontend.snapshot["preedit"], "ほんご")
        self.assertEqual(self.frontend.snapshot["commits"], [])
        self.assertEqual(self.frontend.snapshot["candidateCompletions"], [])

    def test_reset_retires_old_ownership_and_cannot_commit_a_cancelled_response(self):
        old = self.key()
        self.frontend.reset()
        reset = self.coordinator.operations[-1]
        self.assertFalse(self.coordinator.deliver(old, reading_snapshot("", commits=("古い",))))
        with self.assertRaises(ValueError):
            self.coordinator.deliver(reset, reading_snapshot("", commits=("取消後",)))
        self.assertFalse(any(value[1].get("commits") for value in self.effects if value[0] == "input"))

    def test_uncertain_reading_failure_preserves_display_until_explicit_reset(self):
        self.publish_reading()
        self.effects.clear()
        failed_coordinator = self.coordinator
        self.frontend._notice(ReadingNotice("reading_process_unavailable", phase="response-unknown"))
        self.frontend.key({}, lambda consumed: self.effects.append(("blocked-reply", consumed)))
        self.assertEqual(self.frontend.snapshot["preedit"], "あ")
        self.assertFalse(any(effect[0] == "input" for effect in self.effects))
        self.assertEqual(self.effects[-1], ("blocked-reply", True))
        self.frontend.reset()
        self.assertTrue(failed_coordinator.closed)
        self.assertEqual(len(self.coordinators), 2)
        self.assertFalse(self.frontend.blocked)
        self.assertTrue(self.frontend.focused)
        self.assertFalse(any(effect[1].get("commits") for effect in self.effects if effect[0] == "input"))
        self.publish_reading("い")
        self.assertEqual(self.frontend.snapshot["preedit"], "い")

    def test_candidate_failure_keeps_formal_reading_keys_available(self):
        self.publish_reading()
        self.frontend._notice(ReadingNotice("candidate_process_unavailable", operation="candidates"))
        self.assertFalse(self.frontend.blocked)
        self.publish_reading("あい", revision=2)
        self.assertEqual(self.frontend.snapshot["preedit"], "あい")

    def test_modifier_barrier_waits_for_formal_input_without_publishing_text(self):
        operation = self.key()
        self.frontend.barrier(lambda consumed: self.effects.append(("barrier", consumed)))
        barrier = self.coordinator.operations[-1]
        self.coordinator.deliver(operation, reading_snapshot())
        self.coordinator.finish(operation)
        self.coordinator.finish(barrier, False)
        self.assertEqual(self.effects[-2:], [("reply", True), ("barrier", False)])
        self.assertEqual(sum(effect[0] == "input" for effect in self.effects), 1)

    def test_close_finishes_each_original_reply_once_and_rejects_late_input(self):
        operation = self.key()
        self.frontend.close()
        self.coordinator.finish(operation)
        self.assertEqual(self.effects, [("reply", True)])
        self.assertFalse(self.coordinator.deliver(operation, reading_snapshot("", commits=("stale",))))

    def test_new_privacy_context_rejects_old_candidates(self):
        self.publish_reading()
        old = self.candidates()
        self.frontend.focus_in({"leftContext": "", "rightContext": "", "privateInput": True})
        self.assertTrue(self.coordinator.surroundings["privateInput"])
        self.effects.clear()
        self.assertFalse(self.frontend._publish_candidates(old))
        self.assertEqual(self.effects, [])

    def test_reentrant_focus_out_during_input_application_cannot_reopen_candidates(self):
        operation = self.key()
        original_render = self.frontend.render_input

        def render_and_leave(snapshot):
            original_render(snapshot)
            self.frontend.focus_out()

        self.frontend.render_input = render_and_leave
        self.assertTrue(self.coordinator.deliver(operation, reading_snapshot()))
        self.assertFalse(self.frontend.focused)
        self.assertEqual(self.frontend.snapshot, {})
        self.assertEqual(self.effects[-1], ("candidates", {}, None))

    def test_reentrant_focus_out_during_candidate_display_retires_the_batch(self):
        self.publish_reading()
        original_render = self.frontend.render_candidates

        def render_and_leave(snapshot, batch):
            original_render(snapshot, batch)
            if batch is not None:
                self.frontend.focus_out()

        self.frontend.render_candidates = render_and_leave
        self.assertFalse(self.frontend._publish_candidates(self.candidates()))
        self.assertIsNone(self.frontend.batch)
        self.assertEqual(self.effects[-1], ("candidates", {}, None))

    def test_reset_view_reentry_does_not_clear_candidates_for_the_new_field(self):
        def move_to_next_field(_snapshot):
            self.frontend.focus_in({"leftContext": "new", "rightContext": "", "privateInput": False})
            self.effects.clear()

        self.frontend.render_input = move_to_next_field
        self.frontend.reset()
        self.assertTrue(self.frontend.focused)
        self.assertEqual(self.frontend.surroundings["leftContext"], "new")
        self.assertEqual(self.effects, [])


if __name__ == "__main__":
    unittest.main()
