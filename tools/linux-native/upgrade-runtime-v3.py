#!/usr/bin/env python3
"""Korrigierte History2-Runtime nur um den geprüften Default-Return ergänzen."""
from pathlib import Path
import argparse, copy, json, shutil
from common import digest, inventory
import verify

BASE = "fecad3208b5bba9faaf6516f8b5ffaa9c9e96b0a1c0c952aef16e68e17eb99e1"
T = Path(__file__).resolve().parent


def upgrade(a):
    if a.output.exists() or a.output.is_symlink():
        raise ValueError("Output must be new")
    if digest(a.runtime_v2 / "manifest.json") != BASE:
        raise ValueError("Expected corrected History2 runtime")
    old = verify.runtime(a.runtime_v2)
    lock = json.loads((T / "sourceview-native-v3.lock.json").read_text())
    receipt = json.loads((a.sourceview_prefix / "SOURCE-BUILD.json").read_text())
    library = "usr/lib/x86_64-linux-gnu/libgtksourceview-5.so.0.0.0"
    file = a.sourceview_prefix / Path(library).name
    if (
        file.is_symlink()
        or not file.is_file()
        or digest(file) != receipt["library_sha256"]
        or digest(T / "sourceview-native-v3.lock.json") != receipt["source_lock_sha256"]
        or receipt["builder_image"] != lock["builder_image"]
    ):
        raise ValueError("Return SourceView build binding differs")
    expected = {
        **lock["after_delete_files"],
        "gtksourceview/gtksourceview.c": lock["return_after_sha256"],
        "gtksourceview/gtksourceindenter.c": lock["indenter_unchanged_sha256"],
    }
    if receipt["patched_files"] != expected or receipt["return_magic"] != 0x52544E31:
        raise ValueError("Return source/ABI differs")
    temporary = a.output.with_name(a.output.name + ".partial")
    if temporary.exists() or temporary.is_symlink():
        raise ValueError("Partial output must be new")
    shutil.copytree(a.runtime_v2, temporary, symlinks=True)
    try:
        dest = temporary / library
        mode = dest.stat().st_mode & 0o777
        shutil.copyfile(file, dest)
        dest.chmod(mode)
        p = temporary / "provenance/native-v3"
        p.mkdir()
        for source, name in [
            (a.sourceview_prefix / "SOURCE-BUILD.json", "sourceview-source-build.json"),
            (
                a.sourceview_prefix / "builder-packages.tsv",
                "sourceview-builder-packages.tsv",
            ),
            (T / "sourceview-native-v3.lock.json", "sourceview-native-v3.lock.json"),
            (
                T / "sourceview-default-return-v1.patch",
                "sourceview-default-return-v1.patch",
            ),
        ]:
            shutil.copyfile(source, p / name)
            (p / name).chmod(0o644)
        m = copy.deepcopy(old)
        m["native_return_v3"] = {
            "format": 1,
            "base_manifest_sha256": BASE,
            "library": library,
            "base_library_sha256": old["sha256"][library],
            "library_sha256": digest(file),
            "source_lock_sha256": digest(T / "sourceview-native-v3.lock.json"),
            "build_receipt_sha256": digest(a.sourceview_prefix / "SOURCE-BUILD.json"),
            "system_is_default": True,
            "scope": "Default builtin autoindent Return after unconsumed unchanged IM filtering; app linear policy required; no full IME/Grid guarantee",
        }
        hashes, links, modes = inventory(temporary)
        if (
            {k for k, v in old["sha256"].items() if hashes.get(k) != v} != {library}
            or links != old["symlinks"]
            or any(modes[k] != v for k, v in old["modes"].items())
        ):
            raise ValueError("Runtime delta exceeds SourceView and added provenance")
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
    p.add_argument("--runtime-v2", type=Path, required=True)
    p.add_argument("--sourceview-prefix", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    a = p.parse_args()
    m = upgrade(a)
    print(json.dumps({"native_v3_verified": True, "return": m["native_return_v3"]}))
