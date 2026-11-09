#!/usr/bin/env python3
import json,pathlib,subprocess,sys,time
root=pathlib.Path(sys.argv[1]);state=root/'native-state.json'
if state.exists():
    saved=json.loads(state.read_text());pid=saved.get('pid')
    if pid:
        p=subprocess.run(['ps','-p',str(pid),'-o','comm='],capture_output=True,text=True)
        if p.returncode==0:
            if p.stdout.strip()!="/Applications/Poor Man's Text.app/Contents/MacOS/PoorMansTextApp":raise RuntimeError('PID identity changed')
            subprocess.run(['kill','-TERM',str(pid)],check=True)
            for _ in range(50):
                if subprocess.run(['kill','-0',str(pid)],capture_output=True).returncode:break
                time.sleep(.1)
            else:raise RuntimeError('own PMT process alive')
    if saved['saved_preferences']:subprocess.run(['defaults','import','org.poormanstext.PoorMansText',str(root/'pmt-defaults.plist')],check=True,stdout=subprocess.DEVNULL)
    else:subprocess.run(['defaults','delete','org.poormanstext.PoorMansText'],capture_output=True)
    state.unlink()
print('CLEANUP no owned PMT process or saved preferences remain; Fastra runners own their process cleanup')
