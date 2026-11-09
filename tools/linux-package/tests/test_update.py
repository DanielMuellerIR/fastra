import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import update
import verify


def release(current="2.0.0", data=b"package"):
    name = f"fastra-{current}-linux-x86_64.tar.gz"
    return {"draft": False, "prerelease": False, "tag_name": f"v{current}", "assets": [{
        "name": name, "state": "uploaded", "size": len(data),
        "digest": "sha256:" + hashlib.sha256(data).hexdigest(),
        "browser_download_url": f"https://github.com/{update.REPOSITORY}/releases/download/v{current}/{name}"}]}


class Updates(unittest.TestCase):
    def test_only_new_stable_linux_release_with_bound_digest(self):
        self.assertEqual(update.select_release(release(), "1.189.0")["status"], "available")
        self.assertEqual(update.select_release(release(), "2.0.0")["status"], "current")
        self.assertEqual(update.select_release(release(), "3.0.0")["status"], "current")
        value = release(); value["assets"] = []
        self.assertEqual(update.select_release(value, "1.189.0")["status"], "no-linux-package")
        for field, bad in (("digest", None), ("digest", "sha256:bad"),
                           ("browser_download_url", "https://example.org/evil.tar.gz"),
                           ("size", update.MAX_PACKAGE + 1), ("size", True), ("state", "new")):
            value = release(); value["assets"][0][field] = bad
            with self.subTest(field=field, bad=bad), self.assertRaises(ValueError):
                update.select_release(value, "1.189.0")
        for changes in ({"prerelease": True}, {"draft": True}, {"tag_name": "v../../evil"}):
            value = release(); value.update(changes)
            with self.assertRaises(ValueError): update.select_release(value, "1.189.0")
        value = release(); value["assets"] *= 2
        with self.assertRaises(ValueError): update.select_release(value, "1.189.0")

    def test_https_downgrade_refused(self):
        with self.assertRaises(ValueError):
            update.HTTPSRedirect().redirect_request(None, None, 302, "", {}, "http://example.org/pkg")

    def test_preferences_do_not_override_other_settings(self):
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, XDG_CONFIG_HOME=temporary):
            self.assertTrue(update.preferences()["automatic"])
            update.save_preferences({"automatic": False, "checked_at": 123})
            self.assertEqual(update.preferences(), {"automatic": False, "checked_at": 123})

    def test_disabled_or_recent_automatic_check_never_contacts_network(self):
        for prefs in ({"automatic": False, "checked_at": 0},
                      {"automatic": True, "checked_at": update.time.time()}):
            with patch.object(update, "preferences", return_value=prefs), \
                 patch.object(update, "installed_runtime", return_value=(None, None, "1.189.0")), \
                 patch.object(update, "fetch", side_effect=AssertionError("Unexpected network")), \
                 patch.object(sys, "argv", ["update.py", "check", "--automatic"]):
                self.assertEqual(update.main(), {"status": "skipped"})

    def package(self, root, value):
        runtime = root / ("runtime-" + value)
        runtime.mkdir()
        hashes = {}
        for name in ("bin/fastra", "bin/fastra-control", "bin/fastra-diff", "libexec/fastra-linux",
                     "libexec/fastra-control", "libexec/fastra-diff", "share/licenses/fastra/LICENSE",
                     "libexec/fastra-update/update.py", "libexec/fastra-update/install.py", "libexec/fastra-update/verify.py",
                     "share/icons/hicolor/256x256/apps/fastra.png"):
            file = runtime / name; file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(b"#!/bin/sh\nexit 0\n"); file.chmod(0o755)
            hashes[name] = hashlib.sha256(file.read_bytes()).hexdigest()
        if tuple(map(int, value.split("."))) >= (1, 198, 0):
            for name in ("runtime/LICENSE", "grammar/LICENSE", "runtime/src/unicode/LICENSE", "SOURCES.json"):
                name = "share/licenses/fastra/regex-syntax/" + name
                file = runtime / name; file.parent.mkdir(parents=True, exist_ok=True)
                file.write_text("Synthetic complete-license fixture\n")
                hashes[name] = hashlib.sha256(file.read_bytes()).hexdigest()
        folding_revision = None
        if tuple(map(int, value.split("."))) >= (1, 217, 0):
            source = Path(__file__).resolve().parents[3] / "crates/fastra-core/native/folding"
            catalog = json.loads((source / "catalog.json").read_text())
            folding_revision = catalog["mac_catalog_revision"]
            files = [(source / "catalog.json", "catalog.json")]
            for grammar in catalog["grammars"]:
                files += [(source / grammar["repository"] / name, grammar["repository"] + "/" + name) for name in grammar["license_files"]]
            for original, name in files:
                name = "share/licenses/fastra/folding/" + name
                file = runtime / name; file.parent.mkdir(parents=True, exist_ok=True)
                file.write_bytes(original.read_bytes())
                hashes[name] = hashlib.sha256(file.read_bytes()).hexdigest()
        manifest = {"format": 1, "version": value, "architecture": "x86_64",
                    "source_sha256": hashlib.sha256(value.encode()).hexdigest(), "sha256": hashes, "symlinks": {}}
        if tuple(map(int, value.split("."))) >= (1, 198, 0):
            manifest["regex_syntax_revisions"] = {"runtime": "da6fe9beb4f7f67beb75914ca8e0d48ae48d6406", "grammar": "b2ac15e27fce703d2f37a79ccd94a5c0cbe9720b"}
        if folding_revision is not None: manifest["folding_catalog_revision"] = folding_revision
        (runtime / "manifest.json").write_text(json.dumps(manifest))
        archive = root / f"fastra-{value}-linux-x86_64.tar.gz"
        with tarfile.open(archive, "w:gz") as output: output.add(runtime, arcname="fastra")
        (root / "SHA256SUMS").write_text(hashlib.sha256(archive.read_bytes()).hexdigest() + "  " + archive.name + "\n")
        return archive

    def test_new_syntax_runtime_requires_pins_and_all_license_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.package(root, "2.0.0")
            runtime = root / "runtime-2.0.0"
            verify.runtime(runtime)
            path = runtime / "manifest.json"
            original = json.loads(path.read_text())
            for change in ("pin", "license"):
                value = json.loads(json.dumps(original))
                if change == "pin": value["regex_syntax_revisions"]["grammar"] = "0" * 40
                else: del value["sha256"]["share/licenses/fastra/regex-syntax/runtime/src/unicode/LICENSE"]
                path.write_text(json.dumps(value))
                with self.assertRaises(ValueError): verify.runtime(runtime)

    def test_folding_catalog_requires_complete_original_licenses_and_regular_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.package(root, "2.0.0")
            runtime = root / "runtime-2.0.0"
            verify.runtime(runtime)
            path = runtime / "manifest.json"
            original = json.loads(path.read_text())
            bad = json.loads(json.dumps(original)); bad["folding_catalog_revision"] = "0" * 40
            path.write_text(json.dumps(bad))
            with self.assertRaises(ValueError): verify.runtime(runtime)
            bad = json.loads(json.dumps(original))
            name = next(name for name in bad["sha256"] if name.endswith("folding/tree-sitter-bash/LICENSE"))
            del bad["sha256"][name]
            path.write_text(json.dumps(bad))
            with self.assertRaises(ValueError): verify.runtime(runtime)
            path.write_text(json.dumps(original))
            catalog = runtime / "share/licenses/fastra/folding/catalog.json"
            moved = root / "outside-catalog.json"; catalog.rename(moved); catalog.symlink_to(moved)
            with self.assertRaisesRegex(ValueError, "Invalid folding license catalog file"):
                verify.runtime(runtime)

    def test_real_atomic_install_and_failed_download_preserve_current(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            prefix = root / "prefix with spaces"
            old = self.package(root, "1.189.0")
            subprocess.run([sys.executable, "-B", str(Path(update.__file__).with_name("install.py")),
                            "--prefix", str(prefix), "--package", str(old)], check=True, capture_output=True)
            link = prefix / "share/fastra/current"
            old_runtime = link.resolve()
            new = self.package(root, "2.0.0")
            data = new.read_bytes()
            ticket = update.select_release(release(data=data), "1.189.0")
            opener = unittest.mock.Mock()
            opener.open.return_value = io.BytesIO(b"corrupted")
            with patch.object(update.urllib.request, "build_opener", return_value=opener):
                with self.assertRaises(ValueError): update.install(ticket, old_runtime, prefix, "1.189.0")
            self.assertEqual(link.resolve(), old_runtime)
            opener.open.return_value = io.BytesIO(data)
            with patch.object(update.urllib.request, "build_opener", return_value=opener):
                self.assertEqual(update.install(ticket, old_runtime, prefix, "1.189.0")["status"], "installed")
            self.assertNotEqual(link.resolve(), old_runtime)
            self.assertTrue(old_runtime.is_dir())
            self.assertEqual(json.loads((link / "manifest.json").read_text())["version"], "2.0.0")
            self.assertFalse(list(prefix.rglob("__pycache__")))
            rejected = subprocess.run([sys.executable, "-B", str(Path(update.__file__).with_name("install.py")),
                "--prefix", str(prefix), "--package", str(new), "--expected-current", str(old_runtime),
                "--expected-version", "2.0.0"], capture_output=True)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn(b"Installed version changed", rejected.stderr)

    def test_wrong_package_version_does_not_switch(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = self.package(root, "1.189.0")
            data = archive.read_bytes()
            ticket = update.select_release(release(data=data), "1.188.0")
            opener = unittest.mock.Mock(); opener.open.return_value = io.BytesIO(data)
            with patch.object(update.urllib.request, "build_opener", return_value=opener):
                with self.assertRaisesRegex(ValueError, "identity"):
                    update.install(ticket, root / "old", root / "prefix", "1.188.0")


if __name__ == "__main__": unittest.main()
