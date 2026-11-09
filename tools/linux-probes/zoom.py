#!/usr/bin/env python3
"""Globale Größen nativ wählen und im frischen Prozess wiederherstellen."""
import os
from pathlib import Path
import subprocess
import sys
assert os.environ.get("FASTRA_ISOLATED_DISPLAY") == "1"
app = sys.argv[1]
env = os.environ.copy()
if env.get("FASTRA_ZOOM_KEYMAP") == "de":
    subprocess.run(["setxkbmap", "de"], check=True)
if env["FASTRA_ZOOM_SELFTEST"] == "corrupt":
    directory = Path(env["XDG_CONFIG_HOME"]) / "fastra-editor"
    directory.mkdir(mode=0o700, exist_ok=True)
    (directory / "zoom.json").write_text("corrupt preference")
    (directory / "zoom.json").chmod(0o600)
subprocess.run([app], env=env, timeout=55, check=True)
if env["FASTRA_ZOOM_SELFTEST"] != "corrupt":
    env["FASTRA_ZOOM_PHASE"] = "restore"
    subprocess.run([app], env=env, timeout=55, check=True)
