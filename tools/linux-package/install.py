#!/usr/bin/env python3
"""Geprüfte, versionierte Benutzerinstallation mit atomarem Wechsel und Rollback."""
import argparse
import contextlib
import fcntl
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile
import zipfile
import verify

OWNER = "Fastra Linux user installation v1\n"


def unpack(archive, destination):
    # Alle Einträge erst prüfen. Dateien nie durch ein Archiv-Symlink schreiben.
    if archive.name.endswith(".tar.gz"):
        with tarfile.open(archive, "r:gz") as source:
            members = source.getmembers()
            links = {m.name.rstrip("/") for m in members if m.issym()}
            names = set()
            for m in members:
                p = verify.safe_name(m.name)
                if m.name in names or not (m.isfile() or m.isdir() or m.issym()):
                    raise ValueError("Duplicate or unsupported archive entry.")
                names.add(m.name)
                if any(str(parent) in links for parent in p.parents):
                    raise ValueError("Archive writes through symlink.")
                if m.issym():
                    verify.safe_name(m.linkname)
                if m.mode & 0o6000:
                    raise ValueError("Set-id archive entry.")
            source.extractall(destination, filter="data")
    elif archive.suffix == ".zip":
        with zipfile.ZipFile(archive) as source:
            entries = source.infolist()
            names = set()
            links = set()
            for entry in entries:
                verify.safe_name(entry.filename)
                mode = entry.external_attr >> 16
                if entry.filename in names or mode & 0o6000:
                    raise ValueError("Duplicate or set-id ZIP entry.")
                names.add(entry.filename)
                if stat.S_ISLNK(mode):
                    links.add(entry.filename)
                    verify.safe_name(source.read(entry).decode())
                elif stat.S_IFMT(mode) not in (0, stat.S_IFREG, stat.S_IFDIR):
                    raise ValueError("Unsupported ZIP entry.")
            for entry in entries:
                p = verify.safe_name(entry.filename)
                if any(str(parent) in links for parent in p.parents):
                    raise ValueError("ZIP writes through symlink.")
                file = destination / entry.filename
                file.parent.mkdir(parents=True, exist_ok=True)
                mode = entry.external_attr >> 16
                if stat.S_ISLNK(mode):
                    file.symlink_to(source.read(entry).decode())
                elif entry.is_dir():
                    file.mkdir(exist_ok=True)
                else:
                    with source.open(entry) as inp, file.open("xb") as out:
                        shutil.copyfileobj(inp, out)
                    file.chmod(mode & 0o777 or 0o644)
    else:
        raise ValueError("Use the portable .tar.gz or .zip for a user installation.")
    children = list(destination.iterdir())
    if len(children) != 1 or not children[0].is_dir() or children[0].is_symlink():
        raise ValueError("Archive must contain exactly one runtime directory.")
    return children[0]


def atomic_link(target, link):
    fd, name = tempfile.mkstemp(prefix=".fastra-link-", dir=link.parent)
    os.close(fd)
    os.unlink(name)
    try:
        os.symlink(target, name)
        os.replace(name, link)
    finally:
        if os.path.lexists(name):
            os.unlink(name)


def desktop_quote(value):
    # In Exec beginnt % einen Feldcode; Iconwerte bleiben unverändert.
    value = value.replace("%", "%%")
    # Desktop-Entry: zuerst Exec-Quoting, dann die String-Escape-Ebene.
    for char in ("\\", '"', '`', '$'):
        value = value.replace(char, "\\" + char)
    return '"' + value.replace("\\", "\\\\") + '"'


