"""The engine asks Core again only when the settings file changed."""
import os
import pathlib
import sys
import tempfile
import types
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from azookey.settings_reload import SettingsReload


class InputQueue:
    """Records reloads like InputCoordinator and lets the test answer them."""

    def __init__(self):
        self.pending = []

    def submit(self, operation, *, completion):
        self.pending.append(types.SimpleNamespace(operation=operation, completion=completion))

    def answer(self, snapshot):
        self.pending.pop(0).completion(snapshot)


def reply(path, *, values=None, stamp="s1", problem=None):
    state = {"path": str(path), "stamp": stamp, "exists": True}
    if problem is not None:
        state["problem"] = problem
    return {"settings": values or {"live": False}, "settingsResult": {"file": state}}


class SettingsReloadTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.path = pathlib.Path(directory.name) / "settings.json"
        self.queue = InputQueue()
        self.applied = []
        self.problems = []
        self.reload = SettingsReload(self.queue, applied=self.applied.append, problem=self.problems.append)

    def start(self):
        self.reload.request()
        self.queue.answer(reply(self.path))
        self.queue.answer(reply(self.path))

    def test_core_names_the_file_and_an_unchanged_file_sends_no_request(self):
        self.reload.request()
        self.reload.request()
        self.assertEqual(len(self.queue.pending), 1, "the first reload waits for Core's answer")
        self.queue.answer(reply(self.path))
        self.assertEqual(len(self.queue.pending), 1, "the named file is checked at once")
        self.queue.answer(reply(self.path))
        self.assertEqual(self.problems, [None])
        for _ in range(3):
            self.reload.request()
        self.assertEqual(self.queue.pending, [])
        self.path.write_text('{"live":true}')
        self.reload.request()
        self.reload.request()
        self.assertEqual(len(self.queue.pending), 1)
        self.queue.answer(reply(self.path, values={"live": True}, stamp="s2"))
        self.assertEqual(self.applied[-1], {"live": True})

    def test_a_problem_is_reported_with_the_version_core_read(self):
        self.start()
        self.path.write_text("{")
        self.reload.request()
        problem = {"code": "invalidJSON", "message": "settings.invalid_json", "arguments": {"line": "1", "column": "2"}}
        self.queue.answer(reply(self.path, stamp="broken", problem=problem))
        self.assertEqual(self.problems[-1], {**problem, "stamp": "broken"})
        self.reload.request()
        self.assertEqual(self.queue.pending, [], "the same damaged file is not reported again")

    def test_repair_during_a_queued_rejection_asks_again_without_a_stale_notice(self):
        self.start()
        self.path.write_text('{"customTable":"rejected"}')
        self.reload.request()
        self.path.write_text('{"live":true,"customTable":""}')
        rejected = {"code": "engineRejected", "message": "settings.engine_rejected", "arguments": {}}
        self.queue.answer(reply(self.path, stamp="rejected", problem=rejected))
        self.assertEqual(self.problems, [None], "no notice for a version the user already replaced")
        self.assertEqual(len(self.queue.pending), 1)
        self.queue.answer(reply(self.path, values={"live": True}, stamp="repaired"))
        self.assertEqual(self.problems, [None, None])
        self.assertEqual(self.applied[-1], {"live": True})

    def test_a_cancelled_reload_is_sent_again_and_a_failed_answer_keeps_the_settings(self):
        self.start()
        self.path.write_text('{"live":true}')
        self.reload.request()
        # InputCoordinator.cancel drops every pending request without an answer.
        self.queue.pending.clear()
        self.reload.request()
        self.assertEqual(len(self.queue.pending), 1)
        applied = len(self.applied)
        self.queue.answer({"error": "invalid_request"})
        self.assertEqual(len(self.applied), applied)
        self.reload.request()
        self.assertEqual(len(self.queue.pending), 1, "the next key asks again")

    def test_a_removed_file_and_a_dangling_link_are_changes(self):
        self.path.write_text("{}")
        self.start()
        self.path.unlink()
        self.reload.request()
        self.assertEqual(len(self.queue.pending), 1)
        self.queue.answer(reply(self.path, stamp="absent"))
        os.symlink(self.path.with_name("missing.json"), self.path)
        self.reload.request()
        self.assertEqual(len(self.queue.pending), 1)


if __name__ == "__main__":
    unittest.main()
