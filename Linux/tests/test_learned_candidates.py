"""Exercise real learning persistence; every fixture uses disposable preferences."""
import json
import os
import pathlib
import sys
import tempfile
import time
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from azookey.bridge import Bridge
from azookey.keymap import translate
from azookey import settings_client
from azookey.user_dictionary_service import UserDictionaryService


FIXTURES = pathlib.Path(__file__).parent / "fixtures" / "learned_candidates.json"
STAGES = ("unlearned", "learned", "restarted")
DICTIONARY_ENTRY_ID = "18AFEE1D-8174-45C6-80E2-78D315B73F81"


@unittest.skipUnless(sys.platform == "linux" and os.environ.get("AZOOKEY_BRIDGE"),
                     "build the real Swift bridge with isolated Linux preferences")
class LearnedCandidateTests(unittest.TestCase):
    def test_learning_and_restart_keep_the_original_candidate_reading_scope_and_commit(self):
        observations = []
        for fixture in json.loads(FIXTURES.read_text()):
            with self.subTest(fixture=fixture["name"]), tempfile.TemporaryDirectory() as directory:
                environment = {**os.environ, "AZOOKEY_DATA_DIR": directory, "XDG_CONFIG_HOME": directory}
                bridge = Bridge(environment=environment)
                try:
                    self.configure_fixture(bridge, fixture, environment=environment)
                    for stage_index, stage in enumerate(STAGES):
                        if stage == "restarted":
                            bridge.close()
                            self.assertTrue((pathlib.Path(directory) / "memory" / "memory.louds").is_file())
                            bridge = Bridge(environment=environment)
                        observation = self.convert_and_commit(bridge, fixture, stage)
                        expected_counts = fixture.get("normalModelTokenCounts")
                        if expected_counts and not observation["zenzaiLoaded"]:
                            self.assertEqual(observation["tokenCount"], expected_counts[stage_index])
                        observations.append(observation)
                finally:
                    bridge.close()
        # Synthetic fixture candidates can be replayed by the tree benchmark.
        output = os.environ.get("AZOOKEY_LEARNED_CANDIDATE_REPORT")
        if output:
            pathlib.Path(output).write_text(json.dumps(observations, ensure_ascii=False, indent=2) + "\n")

    def configure_fixture(self, bridge, fixture, *, environment):
        settings = bridge.request("settings")["settings"]
        settings.update(live=False, tree=True, learning="inputAndOutput", predictiveTyping=False, typoCorrection=False)
        if fixture.get("userDictionary"):
            entries = [{
                "id": DICTIONARY_ENTRY_ID, "word": fixture["text"], "reading": fixture["reading"],
            }]
            service = UserDictionaryService(
                settings_client.load(bridge), bridge_factory=lambda: Bridge(environment=environment),
            )
            # The editor's save transaction installs and verifies the file before
            # configure reloads it into this existing conversion session.
            service.save(entries)
            self.assertIsNotNone(service.last_saved)
            settings = {**settings, "userDictionary": service.last_saved.values["userDictionary"]}
            self.assertEqual(settings_client.load(bridge).values["userDictionary"]["items"], entries)
        self.assertNotIn("error", bridge.request("configure", settings=settings))
        saved = bridge.request("settings")["settings"]
        self.assertEqual(saved["userDictionary"], settings["userDictionary"])

    def convert_and_commit(self, bridge, fixture, stage):
        started = time.perf_counter()
        for character in fixture["roman"]:
            self.assertNotIn("error", bridge.request("key", event=translate(ord(character), 0)))
        # Live OFF: first Space previews, second Space opens candidate selection.
        bridge.request("key", event=translate(32, 0))
        snapshot = bridge.request("key", event=translate(32, 0))
        conversion_seconds = time.perf_counter() - started
        self.assertEqual(snapshot["reading"], fixture["reading"])
        candidate = next((item for item in snapshot["candidates"] if item["text"] == fixture["text"]), None)
        self.assertIsNotNone(candidate, fixture["name"])
        selected = bridge.request("select", index=candidate["index"], generation=snapshot["generation"], submit=False)
        self.assertEqual(selected["selection"], candidate["index"])
        nodes = {node["id"]: node for node in selected["nodes"]}
        path = [nodes[node_id] for node_id in selected["selectedPath"]]
        # Python equality compares the actual code points, including NFD/NFC.
        self.assertEqual("".join(node["text"] for node in path), candidate["text"])
        self.assertEqual("".join(node["reading"] for node in path),
                         "".join(token["reading"] for token in candidate["tokens"]))
        self.assertEqual(candidate["commitScope"],
                         {"consumedReading": fixture["reading"], "remainingReading": ""})
        for node in path:
            self.assertEqual(node["preview"]["candidateIndex"], candidate["index"])
            self.assertEqual(node["preview"]["text"], candidate["text"])
            self.assertEqual(node["preview"]["scope"], candidate["commitScope"])
        if len(candidate["tokens"]) == 1:
            self.assertEqual(len(path), 1, "learned kanji, names and mixed text must not gain invented boundaries")
        committed = bridge.request("node", node=path[-1]["id"], generation=selected["generation"], submit=True)
        self.assertEqual(committed["commits"], [fixture["text"]])
        self.assertEqual(committed["reading"], "")
        self.assertEqual(committed["preedit"], "")
        return {
            "name": fixture["name"], "stage": stage, "conversionSeconds": conversion_seconds,
            "zenzaiLoaded": selected["zenzaiLoaded"], "tokenCount": len(candidate["tokens"]),
            "pathCount": len(path), "selection": candidate["index"], "candidates": selected["candidates"],
            "commits": committed["commits"], "commitScope": candidate["commitScope"],
        }


if __name__ == "__main__":
    unittest.main()