def main():
    p = argparse.ArgumentParser(description=__doc__, epilog="No sudo, Git changes or system package installation. Uninstall by removing only the printed owned paths; older versions are retained for rollback.")
    p.add_argument("--package", type=Path, help="portable tar.gz/ZIP beside SHA256SUMS; defaults to newest dist/*/packages/*.tar.gz")
    p.add_argument("--prefix", type=Path, default=Path.home() / ".local", help="user-local prefix (default: ~/.local)")
    p.add_argument("--key", help="require SHA256SUMS.asc signed by this full OpenPGP fingerprint")
    p.add_argument("--expected-current", type=Path, help=argparse.SUPPRESS)
    p.add_argument("--expected-version", help=argparse.SUPPRESS)
    p.add_argument("--system-deb", type=Path, help="explicitly install this DEB using dpkg; run as root yourself, never invokes sudo")
    args = p.parse_args()
    if args.package and args.system_deb:
        p.error("Choose --package or --system-deb.")
    archive = args.system_deb or args.package
    if archive is None:
        repo = Path(__file__).resolve().parents[2]
        candidates = list(repo.glob("dist/*/packages/*.tar.gz"))
        if not candidates:
            p.error("No local package found. Run ./linux/package.sh first, then ./install.sh --package PATH.")
        archive = max(candidates, key=lambda f: f.stat().st_mtime_ns)
    archive = archive.resolve(strict=True)
    verify.checksums(archive.parent, archive.name)
    if args.key:
        import re
        if not re.fullmatch(r"(?:[0-9A-Fa-f]{40}|[0-9A-Fa-f]{64})", args.key):
            p.error("Use a full OpenPGP fingerprint.")
        result = subprocess.run(["gpg", "--status-fd", "1", "--verify", str(archive.parent / "SHA256SUMS.asc"), str(archive.parent / "SHA256SUMS")], check=True, capture_output=True, text=True)
        valid = [line.split() for line in result.stdout.splitlines() if line.startswith("[GNUPG:] VALIDSIG ")]
        if not any(args.key.upper() in (line[2].upper(), line[-1].upper()) for line in valid):
            raise ValueError("Signature is not from the requested fingerprint.")
    if args.system_deb:
        if os.geteuid() != 0:
            p.error("--system-deb requires an explicitly root-run invocation; this script never calls sudo.")
        with tempfile.TemporaryDirectory(prefix="fastra-deb-check-") as temporary:
            subprocess.run(["dpkg-deb", "--extract", str(archive), temporary], check=True)
            verify.runtime(Path(temporary) / "opt/fastra")
        subprocess.run(["dpkg", "--install", str(archive)], check=True)
        return
    prefix = args.prefix.expanduser().absolute()
    if any(char in str(prefix) for char in "\n\r\x00"):
        p.error("Prefix must not contain control characters.")
    if prefix.is_symlink():
        p.error("Prefix must be a real directory.")
    root = prefix / "share/fastra"
    for directory in (prefix, prefix / "share", root, prefix / "bin", prefix / "share/applications"):
        if directory.is_symlink() or (directory.exists() and not directory.is_dir()):
            raise ValueError(f"Foreign installation path: {directory}")
        directory.mkdir(parents=True, exist_ok=True)
    marker = root / ".fastra-owner"
    if not marker.exists() and any(root.iterdir()):
        raise ValueError(f"Refusing foreign nonempty directory: {root}")
    if marker.is_symlink() or (marker.exists() and marker.read_text() != OWNER):
        raise ValueError("Foreign ownership marker.")
    if not marker.exists():
        with marker.open("x") as file:
            file.write(OWNER)
    lock_path = root / ".install-lock"
    if lock_path.is_symlink():
        raise ValueError("Installation lock must not be a symlink.")
    with lock_path.open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        install_locked(archive, prefix, root, args.expected_current, args.expected_version)


