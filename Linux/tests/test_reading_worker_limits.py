"""Malformed and over-limit input must preserve formal input and framing."""
import json
import os
import subprocess
import unittest

from Linux.tests.reading_worker_fixture import ReadingWorkerCase, REQUEST_TIMEOUT_SECONDS


class ReadingWorkerLimitTests(ReadingWorkerCase):
    def test_unknown_fields_missing_focus_context_and_invalid_keys_are_rejected_before_editing(self):
        self.type("nihongo")
        payloads = [
            ("key", {"reference": self.reference, "event": {"keyCode": 36, "modifierFlags": 0}, "context": "other"}),
            ("key", {"reference": self.reference, "event": {"keyCode": -1, "modifierFlags": 0}}),
            ("key", {"reference": self.reference, "event": {"keyCode": 0, "modifierFlags": 16}}),
            ("key", {"reference": self.reference, "event": {"keyCode": 0, "characters": "a" * 4097, "modifierFlags": 0}}),
            ("reset", {"reference": self.reference}),
            ("reset", {"reference": {**self.reference, "focusEpoch": -1}, "submit": True}),
            ("reset", {"reference": {**self.reference, "compositionRevision": 1}, "submit": True}),
            ("snapshot", {"context": "field"}),
            ("hello", {"settingsRevision": 1}),
            ("learning-revision", {"readingProcessGeneration": self.process_generation, "settingsRevision": -1}),
        ]
        for operation, payload in payloads:
            with self.subTest(operation=operation, fields=list(payload)):
                self.assert_rejected_without_edit(operation, **payload)
        self.assertEqual(self.key(0xFF0D)["snapshot"]["commits"], ["にほんご"])

    def test_identifiers_and_context_capacity_are_bounded_without_retiring_active_input(self):
        self.type("a")
        for name in ("", " ", "日本語", "a\x00", "a" * (self.limits["identifierBytes"] + 1)):
            self.assert_rejected_without_edit("open", readingProcessGeneration=self.process_generation, context=name)
        maximum = self.open("a" * self.limits["identifierBytes"])
        opened = [maximum] + [self.open(f"field-{index}") for index in range(self.limits["contexts"] - 2)]
        self.assert_rejected_without_edit("open", readingProcessGeneration=self.process_generation, context="overflow",
                                          error="reading_request_limit")
        self.request("close", reference=opened[0])
        self.assertEqual(self.open("replacement")["context"], "replacement")
        self.assertEqual(self.snapshot()["preedit"], "あ")

    def test_surroundings_require_privacy_and_bound_utf8_before_focus_is_acquired(self):
        self.focus_out(submit=False)
        for surroundings in (
                {"leftContext": "", "rightContext": ""},
                {"leftContext": "x" * (self.limits["contextBytes"] + 1), "rightContext": "", "privateInput": False},
                {"leftContext": "", "rightContext": "", "privateInput": False, "focusEpoch": 50}):
            self.assert_rejected_without_edit("focus-in", reference=self.reference, surroundings=surroundings)
        self.focus(left="l" * self.limits["contextBytes"], right="r" * self.limits["contextBytes"])
        self.type("a")
        request = self.prepare()
        self.assertEqual(request["leftContext"], "l" * 100)
        self.assertEqual(request["rightContext"], "r" * 100)

    def test_oversized_and_malformed_lines_are_drained_once_before_later_requests(self):
        hello = b'{"operation":"hello"}'
        oversized = b" " * (self.limits["jsonBytes"] + 1)
        frames = b"\n".join([oversized, b'\xff', hello, b'{"operation":', hello])
        completed = subprocess.run([os.environ["AZOOKEY_BRIDGE"]], input=frames, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, env=self.environment, timeout=REQUEST_TIMEOUT_SECONDS,
                                   check=True)
        replies = [json.loads(line) for line in completed.stdout.splitlines()]
        self.assertEqual(len(replies), 5)
        self.assertEqual([reply["kind"] for reply in replies], ["error", "error", "process", "error", "process"])
        self.assertEqual(replies[0]["error"], "reading_request_limit")
        self.assertEqual(replies[2], replies[4])
        self.assertNotEqual(replies[2]["readingProcessGeneration"], self.process_generation)
        for reply in replies:
            self.assertNotIn("snapshot", reply)


if __name__ == "__main__":
    unittest.main()
