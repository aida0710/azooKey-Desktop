#!/usr/bin/env python3
"""Preserve dependency notices from the exact SwiftPM checkout used to build."""
import pathlib
import shutil
import sys

root = pathlib.Path(__file__).resolve().parents[1]
checkouts, destination = map(pathlib.Path, sys.argv[1:3])
destination.mkdir(parents=True, exist_ok=True)
shutil.copy2(root / "LICENSE", destination / "azooKey-Desktop.txt")
for source in (root / "packaging/licenses").iterdir():
    if source.is_file():
        shutil.copy2(source, destination / source.name)
for checkout in sorted(checkouts.iterdir()):
    if not checkout.is_dir():
        continue
    for source in checkout.rglob("*"):
        if source.is_file() and source.name.upper().split(".")[0] in {"LICENSE", "LICENCE", "NOTICE", "COPYING", "COPYRIGHT"}:
            target = destination / "dependencies" / checkout.name / source.relative_to(checkout)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
swift_notice = pathlib.Path("/usr/share/swift/LICENSE.txt")
if sys.platform == "linux":
    if not swift_notice.is_file():
        raise SystemExit("The bundled Swift runtime license is missing")
    shutil.copy2(swift_notice, destination / "Swift-runtime.txt")
apache = checkouts / "AzooKeyKanaKanjiConverter/Sources/KanaKanjiConverterModuleWithDefaultDictionary/azooKey_dictionary_storage/LICENSE"
shutil.copy2(apache, destination / "Apache-2.0.txt")
print(f"Collected dependency notices in {destination}")
