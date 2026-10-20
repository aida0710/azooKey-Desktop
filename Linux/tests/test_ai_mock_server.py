"""Verify the local server's real HTTP boundary before using it for GUI tests."""
from concurrent.futures import ThreadPoolExecutor
import json
import pathlib
import sys
import tempfile
import threading
import unittest
from urllib import error, request

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "Tools/tests"))
from ai_mock_server import LocalAIServer, control_address


class LocalAIFixtureTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.log = pathlib.Path(self.directory.name) / "requests.jsonl"
        self.server = LocalAIServer(log_path=self.log)
        self.worker = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.worker.start()
        self.clients = ThreadPoolExecutor(max_workers=2)
        self.endpoint = self.server.endpoint

    def tearDown(self):
        for observation in self.server.observations():
            self.server.release(observation["id"], "failure")
        self.clients.shutdown(wait=True)
        self.server.shutdown()
        self.server.server_close()
        self.worker.join(timeout=2)
        self.directory.cleanup()

    @staticmethod
    def body():
        return {
            "model": "fixture-model",
            "messages": [{"role": "user", "content": "fixture rewrite TARGET_TEXT"}],
            "response_format": {"json_schema": {"name": "text_transform_response"}},
        }

    def post(self, body, *, path="/v1/chat/completions"):
        outgoing = request.Request(
            self.endpoint.removesuffix("/v1/chat/completions") + path,
            data=json.dumps(body).encode(),
            headers={"Content-Type": "application/json", "Authorization": "Bearer synthetic-test-placeholder"},
        )
        try:
            response = request.build_opener(request.ProxyHandler({})).open(outgoing, timeout=5)
        except error.HTTPError as failure:
            response = failure
        with response:
            return response.status, json.loads(response.read())

    def test_arriving_request_waits_until_its_own_release_and_never_records_headers(self):
        pending = self.clients.submit(self.post, self.body())
        observed = self.server.wait_for_requests(1, timeout=2)
        self.assertEqual(observed[0]["state"], "waiting")
        self.assertFalse(pending.done())
        self.assertEqual(self.post({"outcome": []}, path="/release/1")[0], 409)
        status, released = self.post({"outcome": "success"}, path="/release/1")
        self.assertEqual((status, released), (200, {"released": True}))
        status, reply = pending.result(timeout=2)
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(reply["choices"][0]["message"]["content"]), {"result": "変換した本文"})
        self.assertEqual(self.post({}, path="/release/1")[0], 409)
        log = self.log.read_text()
        self.assertNotIn("Authorization", log)
        self.assertNotIn("synthetic-test-placeholder", log)

    def test_releasing_second_request_does_not_complete_the_first(self):
        first = self.clients.submit(self.post, self.body())
        self.server.wait_for_requests(1, timeout=2)
        second = self.clients.submit(self.post, self.body())
        self.server.wait_for_requests(2, timeout=2)
        self.assertTrue(self.server.release(2, "empty"))
        status, reply = second.result(timeout=2)
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(reply["choices"][0]["message"]["content"]), {"result": ""})
        self.assertFalse(first.done())
        self.assertTrue(self.server.release(1, "failure"))
        self.assertEqual(first.result(timeout=2), (503, {"error": "fixture_failure"}))

    def test_unreleased_request_expires_without_a_successful_response(self):
        self.server.release_timeout = 0.02
        self.assertEqual(self.post(self.body()), (504, {"error": "fixture_release_timeout"}))
        self.assertFalse(self.server.release(1, "success"))
        self.assertEqual(self.server.observations()[0]["state"], "expired")

    def test_unrelated_input_is_rejected_without_recording_its_contents(self):
        unrelated = self.body()
        unrelated["messages"][0]["content"] = "unrelated content must not be logged"
        self.assertEqual(self.post(unrelated)[0], 422)
        self.assertEqual(self.server.observations(), [])
        self.assertNotIn("unrelated content", self.log.read_text())
        unrelated["model"] = "some-other-model"
        unrelated["messages"][0]["content"] = "TARGET_TEXT"
        self.assertEqual(self.post(unrelated)[0], 422)

    def test_server_and_control_client_only_use_loopback(self):
        self.assertEqual(self.server.server_address[0], "127.0.0.1")
        state = pathlib.Path(self.directory.name) / "server.json"
        for endpoint in ("https://example.org/v1/chat/completions", "http://0.0.0.0:9999/",
                         "http://localhost:9999/", "http://127.0.0.1/"):
            with self.subTest(endpoint=endpoint):
                state.write_text(json.dumps({"endpoint": endpoint}))
                with self.assertRaises(ValueError):
                    control_address(state)
        state.write_text(json.dumps({"endpoint": self.endpoint}))
        self.assertEqual(control_address(state), f"http://127.0.0.1:{self.server.server_port}")

    def test_existing_bridge_fixture_can_return_candidates_without_a_gate(self):
        self.server.hold_requests = False
        # Normal candidate requests use a different structured response schema.
        candidate_request = self.body()
        del candidate_request["response_format"]
        status, reply = self.post(candidate_request, path="/ai")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(reply["choices"][0]["message"]["content"]), {"predictions": ["候補A", "候補B"]})


if __name__ == "__main__":
    unittest.main()
