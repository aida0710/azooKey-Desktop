#!/usr/bin/env python3
"""Loopback-only AI fixture with an observable, explicitly released response."""
import argparse
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import pathlib
import threading
import time
from urllib import request
from urllib.parse import urlsplit


MODEL = "fixture-model"
TARGET = "TARGET_TEXT"
TRANSFORMED_TEXT = "変換した本文"
SUGGESTIONS = ["候補A", "候補B"]
# Test payloads are small. Reject unrelated/oversized input before recording it.
MAXIMUM_BODY_BYTES = 65536
# Stay below the installed bridge's 90-second request deadline.
RELEASE_TIMEOUT_SECONDS = 45
READ_TIMEOUT_SECONDS = 5
API_PATHS = {"/ai", "/transform", "/v1/chat/completions"}
OUTCOMES = {"success", "empty", "failure"}


def reply_content(body, *, path, empty=False):
    schema = body.get("response_format", {}).get("json_schema", {})
    if path == "/transform" or schema.get("name") == "text_transform_response":
        content = {"result": "" if empty else TRANSFORMED_TEXT}
    else:
        content = {"predictions": [] if empty else SUGGESTIONS}
    return {"choices": [{"message": {"content": json.dumps(content, ensure_ascii=False)}}]}


@dataclass
class RequestGate:
    identifier: int
    path: str
    body: dict
    arrived_at: float = field(default_factory=time.time)
    released: threading.Event = field(default_factory=threading.Event)
    outcome: str = "success"
    state: str = "waiting"

    def observation(self):
        return {
            "id": self.identifier, "path": self.path, "body": self.body,
            "arrivedAt": self.arrived_at, "state": self.state, "outcome": self.outcome,
        }


class LocalAIServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, *, hold_requests=True, log_path=None, release_timeout=RELEASE_TIMEOUT_SECONDS):
        # Neither the CLI nor callers can bind an external address or proxy URL.
        super().__init__(("127.0.0.1", 0), FixtureHandler)
        self.hold_requests = hold_requests
        self.log_path = pathlib.Path(log_path) if log_path else None
        self.release_timeout = release_timeout
        self.requests = []
        self.condition = threading.Condition()
        self.events = []

    @property
    def endpoint(self):
        return f"http://127.0.0.1:{self.server_port}/v1/chat/completions"

    def record(self, event, **values):
        with self.condition:
            observation = {"event": event, "at": time.time(), "monotonicNS": time.monotonic_ns(), **values}
            self.events.append(observation)
            if self.log_path:
                with self.log_path.open("a", encoding="utf-8") as stream:
                    stream.write(json.dumps(observation, ensure_ascii=False) + "\n")
            self.condition.notify_all()

    def receive(self, path, body):
        with self.condition:
            gate = RequestGate(len(self.requests) + 1, path, body)
            self.requests.append(gate)
            self.record("received", **gate.observation())
        if not self.hold_requests:
            self.release(gate.identifier, "success")
        return gate

    def release(self, identifier, outcome):
        with self.condition:
            if not isinstance(outcome, str) or outcome not in OUTCOMES or not 1 <= identifier <= len(self.requests):
                return False
            gate = self.requests[identifier - 1]
            if gate.state != "waiting":
                return False
            gate.state, gate.outcome = "released", outcome
            self.record("released", id=identifier, outcome=outcome)
            gate.released.set()
            return True

    def observations(self):
        with self.condition:
            return [gate.observation() for gate in self.requests]

    def wait_for_requests(self, count, *, timeout):
        with self.condition:
            if not self.condition.wait_for(lambda: len(self.requests) >= count, timeout):
                raise TimeoutError("The synthetic AI request did not arrive")
            return self.observations()


