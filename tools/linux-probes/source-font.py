#!/usr/bin/env python3
"""Native Quellschriftwahl und frischer Prozess mit privaten XDG-Pfaden."""
import json
import os
from pathlib import Path
import subprocess
import sys

assert os.environ.get("FASTRA_ISOLATED_DISPLAY") == "1"
app = sys.argv[1]
env = os.environ.copy()
if env["FASTRA_SOURCE_FONT_SELFTEST"] == "missing":
    directory = Path(env["XDG_CONFIG_HOME"]) / "fastra-editor"
    directory.mkdir(mode=0o700, exist_ok=True)
    path = directory / "source-font.json"
    path.write_text(json.dumps({"version": 1, "face": 'Absent "Font"; color: red; ' + 'W' * 400}))
    path.chmod(0o600)
subprocess.run([app], env=env, timeout=50, check=True)
if env["FASTRA_SOURCE_FONT_SELFTEST"] != "missing":
    env["FASTRA_SOURCE_FONT_PHASE"] = "restore"
    subprocess.run([app], env=env, timeout=50, check=True)
