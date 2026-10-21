"""Dictionary indicators follow actual page words and retire late background replies."""
from pathlib import Path
import sys
import unittest
from types import SimpleNamespace
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from azookey.word_definition_availability import WordDefinitionAvailability, has_definition


class WordDefinitionAvailabilityTests(unittest.TestCase):
    def setUp(self):
        self.requests = []
        worker = SimpleNamespace(request=lambda target, callback: self.requests.append((target, callback)))
        self.changes = []
        self.completed = []
        self.lookup = WordDefinitionAvailability(worker, self.changes.append,
                                                 completed=lambda: self.completed.append(True))
        self.snapshot = {"contextId": "field", "generation": 1, "focusedNode": 0,
                         "candidatePage": {"items": [{"index": i} for i in range(12)]},
                         "nodes": [{"id": i, "depth": 0, "parent": None, "terminals": [i],
                                    "text": str(i), "reading": "ご"} for i in range(12)]}

    def test_only_nonempty_found_meanings_mark_at_most_nine_page_candidates(self):
        self.lookup.update(self.snapshot)
        self.assertEqual(len(self.requests), 1)
        for index in range(9):
            target, callback = self.requests[index]
            self.assertEqual(target.word, str(index))
            callback({"status": "found" if index % 2 == 0 else "notFound",
                      "senses": [{"definitions": ["意味"]}]})
        self.assertEqual(len(self.requests), 9)
        self.assertEqual(self.lookup.found_indices, {0, 2, 4, 6, 8})
        self.assertEqual(self.completed, [True])
        self.lookup.update(self.snapshot)
        self.assertEqual(len(self.requests), 9)
        for response in [None, {"status": "loading"}, {"status": "found", "senses": []},
                         {"status": "found", "senses": [{"definitions": [" "]}]}]:
            self.assertFalse(has_definition(response))

    def test_replaced_page_and_hidden_popup_ignore_late_replies_and_stop_old_queries(self):
        self.lookup.update(self.snapshot)
        old = self.requests[-1][1]
        self.lookup.update({**self.snapshot, "generation": 2})
        old({"status": "found", "senses": [{"definitions": ["古い意味"]}]})
        self.assertEqual(len(self.requests), 2)
        self.assertEqual(self.lookup.found_indices, set())
        latest = self.requests[-1][1]
        self.lookup.invalidate()
        latest({"status": "found", "senses": [{"definitions": ["隠れた意味"]}]})
        self.assertEqual(self.lookup.found_indices, set())
        self.assertEqual(len(self.requests), 2)
        self.assertEqual(self.completed, [])
