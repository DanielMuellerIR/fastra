#!/usr/bin/env python3
"""Archivgebundene SourceView-Distroquelle mit Delete und Default-Return neu bauen."""
from pathlib import Path
import json, hashlib, shutil, subprocess, os

T = Path("/tools")
W = Path("/work")


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def run(a, cwd=None):
    subprocess.run([str(x) for x in a], check=True, cwd=cwd)


b = json.loads((T / "sourceview-source.lock.json").read_text())
v = json.loads((T / "sourceview-native-v3.lock.json").read_text())
assert sha(T / "sourceview-source.lock.json") == v["base_source_lock_sha256"]
src = W / "ubuntu-sourceview-source"
src.mkdir()
for n, h in b["archives"].items():
    p = Path("/source-cache") / n
    assert p.is_file() and not p.is_symlink() and sha(p) == h, n
    shutil.copyfile(p, src / n)
run(["dpkg-source", "-x", next(src.glob("*.dsc")).name], src)
src = src / "gtksourceview5-5.12.0"
assert sha(src / "debian/patches/series") == b["ubuntu_patch_series_sha256"]
assert b["ubuntu_patches"] == {} and (src / "debian/patches/series").read_bytes() == b""
for n, h in b["baseline"].items():
    assert sha(src / n) == h, n
for index, p in enumerate(v["patch_series"]):
    patch = T / p["filename"]
    assert sha(patch) == p["sha256"]
    run(["patch", "-p1", "--fuzz=0", "--forward", "-i", patch], src)
    if index == 0:
        for n, h in v["after_delete_files"].items():
            assert sha(src / n) == h, n
        assert sha(src / "gtksourceview/gtksourceview.c") == v["return_before_sha256"]
assert sha(src / "gtksourceview/gtksourceview.c") == v["return_after_sha256"]
assert sha(src / "gtksourceview/gtksourceindenter.c") == v["indenter_unchanged_sha256"]
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
p = W / "sourceview-install"
p.mkdir()
lib = p / "libgtksourceview-5.so.0.0.0"
shutil.copyfile(W / "ubuntu-sourceview-build/gtksourceview" / lib.name, lib)
(p / "libgtksourceview-5.so.0").symlink_to(lib.name)
d = subprocess.check_output(["readelf", "-d", str(lib)], text=True)
assert "RPATH" not in d and "RUNPATH" not in d
files = {
    **v["after_delete_files"],
    "gtksourceview/gtksourceview.c": v["return_after_sha256"],
    "gtksourceview/gtksourceindenter.c": v["indenter_unchanged_sha256"],
}
r = {
    "format": 1,
    "source_lock_sha256": sha(T / "sourceview-native-v3.lock.json"),
    "base_source_lock_sha256": v["base_source_lock_sha256"],
    "builder_image": v["builder_image"],
    "library": lib.name,
    "library_sha256": sha(lib),
    "source_date_epoch": os.environ["SOURCE_DATE_EPOCH"],
    "patch_series": v["patch_series"],
    "patched_files": files,
    "return_magic": v["return_magic"],
}
(p / "SOURCE-BUILD.json").write_text(json.dumps(r, indent=2, sort_keys=True) + "\n")
shutil.copyfile(T / "sourceview-native-v3.lock.json", p / "SOURCE-LOCK.json")
(p / "builder-packages.tsv").write_text(
    subprocess.check_output(
        ["dpkg-query", "-W", "-f=${binary:Package}\t${Version}\n"], text=True
    )
)
print("SOURCEVIEW_V3_BUILD_VERIFIED", r["library_sha256"], flush=True)
