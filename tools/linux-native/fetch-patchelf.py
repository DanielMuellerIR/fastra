#!/usr/bin/env python3
"""Hashgebundenes Buildwerkzeug privat entpacken; keine Hostinstallation."""
import argparse
import hashlib
import json
import shutil
import subprocess
import urllib.request
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
if args.output.exists() or args.output.is_symlink():
    parser.error("Output must be new")
lock = json.loads((Path(__file__).parent / "patchelf.lock.json").read_text())
args.output.mkdir(parents=True)
try:
    archive = args.output / Path(lock["filename"]).name
    with urllib.request.urlopen(
        "https://archive.ubuntu.com/ubuntu/" + lock["filename"], timeout=30
    ) as response:
        data = response.read(lock["size"] + 1)
    if (
        len(data) != lock["size"]
        or hashlib.sha256(data).hexdigest() != lock["deb_sha256"]
    ):
        raise ValueError("Pinned patchelf archive differs")
    archive.write_bytes(data)
    subprocess.run(["dpkg-deb", "-x", str(archive), str(args.output)], check=True)
    binary = args.output / "usr/bin/patchelf"
    if hashlib.sha256(binary.read_bytes()).hexdigest() != lock["executable_sha256"]:
        raise ValueError("Extracted patchelf differs")
    print(
        json.dumps(
            {
                "private_tool_verified": True,
                "version": lock["version"],
                "executable": str(binary),
            }
        )
    )
except BaseException:
    shutil.rmtree(args.output)
    raise
