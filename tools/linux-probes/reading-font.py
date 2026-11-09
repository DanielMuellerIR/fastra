#!/usr/bin/env python3
"""Native Leseschriftwahl mit privaten Einstellungen und frischem Prozess."""
import os
import json
from pathlib import Path
import subprocess
import sys
assert os.environ.get('FASTRA_ISOLATED_DISPLAY') == '1'
env = os.environ.copy()
mode = env['FASTRA_READING_FONT_SELFTEST']
folder = Path(env['XDG_CONFIG_HOME']) / 'fastra-editor'
folder.mkdir(mode=0o700, exist_ok=True)
path = folder / 'reading-font.json'
if mode in ('corrupt', 'missing'):
    data = 'corrupt reading font' if mode == 'corrupt' else json.dumps({'version': 1, 'face': 'Absent "Font"; color:red; ' + 'W' * 300})
    path.write_text(data)
    path.chmod(0o600)
subprocess.run([sys.argv[1]], env=env, timeout=80, check=True)
if mode in ('corrupt', 'missing'):
    assert path.read_text() == data
else:
    env['FASTRA_READING_FONT_PHASE'] = 'restore'
    subprocess.run([sys.argv[1]], env=env, timeout=20, check=True)
