#!/usr/bin/env python3
"""Native Erscheinungsbildwahl und Wiederherstellung im frischen Prozess."""
import os
from pathlib import Path
import subprocess
import sys
assert os.environ.get("FASTRA_ISOLATED_DISPLAY") == "1"
env = os.environ.copy()
if env["FASTRA_APPEARANCE_SELFTEST"] == "corrupt":
    folder = Path(env["XDG_CONFIG_HOME"]) / "fastra-editor"
    folder.mkdir(mode=0o700, exist_ok=True)
    path = folder / "appearance.json"
    path.write_text("corrupt appearance")
    path.chmod(0o600)
subprocess.run([sys.argv[1]], env=env, timeout=75, check=True)
if env["FASTRA_APPEARANCE_SELFTEST"] != "corrupt":
    env["FASTRA_APPEARANCE_PHASE"] = "restore"
    subprocess.run([sys.argv[1]], env=env, timeout=15, check=True)
