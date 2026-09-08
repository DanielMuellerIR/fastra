#!/usr/bin/env python3
"""Aufnahmefehler dürfen keine vorhandenen README-Bilder überschreiben."""
import importlib.util
import os
from pathlib import Path
import subprocess
import signal
import time
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "screenshot", Path(__file__).resolve().parents[1] / "selftest-screenshot.py"
)
screenshot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(screenshot)
PNG = b"\x89PNG\r\n\x1a\nfixture"


class ScreenshotTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="fastra-capture-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.log = self.root / "app.log"
        self.log.write_text("WILDCARDSHOT-WINDOW 42\n")
        self.destination = self.root / "search-wildcards.png"
        self.destination.write_bytes(b"previous image")

    def capture(self):
        screenshot.capture(self.log, "wildcardshot", "de", self.root, os.getpid())

    def test_names_and_quiet_window_capture(self):
        def take_image(arguments, **kwargs):
            self.assertIn("-l42", arguments)
            self.assertIn("-x", arguments)
            Path(arguments[-1]).write_bytes(PNG)
            return subprocess.CompletedProcess(arguments, 0)

        with patch.object(screenshot, "screen_capture_allowed", return_value=True), \
                patch.object(screenshot.time, "sleep"), \
                patch.object(screenshot.subprocess, "run", side_effect=take_image):
            for test, (marker, filename) in screenshot.SHOTS.items():
                for language, suffix in [("de", ""), ("en", ".en")]:
                    with self.subTest(test=test, language=language):
                        self.log.write_text(f"{marker} 42\n")
                        screenshot.capture(self.log, test, language, self.root, os.getpid())
                        self.assertEqual((self.root / f"{filename}{suffix}.png").read_bytes(), PNG)
                        self.assertIn("status=PASS", self.log.read_text())
        self.assertEqual(list(self.root.glob(".fastra-capture-*")), [])

    def test_permission_denial_never_launches_capture(self):
        with patch.object(screenshot, "screen_capture_allowed", return_value=False), \
                patch.object(screenshot.subprocess, "run") as command:
            self.capture()
            command.assert_not_called()
        self.assertIn("status=ENV", self.log.read_text())
        self.assertEqual(self.destination.read_bytes(), b"previous image")

    def test_failed_or_invalid_capture_preserves_previous_image(self):
        for mode in ["exit", "timeout", "invalid"]:
            with self.subTest(mode=mode):
                self.log.write_text("WILDCARDSHOT-WINDOW 42\n")

                def fail(arguments, **kwargs):
                    Path(arguments[-1]).write_bytes(b"incomplete")
                    if mode == "timeout":
                        raise subprocess.TimeoutExpired(arguments, 10)
                    return subprocess.CompletedProcess(arguments, 1 if mode == "exit" else 0)

                with patch.object(screenshot, "screen_capture_allowed", return_value=True), \
                        patch.object(screenshot.time, "sleep"), \
                        patch.object(screenshot.subprocess, "run", side_effect=fail):
                    self.capture()
                self.assertIn("status=ENV", self.log.read_text())
                self.assertEqual(self.destination.read_bytes(), b"previous image")
                self.assertEqual(list(self.root.glob(".fastra-capture-*")), [])

    def test_term_removes_staged_image(self):
        tool = self.root / "capture.py"
        ready = self.root / "ready"
        child_pid = self.root / "child.pid"
        tool.write_text(
            "#!/usr/bin/python3\nimport os,pathlib,sys,time\n"
            "pathlib.Path(sys.argv[-1]).write_bytes(b'partial')\n"
            f"pathlib.Path({str(child_pid)!r}).write_text(str(os.getpid()))\n"
            f"pathlib.Path({str(ready)!r}).touch()\n"
            "time.sleep(30)\n"
        )
        tool.chmod(0o755)
        environment = dict(os.environ, FASTRA_TEST_SCREENCAPTURE=str(tool),
                           FASTRA_TEST_SCREEN_CAPTURE_ALLOWED="1")
        process = subprocess.Popen([
            "/usr/bin/python3", str(Path(screenshot.__file__)), str(self.log),
            "wildcardshot", "de", str(self.root), str(os.getpid())
        ], env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            deadline = time.monotonic() + 3
            while not ready.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(ready.exists(), "Ersatzaufnahme startete nicht")
            process.send_signal(signal.SIGTERM)
            process.wait(timeout=3)
            self.assertEqual(self.destination.read_bytes(), b"previous image")
            self.assertEqual(list(self.root.glob(".fastra-capture-*")), [])
            with self.assertRaises(ProcessLookupError):
                os.kill(int(child_pid.read_text()), 0)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=3)
            # Die Gegenprobe vor dem Fix lässt das bekannte Ersatzkommando
            # zurück. Es gehört eindeutig zu dieser noch vorhandenen Fixture.
            if child_pid.exists():
                pid = int(child_pid.read_text())
                command = subprocess.run(["/bin/ps", "-ww", "-p", str(pid), "-o", "command="],
                                         capture_output=True, text=True, timeout=2)
                if str(tool) in command.stdout:
                    try:
                        os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_missing_window_and_existing_failure_are_not_success(self):
        self.log.write_text("WILDCARDSHOT-WINDOW -1\n")
        with patch.object(screenshot, "WINDOW_TIMEOUT", 0), \
                patch.object(screenshot.subprocess, "run") as command:
            self.capture()
            command.assert_not_called()
        self.assertIn("status=FAIL", self.log.read_text())
        original = "SELFTEST-RESULT v=1 test=wildcardshot status=FAIL\nSELFTEST wildcardshot: FAIL\n"
        self.log.write_text(original)
        self.capture()
        self.assertEqual(self.log.read_text(), original)


if __name__ == "__main__":
    unittest.main()
