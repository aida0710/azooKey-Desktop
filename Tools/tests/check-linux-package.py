#!/usr/bin/env python3
"""Verify an installed desktop user can read every packaged runtime asset."""
import pathlib
import subprocess
import sys
import tarfile


def unreadable_members(package):
    failures = []
    with subprocess.Popen(["dpkg-deb", "--fsys-tarfile", str(package)], stdout=subprocess.PIPE) as process:
        with tarfile.open(fileobj=process.stdout, mode="r|") as archive:
            for member in archive:
                if member.issym() or member.islnk():
                    continue
                # Desktop applications run as a normal user, not the installer.
                required = 0o005 if member.isdir() else 0o004
                if member.name.startswith("./usr/bin/"):
                    required |= 0o001
                if member.mode & required != required:
                    failures.append(f"{member.name}: {member.mode:04o}")
        if process.wait() != 0:
            raise RuntimeError("dpkg-deb could not read the package")
    return failures


if __name__ == "__main__":
    package = pathlib.Path(sys.argv[1])
    failures = unreadable_members(package)
    if failures:
        sys.exit("Package assets are not readable by desktop users:\n" + "\n".join(failures))
    print("PASS: all packaged assets are readable by a desktop user")
