#!/usr/bin/env python3
"""Versiegelte Runtime nur um die beiden geprüften nativen Bibliotheken erweitern."""
import argparse, copy, json, shutil, hashlib
from pathlib import Path
from common import digest, inventory
import verify

BASE = "d1ab22580c340cbe34a910fce2a29f6ef35fb489058380d965e7edc98bf9d37c"
T = Path(__file__).resolve().parent


def upgrade(a):
    if a.output.exists() or a.output.is_symlink():
        raise ValueError("Output must be new")
    if digest(a.runtime_v1 / "manifest.json") != BASE:
        raise ValueError("Unexpected frozen Runtime v1")
    old = verify.runtime(a.runtime_v1)
    if old.get("native_edits_v2"):
        raise ValueError("Already upgraded runtime")
    specs = [
        ("gtk", a.gtk_prefix, "libgtk-4.so.1.1400.5", "gtk-native-v2.lock.json"),
        (
            "sourceview",
            a.sourceview_prefix,
            "libgtksourceview-5.so.0.0.0",
            "sourceview-source.lock.json",
        ),
    ]
    records = {}
    for component, prefix, library, lockname in specs:
        lock = json.loads((T / lockname).read_text())
        receipt = json.loads((prefix / "SOURCE-BUILD.json").read_text())
        if (
            receipt["source_lock_sha256"] != digest(T / lockname)
            or receipt["library_sha256"] != digest(prefix / library)
            or receipt["builder_image"] != lock["builder_image"]
        ):
            raise ValueError("Build binding differs: " + component)
        if receipt["patched_files"] != (
            {
                **lock["patched_files"],
                "gtk/gtktexthistory.c": lock["history_after_sha256"],
            }
            if component == "gtk"
            else lock["patched_files"]
        ):
            raise ValueError("Patched production source differs: " + component)
        records[component] = {
            "library": "usr/lib/x86_64-linux-gnu/" + library,
            "base_library_sha256": old["sha256"]["usr/lib/x86_64-linux-gnu/" + library],
            "library_sha256": receipt["library_sha256"],
            "source_lock_sha256": receipt["source_lock_sha256"],
            "build_receipt_sha256": digest(prefix / "SOURCE-BUILD.json"),
        }
    temporary = a.output.with_name(a.output.name + ".partial")
    if temporary.exists() or temporary.is_symlink():
        raise ValueError("Partial output must be new")
    shutil.copytree(a.runtime_v1, temporary, symlinks=True)
    try:
        provenance = temporary / "provenance/native-v2"
        provenance.mkdir()
        for component, prefix, library, lockname in specs:
            dest = temporary / records[component]["library"]
            mode = dest.stat().st_mode & 0o777
            shutil.copyfile(prefix / library, dest)
            dest.chmod(mode)
            shutil.copyfile(
                prefix / "SOURCE-BUILD.json",
                provenance / (component + "-source-build.json"),
            )
            shutil.copyfile(T / lockname, provenance / lockname)
            shutil.copyfile(
                prefix / "builder-packages.tsv",
                provenance / (component + "-builder-packages.tsv"),
            )
        patch_names = {
            entry["filename"]
            for entry in json.loads((T / "gtk-native-v2.lock.json").read_text())[
                "patch_series"
            ]
        }
        patch_names.add(
            json.loads((T / "sourceview-source.lock.json").read_text())["own_patch"][
                "filename"
            ]
        )
        for n in sorted(patch_names):
            shutil.copyfile(T / n, provenance / n)
        for n in ["copyright", "COPYING"]:
            shutil.copyfile(a.sourceview_prefix / n, provenance / ("sourceview-" + n))
        changed = {records[c]["library"] for c in records}
        m = copy.deepcopy(old)
        m["native_edits_v2"] = {
            "format": 1,
            "base_manifest_sha256": BASE,
            "components": records,
            "system_is_default": True,
            "scope": "Delete/Backspace/Join and bounded GTK history; no general IME transaction claim",
        }
        for p in provenance.rglob("*"):
            if p.is_file():
                p.chmod(0o644)
        hashes, links, modes = inventory(temporary)
        differences = {k for k, v in old["sha256"].items() if hashes.get(k) != v}
        if (
            differences != changed
            or links != old["symlinks"]
            or any(modes[k] != v for k, v in old["modes"].items())
        ):
            raise ValueError("Runtime delta exceeds two libraries and added provenance")
        m.update(
            sha256=hashes,
            symlinks=links,
            modes={k: v for k, v in modes.items() if k != "manifest.json"},
        )
        (temporary / "manifest.json").write_text(
            json.dumps(m, indent=2, sort_keys=True) + "\n"
        )
        (temporary / "manifest.json").chmod(0o644)
        verify.runtime(temporary)
        temporary.rename(a.output)
    except BaseException:
        shutil.rmtree(temporary)
        raise
    return m


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--runtime-v1", type=Path, required=True)
    p.add_argument("--gtk-prefix", type=Path, required=True)
    p.add_argument("--sourceview-prefix", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    a = p.parse_args()
    m = upgrade(a)
    print(
        json.dumps(
            {
                "native_v2_verified": True,
                "files": len(m["sha256"]),
                "components": m["native_edits_v2"]["components"],
            }
        )
    )
