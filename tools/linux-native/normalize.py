#!/usr/bin/env python3
"""Aus dem identifizierten Rohbaum einen relocierbaren, geprüften Kandidaten bilden."""
import argparse
import json
import os
import re
import shutil
import stat
from pathlib import Path
from common import digest, inventory, name, virtual
from elf_paths import relocate


def omitted(key):
    if key == "usr/lib/ssl/private":
        return "Private key directory is intentionally not part of this runtime"
    if key.startswith("usr/share/doc/"):
        return "Dangling informational alias; all package copyrights are materialized separately"
    if key.startswith("usr/share/icons/"):
        return "Dangling optional icon alias from the source package payload"
    if key.startswith("usr/share/locale/") and key.endswith("/LC_TIME/coreutils.mo"):
        return "Dangling coreutils locale alias; bundled coreutils are not selected as host tools"
    return None


def normalize(
    raw,
    copyrights,
    pango,
    source,
    output,
    gtk_source=None,
    patchelf=None,
    gtk_prefix=None,
):
    if output.exists() or output.is_symlink():
        raise ValueError("Output must be new")
    raw = raw.resolve(strict=True)
    original = json.loads((raw / "manifest.json").read_text())
    actual_files = {}
    actual_links = {}
    special = []
    for p in sorted(raw.rglob("*")):
        key = p.relative_to(raw).as_posix()
        name(key)
        st = p.lstat()
        if st.st_mode & 0o7000:
            special.append(
                {
                    "path": key,
                    "from": oct(stat.S_IMODE(st.st_mode)),
                    "to": oct(0o755 if st.st_mode & 0o111 else 0o644),
                }
            )
        if stat.S_ISLNK(st.st_mode):
            actual_links[key] = os.readlink(p)
        elif stat.S_ISREG(st.st_mode):
            if key != "manifest.json":
                actual_files[key] = digest(p)
        elif not stat.S_ISDIR(st.st_mode):
            raise ValueError(f"Special raw file: {key}")
    if actual_files != original["sha256"] or actual_links != original["symlinks"]:
        raise ValueError("Raw runtime differs from its complete manifest")
    packages = json.loads((copyrights / "packages.json").read_text())
    if set(packages) != set(original["packages"]):
        raise ValueError("Copyright package coverage differs")
    copyright_root = copyrights.resolve(strict=True)
    for package, record in packages.items():
        if not re.fullmatch(r"[a-z0-9][a-z0-9+.-]*", package):
            raise ValueError("Unsafe copyright package name")
        file = copyright_root / package / "copyright"
        if (
            file.is_symlink()
            or not file.is_file()
            or not file.resolve().is_relative_to(copyright_root)
        ):
            raise ValueError(f"Unsafe copyright file: {package}")
        if (
            record["version"] != original["packages"][package]
            or digest(copyrights / package / "copyright") != record["copyright_sha256"]
        ):
            raise ValueError(f"Copyright mismatch: {package}")
    lock = json.loads(source.read_text())
    if lock["version"] != "1.52.1+ds-1build1" or len(lock["ubuntu_patches"]) != 3:
        raise ValueError("Unverified Pango distribution source lock")
    receipt = json.loads((pango / "SOURCE-BUILD.json").read_text())
    if (
        receipt["source_lock_sha256"] != digest(source)
        or receipt["own_patches"] != lock["own_patches"]
    ):
        raise ValueError("Pango build receipt differs from source lock")
    gtk_lock = None
    if original["gtk_source"]:
        if gtk_source is None:
            raise ValueError("GTK source lock is required")
        gtk_lock = json.loads(gtk_source.read_text())
        for field in (
            "archives",
            "source",
            "ubuntu_patch_series_sha256",
            "ubuntu_patches",
            "version",
        ):
            if gtk_lock[field] != original["gtk_source"][field]:
                raise ValueError(
                    "GTK distribution source lock differs from raw provenance"
                )
        if (
            digest(raw / "usr/lib/x86_64-linux-gnu/libgtk-4.so.1.1400.5")
            != gtk_lock["library_sha256"]
        ):
            raise ValueError("Raw GTK library differs from verified original")
        if gtk_prefix is None:
            raise ValueError("Verified GTK build prefix is required")
        gtk_receipt = json.loads((gtk_prefix / "SOURCE-BUILD.json").read_text())
        if (
            gtk_receipt["source_lock_sha256"] != digest(gtk_source)
            or gtk_receipt["library_sha256"] != gtk_lock["library_sha256"]
            or digest(gtk_prefix / "libgtk-4.so.1.1400.5") != gtk_lock["library_sha256"]
        ):
            raise ValueError(
                "GTK build receipt does not reproduce the verified runtime library"
            )
    temporary = output.with_name(output.name + ".partial")
    if temporary.exists():
        raise ValueError("Partial output already exists")
    temporary.mkdir(parents=True)
    temporary.chmod(0o755)
    removed = []
    converted = []
    try:
        for p in sorted(raw.rglob("*")):
            key = p.relative_to(raw).as_posix()
            dest = temporary / key
            st = p.lstat()
            if key == "manifest.json":
                continue
            if stat.S_ISDIR(st.st_mode):
                dest.mkdir(parents=True, exist_ok=True)
                dest.chmod(0o755)
            elif stat.S_ISREG(st.st_mode):
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(p, dest)
                dest.chmod(0o755 if st.st_mode & 0o111 else 0o644)
                if digest(dest) != actual_files[key]:
                    raise ValueError(f"Raw file changed while copying: {key}")
            else:
                try:
                    virtual(raw, key)
                except FileNotFoundError:
                    reason = omitted(key)
                    if not reason:
                        raise ValueError(
                            f"Unclassified dangling link: {key} -> {actual_links[key]}"
                        )
                    removed.append(
                        {"path": key, "target": actual_links[key], "reason": reason}
                    )
                    continue
                target = actual_links[key]
                if target.startswith("/"):
                    target = os.path.relpath(
                        temporary / target.lstrip("/"), dest.parent
                    )
                    converted.append(
                        {"path": key, "from": actual_links[key], "to": target}
                    )
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.symlink_to(target)
        # Die vollständigen Texte bleiben auch bei Doc-Verzeichnisaliases eigenständig.
        for package in packages:
            target = temporary / "licenses/debian" / package / "copyright"
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(copyright_root / package / "copyright", target)
        shutil.copyfile(
            copyright_root / "packages.json",
            temporary / "licenses/debian/packages.json",
        )
        provenance = temporary / "provenance"
        provenance.mkdir()
        (provenance / "raw-manifest.json").write_text(
            json.dumps(original, indent=2, sort_keys=True) + "\n"
        )
        shutil.copyfile(source, provenance / "pango-source-lock.json")
        shutil.copyfile(
            pango / "SOURCE-BUILD.json", provenance / "pango-source-build.json"
        )
        shutil.copyfile(
            pango / "builder-packages.tsv", provenance / "pango-builder-packages.tsv"
        )
        overrides = {}
        for component in ["pango", "pangocairo", "pangoft2"]:
            filename = f"lib{component}-1.0.so.0.5200.1"
            lib = pango / "lib" / filename
            if lib.is_symlink() or not lib.is_file():
                raise ValueError(f"Pango library missing: {filename}")
            if digest(lib) != receipt["libraries"].get(filename):
                raise ValueError(
                    f"Pango library differs from build receipt: {filename}"
                )
            target = temporary / "usr/lib/x86_64-linux-gnu" / filename
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(lib, target)
            target.chmod(0o644)
            overrides[str(target.relative_to(temporary))] = digest(target)
        if gtk_source is not None:
            shutil.copyfile(gtk_source, provenance / "gtk-source-lock.json")
            shutil.copyfile(
                gtk_prefix / "SOURCE-BUILD.json", provenance / "gtk-source-build.json"
            )
            shutil.copyfile(
                gtk_prefix / "builder-packages.tsv",
                provenance / "gtk-builder-packages.tsv",
            )
        for filename, expected in lock["own_patches"].items():
            patch = Path(__file__).parent / filename
            if digest(patch) != expected:
                raise ValueError("Pango patch changed after build")
            shutil.copyfile(patch, provenance / filename)
        if gtk_lock is not None:
            patch = Path(__file__).parent / gtk_lock["own_patch"]["filename"]
            if digest(patch) != gtk_lock["own_patch"]["sha256"]:
                raise ValueError("GTK own patch hash changed")
            shutil.copyfile(patch, provenance / patch.name)
        elf_paths = relocate(temporary, patchelf)
        for file in temporary.rglob("*"):
            if file.is_symlink():
                continue
            file.chmod(0o755 if file.is_dir() or file.stat().st_mode & 0o111 else 0o644)
        hashes, links, modes = inventory(temporary)
        manifest = {
            "format": 1,
            "kind": "fastra-optional-native-runtime",
            "architecture": "x86_64",
            "raw_manifest_sha256": digest(raw / "manifest.json"),
            "image": original["image"],
            "gtk_source": original["gtk_source"],
            "gtk_source_lock": gtk_lock,
            "elf_searchpath_normalization": elf_paths,
            "pango_source": lock,
            "pango_overrides": overrides,
            "packages": packages,
            "stripped_modes": special,
            "converted_absolute_links": converted,
            "omitted_dangling_links": removed,
            "sha256": hashes,
            "symlinks": links,
            "modes": modes,
            "limitations": [
                "Software X11 candidate only; native hardware, Host fonts, CachyOS, Wayland and IME acceptance remain open",
                "Specific loader/WebKit/bwrap/proxy paths are shadowed; no complete host filesystem identity claim",
            ],
        }
        (temporary / "manifest.json").write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n"
        )
        (temporary / "manifest.json").chmod(0o644)
        temporary.rename(output)
    except BaseException:
        shutil.rmtree(temporary)
        raise
    return manifest


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--raw", type=Path, required=True)
    p.add_argument("--copyrights", type=Path, required=True)
    p.add_argument("--pango-prefix", type=Path, required=True)
    p.add_argument("--pango-source-lock", type=Path, required=True)
    p.add_argument(
        "--gtk-source-lock",
        type=Path,
        default=Path(__file__).parent / "gtk-source.lock.json",
    )
    p.add_argument("--patchelf", type=Path, required=True)
    p.add_argument("--gtk-prefix", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    a = p.parse_args()
    m = normalize(
        a.raw,
        a.copyrights,
        a.pango_prefix,
        a.pango_source_lock,
        a.output,
        a.gtk_source_lock,
        a.patchelf,
        a.gtk_prefix,
    )
    print(
        json.dumps(
            {
                "files": len(m["sha256"]),
                "links": len(m["symlinks"]),
                "copyrights": len(m["packages"]),
                "stripped_modes": len(m["stripped_modes"]),
                "absolute_links_converted": len(m["converted_absolute_links"]),
                "dangling_aliases_omitted": len(m["omitted_dangling_links"]),
            }
        )
    )


if __name__ == "__main__":
    main()
