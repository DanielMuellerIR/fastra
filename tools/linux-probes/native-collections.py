#!/usr/bin/env python3
"""Nur in der freigegebenen Test-Mac-Sitzung gegen notarisiert installierte Apps."""
import hashlib,json,os,pathlib,signal,subprocess,sys,time
root=pathlib.Path(sys.argv[1]);source=pathlib.Path(sys.argv[2]);root.mkdir(exist_ok=True)
fixture=root/'collections';state=root/'native-state.json';observer=root/'fastra-native-observe'
bundle="org.poormanstext.PoorMansText";app="/Applications/Poor Man's Text.app"
def run(args,**kwargs):return subprocess.run(args,check=True,timeout=180,**kwargs)
def pids():
    p=subprocess.run(['pgrep','-x','PoorMansTextApp'],capture_output=True,text=True)
    return [int(x) for x in p.stdout.split()]
def tree(folder):return {str(p.relative_to(folder)):hashlib.sha256(p.read_bytes()).hexdigest() for p in folder.rglob('*') if p.is_file()}
def stop(pid):
    command=subprocess.check_output(['ps','-p',str(pid),'-o','comm='],text=True).strip()
    assert command==app+'/Contents/MacOS/PoorMansTextApp',command
    os.kill(pid,signal.SIGTERM)
    for _ in range(100):
        if pid not in pids():return
        time.sleep(.05)
    raise RuntimeError('own PMT process did not terminate')
fastra_only='--fastra-only' in sys.argv
if not fastra_only:
    trusted=subprocess.check_output([str(observer),'trust'],text=True).strip()
    if trusted!='true':
        print('ENV native observer is not authorized in this launch context',file=sys.stderr);sys.exit(2)
    assert not pids(),'PMT already running'
    backup=root/'pmt-defaults.plist'
    saved=subprocess.run(['defaults','export',bundle,str(backup)],capture_output=True).returncode==0
    state.write_text(json.dumps({'saved_preferences':saved,'pid':None}))
    run([sys.executable,str(source/'tools/linux-probes/make-collections.py'),str(fixture)])
    for attempt in [1,2]:
        prior=pids()
        run(['open','-n','-a',app,str(fixture/'mail.mbox'),str(fixture/'notes.enex'),'--args','-ApplePersistenceIgnoreState','YES','-NSQuitAlwaysKeepsWindows','NO','-AppleLanguages','(en)','-CLIInstallDeclined','YES','-PandocInstallDeclined','YES','-destinationFolder',str(fixture/'pmt-output'),'-SUEnableAutomaticChecks','NO','-outputLayout','markdownFolder','-sourceMapping','NO','-conversionReport','NO','-frontmatter','NO'])
        pid=None
        for _ in range(100):
            found=[p for p in pids() if p not in prior]
            if len(found)==1:pid=found[0];break
            time.sleep(.1)
        assert pid
        state.write_text(json.dumps({'saved_preferences':saved,'pid':pid}))
        deadline=time.monotonic()+60
        while time.monotonic()<deadline:
            with (root/f'pmt-{attempt}-ax.json').open('wb') as out:run([str(observer),'dump',str(pid)],stdout=out)
            ax=(root/f'pmt-{attempt}-ax.json').read_text()
            if attempt==1 and all((fixture/'pmt-output'/(s+'-markdown')/'index.md').is_file() for s in ['mail','notes']):
                time.sleep(.5);break
            if attempt==2 and ('already exists' in ax or 'exists' in ax or 'Choose Another' in ax):break
            time.sleep(.2)
        else:raise RuntimeError(f'PMT GUI deadline in attempt {attempt}: '+ax[:1000])
        if attempt==1:
            baseline=tree(fixture/'pmt-output');assert len(baseline)>=9
            (root/'pmt-gui-tree.json').write_text(json.dumps(baseline,indent=2))
        else:assert tree(fixture/'pmt-output')==baseline,'PMT collision changed collection'
        stop(pid);state.write_text(json.dumps({'saved_preferences':saved,'pid':None}))
else:
    assert tree(fixture/'pmt-output')==json.loads((root/'pmt-gui-tree.json').read_text()),'PMT reference changed'
# Die Fastra-Selbsttests übernehmen dieselben Quellen, dann öffnet ein neuer
# App-Prozess alle drei Markdown-Dateien jeder Sammlung ohne Konvertierung.
env=dict(os.environ,FASTRA_COLLECTION_REVIEW_DIR=str(fixture),FASTRA_POORMANS_TEXT=app+'/Contents/Resources/poormans-text',FASTRA_SELFTEST_APP_BUNDLE='/Applications/Fastra.app',FASTRA_SELFTEST_APP_BIN='/Applications/Fastra.app/Contents/MacOS/Fastra')
for phase in ['import','reopen']:
    if phase=='reopen':(fixture/'reopen').touch()
    with (root/f'fastra-{phase}.log').open('wb') as out:run([str(source/'app/selftest.sh'),'markdowncollections'],env=env,stdout=out,stderr=subprocess.STDOUT)
    with (root/f'verify-{phase}.json').open('wb') as out:run([sys.executable,str(source/'tools/linux-probes/verify-collections.py'),str(fixture)],stdout=out)
print('PASS real Fastra imports and fresh-process reopen against recorded PMT GUI trees; complete identical trees and PNG bytes' if fastra_only else 'PASS real PMT GUI, preserved collision, real Fastra imports and fresh-process reopen, complete identical trees and PNG bytes')
