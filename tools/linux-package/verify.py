#!/usr/bin/env python3
"""Paketinhalte prüfen; keinerlei Dateien aus dem Paket ausführen."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat


def safe_name(name):
    p = PurePosixPath(name)
    if not name or p.as_posix() != name.rstrip("/") or p.is_absolute() or ".." in p.parts or "\\" in name or any(ord(char) < 32 for char in name):
        raise ValueError(f"Unsafe package path: {name!r}")
    return p


def digest(file):
    h = hashlib.sha256()
    with file.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def checksums(directory, selected=None):
    entries = {}
    for line in (directory / "SHA256SUMS").read_text().splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  ([^/]+)", line)
        if not match or match[2] in entries or match[2] in (".", ".."):
            raise ValueError("SHA256SUMS must contain unique relative basenames.")
        entries[match[2]] = match[1]
    if not entries or (selected and selected not in entries):
        raise ValueError("Package is missing from SHA256SUMS.")
    for name, expected in entries.items():
        if selected and name != selected:
            continue
        file = directory / name
        if file.is_symlink() or not file.is_file() or digest(file) != expected:
            raise ValueError(f"Package checksum mismatch: {name}")


def runtime(root):
    manifest_file = root / "manifest.json"
    if manifest_file.is_symlink():
        raise ValueError("Manifest must be a regular file.")
    manifest = json.loads(manifest_file.read_text())
    if manifest.get("format") != 1 or manifest.get("architecture") != "x86_64":
        raise ValueError("Unsupported runtime manifest.")
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}", manifest["version"]):
        raise ValueError("Invalid runtime version.")
    hashes = manifest["sha256"]
    links = manifest.get("symlinks", {})
    executables = {"bin/fastra", "bin/fastra-control", "libexec/fastra-linux", "libexec/fastra-control"}
    optional_diff = {"bin/fastra-diff", "libexec/fastra-diff"}
    parts = manifest["version"].split(".")
    version = tuple(int(value) for value in parts) + (0,) * (3 - len(parts))
    if version >= (1, 182, 0) or optional_diff.intersection(hashes):
        executables |= optional_diff
    required = executables | {"share/licenses/fastra/LICENSE"}
    if version >= (1, 189, 0):
        required |= {"libexec/fastra-update/" + name for name in ("update.py", "install.py", "verify.py")}
    cmark_files = {"share/licenses/fastra/cmark/COPYING", "share/licenses/fastra/cmark/SOURCE.json"}
    if "cmark_revision" in manifest or cmark_files.intersection(hashes):
        if manifest.get("cmark_revision") != "924936d0427cb25a61169739a7660230bffa6ea6":
            raise ValueError("Unverified native cmark revision")
        required |= cmark_files
    if version >= (1, 198, 0) or "regex_syntax_revisions" in manifest:
        if manifest.get("regex_syntax_revisions") != {"runtime": "da6fe9beb4f7f67beb75914ca8e0d48ae48d6406", "grammar": "b2ac15e27fce703d2f37a79ccd94a5c0cbe9720b"}:
            raise ValueError("Unverified regex syntax revisions")
        required |= {"share/licenses/fastra/regex-syntax/" + name for name in ("runtime/LICENSE", "grammar/LICENSE", "runtime/src/unicode/LICENSE", "SOURCES.json")}
    if version >= (1, 217, 0) or "folding_catalog_revision" in manifest:
        if manifest.get("folding_catalog_revision") != "331d5dbc5fc8513be5848fce8a2a312908f36a11":
            raise ValueError("Unverified folding catalog revision")
        catalog_path = "share/licenses/fastra/folding/catalog.json"
        required.add(catalog_path)
        catalog_file = root / catalog_path
        if catalog_file.is_symlink() or any(parent.is_symlink() for parent in catalog_file.parents if parent != root and root in parent.parents) or not catalog_file.is_file() or catalog_file.stat().st_size > 256 * 1024 or digest(catalog_file) != hashes.get(catalog_path):
            raise ValueError("Invalid folding license catalog file")
        catalog = json.loads(catalog_file.read_text())
        if catalog.get("mac_catalog_revision") != manifest["folding_catalog_revision"] or len(catalog["grammars"]) != 29:
            raise ValueError("Incomplete folding license catalog")
        for grammar in catalog["grammars"]:
            name = grammar["repository"]
            if not re.fullmatch(r"tree-sitter-[a-z-]+", name) or grammar["license"] != "MIT":
                raise ValueError("Invalid folding license entry")
            for filename, expected in grammar["license_sha256"].items():
                path = f"share/licenses/fastra/folding/{name}/{filename}"
                safe_name(path)
                if Path(filename).name != filename or hashes.get(path) != expected:
                    raise ValueError("Missing or altered folding license")
                required.add(path)
    if not required <= hashes.keys() or not re.fullmatch(r"[0-9a-f]{64}", manifest["source_sha256"]):
        raise ValueError("Incomplete runtime manifest.")
    for name in list(hashes) + list(links):
        safe_name(name)
        if any(parent.is_symlink() for parent in (root / name).parents if parent != root and root in parent.parents):
            raise ValueError("Symlink directory in runtime.")
    for name, expected in hashes.items():
        file = root / name
        if file.is_symlink() or not file.is_file() or digest(file) != expected:
            raise ValueError(f"Runtime checksum mismatch: {name}")
    for name, target in links.items():
        file = root / name
        safe_name(target)
        if not file.is_symlink() or os.readlink(file) != target or not file.resolve().is_relative_to(root.resolve()):
            raise ValueError(f"Unsafe or changed runtime symlink: {name}")
    for file in root.rglob("*"):
        name = file.relative_to(root).as_posix()
        if file.is_symlink() and name not in links:
            raise ValueError(f"Unlisted symlink: {name}")
        if not file.is_dir() and name not in hashes and name not in links and name != "manifest.json":
            raise ValueError(f"Unlisted runtime file: {name}")
        if file.lstat().st_mode & (stat.S_ISUID | stat.S_ISGID):
            raise ValueError("Set-id file in runtime.")
    for name in executables:
        if not os.access(root / name, os.X_OK):
            raise ValueError(f"Executable permission missing: {name}")
    return manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--checksums", type=Path)
    parser.add_argument("--runtime", type=Path)
    args = parser.parse_args()
    if args.checksums:
        checksums(args.checksums)
    if args.runtime:
        runtime(args.runtime.resolve())
    print("Verified.")
