#!/usr/bin/env python3
"""Manifeste der optionalen Runtime und des separaten Pakets ohne Ausführung prüfen."""
import argparse
import json
import os
import stat
from pathlib import Path
from common import digest, inventory, virtual, name


def native_v4(root, m):
    v = m["native_iter_metadata_v4"]
    if (
        v.get("format") != 1
        or v.get("base_manifest_sha256")
        != "49f7f669c6ff55d3b340dafc8e916c943e33e93b44552ebf6b6e59876f884cb3"
    ):
        raise ValueError("Unexpected native-v4 base")
    p = root / "provenance/native-v4"
    lockfile = p / "gtk-native-v4.lock.json"
    receiptfile = p / "gtk-source-build.json"
    lock = json.loads(lockfile.read_text())
    receipt = json.loads(receiptfile.read_text())
    path = "usr/lib/x86_64-linux-gnu/libgtk-4.so.1.1400.5"
    if (
        v["library"] != path
        or v["library_sha256"] != digest(root / path)
        or v["source_lock_sha256"] != digest(lockfile)
        or v["build_receipt_sha256"] != digest(receiptfile)
        or receipt["source_lock_sha256"] != v["source_lock_sha256"]
        or receipt["library_sha256"] != v["library_sha256"]
        or receipt["builder_image"] != lock["builder_image"]
    ):
        raise ValueError("Native-v4 source/build binding differs")
    native_lockfile = root / "provenance/native-v2/gtk-native-v2.lock.json"
    native_lock = json.loads(native_lockfile.read_text())
    if (
        lock["base_native_lock_sha256"] != digest(native_lockfile)
        or lock["metadata_magic"] != 0x49545231
        or receipt["metadata_magic"] != lock["metadata_magic"]
    ):
        raise ValueError("Native-v4 metadata ABI/base differs")
    expected = {
        **native_lock["patched_files"],
        "gtk/gtktexthistory.c": native_lock["history_after_sha256"],
        **lock["patched_files"],
    }
    if (
        receipt["patched_files"] != expected
        or digest(p / lock["own_patch"]["filename"]) != lock["own_patch"]["sha256"]
    ):
        raise ValueError("Native-v4 getter source/patch differs")
    return v["base_library_sha256"]


def native_v3(root, m):
    v = m["native_return_v3"]
    if (
        v.get("format") != 1
        or v.get("base_manifest_sha256")
        != "fecad3208b5bba9faaf6516f8b5ffaa9c9e96b0a1c0c952aef16e68e17eb99e1"
    ):
        raise ValueError("Unexpected native-v3 base")
    provenance = root / "provenance/native-v3"
    lockfile = provenance / "sourceview-native-v3.lock.json"
    receiptfile = provenance / "sourceview-source-build.json"
    lock = json.loads(lockfile.read_text())
    receipt = json.loads(receiptfile.read_text())
    path = "usr/lib/x86_64-linux-gnu/libgtksourceview-5.so.0.0.0"
    if (
        v["library"] != path
        or v["library_sha256"] != digest(root / path)
        or v["source_lock_sha256"] != digest(lockfile)
        or v["build_receipt_sha256"] != digest(receiptfile)
        or receipt["source_lock_sha256"] != v["source_lock_sha256"]
        or receipt["library_sha256"] != v["library_sha256"]
        or receipt["builder_image"] != lock["builder_image"]
    ):
        raise ValueError("Native-v3 source/build binding differs")
    if (
        lock["base_source_lock_sha256"]
        != digest(root / "provenance/native-v2/sourceview-source.lock.json")
        or lock["return_magic"] != 0x52544E31
        or receipt["return_magic"] != lock["return_magic"]
    ):
        raise ValueError("Native-v3 distribution/Return ABI binding differs")
    expected = {
        **lock["after_delete_files"],
        "gtksourceview/gtksourceview.c": lock["return_after_sha256"],
        "gtksourceview/gtksourceindenter.c": lock["indenter_unchanged_sha256"],
    }
    if receipt["patched_files"] != expected:
        raise ValueError("Native-v3 patched source differs")
    for patch in lock["patch_series"]:
        directory = (
            root / "provenance/native-v2"
            if patch["filename"] == "gtksourceview-native-edits-v1.patch"
            else provenance
        )
        if digest(directory / patch["filename"]) != patch["sha256"]:
            raise ValueError("Native-v3 patch hash differs")
    return v["base_library_sha256"]


