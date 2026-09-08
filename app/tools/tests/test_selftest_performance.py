#!/usr/bin/env python3
"""Regressionen für die Aussagekraft der lokalen Performance-Baseline."""

import contextlib
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "performance", Path(__file__).resolve().parents[1] / "selftest-performance.py"
)
performance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(performance)


class PerformanceStatusTests(unittest.TestCase):
    def test_history_failures_never_count_as_zero_changes(self):
        def result(status=0, output=""):
            return subprocess.CompletedProcess([], status, stdout=output)

        data = {"long": {"fixture": [{"finished_at": performance.utc_now(), "head": "baseline"}]}}
        cases = [
            ("zero", result(), result(output="0\n"), ""),
            ("below-limit", result(), result(output="19\n"), ""),
            ("at-limit", result(), result(output="20\n"), "20 relevante Änderungen"),
            ("other-history", result(1), None, "gehört nicht zur aktuellen Historie"),
            ("ancestor-error", result(128), None, "Historie konnte nicht geprüft werden"),
            ("ancestor-unavailable", None, None, "Historie konnte nicht geprüft werden"),
            ("count-error", result(), result(128), "Änderungsabstand konnte nicht bestimmt werden"),
            ("count-unavailable", result(), None, "Änderungsabstand konnte nicht bestimmt werden"),
            ("count-malformed", result(), result(output="oops"), "Änderungsabstand konnte nicht bestimmt werden"),
            ("count-negative", result(), result(output="-1"), "Änderungsabstand konnte nicht bestimmt werden"),
        ]
        for label, ancestor, count, expected in cases:
            with self.subTest(label=label), patch.object(
                performance, "git_result", side_effect=[ancestor, count]
            ), contextlib.redirect_stdout(io.StringIO()) as output:
                performance.report_long_status(data, "unused-fixture-repository")
                if expected:
                    self.assertIn("PERFORMANCE-WARN", output.getvalue())
                    self.assertIn(expected, output.getvalue())
                else:
                    self.assertEqual(output.getvalue(), "")

    def test_timeout_ends_the_started_command(self):
        with tempfile.TemporaryDirectory(prefix="fastra-performance-timeout-") as directory:
            pid_file = Path(directory) / "child.pid"
            with patch.object(performance, "COMMAND_TIMEOUT_SECONDS", 0.2, create=True):
                started = time.monotonic()
                # exec hält dieselbe PID. So prüft die Gegenprobe das echte
                # Aufräumen des von subprocess gestarteten Kommandos.
                output = performance.run_text([
                    "/bin/sh", "-c", 'printf "%s\\n" "$$" > "$1"; exec /bin/sleep 30',
                    "timeout-fixture", str(pid_file),
                ])
            self.assertEqual(output, "")
            self.assertLess(time.monotonic() - started, 2)
            pid = int(pid_file.read_text())
            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)

    def test_helpers_preserve_failure_contract(self):
        failed = subprocess.CompletedProcess([], 17, stdout="partial output")
        for failure in [OSError("fixture start failed"), subprocess.TimeoutExpired("fixture", 5)]:
            with self.subTest(failure=type(failure).__name__), patch.object(
                performance.subprocess, "run", side_effect=failure
            ):
                self.assertEqual(performance.run_text(["fixture"]), "")
                self.assertIsNone(performance.git_result("fixture", ["status"]))
        with patch.object(performance.subprocess, "run", return_value=failed):
            self.assertEqual(performance.run_text(["fixture"]), "")
            self.assertIs(performance.git_result("fixture", ["status"]), failed)


if __name__ == "__main__":
    unittest.main()
