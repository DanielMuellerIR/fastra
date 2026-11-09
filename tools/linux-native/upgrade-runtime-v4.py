#!/usr/bin/env python3
"""V3 ausschließlich um die geprüfte GTK-Iterator-Metadatenkorrektur erweitern."""
from pathlib import Path
import argparse, copy, json, shutil
from common import digest, inventory
import verify

BASE = "49f7f669c6ff55d3b340dafc8e916c943e33e93b44552ebf6b6e59876f884cb3"
T = Path(__file__).resolve().parent


def upgrade(a):
    if a.output.exists() or a.output.is_symlink():
        raise ValueError("Output must be new")
    if digest(a.runtime_v3 / "manifest.json") != BASE:
        raise ValueError("Expected frozen Return1 runtime")
    old = verify.runtime(a.runtime_v3)
    lock = json.loads((T / "gtk-native-v4.lock.json").read_text())
    native = json.loads((T / "gtk-native-v2.lock.json").read_text())
    receipt = json.loads((a.gtk_prefix / "SOURCE-BUILD.json").read_text())
    library = "usr/lib/x86_64-linux-gnu/libgtk-4.so.1.1400.5"
    file = a.gtk_prefix / Path(library).name
    if (
        file.is_symlink()
        or not file.is_file()
        or digest(file) != receipt["library_sha256"]
        or digest(T / "gtk-native-v4.lock.json") != receipt["source_lock_sha256"]
        or receipt["builder_image"] != lock["builder_image"]
    ):
        raise ValueError("GTK metadata build binding differs")
    expected = {
        **native["patched_files"],
        "gtk/gtktexthistory.c": native["history_after_sha256"],
        **lock["patched_files"],
    }
    if receipt["patched_files"] != expected or receipt["metadata_magic"] != 0x49545231:
        raise ValueError("Metadata source/ABI differs")
    temporary = a.output.with_name(a.output.name + ".partial")
    if temporary.exists() or temporary.is_symlink():
        raise ValueError("Partial output must be new")
    shutil.copytree(a.runtime_v3, temporary, symlinks=True)
    try:
        dest = temporary / library
        mode = dest.stat().st_mode & 0o777
        shutil.copyfile(file, dest)
        dest.chmod(mode)
        p = temporary / "provenance/native-v4"
        p.mkdir()
        for source, name in [
            (a.gtk_prefix / "SOURCE-BUILD.json", "gtk-source-build.json"),
            (a.gtk_prefix / "builder-packages.tsv", "gtk-builder-packages.tsv"),
            (T / "gtk-native-v4.lock.json", "gtk-native-v4.lock.json"),
            (T / lock["own_patch"]["filename"], lock["own_patch"]["filename"]),
        ]:
            shutil.copyfile(source, p / name)
            (p / name).chmod(0o644)
        m = copy.deepcopy(old)
        m["native_iter_metadata_v4"] = {
            "format": 1,
            "base_manifest_sha256": BASE,
            "library": library,
            "base_library_sha256": old["sha256"][library],
            "library_sha256": digest(file),
            "source_lock_sha256": digest(T / "gtk-native-v4.lock.json"),
            "build_receipt_sha256": digest(a.gtk_prefix / "SOURCE-BUILD.json"),
            "system_is_default": True,
            "scope": "Make iterator real before reading segment-byte offset; private readonly ITR1 marker; no app double-read workaround",
        }
        hashes, links, modes = inventory(temporary)
        if (
            {k for k, v in old["sha256"].items() if hashes.get(k) != v} != {library}
            or links != old["symlinks"]
            or any(modes[k] != v for k, v in old["modes"].items())
        ):
            raise ValueError("Runtime delta exceeds GTK and added provenance")
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
    p.add_argument("--runtime-v3", type=Path, required=True)
    p.add_argument("--gtk-prefix", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    a = p.parse_args()
    m = upgrade(a)
    print(
        json.dumps(
            {"native_v4_verified": True, "metadata": m["native_iter_metadata_v4"]}
        )
    )
