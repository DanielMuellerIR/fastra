#!/usr/bin/env python3
"""Version und Inhaltsidentität des tatsächlich gebauten Quell-Snapshots."""
import hashlib
import json
from pathlib import Path
import plistlib
import re
import sys
import tomllib


def check_version(repo, expected):
    cargo = tomllib.loads((repo / "crates/fastra-linux/Cargo.toml").read_text())["package"]["version"]
    with (repo / "app/Info.plist").open("rb") as file:
        info = plistlib.load(file)
    actual = [cargo, info["CFBundleShortVersionString"]]
    if actual != [expected] * 2:
        raise ValueError(f"Package, Cargo and Info.plist versions differ: {expected!r} versus {actual!r}")
    build = info["CFBundleVersion"]
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", build):
        raise ValueError(f"Invalid Info.plist build number: {build!r}")
    return build


def snapshot_hash(repo):
    entries = []
    for file in sorted(repo.rglob("*")):
        if file.is_symlink():
            raise ValueError(f"Unexpected source symlink: {file.relative_to(repo)}")
        if file.is_file():
            entries.append(f"{hashlib.sha256(file.read_bytes()).hexdigest()}  {file.relative_to(repo)}\n")
    listing = "".join(entries)
    return hashlib.sha256(listing.encode()).hexdigest(), listing


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--version":
        repo = Path(sys.argv[2])
        value = tomllib.loads((repo / "crates/fastra-linux/Cargo.toml").read_text())["package"]["version"]
        check_version(repo, value)
        print(value)
        sys.exit(0)
    repo, version, output = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3])
    build = check_version(repo, version)
    digest, listing = snapshot_hash(repo)
    output.mkdir(parents=True, exist_ok=True)
    (output / "source-sha256.txt").write_text(listing)
    (output / "source-identity.json").write_text(json.dumps({"version": version, "bundle_build": build, "sha256": digest}, indent=2) + "\n")
    print(digest)
