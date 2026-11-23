"""CLI-Vertrag mit echtem SwiftLint; Mocks nur für Tool-/Reporterfehler."""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

APP = Path(__file__).resolve().parents[2]
SCRIPT = APP / "swift-lint.py"
TOOL = os.environ.get("SWIFTLINT_BIN") or shutil.which("swiftlint")


class SwiftLintGateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not TOOL:
            raise RuntimeError("Echtes SwiftLint erforderlich: SWIFTLINT_BIN setzen")

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="fastra-lint-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / "app"
        self.sources = self.app / "Sources"
        (self.sources / "SmallTarget").mkdir(parents=True)
        shutil.copyfile(APP / "swift-lint-configuration.json", self.app / "swift-lint-configuration.json")
        self.source = self.sources / "SmallTarget/Example.swift"
        self.source.write_text("let old = try! operation()\n")
        self.baseline = self.app / "swift-lint-baseline.json"
        self.baseline.write_text(self.invoke("--export", success=True).stdout)

    def invoke(self, *args, success=False, tool=TOOL, cwd=None):
        result = subprocess.run([sys.executable, str(SCRIPT), "--root", str(self.root), *args],
                                cwd=cwd, env={**os.environ, "SWIFTLINT_BIN": str(tool)},
                                capture_output=True, text=True, timeout=30)
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertNotIn("Gate bestanden", result.stdout)
        return result

    def baseline_change(self, change):
        data = json.loads(self.baseline.read_text())
        change(data)
        self.baseline.write_text(json.dumps(data))

    def mock_tool(self, output="[]", code=0, version="0.65.1", stderr=""):
        # Fehler lassen sich nicht zuverlässig mit der echten CLI erzeugen.
        path = self.root / "mock-swiftlint"
        path.write_text(f"#!{sys.executable}\nimport sys\n"
                        f"if sys.argv[1:] == ['version']:\n print({version!r})\n sys.exit(0)\n"
                        f"print({output!r})\nprint({stderr!r}, file=sys.stderr, end='')\nsys.exit({code})\n")
        path.chmod(0o700)
        return path

    def test_known_debt_and_source_bytes_unchanged(self):
        before = {p: p.read_bytes() for p in self.sources.rglob("*.swift")}
        baseline = self.baseline.read_bytes()
        self.invoke(success=True, cwd="/")
        self.assertEqual(before, {p: p.read_bytes() for p in before})
        self.assertEqual(baseline, self.baseline.read_bytes())

    def test_new_violation(self):
        self.source.write_text(self.source.read_text() + "let extra = try! operation()\n")
        self.assertIn("NEU", self.invoke().stderr)

    def test_same_count_and_position_changed_source(self):
        self.source.write_text("let new = try! alternate()\n")
        result = self.invoke()
        self.assertIn("NEU", result.stderr)
        self.assertIn("VERALTET", result.stderr)

    def test_removal_requires_baseline_review(self):
        self.source.write_text("let old = try? operation()\n")
        self.assertIn("VERALTET", self.invoke().stderr)
        self.baseline_change(lambda d: d.update(diagnostics=[]))
        self.invoke(success=True)

    def test_new_untracked_file_in_other_target(self):
        target = self.sources / "SelfTest"
        target.mkdir()
        (target / "New.swift").write_text("let new = try! operation()\n")
        self.assertIn("SelfTest/New.swift", self.invoke().stderr)

    def test_all_three_rules_and_spacing(self):
        self.source.write_text("let cast = value as! Int\nlet tried = try! operation()\nlet unwrap = optional!\n")
        data = json.loads(self.invoke("--export", success=True).stdout)
        self.assertEqual({d["rule"] for d in data["diagnostics"]},
                         {"force_cast", "force_try", "force_unwrapping"})
        self.source.write_text("let   number=1\n")
        data = json.loads(self.invoke("--export", success=True).stdout)
        self.assertEqual(data["diagnostics"], [])

    def test_lint_does_not_validate_swift_syntax(self):
        self.source.write_text("func broken( {\n")
        data = json.loads(self.invoke("--export", success=True).stdout)
        self.assertEqual(data["diagnostics"], [])

    def test_line_hash_includes_complete_line_bytes(self):
        data = json.loads(self.baseline.read_text())
        self.assertEqual(data["diagnostics"][0]["line_sha256"],
                         hashlib.sha256(self.source.read_bytes()).hexdigest())
        self.source.write_bytes(self.source.read_bytes().replace(b"\n", b"\r\n"))
        self.invoke()

    def test_multiset_rejects_duplicate_baseline_entry(self):
        self.baseline_change(lambda d: d["diagnostics"].append(d["diagnostics"][0]))
        self.assertIn("VERALTET", self.invoke().stderr)

    def test_missing_and_empty_sources(self):
        self.source.unlink()
        self.invoke()
        shutil.rmtree(self.sources)
        self.invoke()

    def test_symlinks_and_fifo_are_rejected_before_read(self):
        original = self.source.read_bytes()
        for kind in ("file-link", "directory-link", "fifo"):
            with self.subTest(kind=kind):
                self.source.unlink()
                if kind == "file-link":
                    self.source.symlink_to(self.baseline)
                elif kind == "directory-link":
                    self.source.symlink_to(self.app, target_is_directory=True)
                else:
                    os.mkfifo(self.source)
                self.invoke()
                self.source.unlink()
                self.source.write_bytes(original)

    def test_directory_with_swift_suffix_is_not_a_source_file(self):
        (self.sources / "NotAFile.swift").mkdir()
        self.invoke()

    def test_unreadable_source_and_directory(self):
        for path in (self.source, self.source.parent):
            mode = path.stat().st_mode
            try:
                path.chmod(0)
                self.invoke()
            finally:
                path.chmod(mode)

    def test_invalid_baseline_fields(self):
        original = self.baseline.read_bytes()
        mutations = [lambda d: d.update(schema=True), lambda d: d.update(tool_version="0"),
                     lambda d: d.update(configuration_sha256="0" * 64),
                     lambda d: d["diagnostics"][0].update(line=True),
                     lambda d: d["diagnostics"][0].update(character=0),
                     lambda d: d["diagnostics"][0].update(file="app/Sources/../Other.swift"),
                     lambda d: d["diagnostics"][0].update(reason=""),
                     lambda d: d["diagnostics"][0].update(line_sha256="bad")]
        for mutation in mutations:
            self.baseline.write_bytes(original)
            self.baseline_change(mutation)
            self.invoke()
        self.baseline.write_text("{broken")
        self.invoke()
        self.baseline.unlink()
        self.invoke()

    def test_new_suppression_and_reviewed_controlled_source(self):
        clean_baseline = self.baseline.read_bytes()
        hidden = self.sources / "Suppressed.swift"
        content = "// swiftlint:disable force_try\nlet bad = try! operation()\n"
        hidden.write_text(content)
        self.assertIn("Steuerquellen weichen ab", self.invoke().stderr)
        exported = self.invoke("--export", success=True).stdout
        data = json.loads(exported)
        self.assertEqual(data["controlled_sources"], {
            "app/Sources/Suppressed.swift": hashlib.sha256(hidden.read_bytes()).hexdigest()})
        self.assertEqual(data["diagnostics"], json.loads(clean_baseline)["diagnostics"])
        self.baseline.write_text(exported)
        self.invoke(success=True)
        hidden.write_text(content + "let extra = try! alternate()\n")
        changed = json.loads(self.invoke("--export", success=True).stdout)
        self.assertEqual(changed["diagnostics"], data["diagnostics"])
        self.assertIn("Steuerquellen weichen ab", self.invoke().stderr)
        hidden.write_text(content)
        self.invoke(success=True)
        hidden.unlink()
        self.baseline.write_bytes(clean_baseline)
        self.invoke(success=True)

    def test_marker_literal_in_string_is_conservatively_controlled(self):
        literal = self.sources / "Example.swift"
        literal.write_text('let example = "SWIFTLINT : disable force_try"\n')
        self.assertIn("Steuerquellen weichen ab", self.invoke().stderr)
        exported = self.invoke("--export", success=True).stdout
        data = json.loads(exported)
        self.assertIn("app/Sources/Example.swift", data["controlled_sources"])
        self.baseline.write_text(exported)
        self.invoke(success=True)
        literal.write_text(literal.read_text() + "let ordinary = 1\n")
        self.assertIn("Steuerquellen weichen ab", self.invoke().stderr)

    def test_invalid_controlled_source_map(self):
        original = self.baseline.read_bytes()
        for controls in (True, [], 1, "", {"../bad.swift": "0" * 64},
                         {"app/Sources/absent.swift": "0" * 64},
                         {"app/Sources/SmallTarget/Example.swift": True},
                         {"app/Sources/SmallTarget/Example.swift": 1},
                         {"app/Sources/SmallTarget/Example.swift": "A" * 64},
                         {"app/Sources/SmallTarget/Example.swift": "bad"}):
            with self.subTest(controls=controls):
                self.baseline.write_bytes(original)
                self.baseline_change(lambda d: d.update(controlled_sources=controls))
                self.invoke()
        self.baseline.write_bytes(original)
        self.baseline_change(lambda d: d.pop("controlled_sources"))
        self.invoke()

    def test_invalid_configuration(self):
        config = self.app / "swift-lint-configuration.json"
        for content in ('{broken', '{"only_rules": []}',
                        '{"only_rules": [], "only_rules": []}',
                        '{"only_rules": ["force_try"], "excluded": ["Sources"]}'):
            config.write_text(content)
            self.invoke()
        config.unlink()
        self.invoke()

    def test_tool_failure_and_version_mismatch(self):
        self.invoke(tool=self.mock_tool(version="0.65.0"))
        self.invoke(tool=self.mock_tool(code=1))
        self.invoke(tool=self.mock_tool(stderr="scan failed"))
        self.invoke(tool=self.root / "missing-swiftlint")

    def test_malformed_reporter_and_status(self):
        for output, code in (("not json", 0), ("{}", 0), ('[{"file":"x"}]', 2), ("[]", 2)):
            self.invoke(tool=self.mock_tool(output=output, code=code))

    def test_source_change_during_tool_run_mock(self):
        self.source.write_text("let value = 1\n")
        self.baseline.write_text(self.invoke("--export", success=True).stdout)
        tool = self.mock_tool()
        tool.write_text(tool.read_text().replace("print('[]')",
                        f"from pathlib import Path; Path({str(self.source)!r}).write_text('let changed = 2\\n'); print('[]')"))
        self.assertIn("während des Scans geändert", self.invoke(tool=tool).stderr)

    def test_relative_reporter_path_normalization_mock(self):
        entry = json.loads(self.baseline.read_text())["diagnostics"][0]
        raw = {key: entry[key] for key in ("file", "line", "character", "reason")}
        raw.update(rule_id=entry["rule"], severity="Error", type="Force Try")
        self.invoke(tool=self.mock_tool(output=json.dumps([raw]), code=2), success=True)
        raw["file"] = "../outside.swift"
        self.invoke(tool=self.mock_tool(output=json.dumps([raw]), code=2))


if __name__ == "__main__":
    unittest.main()
