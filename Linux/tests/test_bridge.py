import os
import pathlib
import sys
import unittest
import tempfile
import json
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from azookey.bridge import Bridge
from azookey.keymap import translate
from azookey.personalization import import_model
from unittest.mock import patch


@unittest.skipUnless(os.environ.get("AZOOKEY_BRIDGE"), "build the real Swift bridge first")
class BridgeIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.old = os.environ.get("AZOOKEY_DATA_DIR")
        os.environ["AZOOKEY_DATA_DIR"] = self.directory.name
        self.config_environment = patch.dict(os.environ, {"XDG_CONFIG_HOME": str(pathlib.Path(self.directory.name) / "config")})
        self.config_environment.start()
        self.bridge = Bridge()

    def tearDown(self):
        self.bridge.close()
        self.config_environment.stop()
        if self.old is None:
            os.environ.pop("AZOOKEY_DATA_DIR", None)
        else:
            os.environ["AZOOKEY_DATA_DIR"] = self.old
        self.directory.cleanup()

    def apply_settings(self, settings):
        snapshot = self.bridge.request("configure", settings=settings)
        self.assertNotIn("error", snapshot, "the requested preferences must reach the converter")
        return snapshot

    @unittest.skipUnless(sys.platform == "linux", "isolated settings")
    def test_initial_settings_can_be_reapplied_after_conversion_process_restarts(self):
        settings = self.bridge.request("settings")["settings"]
        self.bridge.close()
        self.bridge = Bridge()
        self.apply_settings({**settings, "learning": "onlyOutput"})
        reapplied = self.bridge.request("settings")["settings"]
        self.assertEqual(reapplied["learning"], "onlyOutput")
        self.assertEqual(reapplied["userDictionary"], settings["userDictionary"])

    @unittest.skipUnless(sys.platform == "linux", "isolated settings")
    def test_restarting_with_saved_default_entries_preserves_their_existing_ids(self):
        settings = self.bridge.request("settings")["settings"]
        for entry in settings["userDictionary"]["items"]:
            entry["id"] = str(uuid.uuid4()).upper()
        settings_path = pathlib.Path(os.environ["XDG_CONFIG_HOME"]) / "azookey-tree" / "settings.json"
        settings_path.parent.mkdir(parents=True, exist_ok=True)
        saved_content = json.dumps(settings, ensure_ascii=False).encode()
        settings_path.write_bytes(saved_content)

        for _ in range(2):
            self.bridge.close()
            self.bridge = Bridge()
            self.apply_settings({**settings, "learning": "onlyOutput"})
            reapplied = self.bridge.request("settings")["settings"]
            self.assertEqual(reapplied["learning"], "onlyOutput")
            self.assertEqual(reapplied["userDictionary"], settings["userDictionary"])
            self.assertEqual(settings_path.read_bytes(), saved_content)

    def test_protocol_real_conversion_and_stale_generation(self):
        for character in "nihongo":
            self.bridge.request("key", event=translate(ord(character), 0))
        result = self.bridge.request("key", event=translate(32, 0))
        if os.environ.get("AZOOKEY_CPU_TRAIT") == "1" and os.environ.get("AZOOKEY_RESOURCES"):
            self.assertTrue(result["zenzaiLoaded"], "CPU Zenzai must load the verified model, without a silent fallback")
        candidate = next(item for item in result["candidates"] if item["text"] == "日本語")
        stale = self.bridge.request("select", index=candidate["index"], generation=result["generation"] - 1, submit=True)
        self.assertEqual(stale["commits"], [])
        selected = self.bridge.request("select", index=candidate["index"], generation=result["generation"], submit=True)
        self.assertEqual(selected["commits"], ["日本語"])
        self.assertEqual(selected["preedit"], "")

    def test_invalid_request_does_not_crash(self):
        self.assertEqual(self.bridge.request("not-an-operation")["error"], "invalid_request")
        self.assertEqual(self.bridge.request("snapshot")["preedit"], "")

    @unittest.skipUnless(sys.platform == "linux", "isolated settings")
    def test_space_cycles_normal_candidates_and_shift_space_reverses(self):
        original = self.bridge.request("settings")["settings"]
        try:
            self.bridge.request("configure", settings={**original, "live": True})
            for character in "nihongo":
                self.bridge.request("key", event=translate(ord(character), 0))
            first = self.bridge.request("key", event=translate(32, 0))
            second = self.bridge.request("key", event=translate(32, 0))
            self.assertEqual(second["selection"], first["selection"] + 1)
            previous = self.bridge.request("key", event=translate(32, 1))
            self.assertEqual(previous["selection"], first["selection"])
        finally:
            self.bridge.request("reset")
            self.bridge.request("configure", settings=original)

    def test_two_input_contexts_keep_independent_compositions(self):
        for character in "nihongo":
            self.bridge.request("key", context="first", event=translate(ord(character), 0))
        for character in "arigatou":
            self.bridge.request("key", context="second", event=translate(ord(character), 0))
        self.assertEqual(self.bridge.request("snapshot", context="first")["reading"], "にほんご")
        self.assertEqual(self.bridge.request("snapshot", context="second")["reading"], "ありがとう")
        self.bridge.request("close", context="first")
        self.assertEqual(self.bridge.request("snapshot", context="second")["reading"], "ありがとう")

    def test_ai_suggestions_reject_changed_composition_and_commit_original_index(self):
        self.bridge.request("key", event=translate(ord("a"), 0))
        snapshot = self.bridge.request("snapshot")
        result = self.bridge.request("suggestions", suggestions=["甲", "乙"], reading=snapshot["reading"], generation=snapshot["generation"] - 1)
        self.assertFalse(any(c["text"] == "乙" for c in result["candidates"]))
        result = self.bridge.request("suggestions", suggestions=["甲", "乙"], reading=snapshot["reading"], generation=snapshot["generation"])
        result = self.bridge.request("select", index=1, generation=result["generation"], submit=True)
        self.assertEqual(result["commits"], ["乙"])

    @unittest.skipUnless(sys.platform == "linux", "isolated settings")
    def test_pending_or_failed_ai_keeps_composition_and_discards_old_suggestions(self):
        original = self.bridge.request("settings")["settings"]
        try:
            self.bridge.request("configure", settings={**original, "aiEnabled": True, "live": False})
            for character in "nihongo":
                self.bridge.request("key", event=translate(ord(character), 0))
            pending = self.bridge.request("key", event=translate(ord("s"), 4))
            self.assertEqual(pending["request"], "replace")
            self.assertTrue(pending["preedit"])
            failed = self.bridge.request("suggestions", suggestions=[], reading=pending["reading"], generation=pending["generation"])
            self.assertTrue(failed["preedit"])
            entered = self.bridge.request("key", event=translate(0xFF0D, 0))
            self.assertTrue(entered["commits"], "Enter after AI failure must preserve and commit the input")
            self.bridge.request("key", event=translate(ord("a"), 0))
            first = self.bridge.request("snapshot")
            self.bridge.request("suggestions", suggestions=["前回の候補"], reading=first["reading"], generation=first["generation"])
            self.bridge.request("key", event=translate(ord("i"), 0))
            again = self.bridge.request("key", event=translate(ord("s"), 4))
            self.assertNotIn("前回の候補", [c["text"] for c in again["candidates"]])
            entered = self.bridge.request("key", event=translate(0xFF0D, 0))
            self.assertTrue(entered["commits"])
            self.assertNotIn("前回の候補", entered["commits"])
            self.assertEqual(entered["preedit"], "")
        finally:
            self.bridge.request("reset")
            self.bridge.request("configure", settings=original)

    @unittest.skipUnless(sys.platform == "linux", "isolated learning data")
    def test_public_learning_survives_private_input_and_fresh_process_can_reset_it(self):
        original = self.bridge.request("settings")["settings"]
        try:
            self.bridge.request("configure", settings={**original, "learning": "inputAndOutput"})
            for character in "nihongo":
                self.bridge.request("key", context="public", event=translate(ord(character), 0))
            shown = self.bridge.request("key", context="public", event=translate(32, 0))
            index = next(c["index"] for c in shown["candidates"] if c["text"] == "日本語")
            self.bridge.request("select", context="public", index=index, generation=shown["generation"], submit=True)
            self.bridge.request("key", context="private", privateInput=True, event=translate(ord("a"), 0))
            self.bridge.close()
            self.bridge = Bridge()
            memory = pathlib.Path(self.directory.name) / "memory" / "memory.louds"
            self.assertTrue(memory.exists(), "PRIVATE input must not discard prior public learning")
            result = self.bridge.request("reset-learning")
            self.assertNotIn("error", result)
            self.assertFalse(memory.exists(), "reset must work before the first conversion")
        finally:
            self.bridge.request("configure", settings=original)

    @unittest.skipUnless(sys.platform == "linux", "isolated learning data")
    def test_stopping_learning_updates_keeps_existing_results_and_disabling_use_keeps_saved_data(self):
        original = self.bridge.request("settings")["settings"]
        # Compare only the learning policy, independently of neural model ranking.
        environment = dict(os.environ)
        environment.pop("AZOOKEY_RESOURCES", None)
        self.bridge.close()
        self.bridge = Bridge(environment=environment)

        def candidates_for(reading):
            self.bridge.request("reset")
            for character in reading:
                self.bridge.request("key", event=translate(ord(character), 0))
            self.bridge.request("key", event=translate(32, 0))
            return self.bridge.request("key", event=translate(32, 0))

        def commit_candidate(snapshot, word):
            candidate = next(item for item in snapshot["candidates"] if item["text"] == word)
            self.bridge.request("select", index=candidate["index"], generation=snapshot["generation"], submit=True)

        def stored_memory():
            directory = pathlib.Path(self.directory.name) / "memory"
            return {path.name: path.read_bytes() for path in directory.iterdir() if path.is_file()}

        try:
            settings = {**original, "live": False, "learning": "inputAndOutput"}
            self.apply_settings(settings)
            baseline = candidates_for("kyou")
            baseline_rank = [item["text"] for item in baseline["candidates"]].index("京")
            commit_candidate(baseline, "京")
            self.bridge.close()
            learned_memory = stored_memory()
            self.assertTrue(learned_memory, "the fixture must save actual converter learning")

            def check_stopped_learning(mode):
                self.bridge = Bridge(environment=environment)
                try:
                    self.apply_settings({**settings, "learning": mode})
                    snapshot = candidates_for("kyou")
                    rank = [item["text"] for item in snapshot["candidates"]].index("京")
                    if mode == "onlyOutput":
                        self.assertLess(rank, baseline_rank, "existing learning must still affect conversion")
                    else:
                        self.assertEqual(rank, baseline_rank, "disabled learning must not affect conversion")
                    # Both modes stop updates, including commits of a different word.
                    commit_candidate(candidates_for("nihongo"), "日本語")
                finally:
                    self.bridge.close()
                self.assertEqual(stored_memory(), learned_memory, "stopping learning must not update or delete saved data")

            for mode in ("onlyOutput", "nothing", "onlyOutput"):
                with self.subTest(mode=mode):
                    check_stopped_learning(mode)
        finally:
            self.bridge.close()
            self.bridge = Bridge()
            self.apply_settings(original)

    @unittest.skipUnless(sys.platform == "linux" and os.environ.get("AZOOKEY_RESOURCES"), "verified MARISA model fixture")
    def test_personalization_import_and_off_apply_to_the_existing_session(self):
        original = self.bridge.request("settings")["settings"]
        try:
            self.bridge.request("configure", settings={**original, "personalization": "off"})
            self.assertFalse(self.bridge.request("snapshot")["personalizationConfigured"])
            # The verified base model is a structurally valid personal-model
            # fixture; this exercises loading, not a claimed quality improvement.
            import_model(os.environ["AZOOKEY_RESOURCES"])
            enabled = self.bridge.request("configure", settings={**original, "personalization": "normal"})
            self.assertTrue(enabled["personalizationConfigured"])
            for char in "nihongo":
                state = self.bridge.request("key", event=translate(ord(char), 0))
            self.assertTrue(state["zenzaiLoaded"])
            self.assertTrue(state["preedit"])
            disabled = self.bridge.request("configure", settings={**original, "personalization": "off"})
            self.assertFalse(disabled["personalizationConfigured"])
            self.assertEqual(disabled["reading"], "にほんご")
        finally:
            self.bridge.request("reset")
            self.bridge.request("configure", settings=original)

    @unittest.skipUnless(sys.platform == "linux", "settings integration runs in the isolated Ubuntu container")
    def test_settings_user_dictionary_and_custom_table_validation(self):
        original = self.bridge.request("settings")["settings"]
        try:
            settings = {**original, "live": False, "learning": "nothing",
                        "userDictionary": {"items": [{"id": "18afee1d-8174-45c6-80e2-78d315b73f81", "reading": "こでっくす", "word": "Codex検証辞書", "hint": "test"}]}}
            self.assertNotIn("error", self.bridge.request("configure", settings=settings))
            for character in "kodekkusu":
                self.bridge.request("key", event=translate(ord(character), 0))
            snapshot = self.bridge.request("key", event=translate(32, 0))
            self.assertEqual(snapshot["preedit"], "Codex検証辞書")
            # With live conversion disabled, the first Space previews the top
            # candidate; the second opens selection, matching upstream.
            snapshot = self.bridge.request("key", event=translate(32, 0))
            self.assertIn("Codex検証辞書", [c["text"] for c in snapshot["candidates"]])
            self.assertIn("error", self.bridge.request("configure", settings={**settings, "inferenceLimit": -1}))
            self.assertEqual(self.bridge.request("settings")["settings"]["inferenceLimit"], settings["inferenceLimit"])
        finally:
            self.bridge.request("reset")
            self.bridge.request("configure", settings=original)

    @unittest.skipUnless(sys.platform == "linux", "local API fixture runs in isolated Ubuntu")
    def test_openai_compatible_api_with_local_fixture(self):
        received = []
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                received.append(body)
                content = json.dumps({"predictions": ["候補A", "候補B"]}, ensure_ascii=False)
                response = json.dumps({"choices": [{"message": {"content": content}}]}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(response)))
                self.end_headers()
                self.wfile.write(response)
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        original = self.bridge.request("settings")["settings"]
        try:
            endpoint = f"http://127.0.0.1:{server.server_port}/v1/chat/completions"
            self.bridge.request("configure", settings={**original, "aiEndpoint": endpoint, "aiModel": "fixture-model"})
            response = self.bridge.request("ai", apiKey="local-test-placeholder", target="えもじ", prompt="fixture context")
            self.assertEqual(response["suggestions"], ["候補A", "候補B"])
            self.assertEqual(received[0]["model"], "fixture-model")
        finally:
            self.bridge.request("configure", settings=original)
            server.shutdown()
            server.server_close()
            worker.join(timeout=2)


if __name__ == "__main__":
    unittest.main()
