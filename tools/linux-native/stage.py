#!/usr/bin/env python3
"""Separater opt-in-Paketbaum; die bisherige Systempaketierung wird nicht geändert."""
import argparse
import importlib.util
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import gzip
from pathlib import Path
from common import digest, inventory, virtual, name
import verify


def elf(file, gtk_free=False):
    if file.is_symlink() or not file.is_file():
        raise ValueError(f"Executable must be regular: {file.name}")
    h = subprocess.check_output(["readelf", "-h", str(file)], text=True)
    d = subprocess.check_output(["readelf", "-d", str(file)], text=True)
    v = subprocess.check_output(["readelf", "--version-info", str(file)], text=True)
    n = subprocess.check_output(["readelf", "-n", str(file)], text=True)
    if "Advanced Micro Devices X86-64" not in h or re.search(r"RPATH|RUNPATH", d):
        raise ValueError(f"Invalid native executable: {file.name}")
    if re.search(r"x86-64-v[234]", n) or any(
        (int(a), int(b)) > (2, 39) for a, b in re.findall(r"GLIBC_(\d+)\.(\d+)", v)
    ):
        raise ValueError(f"ELF exceeds baseline: {file.name}")
    needed = re.findall(r"Shared library: \[([^]]+)\]", d)
    if gtk_free and any(
        re.search(r"gtk|gdk|pango|webkit|javascriptcore|icu", x, re.I) for x in needed
    ):
        raise ValueError(f"Host helper links private GUI libraries: {file.name}")
    return {
        "sha256": digest(file),
        "needed": needed,
        "glibc_max": max(
            (tuple(map(int, x)) for x in re.findall(r"GLIBC_(\d+)\.(\d+)", v)),
            default=(0, 0),
        ),
    }


def stage(a):
    if a.output.exists() or a.output.is_symlink():
        raise ValueError("Output must be new")
    if a.epoch < 0:
        raise ValueError("Invalid SOURCE_DATE_EPOCH")
    verifier = (
        a.app_verifier
        or Path(__file__).resolve().parent.parent / "linux-package/verify.py"
    )
    spec = importlib.util.spec_from_file_location("fastra_app_verify", verifier)
    module = importlib.util.module_from_spec(spec)
    previous_bytecode = sys.dont_write_bytecode
    sys.dont_write_bytecode = True
    try:
        spec.loader.exec_module(module)
    finally:
        sys.dont_write_bytecode = previous_bytecode
    app = module.runtime(a.app_stage.resolve(strict=True))
    native = verify.runtime(a.runtime_stage)
    helpers = {
        name: elf(file, True)
        for name, file in [
            ("fastra-runtime-host", a.host_broker),
            ("fastra-git-commit-hook", a.git_helper),
            ("fastra-4d-worker", a.four_d_worker),
        ]
    }
    proof = {entry["binary"]: entry for entry in json.loads(a.host_proof.read_text())}
    if set(proof) != set(helpers):
        raise ValueError("Host helper proof is incomplete")
    for name, entry in helpers.items():
        if (
            proof[name]["sha256"] != entry["sha256"]
            or not proof[name]["gtk_icu_free"]
            or proof[name]["rpath"]
        ):
            raise ValueError(f"Host helper differs from reviewed proof: {name}")
    elf(a.app_stage / "libexec/fastra-linux")
    tools = Path(__file__).resolve().parent
    temporary = a.output.with_name(a.output.name + ".partial")
    if temporary.exists():
        raise ValueError("Partial output already exists")
    temporary.mkdir(parents=True)
    temporary.chmod(0o755)
    try:
        shutil.copytree(a.app_stage, temporary / "app", symlinks=True)
        shutil.copytree(a.runtime_stage, temporary / "runtime", symlinks=True)
        for name, file in [
            ("fastra-runtime-host", a.host_broker),
            ("fastra-git-commit-hook", a.git_helper),
            ("fastra-4d-worker", a.four_d_worker),
        ]:
            target = temporary / "app/libexec" / name
            shutil.copyfile(file, target)
            target.chmod(0o755)
            app["sha256"][f"libexec/{name}"] = digest(target)
        (temporary / "app/manifest.json").write_text(
            json.dumps(app, indent=2, sort_keys=True) + "\n"
        )
        for source, name in [
            ("fastra-native", "bin/fastra-native"),
            ("fastra-system", "bin/fastra"),
            ("entry.sh", "libexec/fastra-native-entry"),
            ("fastra-native-cli", "bin/fastra-control-native"),
            ("fastra-native-cli", "bin/fastra-diff-native"),
            ("fastra-system-cli", "bin/fastra-control"),
            ("fastra-system-cli", "bin/fastra-diff"),
        ]:
            target = temporary / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(tools / source, target)
            target.chmod(0o755)
        (temporary / "provenance").mkdir()
        shutil.copyfile(a.host_proof, temporary / "provenance/host-elf-proof.json")
        (temporary / "README.txt").write_text(
            "Fastra: system runtime remains the default (bin/fastra).\nThe separately selected optional native runtime uses bin/fastra-native.\nKnown loader/WebKit/sandbox-helper paths are shadowed; this is not a filesystem sandbox.\nNative hardware, host fonts, Wayland, CachyOS and IME acceptance remain open.\n"
        )
        for file in temporary.rglob("*"):
            if file.is_symlink():
                continue
            file.chmod(0o755 if file.is_dir() or file.stat().st_mode & 0o111 else 0o644)
        hashes = {}
        links = {}
        for file in sorted(temporary.rglob("*")):
            key = file.relative_to(temporary).as_posix()
            mode = file.lstat().st_mode
            if mode & 0o7000:
                raise ValueError(f"Special mode in package: {key}")
            if stat.S_ISLNK(mode):
                links[key] = os.readlink(file)
                virtual(temporary, key)
            elif stat.S_ISREG(mode):
                hashes[key] = digest(file)
            elif not stat.S_ISDIR(mode):
                raise ValueError(f"Special package file: {key}")
        manifest = {
            "format": 1,
            "kind": "fastra-optional-native-package",
            "architecture": "x86_64",
            "version": app["version"],
            "source_sha256": app["source_sha256"],
            "system_is_default": True,
            "shadowed_paths": [
                {
                    "path": "/lib64/ld-linux-x86-64.so.2",
                    "kind": "file",
                    "canonical_target": None,
                    "resolve_canonical_on_launch": True,
                },
                {
                    "path": "/usr/lib/x86_64-linux-gnu/webkitgtk-6.0",
                    "kind": "directory",
                    "canonical_target": None,
                    "resolve_canonical_on_launch": True,
                },
                {
                    "path": "/usr/bin/bwrap",
                    "kind": "file",
                    "canonical_target": None,
                    "resolve_canonical_on_launch": True,
                },
                {
                    "path": "/usr/bin/xdg-dbus-proxy",
                    "kind": "file",
                    "canonical_target": None,
                    "resolve_canonical_on_launch": True,
                },
            ],
            "native_manifest_sha256": digest(temporary / "runtime/manifest.json"),
            "host_protocol": 1,
            "host_helpers": helpers,
            "source_date_epoch": a.epoch,
            "sha256": hashes,
            "symlinks": links,
            "app_verifier_sha256": digest(verifier),
            "limitations": native["limitations"],
        }
        (temporary / "native-package.json").write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n"
        )
        (temporary / "native-package.json").chmod(0o644)
        verify.package(temporary)
        temporary.rename(a.output)
    except BaseException:
        shutil.rmtree(temporary)
        raise
    return manifest