class FixtureHandler(BaseHTTPRequestHandler):
    def setup(self):
        super().setup()
        self.connection.settimeout(READ_TIMEOUT_SECONDS)

    def log_message(self, *_arguments):
        # Do not log headers, especially the real application's Authorization.
        pass

    def respond(self, status, body):
        encoded = json.dumps(body, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def do_GET(self):
        if self.path == "/state":
            self.respond(200, {"requests": self.server.observations()})
        else:
            self.respond(404, {"error": "unknown_fixture_path"})

    def read_body(self):
        length = int(self.headers.get("Content-Length", "0"))
        if not 0 < length <= MAXIMUM_BODY_BYTES:
            raise ValueError("invalid_fixture_body_size")
        body = json.loads(self.rfile.read(length))
        if not isinstance(body, dict):
            raise ValueError("invalid_fixture_body")
        return body

    def do_POST(self):
        try:
            body = self.read_body()
        except (ValueError, UnicodeError, TimeoutError):
            self.respond(400, {"error": "invalid_fixture_body"})
            return
        if self.path.startswith("/release/"):
            try:
                identifier = int(self.path.removeprefix("/release/"))
            except ValueError:
                identifier = 0
            released = self.server.release(identifier, body.get("outcome", "success"))
            self.respond(200 if released else 409, {"released": released})
            return
        if self.path not in API_PATHS:
            self.respond(404, {"error": "unknown_fixture_path"})
            return
        if body.get("model") != MODEL or TARGET not in json.dumps(body.get("messages", [])):
            # Never persist a body that was not explicitly prepared for this fixture.
            self.server.record("rejected", reason="fixture_model_or_target_missing")
            self.respond(422, {"error": "fixture_model_or_target_missing"})
            return
        gate = self.server.receive(self.path, body)
        released = gate.released.wait(self.server.release_timeout)
        with self.server.condition:
            if not released and gate.state == "waiting":
                gate.state = "expired"
                self.server.record("expired", id=gate.identifier)
            expired = gate.state == "expired"
        if expired:
            self.respond(504, {"error": "fixture_release_timeout"})
            return
        status = 503 if gate.outcome == "failure" else 200
        response = ({"error": "fixture_failure"} if status == 503 else
                    reply_content(body, path=self.path, empty=gate.outcome == "empty"))
        try:
            self.respond(status, response)
        except (BrokenPipeError, ConnectionResetError):
            self.server.record("disconnected", id=gate.identifier)
        else:
            with self.server.condition:
                gate.state = "responded"
                self.server.record("responded", id=gate.identifier, status=status)


def control_address(state_path):
    state = json.loads(state_path.read_text(encoding="utf-8"))
    endpoint = urlsplit(state["endpoint"])
    if endpoint.scheme != "http" or endpoint.hostname != "127.0.0.1" or endpoint.port is None:
        raise ValueError("Only the local fixture may receive control requests")
    return f"http://127.0.0.1:{endpoint.port}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    serve = commands.add_parser("serve")
    serve.add_argument("--directory", required=True, type=pathlib.Path)
    for action in ("state", "release"):
        control = commands.add_parser(action)
        control.add_argument("--state-file", required=True, type=pathlib.Path)
        if action == "release":
            control.add_argument("--request-id", required=True, type=int)
            control.add_argument("--outcome", choices=sorted(OUTCOMES), default="success")
    arguments = parser.parse_args()
    if arguments.command != "serve":
        address = control_address(arguments.state_file)
        outgoing = request.Request(address + "/state")
        if arguments.command == "release":
            outgoing = request.Request(
                address + f"/release/{arguments.request_id}",
                data=json.dumps({"outcome": arguments.outcome}).encode(),
                headers={"Content-Type": "application/json"},
            )
        # Explicitly ignore proxy environment variables even for control calls.
        with request.build_opener(request.ProxyHandler({})).open(outgoing, timeout=READ_TIMEOUT_SECONDS) as response:
            print(response.read().decode())
        return
    arguments.directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    with LocalAIServer(log_path=arguments.directory / "requests.jsonl") as server:
        state = {"endpoint": server.endpoint, "model": MODEL, "releaseTimeoutSeconds": server.release_timeout}
        (arguments.directory / "server.json").write_text(json.dumps(state) + "\n", encoding="utf-8")
        print(json.dumps(state), flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
