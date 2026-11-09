#!/usr/bin/env python3
"""GTK-Distrobasis mit versiegelter Phase5/Delete/History2/Metadata-Serie neu bauen."""
from pathlib import Path
import hashlib, json, subprocess, shutil, os

T = Path("/tools")
W = Path("/work")


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def run(a, cwd=None):
    subprocess.run([str(x) for x in a], cwd=cwd, check=True)


g = json.loads((T / "gtk-source.lock.json").read_text())
n = json.loads((T / "gtk-native-v2.lock.json").read_text())
v = json.loads((T / "gtk-native-v4.lock.json").read_text())
assert sha(T / "gtk-source.lock.json") == n["base_source_lock_sha256"]
assert sha(T / "gtk-native-v2.lock.json") == v["base_native_lock_sha256"]
s = W / "ubuntu-gtk-source"
s.mkdir()
for name, h in g["archives"].items():
    p = Path("/source-cache") / name
    assert p.is_file() and not p.is_symlink() and sha(p) == h, name
    shutil.copyfile(p, s / name)
run(["dpkg-source", "-x", next(s.glob("*.dsc")).name], s)
s = s / "gtk4-4.14.5+ds"
assert sha(s / "debian/patches/series") == g["ubuntu_patch_series_sha256"]
series = [
    a.split("#", 1)[0].strip().split()[0]
    for a in (s / "debian/patches/series").read_text().splitlines()
    if a.split("#", 1)[0].strip()
]
assert (s / ".pc/applied-patches").read_text().splitlines() == series
for name, h in g["ubuntu_patches"].items():
    assert sha(s / "debian/patches" / name) == h, name
assert sha(s / "gtk/gtktextview.c") == g["gtktextview_before_sha256"]
assert sha(s / "gtk/gtktexthistory.c") == n["history_before_sha256"]
for index, p in enumerate(n["patch_series"]):
    f = T / p["filename"]
    assert sha(f) == p["sha256"]
    run(["patch", "-p1", "--fuzz=0", "--forward", "-i", f], s)
    expected = n["phase5_baseline"] if index == 0 else n["patched_files"]
    for name, h in expected.items():
        assert sha(s / name) == h, name
assert sha(s / "gtk/gtktexthistory.c") == n["history_after_sha256"]
for name, expected in v["baseline_files"].items():
    assert sha(s / name) == expected, name
p = v["own_patch"]
f = T / p["filename"]
assert sha(f) == p["sha256"]
run(["patch", "-p1", "--fuzz=0", "--forward", "-i", f], s)
for name, expected in v["patched_files"].items():
    assert sha(s / name) == expected, name
run(["meson", "setup", W / "ubuntu-gtk-build", *g["meson_options"]], s)
run(["ninja", "-C", W / "ubuntu-gtk-build", "-j4", "gtk/libgtk-4.so.1.1400.5"])
p = W / "gtk-install"
p.mkdir()
lib = p / "libgtk-4.so.1.1400.5"
shutil.copyfile(W / "ubuntu-gtk-build/gtk" / lib.name, lib)
(p / "libgtk-4.so.1").symlink_to(lib.name)
d = subprocess.check_output(["readelf", "-d", str(lib)], text=True)
assert "RPATH" not in d and "RUNPATH" not in d
r = {
    "format": 1,
    "source_lock_sha256": sha(T / "gtk-native-v4.lock.json"),
    "base_native_lock_sha256": v["base_native_lock_sha256"],
    "builder_image": v["builder_image"],
    "library": lib.name,
    "library_sha256": sha(lib),
    "source_date_epoch": os.environ["SOURCE_DATE_EPOCH"],
    "metadata_magic": v["metadata_magic"],
    "patched_files": {
        **n["patched_files"],
        "gtk/gtktexthistory.c": n["history_after_sha256"],
        **v["patched_files"],
    },
}
(p / "SOURCE-BUILD.json").write_text(json.dumps(r, indent=2, sort_keys=True) + "\n")
shutil.copyfile(T / "gtk-native-v4.lock.json", p / "SOURCE-LOCK.json")
(p / "builder-packages.tsv").write_text(
    subprocess.check_output(
        ["dpkg-query", "-W", "-f=${binary:Package}\t${Version}\n"], text=True
    )
)
print("GTK_V4_METADATA_BUILD_VERIFIED", r["library_sha256"], flush=True)