def archive(root, destination, epoch):
    name(destination.name)
    checksum = destination.with_name(destination.name + ".sha256")
    temporary = destination.with_name(destination.name + ".partial")
    if any(
        path.exists() or path.is_symlink()
        for path in [destination, checksum, temporary]
    ):
        raise ValueError("Archive/checksum/partial output must be new")
    if destination.resolve().is_relative_to(root.resolve()):
        raise ValueError("Archive must be outside its package tree")
    checksum_created = False
    stream = temporary.open("xb")
    try:
        with (
            stream,
            gzip.GzipFile(
                filename="", fileobj=stream, mode="wb", mtime=epoch, compresslevel=6
            ) as gz,
            tarfile.open(fileobj=gz, mode="w") as tar,
        ):
            for file in [root, *sorted(root.rglob("*"))]:
                arc = str(Path(root.name) / file.relative_to(root))
                info = tar.gettarinfo(str(file), arcname=arc)
                info.uid = info.gid = 0
                info.uname = info.gname = ""
                info.mtime = epoch
                info.pax_headers = {}
                if info.isfile():
                    with file.open("rb") as contents:
                        tar.addfile(info, contents)
                elif info.isdir() or info.issym():
                    tar.addfile(info)
                else:
                    raise ValueError(f"Special archive file: {arc}")
        with checksum.open("x") as out:
            checksum_created = True
            out.write(f"{digest(temporary)}  {destination.name}\n")
        checksum.chmod(0o644)
        # Hardlink statt ersetzendem rename: auch ein inzwischen erzeugtes Ziel bleibt erhalten.
        os.link(temporary, destination)
        destination.chmod(0o644)
    except BaseException:
        if checksum_created:
            checksum.unlink(missing_ok=True)
        raise
    finally:
        temporary.unlink(missing_ok=True)


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--app-stage", type=Path, required=True)
    p.add_argument("--runtime-stage", type=Path, required=True)
    p.add_argument("--host-broker", type=Path, required=True)
    p.add_argument("--git-helper", type=Path, required=True)
    p.add_argument("--four-d-worker", type=Path, required=True)
    p.add_argument("--host-proof", type=Path, required=True)
    p.add_argument("--app-verifier", type=Path)
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--archive", type=Path)
    p.add_argument("--epoch", type=int, required=True)
    a = p.parse_args()
    m = stage(a)
    if a.archive:
        archive(a.output, a.archive, a.epoch)
    print(
        json.dumps(
            {
                "kind": m["kind"],
                "version": m["version"],
                "files": len(m["sha256"]),
                "system_is_default": True,
            }
        )
    )