def install_locked(archive, prefix, root, expected_current=None, expected_version=None):
    versions = root / "versions"
    if versions.is_symlink():
        raise ValueError("Versions directory must not be a symlink.")
    versions.mkdir(exist_ok=True)
    current = root / "current"
    if os.path.lexists(current):
        if not current.is_symlink() or not current.resolve().is_relative_to(versions.resolve()):
            raise ValueError("Refusing foreign current path.")
        verify.runtime(current.resolve())
    old_target = os.readlink(current) if current.is_symlink() else None
    if expected_current is not None and (old_target is None or current.resolve() != expected_current):
        raise ValueError("Installed version changed; restart Fastra and check for updates again.")
    links = {prefix / "bin" / name: str(current / "bin" / name) for name in ("fastra", "fastra-control")}
    for file, target in links.items():
        if os.path.lexists(file) and (not file.is_symlink() or os.readlink(file) != target):
            raise ValueError(f"Refusing foreign launcher: {file}")
    diff_link = prefix / "bin/fastra-diff"
    diff_target = str(current / "bin/fastra-diff")
    old_diff_owned = diff_link.is_symlink() and os.readlink(diff_link) == diff_target
    removed_diff = False
    desktop = prefix / "share/applications/fastra.desktop"
    desktop_marker = "# Managed by Fastra user installer\n"
    if desktop.is_symlink() or (desktop.exists() and not desktop.read_text().startswith(desktop_marker)):
        raise ValueError(f"Refusing foreign desktop entry: {desktop}")
    old_desktop = desktop.read_bytes() if desktop.exists() else None
    created_links = []
    switched = False
    dest = None
    created_dest = False
    for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(sig, lambda number, frame: (_ for _ in ()).throw(InterruptedError(f"Interrupted by signal {number}")))
    with tempfile.TemporaryDirectory(prefix=".install-", dir=root) as temporary:
        temporary = Path(temporary)
        try:
            unpacked = unpack(archive, temporary)
            manifest = verify.runtime(unpacked)
            if expected_version is not None and manifest["version"] != expected_version:
                raise ValueError("Package version does not match the approved update.")
            has_diff = "bin/fastra-diff" in manifest["sha256"]
            if has_diff:
                if os.path.lexists(diff_link) and not old_diff_owned:
                    raise ValueError(f"Refusing foreign launcher: {diff_link}")
                links[diff_link] = diff_target
            dest = versions / (manifest["version"] + "-" + manifest["source_sha256"][:16])
            if dest.is_symlink():
                raise ValueError("Version destination must not be a symlink.")
            if dest.exists():
                if (dest / "manifest.json").read_bytes() != (unpacked / "manifest.json").read_bytes():
                    raise ValueError("Existing version has different content; refusing to replace it.")
                verify.runtime(dest)
            else:
                os.rename(unpacked, dest)
                created_dest = True
            if not has_diff and old_diff_owned:
                blocked = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTERM, signal.SIGHUP, signal.SIGINT})
                try:
                    diff_link.unlink()
                    removed_diff = True
                finally:
                    signal.pthread_sigmask(signal.SIG_SETMASK, blocked)
            switched = True
            atomic_link(str(dest.relative_to(root)), current)
            for file, target in links.items():
                if not os.path.lexists(file):
                    blocked = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTERM, signal.SIGHUP, signal.SIGINT})
                    try:
                        file.symlink_to(target)
                        created_links.append(file)
                    finally:
                        signal.pthread_sigmask(signal.SIG_SETMASK, blocked)
            text = desktop_marker + "[Desktop Entry]\nType=Application\nName=Fastra\nComment=Search and replace with previews\n"
            # GIO prüft das erste Programm vor der %-Expansion; env hält diesen Pfad konstant.
            text += "Exec=/usr/bin/env -- " + desktop_quote(str(prefix / "bin/fastra")) + " %F\n"
            text += "Icon=" + str(current / "share/icons/hicolor/256x256/apps/fastra.png").replace("\\", "\\\\") + "\nTerminal=false\nCategories=Utility;TextEditor;\nMimeType=text/plain;\n"
            desktop_new = temporary / "desktop.new"
            desktop_new.write_text(text)
            os.replace(desktop_new, desktop)
            verify.runtime(current.resolve())
            for file, target in links.items():
                if not file.is_symlink() or os.readlink(file) != target or not os.access(file, os.X_OK):
                    raise ValueError("Installed launcher verification failed.")
            launchers = ", ".join(str(file) for file in links)
            print(f"Installed Fastra {manifest['version']}: {current}\nLaunchers: {launchers}\nDesktop entry: {desktop}\nOlder versions retained in {versions}")
        except BaseException:
            # Ein zweites Signal darf die Rücknahme nicht erneut unterbrechen.
            for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
                signal.signal(sig, signal.SIG_IGN)
            if switched:
                if old_target is None:
                    current.unlink(missing_ok=True)
                else:
                    atomic_link(old_target, current)
            for file in created_links:
                file.unlink(missing_ok=True)
            if removed_diff and not os.path.lexists(diff_link):
                diff_link.symlink_to(diff_target)
            if old_desktop is None:
                desktop.unlink(missing_ok=True)
            else:
                restore = temporary / "desktop.restore"
                restore.write_bytes(old_desktop)
                os.replace(restore, desktop)
            if created_dest:
                shutil.rmtree(dest)
            raise


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f"Fastra install: {error}", file=sys.stderr)
        sys.exit(1)
