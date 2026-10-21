"""Delayed dictionary replies and deletion ACKs preserve the original field."""
from copy import deepcopy
import unittest

from azookey.keymap import translate
from azookey.native_key_reply import NativeKeyReply
from azookey.reading_coordinator import ReadingCoordinator
from azookey.reading_frontend import ReadingFrontend
from azookey.reading_reconversion_input import ReadingReconversionInput
from azookey.reconversion import ReconversionCoordinator, surrounding_context
from candidate_fixture import CallbackQueue, WAIT_SECONDS
from reading_reconversion_fixture import ReconversionCandidateFixture, ReconversionReaderFixture
from test_reading_frontend import reading_snapshot


START = (ord("r"), 27, 5)
ENTER = (0xFF0D, 36, 0)


class ReadingReconversionTests(unittest.TestCase):
    def setUp(self):
        self.callbacks = CallbackQueue()
        self.reader = ReconversionReaderFixture()
        self.candidate = ReconversionCandidateFixture()
        self.effects = []
        self.timers = {}
        self.document = surrounding_context("前日本語後", 4, 1, can_replace=True, sensitive=False)
        self.plan = {"token": "one-use", "offset": -3, "count": 3, "text": "日本語", "reading": "にほんご"}

        def create(dispatch, **callbacks):
            return ReadingCoordinator(dispatch, **callbacks, reader_factory=lambda: self.reader,
                                      candidate_factory=lambda: self.candidate)

        self.frontend = ReadingFrontend(
            self.callbacks.dispatch, coordinator_factory=create,
            render_input=lambda value: self.effects.append(("input", deepcopy(value))),
            render_candidates=lambda *_: None, notify=lambda value: self.effects.append(("notice", value)),
        )
        self.frontend.focus_in({"leftContext": "前", "rightContext": "後", "privateInput": False})
        self.inputs = ReadingReconversionInput(
            self.frontend, context=lambda: self.document, recover=self.recover,
            publish_recovery=lambda value: self.effects.append(("recovery-preedit", value)),
        )
        self.reconversion = ReconversionCoordinator(
            self.inputs, context=lambda: self.document,
            delete=lambda offset, count: self.effects.append(("delete", offset, count)),
            status=lambda text: self.effects.append(("status", text)),
            replay=self.replay, forward=lambda *_: self.fail("native key must keep its original reply"),
            schedule_timeout=self.schedule, remove_timeout=self.timers.pop,
            confirm_replacement=self.inputs.confirm_replacement,
        )
        self.drain_until(lambda: self.frontend.reference and self.frontend.coordinator._candidate_settings)
        self.addCleanup(self.close)

    def close(self):
        self.reconversion.cancel()
        self.frontend.close()
        for transport in (self.frontend.coordinator.transport, self.frontend.coordinator.candidates.transport):
            transport.worker.join(WAIT_SECONDS)
            self.assertFalse(transport.worker.is_alive())

    def schedule(self, _milliseconds, callback):
        token = object()
        self.timers[token] = callback
        return token

    def drain_until(self, predicate):
        for _ in range(100):
            if predicate():
                return
            self.callbacks.drain(1)
        self.fail("replacement ownership did not progress")

    def native(self, key):
        reply = NativeKeyReply(lambda consumed: self.effects.append(("reply", key, consumed)))
        self.dispatch(key, reply)
        return reply

    def dispatch(self, key, reply):
        event = translate(key[0], key[2])
        if self.reconversion.process(event, key, key_reply=reply):
            if not reply.deferred:
                reply.finish(True)
        else:
            self.frontend.key(event, reply.defer(), reconversion_context=self.document)

    def replay(self, *key, key_reply):
        self.dispatch(key, NativeKeyReply(key_reply))

    def recover(self, text):
        text, recovery = self.reconversion.take_recovery(text)
        self.frontend.reset()
        self.effects.append(("recover", text))
        self.reconversion.finish_recovery(recovery, allow_native=self.reconversion.is_current_recovery(recovery))

    def prepare(self):
        self.reader.reconversion_replies["resolve-reconversion"].append({"reconversion": self.plan})
        self.native(START)
        self.drain_until(lambda: self.reconversion.phase == "deleting")

    def acknowledge(self):
        self.document = surrounding_context("前後", 1, 1, can_replace=True, sensitive=False)
        self.reconversion.surrounding_changed()

    def test_delayed_dictionary_reading_does_not_block_dispatch_or_delete_before_its_reply(self):
        gate = self.candidate.gate("resolve-reconversion-reading")
        self.native(START)
        self.drain_until(lambda: not self.frontend.pending)
        self.assertTrue(gate.entered.wait(WAIT_SECONDS))
        self.callbacks.dispatch(lambda _: self.effects.append(("heartbeat",)), None)
        self.callbacks.drain(1)
        self.assertIn(("heartbeat",), self.effects)
        self.assertFalse(any(effect[0] in ("input", "delete", "reply") for effect in self.effects))
        self.reader.reconversion_replies["resolve-reconversion"].append({"reconversion": self.plan})
        gate.proceed.set()
        self.drain_until(lambda: self.reconversion.phase == "deleting")
        self.assertEqual([effect for effect in self.effects if effect[0] == "delete"], [("delete", -3, 3)])
        self.assertEqual([effect for effect in self.effects if effect[0] == "reply"], [("reply", START, True)])
        self.assertFalse(any(effect[0] == "input" for effect in self.effects))
        self.assertEqual(self.candidate.learning_updates, [])

    def test_confirmed_input_precedes_buffered_enter_and_the_start_reply_is_not_repeated(self):
        self.prepare()
        self.reader.reconversion_replies["confirm-reconversion"].append(
            {"kind": "input", "snapshot": reading_snapshot("にほんご")})
        self.native(ENTER)
        self.assertFalse(any(operation == "confirm-reconversion" for operation, _ in self.reader.calls))
        self.acknowledge()
        self.drain_until(lambda: ("reply", ENTER, True) in self.effects)
        inputs = [effect[1]["preedit"] for effect in self.effects if effect[0] == "input"]
        self.assertEqual(inputs, ["にほんご", ""])
        self.assertEqual([effect for effect in self.effects if effect[0] == "reply"],
                         [("reply", START, True), ("reply", ENTER, True)])
        self.assertLess(next(index for index, effect in enumerate(self.effects) if effect[0] == "input"),
                        self.effects.index(("reply", ENTER, True)))

    def test_document_change_before_dictionary_reply_retires_without_deleting_or_replaying(self):
        gate = self.candidate.gate("resolve-reconversion-reading")
        self.native(START)
        self.drain_until(lambda: not self.frontend.pending)
        self.assertTrue(gate.entered.wait(WAIT_SECONDS))
        self.native(ENTER)
        self.document = surrounding_context("別日本語後", 4, 1, can_replace=True, sensitive=False)
        gate.proceed.set()
        self.drain_until(lambda: ("reply", ENTER, True) in self.effects)
        self.assertFalse(any(effect[0] == "delete" for effect in self.effects))
        self.assertFalse(any(operation == "resolve-reconversion" for operation, _ in self.reader.calls))

    def test_focus_change_before_reading_resolution_keeps_the_next_field_untouched(self):
        gate = self.candidate.gate("resolve-reconversion-reading")
        self.native(START)
        self.drain_until(lambda: not self.frontend.pending)
        self.assertTrue(gate.entered.wait(WAIT_SECONDS))
        self.reconversion.cancel()
        self.inputs.cancel()
        self.frontend.focus_out()
        self.frontend.focus_in({"leftContext": "別", "rightContext": "", "privateInput": False})
        self.document = surrounding_context("別", 1, 1, can_replace=True, sensitive=False)
        self.effects.clear()
        gate.proceed.set()
        done = []
        self.frontend.coordinator.candidates.settings(done.append)
        self.drain_until(lambda: done)
        self.assertFalse(any(effect[0] in ("input", "delete") for effect in self.effects))
        self.assertFalse(any(operation == "resolve-reconversion" for operation, _ in self.reader.calls))

    def test_failed_confirmation_restores_the_deleted_original_once_without_publishing_its_snapshot(self):
        self.prepare()
        self.reader.reconversion_replies["confirm-reconversion"].append(
            {"kind": "input", "snapshot": reading_snapshot(""), "reconversionError": "changed_context"})
        self.native(ENTER)
        self.acknowledge()
        self.drain_until(lambda: any(effect[0] == "recover" for effect in self.effects))
        self.assertEqual([effect for effect in self.effects if effect[0] == "recover"], [("recover", "日本語")])
        self.assertFalse(any(effect[0] == "input" and "compositionRevision" in effect[1] for effect in self.effects))
        self.inputs.recover_pending()
        self.assertEqual([effect for effect in self.effects if effect[0] == "recover" and effect[1]],
                         [("recover", "日本語")])
        self.assertEqual([effect for effect in self.effects if effect[0] == "reply"],
                         [("reply", START, True), ("reply", ENTER, False)])

    def test_unknown_reading_stays_local_and_does_not_mutate_the_selected_document(self):
        self.candidate.resolved_reading = None
        self.reader.reconversion_replies["resolve-reconversion"].append(
            {"reconversionReading": "", "reconversionError": "reading_required"})
        self.native(START)
        self.drain_until(lambda: self.reconversion.phase == "reading")
        self.assertEqual(self.document["selected"], "日本語")
        self.assertFalse(any(effect[0] in ("input", "delete") for effect in self.effects))
        self.assertTrue(any(effect[0] == "status" and "読み" in effect[1] for effect in self.effects))

    def test_each_key_retains_the_same_document_context_for_the_short_commit_history(self):
        self.native((ord("a"), 38, 0))
        self.drain_until(lambda: not self.frontend.pending)
        payload = next(payload for operation, payload in self.reader.calls if operation == "key")
        self.assertEqual(payload["reconversionContext"], self.document)

    def test_recovery_preedit_appears_only_after_deletion_ack_and_late_confirm_cannot_follow_focus(self):
        self.prepare()
        self.assertFalse(any(effect[0] == "recovery-preedit" for effect in self.effects))
        self.reader.reconversion_replies["confirm-reconversion"].append(
            {"kind": "input", "snapshot": reading_snapshot("にほんご")})
        gate = self.reader.gate("confirm-reconversion")
        self.acknowledge()
        self.assertTrue(gate.entered.wait(WAIT_SECONDS))
        self.assertEqual([effect for effect in self.effects if effect[0] == "recovery-preedit"],
                         [("recovery-preedit", "日本語")])
        self.reconversion.cancel()
        self.inputs.retire()
        self.frontend.focus_out()
        self.frontend.focus_in({"leftContext": "別", "rightContext": "", "privateInput": False})
        self.document = surrounding_context("別", 1, 1, can_replace=True, sensitive=False)
        self.effects.clear()
        gate.proceed.set()
        self.drain_until(lambda: self.frontend.reference is not None)
        self.assertFalse(any(effect[0] in ("input", "delete", "recovery-preedit", "recover") for effect in self.effects))

    def test_document_change_while_confirming_retires_the_formal_response_and_queued_keys(self):
        self.prepare()
        self.reader.reconversion_replies["confirm-reconversion"].append(
            {"kind": "input", "snapshot": reading_snapshot("にほんご")})
        gate = self.reader.gate("confirm-reconversion")
        self.acknowledge()
        self.assertTrue(gate.entered.wait(WAIT_SECONDS))
        self.native(ENTER)
        self.document = surrounding_context("別", 1, 1, can_replace=True, sensitive=False)
        self.reconversion.surrounding_changed()
        gate.proceed.set()
        self.drain_until(lambda: not self.frontend.pending)
        self.assertFalse(any(effect[0] == "input" and effect[1].get("preedit") for effect in self.effects))
        self.assertFalse(any(effect[0] == "recover" and effect[1] for effect in self.effects))
        self.assertEqual([effect for effect in self.effects if effect[0] == "reply"],
                         [("reply", START, True), ("reply", ENTER, True)])

    def test_lost_confirmation_reply_recovers_original_once_without_resending_confirmation(self):
        self.prepare()
        self.reader.reconversion_replies["confirm-reconversion"].append(
            {"kind": "input", "snapshot": reading_snapshot("にほんご")})
        self.reader.fail("confirm-reconversion", after_effect=True)
        self.acknowledge()
        self.drain_until(lambda: any(effect[0] == "recover" for effect in self.effects))
        self.assertEqual([effect for effect in self.effects if effect[0] == "recover"], [("recover", "日本語")])
        self.assertEqual(sum(operation == "confirm-reconversion" for operation, _ in self.reader.calls), 1)
        self.assertFalse(any(effect[0] == "input" and effect[1].get("preedit") for effect in self.effects))

    def test_private_or_unavailable_document_never_reaches_either_worker(self):
        original_calls = len(self.reader.calls), len(self.candidate.calls)
        for document in (None, {**self.document, "isSensitive": True}, {**self.document, "canReplace": False}):
            with self.subTest(document=document):
                self.document = document
                self.native(START)
                self.assertEqual((len(self.reader.calls), len(self.candidate.calls)), original_calls)
        self.assertFalse(any(effect[0] in ("input", "delete", "recovery-preedit") for effect in self.effects))

    def test_restarted_candidate_does_not_resolve_under_unconfirmed_settings_or_delete(self):
        self.candidate.dead = True
        self.native(START)
        self.drain_until(lambda: ("reply", START, True) in self.effects)
        self.assertFalse(any(operation == "resolve-reconversion-reading" for _, operation, _ in self.candidate.calls))
        self.assertFalse(any(effect[0] in ("delete", "recovery-preedit") for effect in self.effects))

    def test_changed_reading_result_is_rejected_before_a_plan_is_requested(self):
        def changed(operation, response):
            if operation == "resolve-reconversion-reading":
                response["reconversionReadingResult"]["request"]["text"] = "他"
            return response

        self.candidate.rewrite = changed
        self.native(START)
        self.drain_until(lambda: ("reply", START, True) in self.effects)
        self.assertFalse(any(operation == "resolve-reconversion" for operation, _ in self.reader.calls))
        self.assertFalse(any(effect[0] == "delete" for effect in self.effects))


if __name__ == "__main__":
    unittest.main()
