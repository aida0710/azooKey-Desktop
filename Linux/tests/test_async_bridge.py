import pathlib
import queue
import sys
import tempfile
import threading
import time
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from azookey.async_bridge import AsyncBridge, Request
from azookey.bridge import Bridge
from azookey.input_coordinator import InputCoordinator
from azookey.keymap import translate


class AsyncBridgeTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.callbacks = queue.Queue()
        self.bridges = []
        self.workers = []
        self.started_requests = queue.Queue()

    def tearDown(self):
        for worker in self.workers:
            worker.close()
            worker.worker.join(timeout=5)
            self.assertFalse(worker.worker.is_alive(), "test converter did not stop")
        self.directory.cleanup()

    def make_worker(self, delay, *, timeout=3):
        executable = pathlib.Path(self.directory.name) / f"delayed-{len(self.workers)}"
        executable.write_text(
            "#!/usr/bin/env python3\n"
            "import json, sys, time\n"
            "for line in sys.stdin:\n"
            " request = json.loads(line)\n"
            f" if request['operation'] == 'key': time.sleep({delay})\n"
            " print(json.dumps(request), flush=True)\n"
        )
        executable.chmod(0o700)

        started_requests = self.started_requests

        class ObservedBridge(Bridge):
            def request(self, operation, **payload):
                started_requests.put(operation)
                return super().request(operation, **payload)

        def create_bridge():
            bridge = ObservedBridge(str(executable), timeout=timeout)
            self.bridges.append(bridge)
            return bridge

        worker = AsyncBridge(lambda *callback: self.callbacks.put(callback), bridge_factory=create_bridge)
        self.workers.append(worker)
        return worker

    def await_replies(self, count, *, timeout=4):
        deadline = time.monotonic() + timeout
        for _ in range(count):
            complete, reply = self.callbacks.get(timeout=max(0, deadline - time.monotonic()))
            complete(reply)

    def test_delayed_converter_does_not_block_key_acceptance_or_reorder_requests(self):
        for delay in (0.25, 2.0):
            with self.subTest(delay=delay):
                worker = self.make_worker(delay)
                replies = []
                start = time.monotonic()
                worker.submit(Request("key", {"sequence": 1}, replies.append))
                worker.submit(Request("snapshot", {"sequence": 2}, replies.append))
                self.assertLess(time.monotonic() - start, 0.05)
                # The main-loop dispatcher remains available before conversion.
                heartbeat = []
                self.callbacks.put((lambda reply: heartbeat.append(reply), "alive"))
                self.await_replies(1)
                self.assertEqual(heartbeat, ["alive"])
                self.await_replies(2)
                self.assertEqual([reply.snapshot["sequence"] for reply in replies], [1, 2])
                self.assertEqual([reply.generation for reply in replies], [0, 0])
                self.assertFalse(any(reply.failed for reply in replies))

    def test_unresponsive_converter_recovers_and_accepts_first_next_request(self):
        worker = self.make_worker(10, timeout=0.1)
        replies = []
        worker.submit(Request("key", {}, replies.append))
        self.await_replies(1)
        self.assertTrue(replies[0].failed)
        worker.submit(Request("snapshot", {}, replies.append))
        self.await_replies(1)
        self.assertFalse(replies[1].failed)
        self.assertEqual(replies[1].generation, 1)

    def test_focus_change_cancels_queued_keys_without_waiting_for_slow_conversion(self):
        worker = self.make_worker(2)
        effects = []
        coordinator = InputCoordinator(
            worker, "old-field", render=effects.append, forward=lambda *key: effects.append(key),
            recover=effects.append, preview=lambda *_: None,
        )
        for character in "abc":
            coordinator.submit("key", payload={"event": translate(ord(character), 0)}, key=(ord(character), 0, 0))
        self.assertEqual(self.started_requests.get(timeout=2), "key")
        start = time.monotonic()
        coordinator.cancel()
        self.assertLess(time.monotonic() - start, 0.05)
        completed = []
        worker.submit(Request("snapshot", {"context": "new-field"}, completed.append))
        self.await_replies(2)
        self.assertEqual(effects, [])
        self.assertEqual(completed[0].snapshot["context"], "new-field")

    def test_stopped_converter_accepts_the_first_key_without_resending_it(self):
        worker = self.make_worker(0)
        replies = []
        worker.submit(Request("snapshot", {}, replies.append))
        self.await_replies(1)
        process = self.bridges[0].process
        process.kill()
        process.wait(timeout=2)
        worker.submit(Request("key", {"sequence": 1}, replies.append))
        self.await_replies(1)
        self.assertEqual(replies[-1].generation, 1)
        self.assertEqual(replies[-1].snapshot["sequence"], 1)

    def test_shutdown_returns_immediately_and_reaps_a_nonresponding_child(self):
        worker = self.make_worker(60, timeout=30)
        worker.submit(Request("key", {}, lambda _reply: None))
        self.assertEqual(self.started_requests.get(timeout=2), "key")
        start = time.monotonic()
        worker.close()
        self.assertLess(time.monotonic() - start, 0.05)
        worker.worker.join(timeout=2)
        self.assertFalse(worker.worker.is_alive())
        self.assertIsNotNone(self.bridges[0].process.poll())

    def test_slow_settings_backup_keeps_dispatcher_available_and_preserves_request_order(self):
        worker = self.make_worker(0)
        started = threading.Event()
        release = threading.Event()
        effects = []

        def persist():
            started.set()
            if not release.wait(timeout=2):
                raise AssertionError("test did not release settings backup")
            effects.append("saved")

        worker.submit(Request("configure", {}, lambda _reply: effects.append("configured"), persist=persist))
        try:
            self.assertTrue(started.wait(timeout=2))
            worker.submit(Request("key", {}, lambda _reply: effects.append("key")))
            self.callbacks.put((lambda _reply: effects.append("heartbeat"), None))
            self.await_replies(1)
            self.assertEqual(effects, ["heartbeat"])
        finally:
            release.set()
        self.await_replies(2)
        self.assertEqual(effects, ["heartbeat", "saved", "configured", "key"])

    def test_failed_backup_does_not_fail_successful_settings_or_restart_converter(self):
        worker = self.make_worker(0)
        replies = []

        def fail_backup():
            raise OSError("synthetic disk full")

        worker.submit(Request("configure", {}, replies.append, persist=fail_backup))
        worker.submit(Request("key", {}, replies.append))
        self.await_replies(2)
        self.assertFalse(any(reply.failed for reply in replies))
        self.assertEqual([reply.generation for reply in replies], [0, 0])
        persisted = []
        worker.submit(Request("configure", {"error": "invalid_request"}, replies.append, persist=lambda: persisted.append(True)))
        self.await_replies(1)
        self.assertEqual(persisted, [])


if __name__ == "__main__":
    unittest.main()
