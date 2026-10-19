#!/usr/bin/env python3
"""Hydrate pinned model files into build/models without installing git-lfs."""
import hashlib
import pathlib
import re
import subprocess
import sys
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
MODELS = {
    "base_n5_lm": ("Miwa-Keita/base_n5_lm", ["lm_c_abc.marisa", "lm_r_xbx.marisa", "lm_u_abx.marisa", "lm_u_xbc.marisa"]),
    "gguf": ("Miwa-Keita/zenz-v3.2-small-gguf", ["ggml-model-Q5_K_M.gguf"]),
}


def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True).strip()


def valid(path, size, digest):
    if not path.is_file() or path.stat().st_size != size:
        return False
    with path.open("rb") as stream:
        hasher = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest() == digest


def main():
    destination = ROOT / "build/models"
    destination.mkdir(parents=True, exist_ok=True)
    for name, (repository, files) in MODELS.items():
        submodule = ROOT / "azooKeyMac/Resources" / name
        relative = submodule.relative_to(ROOT).as_posix()
        revision = git("ls-tree", "HEAD", relative).split()[2]
        for filename in files:
            pointer = git("-C", str(submodule), "show", f"{revision}:{filename}")
            digest_match = re.search(r"^oid sha256:([a-f0-9]{64})$", pointer, re.M)
            size_match = re.search(r"^size (\d+)$", pointer, re.M)
            if not digest_match or not size_match:
                raise RuntimeError(f"Invalid LFS pointer: {filename}")
            digest, size = digest_match[1], int(size_match[1])
            target = destination / filename
            if not valid(target, size, digest):
                if "--verify-only" in sys.argv:
                    raise RuntimeError(f"Missing or invalid model: {filename}")
                temporary = target.with_suffix(target.suffix + ".part")
                url = f"https://huggingface.co/{repository}/resolve/{revision}/{filename}"
                print(f"Downloading {filename} ({size} bytes)", flush=True)
                try:
                    with urllib.request.urlopen(url, timeout=60) as response, temporary.open("wb") as output:
                        while chunk := response.read(1024 * 1024):
                            output.write(chunk)
                    if not valid(temporary, size, digest):
                        raise RuntimeError(f"SHA-256 or size mismatch: {filename}")
                    temporary.replace(target)
                finally:
                    temporary.unlink(missing_ok=True)
            print(f"Verified {filename}: {digest}", flush=True)


if __name__ == "__main__":
    main()
