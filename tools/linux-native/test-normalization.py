#!/usr/bin/env python3
"""Kleine Gegenproben gegen Linkausbruch, Sonderdateien und Privilegienbits."""
import importlib.util
import json
import os
import stat
import tempfile
import unittest
import subprocess
import sys
import tarfile
from pathlib import Path
from common import digest, virtual, inventory
from normalize import normalize
from elf_paths import relocate
from stage import archive


class NormalizationTests(unittest.TestCase):
    def test_virtual_root_does_not_follow_host_absolute_or_parent_escape(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            root = base / "root"
            (root / "usr/lib").mkdir(parents=True)
            secret = base / "secret"
            secret.write_text("outside")
            (root / "usr/lib/absolute").symlink_to(secret)
            with self.assertRaises(FileNotFoundError):
                virtual(root, "usr/lib/absolute")
            (root / "usr/lib/escape").symlink_to("../../../secret")
            with self.assertRaises(ValueError):
                virtual(root, "usr/lib/escape")
            (root / "usr/lib/loop").symlink_to("loop")
            with self.assertRaises(ValueError):
                virtual(root, "usr/lib/loop")
            self.assertEqual(secret.read_text(), "outside")

    def fixture(self, base):
        raw = base / "raw"
        (raw / "usr/bin").mkdir(parents=True)
        (raw / "etc").mkdir()
        (raw / "usr/share/doc/example").mkdir(parents=True)
        (raw / "usr/bin/tool").write_text("tool")
        (raw / "usr/bin/tool").chmod(0o6755)
        (raw / "etc/data").write_text("inside")
        (raw / "usr/bin/link").symlink_to("/etc/data")
        (raw / "usr/share/doc/example/old").symlink_to("missing")
        (raw / "manifest.json").write_text(
            json.dumps(
                {
                    "sha256": {
                        "usr/bin/tool": digest(raw / "usr/bin/tool"),
                        "etc/data": digest(raw / "etc/data"),
                    },
                    "symlinks": {
                        "usr/bin/link": "/etc/data",
                        "usr/share/doc/example/old": "missing",
                    },
                    "packages": {"example": "1"},
                    "image": "sha256:fixture",
                    "gtk_source": {},
                }
            )
        )
        copyrights = base / "copyrights"
        (copyrights / "example").mkdir(parents=True)
        (copyrights / "example/copyright").write_text("complete fixture copyright")
        (copyrights / "packages.json").write_text(
            json.dumps(
                {
                    "example": {
                        "version": "1",
                        "copyright_sha256": digest(copyrights / "example/copyright"),
                    }
                }
            )
        )
        pango = base / "pango"
        (pango / "lib").mkdir(parents=True)
        for component in ["pango", "pangocairo", "pangoft2"]:
            (pango / "lib" / f"lib{component}-1.0.so.0.5200.1").write_text(
                "fixture only"
            )
        lock = base / "lock.json"
        lock.write_text(
            json.dumps(
                {
                    "version": "1.52.1+ds-1build1",
                    "ubuntu_patches": {"a": "a", "b": "b", "c": "c"},
                    "own_patches": {},
                }
            )
        )
        (pango / "SOURCE-BUILD.json").write_text(
            json.dumps(
                {
                    "source_lock_sha256": digest(lock),
                    "own_patches": {},
                    "libraries": {p.name: digest(p) for p in (pango / "lib").iterdir()},
                }
            )
        )
        (pango / "builder-packages.tsv").write_text("fixture only")
        return raw, copyrights, pango, lock

    def test_absolute_internal_link_relocated_privilege_bits_removed_alias_recorded(
        self,
    ):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            raw, copyrights, pango, lock = self.fixture(base)
            out = base / "runtime with spaces"
            m = normalize(raw, copyrights, pango, lock, out)
            self.assertEqual((out / "usr/bin/link").read_text(), "inside")
            self.assertFalse(os.readlink(out / "usr/bin/link").startswith("/"))
            self.assertEqual(stat.S_IMODE((out / "usr/bin/tool").stat().st_mode), 0o755)
            self.assertEqual(len(m["stripped_modes"]), 1)
            self.assertEqual(len(m["omitted_dangling_links"]), 1)
            self.assertEqual((raw / "usr/bin/tool").stat().st_mode & 0o6000, 0o6000)
            moved = base / "moved elsewhere"
            out.rename(moved)
            self.assertEqual((moved / "usr/bin/link").read_text(), "inside")
            inventory(moved)

    def test_special_files_and_unclassified_dangling_links_are_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            raw, copyrights, pango, lock = self.fixture(base)
            os.mkfifo(raw / "fifo")
            with self.assertRaises(ValueError):
                normalize(raw, copyrights, pango, lock, base / "bad")
            (raw / "fifo").unlink()
            (raw / "usr/bin/unclassified").symlink_to("missing")
            m = json.loads((raw / "manifest.json").read_text())
            m["symlinks"]["usr/bin/unclassified"] = "missing"
            (raw / "manifest.json").write_text(json.dumps(m))
            with self.assertRaises(ValueError):
                normalize(raw, copyrights, pango, lock, base / "bad")
            self.assertFalse((base / "bad").exists())
            self.assertFalse((base / "bad.partial").exists())


@unittest.skipUnless(
    sys.platform == "linux" and os.environ.get("NATIVE_PATCHELF"),
    "private Linux patchelf fixture required",
)
class ElfPathTests(unittest.TestCase):
    def test_real_dependency_load_after_origin_rewrite_and_move(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            root = base / "runtime"
            dependencies = root / "usr/lib/x86_64-linux-gnu"
            libraries = root / "usr/lib/custom"
            dependencies.mkdir(parents=True)
            libraries.mkdir(parents=True)
            (base / "dep.c").write_text("int dependency_marker(void) { return 7; }\n")
            (base / "probe.c").write_text(
                "extern int dependency_marker(void); int probe_marker(void) { return dependency_marker(); }\n"
            )
            subprocess.run(
                [
                    "cc",
                    "-shared",
                    "-fPIC",
                    str(base / "dep.c"),
                    "-o",
                    str(dependencies / "libfastra_relocation_fixture.so"),
                ],
                check=True,
            )
            probe = libraries / "libprobe.so"
            subprocess.run(
                [
                    "cc",
                    "-shared",
                    "-fPIC",
                    str(base / "probe.c"),
                    "-L" + str(dependencies),
                    "-lfastra_relocation_fixture",
                    "-Wl,-rpath,/usr/lib/x86_64-linux-gnu",
                    "-o",
                    str(probe),
                ],
                check=True,
            )
            load = lambda file: subprocess.run(
                [
                    sys.executable,
                    "-c",
                    "import ctypes,sys;assert ctypes.CDLL(sys.argv[1]).probe_marker()==7",
                    str(file),
                ],
                capture_output=True,
            )
            self.assertNotEqual(load(probe).returncode, 0)
            result = relocate(root, Path(os.environ["NATIVE_PATCHELF"]))
            self.assertEqual(len(result["transforms"]), 1)
            self.assertEqual(load(probe).returncode, 0)
            moved = base / "moved runtime with spaces"
            root.rename(moved)
            self.assertEqual(load(moved / "usr/lib/custom/libprobe.so").returncode, 0)

    def test_unknown_external_searchpath_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "runtime"
            root.mkdir()
            source = Path(temp) / "bad.c"
            source.write_text("int marker(void) { return 1; }\n")
            subprocess.run(
                [
                    "cc",
                    "-shared",
                    "-fPIC",
                    str(source),
                    "-Wl,-rpath,/outside-not-in-runtime",
                    "-o",
                    str(root / "libbad.so"),
                ],
                check=True,
            )
            with self.assertRaises(FileNotFoundError):
                relocate(root, Path(os.environ["NATIVE_PATCHELF"]))


class ArchiveTests(unittest.TestCase):
    def test_portable_archive_checksums_and_existing_outputs_are_preserved(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            root = base / "candidate package"
            (root / "nested").mkdir(parents=True)
            payload = root / "nested/文書.txt"
            payload.write_text("café 🙂\n")
            (root / "alias").symlink_to("nested/文書.txt")
            target = base / "candidate.tar.gz"
            archive(root, target, 1793955600)
            self.assertEqual(
                (base / "candidate.tar.gz.sha256").read_text(),
                digest(target) + "  candidate.tar.gz\n",
            )
            before = target.read_bytes()
            with self.assertRaises(ValueError):
                archive(root, target, 1793955600)
            self.assertEqual(target.read_bytes(), before)
            moved = base / "unpacked elsewhere"
            moved.mkdir()
            with tarfile.open(target) as tar:
                self.assertTrue(
                    all(
                        entry.uid == 0 and entry.gid == 0 and entry.mtime == 1793955600
                        for entry in tar.getmembers()
                    )
                )
                tar.extractall(moved, filter="data")
            self.assertEqual((moved / root.name / "alias").read_text(), "café 🙂\n")
            self.assertFalse((base / "candidate.tar.gz.partial").exists())


if __name__ == "__main__":
    unittest.main()
