#!/usr/bin/env python3
"""Privater Runtimekandidat aus dem unveränderten, identifizierten Ubuntu-Builder."""
import argparse, hashlib, json, os, re, shutil, subprocess
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument("--output", type=Path, required=True)
p.add_argument("--gtk-prefix", type=Path, required=True)
a = p.parse_args()
lock = json.loads(Path(__file__).with_name("runtime-input.lock.json").read_text())
root = a.output
if root.exists():
    raise SystemExit("Output must be new")
rows = subprocess.check_output(
    ["dpkg-query", "-W", "-f=${db:Status-Abbrev}\t${binary:Package}\t${Version}\n"],
    text=True,
)
installed = {}
for row in rows.splitlines():
    status, name, version = row.split("\t")
    if status == "ii ":
        installed[name.split(":")[0]] = (name, version)
required = [
    "libgtk-4-1",
    "libgtksourceview-5-0",
    "libwebkitgtk-6.0-4",
    "bubblewrap",
    "libc-bin",
    "libglib2.0-bin",
    "libgdk-pixbuf2.0-bin",
    "glib-networking",
    "ca-certificates",
    "shared-mime-info",
    "fontconfig",
    "fonts-dejavu-core",
]
missing = set(required) - set(installed)
if missing:
    raise SystemExit(f"Missing required packages: {sorted(missing)}")
essential_rows = subprocess.check_output(
    ["dpkg-query", "-W", "-f=${binary:Package}\t${Essential}\n"], text=True
)
essential = [
    line.split("\t")[0].split(":")[0]
    for line in essential_rows.splitlines()
    if line.endswith("\tyes") and line.split("\t")[0].split(":")[0] in installed
]
seeds = (
    required
    + essential
    + [x for x in ["libgl1-mesa-dri", "libegl-mesa0", "libglx-mesa0"] if x in installed]
    + [
        x
        for x in installed
        if x.startswith("gstreamer1.0-plugins-") or x == "gstreamer1.0-libav"
    ]
)
deps = subprocess.check_output(
    [
        "apt-cache",
        "depends",
        "--recurse",
        "--installed",
        "--no-recommends",
        "--no-suggests",
        "--no-breaks",
        "--no-conflicts",
        "--no-replaces",
        "--no-enhances",
        *seeds,
    ],
    text=True,
)
names = set(seeds)
for line in deps.splitlines():
    if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9+.-]*(?::[a-z0-9]+)?", line):
        names.add(line.split(":")[0])
if names - set(installed):
    raise SystemExit(f"Unresolved package owners: {sorted(names-set(installed))}")
actual = {name: installed[name][1] for name in sorted(names)}
if actual != lock["packages"]:
    raise SystemExit("Pinned runtime package closure differs")
root.mkdir(parents=True)
copied = set()


def copy_file(src):
    src = Path(src)
    # Usrmerge wird schon bei der Elterndirectory aufgelöst, der Link selbst bleibt erhalten.
    src = src.parent.resolve() / src.name
    key = str(src)
    if key in copied:
        return
    if not src.is_file() and not src.is_symlink():
        return
    if not (key.startswith("/usr/") or key.startswith("/etc/")):
        return
    copied.add(key)
    dst = root / key.lstrip("/")
    dst.parent.mkdir(parents=True, exist_ok=True)
    if src.is_symlink():
        dst.symlink_to(os.readlink(src))
        target = Path(os.path.normpath(str(src.parent / os.readlink(src))))
        if target.exists() or target.is_symlink():
            copy_file(target)
    else:
        shutil.copy2(src, dst)


for name in sorted(names):
    files = subprocess.check_output(["dpkg-query", "-L", installed[name][0]], text=True)
    for value in files.splitlines():
        if value.startswith(("/usr/", "/lib/", "/lib64/", "/bin/", "/sbin/", "/etc/")):
            copy_file(value)
for directory in ["/etc/fonts", "/etc/ssl/certs", "/etc/ld.so.conf.d"]:
    for value in Path(directory).rglob("*"):
        copy_file(value)
for value in [
    "/usr/lib/x86_64-linux-gnu/gio/modules/giomodule.cache",
    "/usr/lib/x86_64-linux-gnu/gdk-pixbuf-2.0/2.10.0/loaders.cache",
    "/usr/lib/x86_64-linux-gnu/gtk-4.0/4.0.0/immodules.cache",
    "/usr/share/glib-2.0/schemas/gschemas.compiled",
    "/usr/share/mime/mime.cache",
]:
    copy_file(value)
for value in Path("/usr/share/icons").glob("*/icon-theme.cache"):
    copy_file(value)
for value in ["/etc/ld.so.cache", "/etc/ld.so.conf", "/etc/nsswitch.conf"]:
    copy_file(value)
gtk_lock_path = Path(__file__).with_name("gtk-source.lock.json")
gtk_lock = json.loads(gtk_lock_path.read_text())
gtk_receipt = json.loads((a.gtk_prefix / "SOURCE-BUILD.json").read_text())
gtk_library = a.gtk_prefix / "libgtk-4.so.1.1400.5"
if (
    gtk_receipt["source_lock_sha256"]
    != hashlib.sha256(gtk_lock_path.read_bytes()).hexdigest()
    or gtk_receipt["library_sha256"] != gtk_lock["library_sha256"]
    or hashlib.sha256(gtk_library.read_bytes()).hexdigest()
    != gtk_lock["library_sha256"]
):
    raise SystemExit("Verified GTK rebuild differs")
gtk_target = root / "usr/lib/x86_64-linux-gnu/libgtk-4.so.1.1400.5"
shutil.copyfile(gtk_library, gtk_target)
manifest = {
    "format": 1,
    "overrides": {str(gtk_target.relative_to(root)): gtk_lock["library_sha256"]},
    "gtk_source": gtk_lock,
    "kind": "candidate-not-release",
    "image": lock["builder_image"],
    "packages": actual,
    "sha256": {},
    "symlinks": {},
    "limitations": [
        "Raw distribution snapshot; patched GTK/Pango and normalization are required",
        "No native hardware/desktop acceptance",
    ],
}
for value in sorted(root.rglob("*")):
    relative = str(value.relative_to(root))
    if value.is_symlink():
        manifest["symlinks"][relative] = os.readlink(value)
    elif value.is_file():
        manifest["sha256"][relative] = hashlib.sha256(value.read_bytes()).hexdigest()
(root / "manifest.json").write_text(
    json.dumps(manifest, indent=2, sort_keys=True) + "\n"
)
print(
    json.dumps(
        {
            "packages": len(names),
            "files": len(manifest["sha256"]),
            "symlinks": len(manifest["symlinks"]),
        }
    )
)
