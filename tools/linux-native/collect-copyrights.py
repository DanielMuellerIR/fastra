#!/usr/bin/env python3
"""Vollständige Debian-Copyrighttexte der exakt identifizierten Laufzeitpakete."""
import argparse
import hashlib
import json
import subprocess
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument("--raw-manifest", type=Path, required=True)
p.add_argument("--output", type=Path, required=True)
a = p.parse_args()
if a.output.exists():
    p.error("Output must be new")
manifest = json.loads(a.raw_manifest.read_text())
wanted = manifest["packages"]
rows = subprocess.check_output(
    [
        "dpkg-query",
        "-W",
        "-f=${binary:Package}\t${Version}\t${source:Package}\t${source:Version}\t${Architecture}\n",
    ],
    text=True,
)
installed = {
    row.split("\t")[0].split(":")[0]: row.split("\t") for row in rows.splitlines()
}
a.output.mkdir(parents=True)
entries = {}
for name, expected in sorted(wanted.items()):
    row = installed[name]
    assert row[1] == expected, f"Package version changed: {name}"
    source = (Path("/usr/share/doc") / name / "copyright").resolve(strict=True)
    assert source.is_relative_to("/usr/share/doc") or source.is_relative_to(
        "/usr/share/common-licenses"
    ), name
    assert source.is_file(), name
    target = a.output / name / "copyright"
    target.parent.mkdir()
    target.write_bytes(source.read_bytes())
    entries[name] = {
        "binary_package": row[0],
        "version": row[1],
        "source_package": row[2],
        "source_version": row[3],
        "architecture": row[4],
        "copyright_sha256": hashlib.sha256(target.read_bytes()).hexdigest(),
    }
(a.output / "packages.json").write_text(
    json.dumps(entries, indent=2, sort_keys=True) + "\n"
)
print(json.dumps({"packages": len(entries), "complete_copyrights": len(entries)}))
