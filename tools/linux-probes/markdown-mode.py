#!/usr/bin/env python3
"""Markdown-Standard und erster Modusdialog mit privaten XDG-Pfaden."""
import json
import os
from pathlib import Path
import subprocess
import sys
assert os.environ.get('FASTRA_ISOLATED_DISPLAY') == '1'
env=os.environ.copy()
mode=env['FASTRA_MARKDOWN_MODE_SELFTEST']
folder=Path(env['XDG_CONFIG_HOME'])/'fastra-editor'
folder.mkdir(mode=0o700,exist_ok=True)
path=folder/'markdown-mode.json'
if not mode.startswith('choice'):
    path.write_text('corrupt mode' if mode=='corrupt' else json.dumps({'version':1,'visual':False}))
    path.chmod(0o600)
subprocess.run([sys.argv[1]],env=env,timeout=90,check=True)
if mode=='corrupt':
    assert (Path(env['FASTRA_UI_TEST_ROOT'])/'mode-corrupt-preserved').read_text()=='corrupt mode'
if mode=='choice-quit':
    assert not path.exists()
    print('FASTRA_TOOL_SELFTEST_OK markdown-mode first-choice normal Quit, no default written')
    sys.exit(0)
expected='visual' in mode
env['FASTRA_MARKDOWN_MODE_EXPECT']='true' if expected else 'false'
env['FASTRA_MARKDOWN_MODE_PHASE']='restore'
subprocess.run([sys.argv[1]],env=env,timeout=25,check=True)
