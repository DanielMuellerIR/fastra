"""Nur Laufzeitsuchpfade anpassen; Code und Distributionspatches bleiben erhalten."""

import json
import os
import re
import subprocess
from pathlib import Path
from common import digest, virtual


def paths(file):
    result = subprocess.check_output(["readelf", "-d", str(file)], text=True)
    return re.findall(r"\((?:RPATH|RUNPATH)\).*?\[([^]]*)\]", result)


def relocate(root, tool):
    files = []
    for file in sorted(root.rglob("*")):
        if not file.is_file() or file.is_symlink():
            continue
        with file.open("rb") as stream:
            magic = stream.read(4)
        if magic == b"\x7fELF":
            files.append(file)
    if not files:
        return {"elf_files": 0, "transforms": [], "origin_paths": {}}
    lock = json.loads((Path(__file__).parent / "patchelf.lock.json").read_text())
    if tool is None or tool.is_symlink() or digest(tool) != lock["executable_sha256"]:
        raise ValueError("Pinned private patchelf is required")
    if (
        subprocess.check_output([str(tool), "--version"], text=True).strip()
        != lock["banner"]
    ):
        raise ValueError("Unexpected patchelf version")
    changes = []
    kept = {}
    for file in files:
        old = paths(file)
        if len(old) > 1:
            raise ValueError(f"Multiple runtime path tags: {file.name}")
        if not old:
            continue
        new = []
        omitted = []
        for value in old[0].split(":"):
            if value.startswith("/"):
                target = virtual(root, value.lstrip("/"))
                if not (root / target).is_dir():
                    raise ValueError(f"Non-directory RPATH: {value}")
                relative = os.path.relpath(root / target, file.parent)
                new.append("$ORIGIN" if relative == "." else "$ORIGIN/" + relative)
            elif value == "$ORIGIN" or value.startswith("$ORIGIN/"):
                relative = Path(
                    os.path.normpath(
                        str(file.parent / value.removeprefix("$ORIGIN").lstrip("/"))
                    )
                )
                if not relative.is_relative_to(root):
                    raise ValueError(f"Origin RPATH escapes runtime: {file.name}")
                key = str(relative.relative_to(root))
                try:
                    virtual(root, key)
                except FileNotFoundError:
                    # Dieser unbenutzte Debian-LLVM-Pfad hat in der erfassten Closure kein Ziel.
                    if file.name == "libLLVM.so.20.1" and value == "$ORIGIN/../lib":
                        omitted.append(value)
                        continue
                    raise
                new.append(value)
            else:
                raise ValueError(f"Unsupported relative RPATH: {value}")
        joined = ":".join(new)
        if joined != old[0]:
            before = digest(file)
            subprocess.run(
                (
                    [str(tool), "--set-rpath", joined, str(file)]
                    if joined
                    else [str(tool), "--remove-rpath", str(file)]
                ),
                check=True,
            )
            actual = paths(file)
            if actual != ([joined] if joined else []):
                raise ValueError(f"RPATH normalization failed: {file.name}")
            changes.append(
                {
                    "path": str(file.relative_to(root)),
                    "before": old[0],
                    "after": joined,
                    "removed_absent_paths": omitted,
                    "before_sha256": before,
                    "after_sha256": digest(file),
                }
            )
        if new:
            kept[str(file.relative_to(root))] = new
    return {
        "elf_files": len(files),
        "tool": lock,
        "transforms": changes,
        "origin_paths": kept,
    }
