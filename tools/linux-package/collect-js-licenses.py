#!/usr/bin/env python3
"""Lizenztexte aus integritätsgepinnten npm-Archiven, ohne Paketcode auszuführen."""
import argparse
import base64
from concurrent.futures import ThreadPoolExecutor
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import tarfile
import urllib.parse
import urllib.request


def download(url):
    with urllib.request.urlopen(url, timeout=45) as response:
        return response.read(64 * 1024 * 1024 + 1)


def collect(package, output, cache):
    name, version, integrity = package["name"], package["version"], package["integrity"]
    algorithm, expected = integrity.split("-", 1)
    slug = name.replace("/", "_") + "-" + version
    archive = cache / (slug + ".tgz")
    if not archive.exists():
        url = package.get("tarball") or f"https://registry.npmjs.org/{name}/-/{name.split('/')[-1]}-{version}.tgz"
        data = download(url)
        if len(data) > 64 * 1024 * 1024:
            raise ValueError(f"npm archive exceeds safety limit: {name}")
        archive.write_bytes(data)
    data = archive.read_bytes()
    actual = base64.b64encode(hashlib.new(algorithm, data).digest()).decode()
    if actual != expected:
        raise ValueError(f"npm integrity mismatch: {name}@{version}")
    files = {}
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tar:
        for member in tar.getmembers():
            path = PurePosixPath(member.name)
            if not member.isfile() or ".." in path.parts or path.is_absolute():
                continue
            leaf = path.name.lower()
            if not leaf.startswith(("license", "licence", "copying", "copyright", "notice")):
                continue
            if member.size > 1024 * 1024:
                raise ValueError(f"License file exceeds safety limit: {name}/{path}")
            content = tar.extractfile(member).read()
            if not content.strip():
                continue
            relative = Path(*path.parts[1:])
            destination = output / slug / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(content)
            files[str(relative)] = hashlib.sha256(content).hexdigest()
    if not files:
        raise ValueError(f"Complete license missing: {name}@{version}")
    return {**package, "files": files}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--lock", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--cache", type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        parser.error("Output must not exist.")
    lock = json.loads(args.lock.read_text())
    args.output.mkdir(parents=True)
    args.cache.mkdir(parents=True, exist_ok=True)
    with ThreadPoolExecutor(max_workers=6) as executor:
        results = list(executor.map(lambda package: collect(package, args.output, args.cache), lock["packages"]))
    manifest = {"format": 1, "lock_sha256": hashlib.sha256(args.lock.read_bytes()).hexdigest(), "packages": results}
    (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(f"Complete JS license packages: {len(results)}")


if __name__ == "__main__":
    main()
