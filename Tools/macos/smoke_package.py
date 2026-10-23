"""Acquire and verify the exact distribution ZIP used by an IME smoke test."""

import hashlib
from pathlib import Path
import plistlib

from smoke_evidence import require_success

REPOSITORY = "aida0710/azooKey-Desktop"
# Distribution downloads can be slow on a fresh runner.
RELEASE_DOWNLOAD_TIMEOUT_SECONDS = 120


def download_release(evidence, *, tag, backend):
    version = tag.removeprefix("tree-v")
    suffix = "-cpu" if backend == "cpu" else ""
    asset = f"azookey-tree-{version}-arm64{suffix}.zip"
    downloads = evidence.directory / "downloads"
    downloads.mkdir()
    require_success(evidence.run("release-download", ["gh", "release", "download", tag,
                    "--repo", REPOSITORY, "--pattern", asset, "--pattern", asset + ".sha256",
                    "--dir", str(downloads)], timeout=RELEASE_DOWNLOAD_TIMEOUT_SECONDS), "Release download")
    return downloads / asset


def verify_checksum(evidence, archive, *, tag, backend):
    expected = Path(str(archive) + ".sha256").read_text().split()[0]
    hasher = hashlib.sha256()
    with archive.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            hasher.update(chunk)
    actual = hasher.hexdigest()
    evidence.write_json("package.json", {"tag": tag, "backend": backend, "archive": str(archive),
                                        "expectedSHA256": expected, "actualSHA256": actual})
    if expected != actual:
        raise RuntimeError("Package checksum mismatch")


def install_package(evidence, *, archive, tag, backend):
    archive = archive.resolve() if archive else download_release(evidence, tag=tag, backend=backend)
    verify_checksum(evidence, archive, tag=tag, backend=backend)
    input_methods = Path.home() / "Library/Input Methods"
    app = input_methods / "azooKeyMac.app"
    if app.exists():
        raise RuntimeError(f"Refusing to overwrite an existing installation: {app}")
    input_methods.mkdir(parents=True, exist_ok=True)
    require_success(evidence.run("install", ["ditto", "-x", "-k", str(archive), str(input_methods)]),
                    "Package extraction")
    # Retain the checksum evidence without uploading a second copy of the package.
    if tag:
        archive.unlink()
        Path(str(archive) + ".sha256").unlink()
        archive.parent.rmdir()
    require_success(evidence.run("codesign-verify", ["codesign", "--verify", "--deep", "--strict", str(app)]),
                    "Package signature verification")
    evidence.run("codesign-details", ["codesign", "-d", "--entitlements", ":-", str(app)])
    evidence.run("bundle-files", ["find", str(app), "-type", "f"])
    evidence.run("linked-libraries", ["otool", "-L", str(app / "Contents/MacOS/azooKeyMac")])
    with (app / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    evidence.write_json("Info.plist.json", info)
    if info.get("AzooKeyInferenceBackend") != backend:
        raise RuntimeError("Installed package has the wrong inference backend")
    return app
