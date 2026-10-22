#!/usr/bin/env python3
"""Catalog validation and per-platform rendering of Tools/generate-messages.py."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


GENERATOR_PATH = Path(__file__).resolve().parents[1] / "generate-messages.py"
SPECIFICATION = importlib.util.spec_from_file_location("generate_messages", GENERATOR_PATH)
generator = importlib.util.module_from_spec(SPECIFICATION)
SPECIFICATION.loader.exec_module(generator)


def write_catalog(directory, localizable, user_dictionary=None):
    for table, entries in (("Localizable", localizable), ("UserDictionary", user_dictionary or {"title": {"ja": "辞書", "en": "Dictionary"}})):
        path = Path(directory) / table / "group.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(entries, ensure_ascii=False), encoding="utf-8")


def load(localizable, user_dictionary=None):
    with tempfile.TemporaryDirectory() as directory:
        write_catalog(directory, localizable, user_dictionary)
        return generator.load_catalog(Path(directory))


class CatalogValidationTests(unittest.TestCase):
    def assert_rejected(self, localizable, user_dictionary=None):
        with self.assertRaises(generator.CatalogError):
            load(localizable, user_dictionary)

    def test_every_entry_needs_both_languages(self):
        self.assert_rejected({"a.b": {"ja": "あ"}})

    def test_platform_wording_replaces_both_languages(self):
        self.assert_rejected({"a.b": {"ja": "あ", "en": "a", "linux": {"ja": "い"}}})

    def test_placeholders_must_match_in_every_text(self):
        self.assert_rejected({"a.b": {"ja": "{count}件", "en": "{total} items"}})
        self.assert_rejected({"a.b": {"ja": "{count:d}件", "en": "{count} items"}})

    def test_literal_braces_are_rejected(self):
        self.assert_rejected({"a.b": {"ja": "{ 件", "en": "items"}})

    def test_keys_are_unique_across_files_of_a_table(self):
        with tempfile.TemporaryDirectory() as directory:
            write_catalog(directory, {"a.b": {"ja": "あ", "en": "a"}})
            (Path(directory) / "Localizable/other.json").write_text(json.dumps({"a.b": {"ja": "い", "en": "i"}}))
            with self.assertRaises(generator.CatalogError):
                generator.load_catalog(Path(directory))

    def test_unknown_fields_are_rejected(self):
        self.assert_rejected({"a.b": {"ja": "あ", "en": "a", "android": {"ja": "あ", "en": "a"}}})


class RenderingTests(unittest.TestCase):
    def setUp(self):
        self.tables = load({
            "candidate.position": {"ja": "変換候補 {position} / {total}", "en": "{total} candidates, at {position}", "gjs": "position"},
            "candidate.score": {"ja": "スコア {score:d}%", "en": "Score {score:d}%"},
            "reconversion.undo": {"ja": "取り消す（Ctrl）", "en": "Undo (Ctrl)",
                                  "macos": {"ja": "取り消す（Control）", "en": "Undo (Control)"}, "gjs": "undo"},
            "settings.detail": {"ja": "{reason}\n対象: \"{path}\"", "en": "{reason}\nFile: \"{path}\""},
        })
        self.sources = generator.generated_sources(self.tables)

    def test_macos_uses_its_wording_and_apple_format_specifiers(self):
        japanese = self.sources["Core/Sources/Core/Resources/ja.lproj/Localizable.strings"]
        english = self.sources["Core/Sources/Core/Resources/en.lproj/Localizable.strings"]
        self.assertIn('"reconversion.undo" = "取り消す（Control）";', japanese)
        self.assertIn('"candidate.position" = "変換候補 %@ / %@";', japanese)
        # The base Japanese order defines the argument order for every language.
        self.assertIn('"candidate.position" = "%2$@ candidates, at %1$@";', english)
        self.assertIn('"candidate.score" = "スコア %d%%";', japanese)
        self.assertIn('"settings.detail" = "%@\\n対象: \\"%@\\"";', japanese)

    def test_linux_uses_base_wording_and_named_placeholders(self):
        table = json.loads(self.sources["Linux/azookey/locales/ja.json"])
        self.assertEqual(table["reconversion.undo"], "取り消す（Ctrl）")
        self.assertEqual(table["candidate.score"].format(score=3), "スコア 3%")

    def test_gjs_exports_only_named_messages(self):
        source = self.sources["Linux/gnome-extension/candidateMessages.js"]
        self.assertIn("    position: (position, total) => `変換候補 ${position} / ${total}`,", source)
        self.assertIn('    undo: "取り消す（Ctrl）",', source)
        self.assertNotIn("score", source)

    def test_cpp_escapes_non_ascii_text(self):
        header = self.sources["Windows/src/shared/message_catalog_data.h"]
        self.assertIn('{"candidate.score", L"\\u30B9\\u30B3\\u30A2 {score}%", L"Score {score}%"},', header)
        self.assertIn("kUserDictionaryMessages[]", header)


class RepositoryCatalogTests(unittest.TestCase):
    def test_committed_files_match_the_catalog(self):
        sources = generator.generated_sources(generator.load_catalog())
        for relative, source in sources.items():
            with self.subTest(relative):
                self.assertEqual((generator.ROOT / relative).read_text(encoding="utf-8"), source)


if __name__ == "__main__":
    unittest.main()
