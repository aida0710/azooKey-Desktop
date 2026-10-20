"""Read Japanese WordNet locally; converter readings remain separate from dictionary evidence."""
from pathlib import Path
import sqlite3
import time
import unicodedata

QUERY_TIMEOUT_SECONDS = 0.5  # A damaged/unindexed dictionary must not monopolize the worker.

MAXIMUM_SYNONYMS = 8  # Read-only suggestions are deliberately bounded, never conversion candidates.

WORDNET_PATH = Path("/opt/azookey-tree/dictionaries/wnjpn.db")
WORDNET_URL = "https://bond-lab.github.io/wnja/index.ja.html"
WORDNET_COPYRIGHT = ("日本語ワードネット（1.1版）© 2009-2011 NICT, 2012-2015 Francis Bond and "
                     "2016-2024 Francis Bond, Takayuki Kuribayashi")


def normalized_reading(reading):
    return "".join(chr(ord(character) - 0x60) if "ァ" <= character <= "ヶ" else character
                   for character in unicodedata.normalize("NFKC", reading))


class WordDefinitionProvider:
    def __init__(self, path=WORDNET_PATH):
        self.path = Path(path)

    def lookup(self, word, reading):
        response = {"status": "unavailable", "word": word, "reading": reading, "senses": [],
                    "readingUnspecified": False, "sourceURL": WORDNET_URL, "copyright": WORDNET_COPYRIGHT}
        if not self.path.is_file():
            return response
        try:
            connection = sqlite3.connect(self.path.resolve().as_uri() + "?mode=ro", uri=True)
            try:
                connection.execute("PRAGMA query_only=ON")
                deadline = time.monotonic() + QUERY_TIMEOUT_SECONDS
                connection.set_progress_handler(lambda: int(time.monotonic() >= deadline), 1000)
                rows = connection.execute(
                    "SELECT s.synset, w.pron FROM word w JOIN sense s ON s.wordid=w.wordid "
                    "WHERE w.lang='jpn' AND w.lemma=? ORDER BY s.rank, s.synset", (word,)).fetchall()
                synsets = {}
                for synset, pronunciation in rows:
                    if pronunciation and normalized_reading(pronunciation) != normalized_reading(reading):
                        continue
                    synsets[synset] = synsets.get(synset, False) or not pronunciation
                for synset, unspecified in synsets.items():
                    definitions = self.texts(connection, "synset_def", synset)
                    if not definitions:
                        continue
                    response["senses"].append({"synset": synset, "definitions": definitions,
                                               "examples": self.texts(connection, "synset_ex", synset),
                                               "synonyms": self.synonyms(connection, synset, word)})
                    response["readingUnspecified"] |= unspecified
                response["status"] = "found" if response["senses"] else "notFound"
            finally:
                connection.close()
        except (sqlite3.Error, OSError, ValueError):
            response["status"] = "error"
            response["senses"] = []
        return response

    @staticmethod
    def synonyms(connection, synset, word):
        rows = connection.execute(
            "SELECT DISTINCT w.lemma FROM sense s JOIN word w ON w.wordid=s.wordid "
            "WHERE s.synset=? AND w.lang='jpn' AND w.lemma<>? ORDER BY w.lemma LIMIT ?",
            (synset, word, MAXIMUM_SYNONYMS)).fetchall()
        return [lemma for (lemma,) in rows if isinstance(lemma, str) and lemma]

    @staticmethod
    def texts(connection, table, synset):
        # Only these two internal constant table names reach this query.
        if table not in ("synset_def", "synset_ex"):
            raise ValueError("Unknown WordNet text table")
        rows = connection.execute(f'SELECT def FROM {table} WHERE synset=? AND lang=\'jpn\' ORDER BY sid',
                                  (synset,)).fetchall()
        return list(dict.fromkeys(text for (text,) in rows if isinstance(text, str) and text))