def native_v2(root, m, sourceview_base_hash=None, gtk_library_base_hash=None):
    v = m["native_edits_v2"]
    if (
        v.get("format") != 1
        or v.get("base_manifest_sha256")
        != "d1ab22580c340cbe34a910fce2a29f6ef35fb489058380d965e7edc98bf9d37c"
    ):
        raise ValueError("Unexpected native-v2 base")
    if set(v["components"]) != {"gtk", "sourceview"}:
        raise ValueError("Incomplete native-v2 pair")
    provenance = root / "provenance/native-v2"
    for component, lockname, library in [
        ("gtk", "gtk-native-v2.lock.json", "libgtk-4.so.1.1400.5"),
        ("sourceview", "sourceview-source.lock.json", "libgtksourceview-5.so.0.0.0"),
    ]:
        entry = v["components"][component]
        path = "usr/lib/x86_64-linux-gnu/" + library
        lock = json.loads((provenance / lockname).read_text())
        receipt_file = provenance / (component + "-source-build.json")
        receipt = json.loads(receipt_file.read_text())
        if (
            entry["library"] != path
            or entry["library_sha256"]
            != (
                sourceview_base_hash
                if component == "sourceview" and sourceview_base_hash
                else (
                    gtk_library_base_hash
                    if component == "gtk" and gtk_library_base_hash
                    else digest(root / path)
                )
            )
            or entry["source_lock_sha256"] != digest(provenance / lockname)
            or entry["build_receipt_sha256"] != digest(receipt_file)
            or receipt["source_lock_sha256"] != entry["source_lock_sha256"]
            or receipt["library_sha256"] != entry["library_sha256"]
            or receipt["builder_image"] != lock["builder_image"]
        ):
            raise ValueError("Native-v2 source/build binding differs: " + component)
        expected = (
            {
                **lock["patched_files"],
                "gtk/gtktexthistory.c": lock["history_after_sha256"],
            }
            if component == "gtk"
            else lock["patched_files"]
        )
        if receipt["patched_files"] != expected:
            raise ValueError("Native-v2 patched source differs")
        patches = lock["patch_series"] if component == "gtk" else [lock["own_patch"]]
        for patch in patches:
            file = (
                root / "provenance"
                if patch["filename"] == "gtk-commit-preflight.patch"
                else provenance
            ) / patch["filename"]
            if digest(file) != patch["sha256"]:
                raise ValueError("Native-v2 patch hash differs")
        if component == "gtk" and lock["base_source_lock_sha256"] != digest(
            root / "provenance/gtk-source-lock.json"
        ):
            raise ValueError("Native-v2 GTK distribution base differs")
        if component == "sourceview":
            if lock["version"] != "5.12.0-1build1" or lock["ubuntu_patches"]:
                raise ValueError("Native-v2 SourceView distribution differs")
            if (
                digest(provenance / "sourceview-copyright")
                != receipt["copyright_sha256"]
                or digest(provenance / "sourceview-COPYING")
                != receipt["copying_sha256"]
            ):
                raise ValueError("Native-v2 SourceView license differs")
    return v["components"]["gtk"]["base_library_sha256"]


