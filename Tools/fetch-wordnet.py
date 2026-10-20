#!/usr/bin/env python3
"""Prepare the pinned, offline word-definition database for Linux packages."""

import argparse
from contextlib import contextmanager
import gzip
import hashlib
import json
from pathlib import Path
import shutil
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
# Bound memory use and decompression even when a download is corrupt.
COPY_BLOCK_BYTES = 1024 * 1024
# This is a build download; a stalled connection must fail rather than hang CI.
NETWORK_TIMEOUT_SECONDS = 60


def file_matches(path, specification):
    if not path.is_file() or path.stat().st_size != specification["size"]:
        return False
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(COPY_BLOCK_BYTES), b""):
            digest.update(block)
    return digest.hexdigest() == specification["sha256"]


def copy_bounded(source, destination, maximum_bytes):
    copied_bytes = 0
    while block := source.read(COPY_BLOCK_BYTES):
        copied_bytes += len(block)
        if copied_bytes > maximum_bytes:
            raise ValueError("WordNet content exceeds its pinned size")
        destination.write(block)


@contextmanager
def atomic_output(target, *, specification=None):
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=target.parent, prefix=".wordnet-", delete=False) as output:
            temporary = Path(output.name)
            yield output
        if specification is not None and not file_matches(temporary, specification):
            raise ValueError(f"WordNet content does not match its pinned SHA-256 and size: {target.name}")
        temporary.chmod(0o644)
        temporary.replace(target)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def atomic_copy(source, target):
    with atomic_output(target) as output, source.open("rb") as stream:
        shutil.copyfileobj(stream, output, COPY_BLOCK_BYTES)


def source_description(manifest):
    return (json.dumps(manifest, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode("utf-8")


def verify_resources(output_dir, manifest):
    resources = [manifest["database"], *manifest["licenses"]]
    for specification in resources:
        if not file_matches(output_dir / specification["filename"], specification):
            raise ValueError(f"Missing or invalid WordNet resource: {specification['filename']}")
    metadata = output_dir / "source.json"
    if not metadata.is_file() or metadata.read_bytes() != source_description(manifest):
        raise ValueError("Missing or invalid WordNet source description")


def download_archive(target, specification):
    with atomic_output(target, specification=specification) as output:
        with urllib.request.urlopen(specification["url"], timeout=NETWORK_TIMEOUT_SECONDS) as response:
            copy_bounded(response, output, specification["size"])


def extract_database(archive, target, specification):
    with atomic_output(target, specification=specification) as output, gzip.open(archive, "rb") as source:
        copy_bounded(source, output, specification["size"])


def prepare_resources(output_dir, *, manifest, licenses_dir, archive=None, verify_only=False):
    if verify_only:
        verify_resources(output_dir, manifest)
        return
    for specification in manifest["licenses"]:
        if not file_matches(licenses_dir / specification["filename"], specification):
            raise ValueError(f"Invalid bundled WordNet license: {specification['filename']}")
    output_dir.mkdir(parents=True, exist_ok=True)
    database = output_dir / manifest["database"]["filename"]
    if not file_matches(database, manifest["database"]):
        if archive is not None:
            if not file_matches(archive, manifest["archive"]):
                raise ValueError("Supplied WordNet archive does not match the pinned SHA-256 and size")
        else:
            archive = output_dir / "wnjpn.db.gz"
            if not file_matches(archive, manifest["archive"]):
                download_archive(archive, manifest["archive"])
        extract_database(archive, database, manifest["database"])
    for specification in manifest["licenses"]:
        atomic_copy(licenses_dir / specification["filename"], output_dir / specification["filename"])
    metadata = output_dir / "source.json"
    with atomic_output(metadata) as output:
        output.write(source_description(manifest))
    verify_resources(output_dir, manifest)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, default=ROOT / "build/wordnet")
    parser.add_argument("--archive", type=Path, help="Use a previously downloaded, pinned archive")
    parser.add_argument("--verify-only", action="store_true", help="Check resources without writes or downloads")
    arguments = parser.parse_args()
    manifest = json.loads((ROOT / "Tools/wordnet-manifest.json").read_text(encoding="utf-8"))
    try:
        prepare_resources(arguments.output_dir, manifest=manifest, licenses_dir=ROOT / "packaging/licenses",
                          archive=arguments.archive, verify_only=arguments.verify_only)
    except (OSError, ValueError, EOFError) as error:
        parser.exit(1, f"WordNet preparation failed: {error}\n")
    print(f"Verified {manifest['name']} {manifest['version']}: {arguments.output_dir}")


if __name__ == "__main__":
    main()
