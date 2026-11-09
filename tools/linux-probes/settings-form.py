#!/usr/bin/env python3
"""Gruppierte Einstellungen und frischer Wiederherstellungsprozess."""
import json
import os
from pathlib import Path
import subprocess
import sys
assert os.environ.get("FASTRA_ISOLATED_DISPLAY") == "1"
env = os.environ.copy()
root = Path(env["XDG_CONFIG_HOME"])
folder = root / "fastra-editor"
folder.mkdir(mode=0o700, exist_ok=True)
valid = json.dumps({"version": 2, "formats": {"rust": {"tab": 7, "indent": 3, "spaces": False}}, "guide": {"column": 80, "visible": False}})
(root / "valid-profiles.json").write_text(valid)
path = folder / "profiles.json"
path.write_text("corrupt profiles" if env["FASTRA_SETTINGS_FORM_SELFTEST"] == "corrupt" else valid)
path.chmod(0o600)
subprocess.run([sys.argv[1]], env=env, timeout=75, check=True)
env["FASTRA_SETTINGS_FORM_RESTORE"] = "1"
subprocess.run([sys.argv[1]], env=env, timeout=15, check=True)