def runtime(root):
    root = root.resolve(strict=True)
    m = json.loads((root / "manifest.json").read_text())
    if (
        m.get("kind") != "fastra-optional-native-runtime"
        or m.get("format") != 1
        or m.get("architecture") != "x86_64"
    ):
        raise ValueError("Unsupported optional native runtime")
    hashes, links, modes = inventory(root)
    if hashes != m["sha256"] or links != m["symlinks"]:
        raise ValueError("Optional runtime payload changed")
    if modes != {**m["modes"], "manifest.json": modes["manifest.json"]}:
        raise ValueError("Runtime file modes changed")
    if len(m["packages"]) != 278:
        raise ValueError("Unexpected native package closure")
    for package, entry in m["packages"].items():
        if (
            digest(root / "licenses/debian" / package / "copyright")
            != entry["copyright_sha256"]
        ):
            raise ValueError(f"Incomplete copyright: {package}")
    if (
        m["pango_source"]["version"] != "1.52.1+ds-1build1"
        or len(m["pango_source"]["ubuntu_patches"]) != 3
    ):
        raise ValueError("Pango distribution source mismatch")
    gtk_library_base_hash = (
        native_v4(root, m) if "native_iter_metadata_v4" in m else None
    )
    sourceview_base_hash = native_v3(root, m) if "native_return_v3" in m else None
    gtk_base_hash = (
        native_v2(root, m, sourceview_base_hash, gtk_library_base_hash)
        if "native_edits_v2" in m
        else digest(root / "usr/lib/x86_64-linux-gnu/libgtk-4.so.1.1400.5")
    )
    gtk_lock = m["gtk_source_lock"]
    gtk_receipt = json.loads((root / "provenance/gtk-source-build.json").read_text())
    if (
        gtk_lock["version"] != "4.14.5+ds-0ubuntu0.10"
        or len(gtk_lock["ubuntu_patches"]) != 30
        or gtk_receipt["source_lock_sha256"]
        != digest(root / "provenance/gtk-source-lock.json")
        or gtk_receipt["library_sha256"] != gtk_base_hash
    ):
        raise ValueError("GTK source/build binding differs")
    for transform in m["elf_searchpath_normalization"]["transforms"]:
        if m["sha256"].get(transform["path"]) != transform["after_sha256"]:
            raise ValueError("ELF normalization binding differs")
    return m


def package(root):
    root = root.resolve(strict=True)
    if (
        (root / "native-package.json").is_symlink()
        or (root / "runtime").is_symlink()
        or (root / "app").is_symlink()
    ):
        raise ValueError("Package roots and manifest must not be symlinks")
    m = json.loads((root / "native-package.json").read_text())
    if m.get("kind") != "fastra-optional-native-package" or m.get("format") != 1:
        raise ValueError("Unsupported native package")
    rt = runtime(root / "runtime")
    for key, expected in m["sha256"].items():
        name(key)
        if virtual(root, key) != (Path(key)):
            raise ValueError("Symlink parent in package hash path")
        file = root / key
        if file.is_symlink() or not file.is_file() or digest(file) != expected:
            raise ValueError(f"Native package checksum mismatch: {key}")
    for key, target in m["symlinks"].items():
        name(key)
        if target.startswith("/"):
            raise ValueError("Absolute package link")
        file = root / key
        if not file.is_symlink() or os.readlink(file) != target:
            raise ValueError(f"Native package link changed: {key}")
        virtual(root, key)
    actual_files = {}
    actual_links = {}
    for file in root.rglob("*"):
        key = file.relative_to(root).as_posix()
        mode = file.lstat().st_mode
        if mode & 0o7000:
            raise ValueError(f"Special package mode: {key}")
        if stat.S_ISLNK(mode):
            actual_links[key] = os.readlink(file)
        elif stat.S_ISREG(mode) and key != "native-package.json":
            actual_files[key] = digest(file)
        elif not stat.S_ISDIR(mode) and not stat.S_ISREG(mode):
            raise ValueError(f"Special package file: {key}")
    if actual_files != m["sha256"] or actual_links != m["symlinks"]:
        raise ValueError("Unlisted native package payload")
    for key in [
        "bin/fastra",
        "bin/fastra-native",
        "bin/fastra-control-native",
        "bin/fastra-diff-native",
        "bin/fastra-control",
        "bin/fastra-diff",
        "libexec/fastra-native-entry",
        "app/libexec/fastra-runtime-host",
        "app/libexec/fastra-git-commit-hook",
        "app/libexec/fastra-4d-worker",
    ]:
        if not os.access(root / key, os.X_OK):
            raise ValueError(f"Nonexecutable required file: {key}")
    return m


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--runtime", type=Path)
    g.add_argument("--package", type=Path)
    a = p.parse_args()
    m = runtime(a.runtime) if a.runtime else package(a.package)
    print(json.dumps({"verified": True, "kind": m["kind"]}))
