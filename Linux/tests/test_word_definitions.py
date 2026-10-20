"""Dictionary lookups preserve the converter target and never wait in input callbacks."""
from pathlib import Path
from queue import Queue
import json
import os
import sqlite3
import sys
import tempfile
from threading import Event
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from azookey.word_definition_target import WordDefinitionTarget, candidate_path, word_definition_target
from azookey.word_definition_provider import WordDefinitionProvider, MAXIMUM_SYNONYMS
from azookey.word_definition_lookup import WordDefinitionLookup, WordDefinitionWorker, MAXIMUM_CACHED_WORDS


def dictionary(path):
    connection = sqlite3.connect(path)
    connection.executescript("""
        CREATE TABLE word(wordid INTEGER PRIMARY KEY,lang TEXT,lemma TEXT,pron TEXT,pos TEXT);
        CREATE TABLE sense(synset TEXT,wordid INTEGER,lang TEXT,rank INTEGER,lexid INTEGER,freq INTEGER,src TEXT);
        CREATE TABLE synset_def(synset TEXT,lang TEXT,def TEXT,sid INTEGER);
        CREATE TABLE synset_ex(synset TEXT,lang TEXT,def TEXT,sid INTEGER);
        CREATE INDEX lemma ON word(lemma);
        CREATE INDEX sense_word ON sense(wordid);
        CREATE INDEX sense_synset ON sense(synset);
        CREATE INDEX definitions ON synset_def(synset);
        CREATE INDEX examples ON synset_ex(synset);
    """)
    for index, word, reading, synset, definition in (
        (1, "保証", None, "assurance", "義務が果たされるという保証"),
        (2, "保障", None, "protection", "損失や危険から保護すること"),
        (3, "補償", None, "compensation", "損失に対する埋め合わせ"),
        (4, "生物", "せいぶつ", "organism", "生命を持つもの"),
        (5, "生物", "なまもの", "raw", "加熱していない食品"),
        (6, "生物", None, "unspecified", "同じ表記に対する語釈"),
    ):
        connection.execute("INSERT INTO word VALUES(?, 'jpn', ?, ?, 'n')", (index, word, reading))
        connection.execute("INSERT INTO sense VALUES(?, ?, 'jpn', 1, 0, 0, 'fixture')", (synset, index))
        connection.execute("INSERT INTO synset_def VALUES(?, 'jpn', ?, 1)", (synset, definition))
    connection.execute("INSERT INTO synset_ex VALUES('assurance', 'jpn', '保証を求める', 1)")
    for index in range(10, 21):
        connection.execute("INSERT INTO word VALUES(?, 'jpn', ?, NULL, 'n')", (index, f"実在類語{index}"))
        connection.execute("INSERT INTO sense VALUES('assurance', ?, 'jpn', 1, 0, 0, 'fixture')", (index,))
    connection.commit()
    connection.close()


def target(word="保証", reading="ホショウ", generation=1):
    return WordDefinitionTarget("field", generation, 0, word, reading)


class WordDefinitionTargetTests(unittest.TestCase):
    def setUp(self):
        self.snapshot = {"contextId": "field", "generation": 7, "selection": 0, "focusedNode": 0,
                         "selectedPath": [0, 1], "candidates": [{"index": 0, "text": "日本語を勉強"},
                         {"index": 12, "text": "日本語"}], "nodes": [
                         {"id": 0, "text": "日本語", "reading": "ニホンゴ", "depth": 0,
                          "parent": None, "terminals": [12], "preview": {"text": "日本語を勉強", "candidateIndex": 0}},
                         {"id": 1, "text": "を勉強", "reading": "ヲベンキョウ", "depth": 1,
                          "parent": 0, "terminals": [0]}]}

    def test_node_word_is_not_its_descendant_sentence_preview(self):
        result = word_definition_target(self.snapshot)
        self.assertEqual((result.word, result.reading, result.node_id), ("日本語", "ニホンゴ", 0))

    def test_sentence_row_resolves_the_real_display_path(self):
        self.snapshot["candidates"][0]["tokens"] = [{"text": "日本語を勉強", "reading": "ニホンゴヲベンキョウ"}]
        self.assertEqual(candidate_path(self.snapshot, 0), [0, 1])
        self.snapshot["focusedNode"] = 1
        self.assertEqual(word_definition_target(self.snapshot, candidate_index=0).word, "を勉強")

    def test_short_partial_candidate_does_not_invent_a_missing_word(self):
        self.snapshot["focusedNode"] = 1
        self.assertIsNone(word_definition_target(self.snapshot, candidate_index=12))

    def test_missing_reading_special_sentence_is_not_guessed_into_words(self):
        self.snapshot["nodes"][0]["reading"] = ""
        self.assertIsNone(word_definition_target(self.snapshot))

    def test_unknown_or_cyclic_candidate_path_is_rejected(self):
        self.assertIsNone(word_definition_target(self.snapshot, candidate_index=99))
        self.snapshot["nodes"][0]["parent"] = 1
        self.assertEqual(candidate_path(self.snapshot, 0), [])

    def test_generation_and_context_are_part_of_the_target(self):
        first = word_definition_target(self.snapshot)
        self.snapshot["generation"] += 1
        self.assertNotEqual(first, word_definition_target(self.snapshot))
        self.snapshot["contextId"] = "another-field"
        self.assertNotEqual(first, word_definition_target(self.snapshot))


class WordDefinitionProviderTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.path = Path(self.temporary.name) / "wnjpn.db"
        dictionary(self.path)
        self.provider = WordDefinitionProvider(self.path)

    def tearDown(self):
        self.temporary.cleanup()

    def test_homophones_keep_distinct_written_forms(self):
        results = [self.provider.lookup(word, "ホショウ") for word in ("保証", "保障", "補償")]
        self.assertTrue(all(result["status"] == "found" for result in results))
        self.assertEqual(len({result["senses"][0]["definitions"][0] for result in results}), 3)

    def test_real_definitions_examples_and_limited_synonyms_are_read_only(self):
        before = self.path.read_bytes()
        result = self.provider.lookup("保証", "ホショウ")
        self.assertEqual(result["senses"][0]["examples"], ["保証を求める"])
        synonyms = result["senses"][0]["synonyms"]
        self.assertEqual(len(synonyms), MAXIMUM_SYNONYMS)
        self.assertNotIn("保証", synonyms)
        self.assertTrue(all(word.startswith("実在類語") for word in synonyms))
        self.assertEqual(before, self.path.read_bytes())
        self.assertEqual(list(self.path.parent.iterdir()), [self.path])

    def test_known_pronunciation_filters_only_known_other_readings(self):
        result = self.provider.lookup("生物", "セイブツ")
        synsets = {sense["synset"] for sense in result["senses"]}
        self.assertEqual(synsets, {"organism", "unspecified"})
        self.assertTrue(result["readingUnspecified"])

    def test_unrecorded_reading_is_not_claimed_to_be_verified(self):
        result = self.provider.lookup("保証", "ホショウ")
        self.assertTrue(result["readingUnspecified"])

    def test_missing_word_is_different_from_missing_dictionary(self):
        self.assertEqual(self.provider.lookup("未収録の単語", "ミシュウロク")["status"], "notFound")
        self.path.unlink()
        self.assertEqual(self.provider.lookup("保証", "ホショウ")["status"], "unavailable")
        self.assertFalse(self.path.exists())

    def test_corrupt_dictionary_failure_does_not_create_or_repair_files(self):
        self.path.write_text("not a database")
        self.assertEqual(self.provider.lookup("保証", "ホショウ")["status"], "error")
        self.assertEqual(self.path.read_text(), "not a database")

    def test_lookup_text_is_bound_as_a_value(self):
        self.assertEqual(self.provider.lookup("保証' OR 1=1 --", "ホショウ")["status"], "notFound")


class BlockingProvider:
    def __init__(self):
        self.started = Event()
        self.release = Event()
        self.calls = []

    def lookup(self, word, reading):
        self.calls.append(word)
        if len(self.calls) == 1:
            self.started.set()
            if not self.release.wait(3):
                raise RuntimeError("Fixture did not release the provider")
        return {"status": "found", "word": word, "reading": reading, "senses": []}


