#!/usr/bin/env python3
"""Test offline dictionary preparation with small private archives and no network."""

import gzip
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

MODULE_PATH = Path(__file__).resolve().parents[1] / "fetch-wordnet.py"
SPECIFICATION = importlib.util.spec_from_file_location("fetch_wordnet", MODULE_PATH)
fetch_wordnet = importlib.util.module_from_spec(SPECIFICATION)
SPECIFICATION.loader.exec_module(fetch_wordnet)


def specification(content, **fields):
    return {"size": len(content), "sha256": hashlib.sha256(content).hexdigest(), **fields}


class WordNetPreparationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="azookey-wordnet-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.output = self.directory / "prepared"
        self.licenses = self.directory / "licenses"
        self.licenses.mkdir()
        self.database = b"SQLite format 3\0private test database"
        self.archive_content = gzip.compress(self.database, mtime=0)
        self.archive = self.directory / "pinned.db.gz"
        self.archive.write_bytes(self.archive_content)
        license_content = b"Private fixture license\n"
        (self.licenses / "license.txt").write_bytes(license_content)
        self.manifest = {
            "name": "Fixture dictionary", "version": "1.1", "source": "https://example.invalid/",
            "archive": specification(self.archive_content, url="https://example.invalid/wnjpn.db.gz"),
            "database": specification(self.database, filename="wnjpn.db"),
            "licenses": [specification(license_content, filename="license.txt")],
        }

    def prepare(self, **options):
        fetch_wordnet.prepare_resources(self.output, manifest=self.manifest, licenses_dir=self.licenses,
                                        **options)

    def test_verified_archive_prepares_readable_database_license_and_source_description(self):
        self.prepare(archive=self.archive)
        self.assertEqual((self.output / "wnjpn.db").read_bytes(), self.database)
        self.assertEqual((self.output / "license.txt").read_bytes(), (self.licenses / "license.txt").read_bytes())
        self.assertEqual(json.loads((self.output / "source.json").read_text()), self.manifest)
        for resource in self.output.iterdir():
            self.assertEqual(resource.stat().st_mode & 0o777, 0o644)
        self.prepare(verify_only=True)

    def test_verify_only_missing_resources_neither_creates_output_nor_downloads(self):
        with patch.object(fetch_wordnet.urllib.request, "urlopen") as open_url:
            with self.assertRaises(ValueError):
                self.prepare(verify_only=True)
            open_url.assert_not_called()
        self.assertFalse(self.output.exists())

    def test_verify_only_reports_corruption_without_changing_files(self):
        self.prepare(archive=self.archive)
        target = self.output / "wnjpn.db"
        target.write_bytes(b"damaged")
        with patch.object(fetch_wordnet.urllib.request, "urlopen") as open_url:
            with self.assertRaises(ValueError):
                self.prepare(verify_only=True)
            open_url.assert_not_called()
        self.assertEqual(target.read_bytes(), b"damaged")

    def test_valid_cached_database_does_not_download_again(self):
        self.prepare(archive=self.archive)
        self.archive.unlink()
        with patch.object(fetch_wordnet.urllib.request, "urlopen") as open_url:
            self.prepare()
            open_url.assert_not_called()

    def test_archive_hash_mismatch_cannot_install_a_database(self):
        self.archive.write_bytes(b"untrusted archive")
        with self.assertRaises(ValueError):
            self.prepare(archive=self.archive)
        self.assertEqual(list(self.output.iterdir()), [])

    def test_decompressed_hash_mismatch_preserves_the_previous_database(self):
        self.output.mkdir()
        previous = self.output / "wnjpn.db"
        previous.write_bytes(b"previous data")
        self.manifest["database"]["sha256"] = "0" * 64
        with self.assertRaises(ValueError):
            self.prepare(archive=self.archive)
        self.assertEqual(previous.read_bytes(), b"previous data")
        self.assertEqual(sorted(p.name for p in self.output.iterdir()), ["wnjpn.db"])

    def test_decompression_exceeding_the_pinned_size_leaves_no_partial_database(self):
        self.manifest["database"]["size"] = len(self.database) - 1
        with self.assertRaises(ValueError):
            self.prepare(archive=self.archive)
        self.assertEqual(list(self.output.iterdir()), [])

    def test_download_is_verified_before_extraction(self):
        with patch.object(fetch_wordnet.urllib.request, "urlopen", return_value=io.BytesIO(self.archive_content)) as open_url:
            self.prepare()
            open_url.assert_called_once_with(self.manifest["archive"]["url"], timeout=fetch_wordnet.NETWORK_TIMEOUT_SECONDS)
        self.prepare(verify_only=True)

    def test_corrupt_download_preserves_an_existing_archive_and_cleans_temporary_files(self):
        self.output.mkdir()
        previous = self.output / "wnjpn.db.gz"
        previous.write_bytes(b"previous archive")
        with patch.object(fetch_wordnet.urllib.request, "urlopen", return_value=io.BytesIO(b"wrong bytes")):
            with self.assertRaises(ValueError):
                self.prepare()
        self.assertEqual(previous.read_bytes(), b"previous archive")
        self.assertEqual(sorted(p.name for p in self.output.iterdir()), ["wnjpn.db.gz"])

    def test_altered_license_prevents_preparation_before_any_output_is_written(self):
        (self.licenses / "license.txt").write_bytes(b"altered")
        with self.assertRaises(ValueError):
            self.prepare(archive=self.archive)
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
