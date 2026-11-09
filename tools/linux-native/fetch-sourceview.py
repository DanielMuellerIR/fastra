#!/usr/bin/env python3
"""Gepinnte Ubuntu-GtkSourceView-Quelle samt Signaturkette holen und vollständig extrahieren."""
import argparse
import hashlib
import json
import lzma
import subprocess
import urllib.request
from pathlib import Path


def fetch(url, path, expected, limit):
    if path.exists():
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise ValueError(f"Changed cached source: {path.name}")
        return
    temporary = path.with_suffix(path.suffix + ".partial")
    total = 0
    h = hashlib.sha256()
    try:
        with (
            urllib.request.urlopen(url, timeout=30) as response,
            temporary.open("xb") as out,
        ):
            while True:
                block = response.read(1024 * 1024)
                if not block:
                    break
                total += len(block)
                if total > limit:
                    raise ValueError(f"Source exceeds pinned size: {path.name}")
                h.update(block)
                out.write(block)
        if h.hexdigest() != expected:
            raise ValueError(f"Source SHA256 mismatch: {path.name}")
        temporary.rename(path)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--lock", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    p.add_argument(
        "--keyring",
        type=Path,
        default=Path("/usr/share/keyrings/ubuntu-archive-keyring.gpg"),
    )
    a = p.parse_args()
    if a.output.exists():
        p.error("Source output must be new")
    a.output.mkdir(parents=True)
    lock = json.loads(a.lock.read_text())
    if lock["version"] != "5.12.0-1build1":
        raise ValueError("Unreviewed source version")
    release = a.output / "InRelease"
    fetch(
        lock["inrelease"]["url"], release, lock["inrelease"]["sha256"], 2 * 1024 * 1024
    )
    subprocess.run(["gpgv", "--keyring", str(a.keyring), str(release)], check=True)
    index = a.output / "Sources.xz"
    entry = lock["sources_xz"]
    fetch(entry["url"], index, entry["sha256"], entry["size"])
    plain = lzma.open(index).read(lock["source_index"]["uncompressed_size"] + 1)
    if (
        len(plain) != lock["source_index"]["uncompressed_size"]
        or hashlib.sha256(plain).hexdigest()
        != lock["source_index"]["uncompressed_sha256"]
    ):
        raise ValueError("Sources index differs from authenticated lock")
    index_line = next(
        x
        for x in release.read_text().splitlines()
        if x.split()[-1:] == ["main/source/Sources.xz"] and len(x.split()[0]) == 64
    )
    sha, size, _ = index_line.split()
    if sha != entry["sha256"] or int(size) != entry["size"]:
        raise ValueError("Compressed Sources not bound by InRelease")
    record = next(
        r
        for r in plain.decode().split("\n\n")
        if "\nVersion: " + lock["version"] + "\n" in "\n" + r + "\n"
        and r.startswith("Package: gtksourceview5\n")
    )
    fields = {}
    field = None
    for line in record.splitlines():
        if line.startswith(" "):
            fields[field] += "\n" + line
        else:
            field, value = line.split(":", 1)
            fields[field] = value.strip()
    hashes = {}
    for line in fields["Checksums-Sha256"].strip().splitlines():
        expected, size, name = line.split()
        hashes[name] = expected
        if (
            expected != lock["archives"][name]
            or int(size) != lock["archive_sizes"][name]
        ):
            raise ValueError("Selected source stanza differs from lock")
    if hashes != lock["archives"]:
        raise ValueError("Source archive coverage changed")
    for name, expected in hashes.items():
        if Path(name).name != name:
            raise ValueError("Unsafe source archive name")
        fetch(
            "https://archive.ubuntu.com/ubuntu/"
            + lock["source_directory"]
            + "/"
            + name,
            a.output / name,
            expected,
            lock["archive_sizes"][name],
        )
    dsc = next(a.output.glob("*.dsc"))
    subprocess.run(["dpkg-source", "-x", dsc.name], cwd=a.output, check=True)
    source = a.output / "gtksourceview5-5.12.0"
    series = (source / "debian/patches/series").read_bytes()
    if hashlib.sha256(series).hexdigest() != lock["ubuntu_patch_series_sha256"]:
        raise ValueError("Distribution patch series changed")
    for name, expected in lock["ubuntu_patches"].items():
        if (
            hashlib.sha256((source / "debian/patches" / name).read_bytes()).hexdigest()
            != expected
        ):
            raise ValueError(f"Distribution patch changed: {name}")
    applied_file = source / ".pc/applied-patches"
    applied = applied_file.read_text().splitlines() if applied_file.exists() else []
    if applied != [
        x for x in series.decode().splitlines() if x and not x.startswith("#")
    ]:
        raise ValueError("Distribution patches were not all applied")
    for name, expected in lock["baseline"].items():
        if hashlib.sha256((source / name).read_bytes()).hexdigest() != expected:
            raise ValueError("Unexpected production baseline: " + name)
    (a.output / "selected-source-record.txt").write_text(record + "\n")
    (a.output / "verified-source.json").write_text(
        json.dumps(lock, indent=2, sort_keys=True) + "\n"
    )
    print(
        json.dumps(
            {
                "authenticated": True,
                "source": lock["source"],
                "version": lock["version"],
                "distribution_patches": len(applied),
            }
        )
    )


if __name__ == "__main__":
    main()
