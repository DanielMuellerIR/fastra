import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


PATCHER = Path(__file__).resolve().parents[2] / "Patches/CodeEditSymbols/portable-resource-bundle.py"
SOURCE = """import SwiftUI

extension Image {
    init(symbol: String) {
        self.init(symbol, bundle: Bundle.module)
    }
}

extension NSImage {
    static func symbol(named: String) -> NSImage? {
        Bundle.module.image(forResource: named)
    }
}
"""


class CodeEditSymbolsPatchTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="fastra-codeedit-symbols-")
        self.addCleanup(temporary.cleanup)
        self.source = Path(temporary.name) / "CodeEditSymbols.swift"

    def run_patcher(self, *arguments):
        return subprocess.run(
            [sys.executable, str(PATCHER), *arguments, str(self.source)],
            capture_output=True, text=True, timeout=5,
        )

    def test_pinned_call_sites_can_be_patched_and_checked(self):
        self.source.write_text(SOURCE)
        applied = self.run_patcher()
        self.assertEqual(applied.returncode, 0, applied.stderr)
        patched = self.source.read_bytes()
        self.assertNotEqual(patched, SOURCE.encode())
        checked = self.run_patcher("--check")
        self.assertEqual(checked.returncode, 0, checked.stderr)
        self.assertEqual(self.source.read_bytes(), patched)

    def test_drift_stops_before_writing(self):
        image_extension = SOURCE[SOURCE.index("extension NSImage"):]
        cases = {
            "removed call": SOURCE.replace("bundle: Bundle.module", "bundle: Bundle.main"),
            "reformatted call": SOURCE.replace("Bundle.module.image", "Bundle\n            .module.image"),
            "duplicate call": SOURCE + image_extension.replace("func symbol(", "func otherSymbol("),
        }
        for name, source in cases.items():
            with self.subTest(name=name):
                self.source.write_text(source)
                rejected = self.run_patcher()
                self.assertNotEqual(rejected.returncode, 0)
                self.assertTrue(rejected.stderr.startswith("CodeEditSymbols:"), rejected.stderr)
                self.assertEqual(self.source.read_bytes(), source.encode())

    def test_existing_marker_does_not_hide_a_stale_call(self):
        self.source.write_text(SOURCE)
        applied = self.run_patcher()
        self.assertEqual(applied.returncode, 0, applied.stderr)
        patched = self.source.read_text()
        actual_call = "fastraCodeEditSymbolsBundle.image(forResource: named)"
        split_call = "Bundle\n            .module.image(forResource: named)"
        extra_call = f"extension NSImage {{ static func extra(named: String) -> NSImage? {{ {split_call} }} }}\n"
        for name, changed in {
            "direct": patched.replace(actual_call, "Bundle.module.image(forResource: named)"),
            "split": patched.replace(actual_call, split_call),
            "additional": patched + extra_call,
        }.items():
            with self.subTest(name=name):
                self.source.write_text(changed)
                rejected = self.run_patcher("--check")
                self.assertNotEqual(rejected.returncode, 0)
                self.assertTrue(rejected.stderr.startswith("CodeEditSymbols:"), rejected.stderr)
                self.assertEqual(self.source.read_bytes(), changed.encode())
