#!/usr/bin/env python3
"""Appweite Markdown-Vorschau in isolierten Prozessen und XDG-Pfaden."""
import os
from pathlib import Path
import subprocess
import sys
assert os.environ.get('FASTRA_ISOLATED_DISPLAY') == '1'
env = os.environ.copy()
folder = Path(env['XDG_CONFIG_HOME']) / 'fastra-editor'
folder.mkdir(mode=0o700, exist_ok=True)
path = folder / 'markdown-preview.json'
if env['FASTRA_MARKDOWN_PREVIEW_SELFTEST'] == 'corrupt':
    path.write_text('corrupt preview preference')
    path.chmod(0o600)
subprocess.run([sys.argv[1]], env=env, timeout=90, check=True)
if env['FASTRA_MARKDOWN_PREVIEW_SELFTEST'] == 'corrupt':
    assert (Path(env['FASTRA_UI_TEST_ROOT']) / 'corrupt-preserved').read_text() == 'corrupt preview preference'
env['FASTRA_MARKDOWN_PREVIEW_PHASE'] = 'restore'
subprocess.run([sys.argv[1]], env=env, timeout=25, check=True)
