#!/usr/bin/env python3
import argparse
import hashlib
import pathlib
import re

parser = argparse.ArgumentParser(description="Render a cask from a real, verified release archive")
parser.add_argument("archive", type=pathlib.Path)
parser.add_argument("output", type=pathlib.Path)
args = parser.parse_args()
match = re.fullmatch(r"azookey-tree-(\d+\.\d+\.\d+)-arm64\.zip", args.archive.name)
if not match or not args.archive.is_file():
    parser.error("expected an existing azookey-tree-VERSION-arm64.zip")
with args.archive.open("rb") as stream:
    digest = hashlib.file_digest(stream, "sha256").hexdigest()
template = pathlib.Path(__file__).resolve().parent.parent / "packaging/homebrew/azookey-tree.rb.in"
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(template.read_text().replace("@VERSION@", match[1]).replace("@SHA256@", digest))
print(args.output)
