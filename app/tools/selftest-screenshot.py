#!/usr/bin/env python3
"""Fensteraufnahme innerhalb des bestehenden Selbsttest-Runners."""

import argparse
import ctypes
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile
import time

SHOTS = {
    "projectshot": ("PROJECTSHOT-WINDOW", "editor-light"),
    "wildcardshot": ("WILDCARDSHOT-WINDOW", "search-wildcards"),
    "regexshot": ("REGEXSHOT-WINDOW", "search-regex"),
    "gitshot": ("GITSHOT-WINDOW", "git-changes"),
    "graphshot": ("GRAPHSHOT-WINDOW", "git-graph"),
    "historyshot": ("HISTORYSHOT-WINDOW", "git-history"),
}
WINDOW_TIMEOUT = 15
CAPTURE_TIMEOUT = 10


def screen_capture_allowed():
    # Nur Ersatzprogramme der Runner-Tests umgehen die echte macOS-Abfrage.
    if os.environ.get("FASTRA_TEST_SCREENCAPTURE"):
        return os.environ.get("FASTRA_TEST_SCREEN_CAPTURE_ALLOWED") == "1"
    framework = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
    preflight = framework.CGPreflightScreenCaptureAccess
    preflight.restype = ctypes.c_bool
    preflight.argtypes = []
    return preflight()


def capture(log, test, language, directory, app_pid):
    marker, filename = SHOTS[test]

    def finish(status, detail):
        with log.open("a", encoding="utf-8") as handle:
            handle.write(f"SELFTEST-RESULT v=1 test={test} status={status}\n"
                         f"SELFTEST {test}: {status} — {detail}\n")

    deadline = time.monotonic() + WINDOW_TIMEOUT
    window_id = None
    while time.monotonic() < deadline:
        output = log.read_text(encoding="utf-8", errors="replace")
        # Eine echte Fehlerausgabe der App bleibt maßgeblich.
        if re.search(r"^SELFTEST(?:-RESULT)? ", output, re.MULTILINE):
            return
        match = re.search(rf"^{marker} ([1-9][0-9]*)$", output, re.MULTILINE)
        if match:
            window_id = match.group(1)
            break
        try:
            os.kill(app_pid, 0)
        except ProcessLookupError:
            finish("FAIL", "Screenshot-App endete vor der Fensterbereitschaft")
            return
        time.sleep(0.05)
    if window_id is None:
        finish("FAIL", "Screenshot-Fenster wurde nicht rechtzeitig bereit")
        return
    try:
        if not screen_capture_allowed():
            finish("ENV", "Bildschirmaufnahme ist nicht freigegeben")
            return
        # Die bestehende Renderpause bleibt für echte Aufnahmen erhalten.
        if not os.environ.get("FASTRA_TEST_SCREENCAPTURE"):
            time.sleep(1)
        directory.mkdir(parents=True, exist_ok=True)
        suffix = ".en" if language == "en" else ""
        destination = directory / f"{filename}{suffix}.png"
        # Ein Aufnahmefehler darf eine vorhandene README-Datei nicht ersetzen.
        with tempfile.TemporaryDirectory(prefix=".fastra-capture-", dir=directory) as temporary:
            image = Path(temporary) / "capture.png"
            command = os.environ.get("FASTRA_TEST_SCREENCAPTURE", "/usr/sbin/screencapture")
            result = subprocess.run(
                [command, f"-l{window_id}", "-o", "-x", "-t", "png", str(image)],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                timeout=CAPTURE_TIMEOUT,
            )
            if result.returncode != 0 or not image.is_file():
                finish("ENV", "Fensteraufnahme fehlgeschlagen")
                return
            with image.open("rb") as handle:
                if handle.read(8) != b"\x89PNG\r\n\x1a\n":
                    finish("ENV", "Aufnahme lieferte keine PNG-Datei")
                    return
            os.replace(image, destination)
        finish("PASS", f"Screenshot {destination.name} gespeichert")
    except (OSError, subprocess.TimeoutExpired):
        finish("ENV", "Fensteraufnahme oder Speichern fehlgeschlagen")


def terminate(signum, _frame):
    # SystemExit durchläuft die Kontextmanager: subprocess.run beendet sein
    # Kind, und TemporaryDirectory entfernt die noch unveröffentlichte Aufnahme.
    raise SystemExit(128 + signum)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, terminate)
    parser = argparse.ArgumentParser()
    parser.add_argument("log", type=Path)
    parser.add_argument("test", choices=SHOTS)
    parser.add_argument("language", choices=("de", "en"))
    parser.add_argument("directory", type=Path)
    parser.add_argument("app_pid", type=int)
    args = parser.parse_args()
    if args.app_pid <= 0:
        parser.error("App-PID muss positiv sein")
    capture(args.log, args.test, args.language, args.directory, args.app_pid)
