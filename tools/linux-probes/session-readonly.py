#!/usr/bin/env python3
"""Isolierter Sitzungsabbruch und Neustart mit aktuellen schreibgeschützten Quellen."""
import os
from pathlib import Path
import signal
import subprocess
import sys

assert os.environ.get("FASTRA_ISOLATED_DISPLAY") == "1"
root = Path(os.environ["FASTRA_SESSION_FIXTURE"])
assert root.is_absolute() and root.is_dir()
app = sys.argv[1]
env = os.environ.copy()
env["FASTRA_SESSION_READONLY_PHASE"] = "capture"
producer = subprocess.run([app], env=env, timeout=50)
assert producer.returncode == -signal.SIGKILL, producer.returncode
# Der ursprüngliche Grund für die reine Lesegrundlage entfällt vor dem Neustart.
(root / "reader-one-alias.md").unlink()
(root / "reader-one.md").write_bytes(b"\xff\xfe" + "# Current disk reader\r\n".encode("utf-16-le"))
if env["FASTRA_SESSION_SELFTEST"] == "readonly-missing":
    (root / "reader-two.md").unlink()
env["FASTRA_SESSION_READONLY_PHASE"] = "restore"
subprocess.run([app], env=env, timeout=50, check=True)
