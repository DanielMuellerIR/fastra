#!/usr/bin/env python3
"""Distroquellen mit exakt gebundener privater Patchserie vollständig neu bauen."""
from pathlib import Path
import hashlib, json, subprocess, shutil, os

T = Path("/tools")
W = Path("/work")


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def run(args, cwd=None):
    subprocess.run([str(x) for x in args], cwd=cwd, check=True)


def load(n):
    return json.loads((T / n).read_text())


def unpack(lock, cache, target, pkg):
    target.mkdir()
    for n, h in lock["archives"].items():
        p = cache / n
        assert p.is_file() and not p.is_symlink() and sha(p) == h, n
        shutil.copyfile(p, target / n)
    run(["dpkg-source", "-x", next(target.glob("*.dsc")).name], target)
    s = target / pkg
    series = s / "debian/patches/series"
    assert sha(series) == lock["ubuntu_patch_series_sha256"]
    names = [
        x.split("#", 1)[0].strip().split()[0]
        for x in series.read_text().splitlines()
        if x.split("#", 1)[0].strip()
    ]
    assert set(names) == set(lock["ubuntu_patches"])
    for n, h in lock["ubuntu_patches"].items():
        assert sha(s / "debian/patches" / n) == h, n
    applied = s / ".pc/applied-patches"
    assert (applied.read_text().splitlines() if applied.exists() else []) == names
    return s


def patch(s, entry):
    p = T / entry["filename"]
    assert sha(p) == entry["sha256"]
    run(["patch", "-p1", "--fuzz=0", "--forward", "-i", p], s)


def files(s, expected):
    for n, h in expected.items():
        assert sha(s / n) == h, n


def receipt(prefix, library, lockname, extra):
    lib = prefix / library
    d = subprocess.check_output(["readelf", "-d", str(lib)], text=True)
    assert "RPATH" not in d and "RUNPATH" not in d
    soname = (
        "libgtk-4.so.1" if library.startswith("libgtk-") else "libgtksourceview-5.so.0"
    )
    (prefix / soname).symlink_to(library)
    m = {
        "format": 1,
        "source_lock_sha256": sha(T / lockname),
        "library_sha256": sha(lib),
        "library": library,
        "builder_image": load(lockname)["builder_image"],
        "source_date_epoch": os.environ["SOURCE_DATE_EPOCH"],
        **extra,
    }
    (prefix / "SOURCE-BUILD.json").write_text(
        json.dumps(m, indent=2, sort_keys=True) + "\n"
    )
    shutil.copyfile(T / lockname, prefix / "SOURCE-LOCK.json")
    (prefix / "builder-packages.tsv").write_text(
        subprocess.check_output(
            ["dpkg-query", "-W", "-f=${binary:Package}\t${Version}\n"], text=True
        )
    )
    print("VERIFIED_BUILD", library, m["library_sha256"], flush=True)


g = load("gtk-source.lock.json")
n = load("gtk-native-v2.lock.json")
v = load("sourceview-source.lock.json")
assert sha(T / "gtk-source.lock.json") == n["base_source_lock_sha256"]
gtk = unpack(g, Path("/gtk-cache"), W / "ubuntu-gtk-source", "gtk4-4.14.5+ds")
assert sha(gtk / "gtk/gtktextview.c") == g["gtktextview_before_sha256"]
assert sha(gtk / "gtk/gtktexthistory.c") == n["history_before_sha256"]
patch(gtk, n["patch_series"][0])
files(gtk, n["phase5_baseline"])
patch(gtk, n["patch_series"][1])
files(gtk, n["patched_files"])
patch(gtk, n["patch_series"][2])
assert sha(gtk / "gtk/gtktexthistory.c") == n["history_after_sha256"]
run(["meson", "setup", W / "ubuntu-gtk-build", *g["meson_options"]], gtk)
run(["ninja", "-C", W / "ubuntu-gtk-build", "-j4", "gtk/libgtk-4.so.1.1400.5"])
prefix = W / "gtk-install"
prefix.mkdir()
shutil.copyfile(
    W / "ubuntu-gtk-build/gtk/libgtk-4.so.1.1400.5", prefix / "libgtk-4.so.1.1400.5"
)
receipt(
    prefix,
    "libgtk-4.so.1.1400.5",
    "gtk-native-v2.lock.json",
    {
        "base_source_lock_sha256": n["base_source_lock_sha256"],
        "patch_series": n["patch_series"],
        "patched_files": {
            **n["patched_files"],
            "gtk/gtktexthistory.c": n["history_after_sha256"],
        },
    },
)
src = unpack(
    v,
    Path("/sourceview-cache"),
    W / "ubuntu-sourceview-source",
    "gtksourceview5-5.12.0",
)
files(src, v["baseline"])
patch(src, v["own_patch"])
files(src, v["patched_files"])
run(["meson", "setup", W / "ubuntu-sourceview-build", *v["meson_options"]], src)
run(
    [
        "ninja",
        "-C",
        W / "ubuntu-sourceview-build",
        "-j4",
        "gtksourceview/libgtksourceview-5.so.0.0.0",
    ]
)
prefix = W / "sourceview-install"
prefix.mkdir()
shutil.copyfile(
    W / "ubuntu-sourceview-build/gtksourceview/libgtksourceview-5.so.0.0.0",
    prefix / "libgtksourceview-5.so.0.0.0",
)
shutil.copyfile(src / "debian/copyright", prefix / "copyright")
shutil.copyfile(src / "COPYING", prefix / "COPYING")
receipt(
    prefix,
    "libgtksourceview-5.so.0.0.0",
    "sourceview-source.lock.json",
    {
        "own_patch": v["own_patch"],
        "patched_files": v["patched_files"],
        "copyright_sha256": sha(prefix / "copyright"),
        "copying_sha256": sha(prefix / "COPYING"),
    },
)
