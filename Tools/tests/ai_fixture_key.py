#!/usr/bin/env python3
"""Create/remove only this synthetic test's temporary Secret Service item."""
import argparse
import json
import os
import pathlib
import uuid


SCHEMA_NAME = "org.azookey.Tree"
SERVICE = "openai-compatible"
FAKE_KEY = "azookey-ux-local-fixture-not-a-real-key"
LABEL = "azooKey UX loopback test (synthetic)"


def save_state(path, state):
    pending = path.with_suffix(".pending")
    with pending.open("w", encoding="utf-8") as stream:
        os.chmod(pending, 0o600)
        json.dump(state, stream)
        stream.flush()
        os.fsync(stream.fileno())
    pending.replace(path)


class FixtureKey:
    def __init__(self, secret):
        self.secret = secret
        self.service = secret.Service.get_sync(secret.ServiceFlags.NONE, None)
        attributes = {"service": secret.SchemaAttributeType.STRING}
        self.product_schema = secret.Schema.new(SCHEMA_NAME, secret.SchemaFlags.NONE, attributes)
        self.fixture_schema = secret.Schema.new(
            SCHEMA_NAME, secret.SchemaFlags.NONE,
            {**attributes, "azookey-ux-fixture": secret.SchemaAttributeType.STRING},
        )

    def search(self, schema, attributes):
        # ALL includes locked entries; neither UNLOCK nor LOAD_SECRETS is used.
        return self.service.search_sync(schema, attributes, self.secret.SearchFlags.ALL, None)

    def create(self, path):
        if path.exists():
            raise ValueError("The fixture state already exists; restore that session first")
        if self.search(self.product_schema, {"service": SERVICE}):
            raise ValueError("An existing AI key is present; its contents were not read or changed")
        state = {"fixture": str(uuid.uuid4()), "phase": "creating"}
        save_state(path, state)
        attributes = {"service": SERVICE, "azookey-ux-fixture": state["fixture"]}
        # An extra attribute identifies our item; the product matches the same
        # schema/service subset. Session storage does not persist after logout.
        if not self.secret.password_store_sync(
            self.fixture_schema, attributes, self.secret.COLLECTION_SESSION, LABEL, FAKE_KEY, None,
        ):
            raise RuntimeError("The synthetic session key could not be stored")
        items = self.search(self.fixture_schema, attributes)
        if len(items) != 1:
            raise RuntimeError("The synthetic key's identity could not be verified")
        state.update(phase="created", objectPath=items[0].get_object_path())
        save_state(path, state)
        return state

    def remove(self, path):
        state = json.loads(path.read_text(encoding="utf-8"))
        identifier = str(uuid.UUID(state["fixture"]))
        attributes = {"service": SERVICE, "azookey-ux-fixture": identifier}
        items = self.search(self.fixture_schema, attributes)
        if len(items) > 1:
            raise RuntimeError("More than one item matches this fixture; no item was removed")
        for item in items:
            actual = item.get_attributes()
            if (any(actual.get(key) != value for key, value in attributes.items())
                    or item.get_label() != LABEL
                    or state.get("objectPath", item.get_object_path()) != item.get_object_path()):
                raise RuntimeError("The item no longer matches this fixture; it was preserved")
            if not item.delete_sync(None):
                raise RuntimeError("The synthetic key could not be removed")
        state["phase"] = "removed"
        save_state(path, state)
        return state


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("create", "remove"))
    parser.add_argument("--state-file", required=True, type=pathlib.Path)
    arguments = parser.parse_args()
    directory = arguments.state_file.parent
    if not directory.is_dir() or directory.stat().st_mode & 0o077:
        raise SystemExit("Use an existing 0700 VM-only directory for fixture state")
    import gi
    gi.require_version("Secret", "1")
    from gi.repository import Secret
    state = getattr(FixtureKey(Secret), arguments.action)(arguments.state_file)
    print(json.dumps({"phase": state["phase"], "fixture": state["fixture"]}))


if __name__ == "__main__":
    main()
