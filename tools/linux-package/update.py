#!/usr/bin/env python3
"""GitHub-Updates für die versionierte Fastra-Benutzerinstallation."""
import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

sys.dont_write_bytecode = True

REPOSITORY = "DanielMuellerIR/fastra"
API = f"https://api.github.com/repos/{REPOSITORY}/releases/latest"
MAX_PACKAGE = 512 * 1024 * 1024


def version(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", value):
        raise ValueError("Invalid release version")
    return tuple(map(int, value.split(".")))


class HTTPSRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, url):
        if not url.startswith("https://"):
            raise ValueError("Update redirect must use HTTPS")
        return super().redirect_request(request, fp, code, message, headers, url)


def fetch(url, limit):
    request = urllib.request.Request(url, headers={
        "User-Agent": "Fastra-Linux-Updater", "Accept": "application/vnd.github+json"})
    with urllib.request.build_opener(HTTPSRedirect()).open(request, timeout=30) as response:
        data = response.read(limit + 1)
    if len(data) > limit:
        raise ValueError("Update response exceeds size limit")
    return data


def select_release(release, current):
    if not isinstance(release, dict) or release.get("draft") is not False or release.get("prerelease") is not False:
        raise ValueError("Expected a stable published release")
    tag = release.get("tag_name", "")
    candidate = tag.removeprefix("v")
    if version(candidate) <= version(current):
        return {"status": "current"}
    name = f"fastra-{candidate}-linux-x86_64.tar.gz"
    assets = [asset for asset in release.get("assets", []) if asset.get("name") == name]
    if not assets:
        return {"status": "no-linux-package"}
    if len(assets) != 1:
        raise ValueError("Ambiguous Linux release asset")
    asset = assets[0]
    url = f"https://github.com/{REPOSITORY}/releases/download/{tag}/{name}"
    digest = asset.get("digest", "")
    size = asset.get("size")
    if (asset.get("browser_download_url") != url or asset.get("state") != "uploaded"
            or not isinstance(digest, str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", digest)
            or type(size) is not int or not 0 < size <= MAX_PACKAGE):
        raise ValueError("Invalid Linux release asset or missing GitHub SHA256 digest")
    return {"status": "available", "version": candidate, "sha256": digest[7:],
            "url": url, "name": name, "size": size}


def preferences_path():
    base = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
    if not base.is_absolute():
        raise ValueError("XDG_CONFIG_HOME must be absolute")
    return base / "fastra/updates.json"


def preferences():
    file = preferences_path()
    if not file.exists():
        return {"automatic": True, "checked_at": 0}
    value = json.loads(file.read_text())
    if type(value.get("automatic")) is not bool or type(value.get("checked_at")) not in (int, float):
        raise ValueError("Invalid update preferences")
    return value


@contextmanager
def preferences_lock():
    file = preferences_path().with_suffix(".lock")
    file.parent.mkdir(parents=True, exist_ok=True)
    # Die JSON-Datei wird atomar ersetzt. Nur eine separate, nie entfernte
    # Sperrdatei bindet alle Helfer auch nach diesem Inode-Wechsel zusammen.
    with file.open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def save_preferences(value):
    file = preferences_path()
    file.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".updates-", dir=file.parent)
    try:
        with os.fdopen(fd, "w") as output:
            json.dump(value, output)
        os.replace(temporary, file)
    finally:
        Path(temporary).unlink(missing_ok=True)


def installed_runtime():
    runtime = Path(__file__).resolve().parents[2]
    # Nur unser Installer besitzt den current-Link. DEB/Quellbuilds werden
    # weiterhin durch ihren Paketmanager bzw. Entwickler aktualisiert.
    root = runtime.parent.parent
    if (runtime.parent.name != "versions" or root.name != "fastra"
            or root.parent.name != "share" or (root / ".fastra-owner").read_text() != "Fastra Linux user installation v1\n"
            or not (root / "current").is_symlink() or (root / "current").resolve() != runtime):
        raise ValueError("Updates require the active Fastra user installation; restart after updating")
    manifest = json.loads((runtime / "manifest.json").read_text())
    if manifest.get("architecture") != "x86_64" or manifest.get("native_runtime"):
        raise ValueError("This runtime must be updated with its original package channel")
    return runtime, root.parent.parent, manifest["version"]


def install(ticket, runtime, prefix, current):
    with tempfile.TemporaryDirectory(prefix="fastra-update-") as temporary:
        directory = Path(temporary)
        archive = directory / ticket["name"]
        request = urllib.request.Request(ticket["url"], headers={"User-Agent": "Fastra-Linux-Updater"})
        digest = hashlib.sha256()
        length = 0
        deadline = time.monotonic() + 600
        with urllib.request.build_opener(HTTPSRedirect()).open(request, timeout=30) as response, archive.open("xb") as output:
            while block := response.read(1024 * 1024):
                length += len(block)
                if length > ticket["size"] or time.monotonic() > deadline:
                    raise ValueError("Update download exceeded size or time limit")
                digest.update(block)
                output.write(block)
        if length != ticket["size"] or digest.hexdigest() != ticket["sha256"]:
            raise ValueError("Update download does not match the GitHub SHA256 digest")
        (directory / "SHA256SUMS").write_text(f"{ticket['sha256']}  {ticket['name']}\n")
        import install as installer
        import verify
        # Vor jedem Versionswechsel Paketidentität und vollständigen Inhalt prüfen.
        inspection = directory / "inspection"
        inspection.mkdir()
        unpacked = installer.unpack(archive, inspection)
        manifest = verify.runtime(unpacked)
        if (manifest["version"] != ticket["version"] or manifest["architecture"] != "x86_64"
                or manifest.get("native_runtime") or version(manifest["version"]) <= version(current)):
            raise ValueError("Update package identity does not match the approved release")
        if (runtime.parent.parent / "current").resolve() != runtime:
            raise ValueError("Installed version changed during download; restart Fastra")
        subprocess.run([sys.executable, "-B", str(Path(__file__).with_name("install.py")),
                        "--prefix", str(prefix), "--package", str(archive),
                        "--expected-current", str(runtime), "--expected-version", ticket["version"]],
                       check=True, capture_output=True, timeout=120)
    return {"status": "installed", "version": ticket["version"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("check", "install", "preferences", "enable", "disable"))
    parser.add_argument("--automatic", action="store_true")
    parser.add_argument("--version")
    parser.add_argument("--sha256")
    args = parser.parse_args()
    if args.action in ("enable", "disable"):
        with preferences_lock():
            prefs = preferences()
            prefs["automatic"] = args.action == "enable"
            save_preferences(prefs)
        return prefs
    if args.action == "preferences":
        return preferences()
    runtime, prefix, current = installed_runtime()
    with preferences_lock():
        prefs = preferences()
        if args.automatic and (not prefs["automatic"] or time.time() - prefs["checked_at"] < 86400):
            return {"status": "skipped"}
        if args.action == "check":
            prefs["checked_at"] = time.time()
            save_preferences(prefs)
    try:
        release = json.loads(fetch(API, 2 * 1024 * 1024))
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return {"status": "no-linux-package"}
        raise
    ticket = select_release(release, current)
    if args.action == "install":
        if ticket.get("version") != args.version or ticket.get("sha256") != args.sha256 or ticket["status"] != "available":
            raise ValueError("Approved release changed; check for updates again")
        return install(ticket, runtime, prefix, current)
    return ticket


if __name__ == "__main__":
    try:
        print(json.dumps(main()))
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print(json.dumps({"status": "error", "error": str(error)}))
        sys.exit(1)
