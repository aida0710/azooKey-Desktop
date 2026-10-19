import pathlib
import sys
import tempfile
import unittest
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from azookey.personalization import FILES, import_model


class PersonalizationImportTests(unittest.TestCase):
    def test_all_four_files_switch_together_and_invalid_import_preserves_previous(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / "source"
            source.mkdir()
            for name in FILES:
                (source / name).write_bytes(b"We love Marisa.\0" + b"fixture")
            first = import_model(source, root / "models")
            self.assertEqual((root / "models/current").resolve(), first)
            for name in FILES:
                self.assertEqual((first / name).read_bytes(), (source / name).read_bytes())
            (source / FILES[2]).write_bytes(b"broken")
            with self.assertRaises(ValueError):
                import_model(source, root / "models")
            self.assertEqual((root / "models/current").resolve(), first)