class WordDefinitionLookupTests(unittest.TestCase):
    def setUp(self):
        self.provider = BlockingProvider()
        self.deliveries = Queue()
        self.worker = WordDefinitionWorker(provider=self.provider, dispatch=self.deliveries.put)
        self.changed = []
        self.lookup = WordDefinitionLookup(self.worker, self.changed.append)

    def tearDown(self):
        self.provider.release.set()
        self.worker.close()
        if self.worker.thread:
            self.worker.thread.join(3)
            self.assertFalse(self.worker.thread.is_alive())

    def deliver(self):
        self.deliveries.get(timeout=3)()

    def test_slow_query_returns_to_input_without_waiting_for_dictionary(self):
        started = time.monotonic()
        self.lookup.update(target())
        self.assertLess(time.monotonic() - started, .25)
        self.assertTrue(self.provider.started.wait(3))
        self.assertEqual(self.changed[-1]["status"], "loading")
        self.provider.release.set(); self.deliver()
        self.assertEqual(self.changed[-1]["status"], "found")

    def test_only_newest_waiting_word_runs_after_a_slow_query(self):
        self.lookup.update(target("保証"))
        self.assertTrue(self.provider.started.wait(3))
        self.lookup.update(target("保障"))
        self.lookup.update(target("補償"))
        self.provider.release.set()
        self.deliver(); self.deliver(); self.deliver()
        self.assertEqual(self.lookup.result["status"], "found")
        self.assertEqual(self.provider.calls, ["保証", "補償"])
        self.assertEqual(self.changed[-1]["word"], "補償")
        self.assertNotIn("保証", [entry["word"] for entry in self.changed if entry["status"] == "found"])

    def test_every_replaced_request_gets_a_stale_or_completed_reply(self):
        replies = []
        self.worker.request(target("保証"), lambda response: replies.append(("first", response["status"])))
        self.assertTrue(self.provider.started.wait(3))
        self.worker.request(target("保障"), lambda response: replies.append(("replaced", response["status"])))
        self.worker.request(target("補償"), lambda response: replies.append(("latest", response["status"])))
        self.provider.release.set()
        self.deliver(); self.deliver(); self.deliver()
        self.assertEqual(sorted(replies), [("first", "found"), ("latest", "found"), ("replaced", "stale")])

    def test_closing_worker_answers_running_waiting_and_later_requests_once(self):
        replies = []
        self.worker.request(target("保証"), lambda response: replies.append(("running", response["status"])))
        self.assertTrue(self.provider.started.wait(3))
        self.worker.request(target("保障"), lambda response: replies.append(("waiting", response["status"])))
        self.worker.close()
        self.worker.request(target("補償"), lambda response: replies.append(("later", response["status"])))
        self.provider.release.set()
        self.deliver(); self.deliver(); self.deliver()
        self.assertEqual(sorted(replies), [("later", "stale"), ("running", "stale"), ("waiting", "stale")])

    def test_hidden_or_old_focus_result_cannot_restore_the_dictionary_view(self):
        self.lookup.update(target())
        self.assertTrue(self.provider.started.wait(3))
        self.lookup.invalidate()
        self.provider.release.set(); self.deliver()
        self.assertIsNone(self.lookup.result)
        self.assertEqual(len(self.changed), 1)

    def test_same_word_new_generation_discards_old_completion(self):
        self.lookup.update(target())
        self.assertTrue(self.provider.started.wait(3))
        self.lookup.update(target(generation=2))
        self.provider.release.set()
        self.deliver()
        self.assertEqual(self.lookup.result["status"], "loading")
        self.deliver()
        self.assertEqual(self.lookup.result["status"], "found")

    def test_cached_words_and_cache_size_remain_bounded(self):
        self.provider.release.set()
        for index in range(MAXIMUM_CACHED_WORDS + 1):
            self.lookup.update(target(f"語{index}")); self.deliver()
        self.assertEqual(len(self.worker.cache), MAXIMUM_CACHED_WORDS)
        calls = len(self.provider.calls)
        self.lookup.invalidate(); self.lookup.update(target(f"語{MAXIMUM_CACHED_WORDS}")); self.deliver()
        self.assertEqual(len(self.provider.calls), calls)

    def test_provider_exception_becomes_an_error_without_ending_the_worker(self):
        self.provider.release.set()
        def broken(*_args):
            raise sqlite3.DatabaseError("fixture")
        self.provider.lookup = broken
        self.lookup.update(target()); self.deliver()
        self.assertEqual(self.lookup.result["status"], "error")


@unittest.skipUnless(os.environ.get("AZOOKEY_WORDNET_TEST_DB"), "requires the fixed official WordNet database")
class OfficialWordNetTests(unittest.TestCase):
    def test_official_homophones_have_real_separate_definitions_and_attribution(self):
        provider = WordDefinitionProvider(os.environ["AZOOKEY_WORDNET_TEST_DB"])
        results = [provider.lookup(word, "ホショウ") for word in ("保証", "保障", "補償")]
        self.assertTrue(all(result["status"] == "found" and result["senses"] for result in results))
        self.assertEqual(len({json.dumps(result["senses"], ensure_ascii=False) for result in results}), 3)
        self.assertTrue(any(sense["examples"] for result in results for sense in result["senses"]))
        self.assertTrue(all("NICT" in result["copyright"] and result["sourceURL"].startswith("https://bond-lab.github.io/") for result in results))
        if output := os.environ.get("AZOOKEY_WORD_DEFINITION_EVIDENCE"):
            Path(output).write_text(json.dumps(results, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    unittest.main()
