#!/usr/bin/env python3
"""Nur mit privaten XDG-Pfaden, D-Bus und Xvfb ausführen; keine Benutzeroberfläche."""
import ctypes
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import uuid
from urllib.parse import quote_from_bytes

assert os.environ.get('FASTRA_ISOLATED_DISPLAY') == '1'
# Den vom kurzlebigen CLI gestarteten Dienst übernehmen und seinen Exit prüfen.
assert ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0) == 0
ROOT = Path(os.environ['FASTRA_LIFECYCLE_SELFTEST_DIR'])
APP = Path(sys.argv[1]).resolve()
CLI = APP.with_name('fastra-control')
SOCKET = Path(os.environ['XDG_RUNTIME_DIR']) / 'org.fastra.Fastra.Development.control.v1.sock'


def wait(check, label):
    end = time.monotonic() + 15
    while time.monotonic() < end:
        try:
            value = check()
            if value:
                return value
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        time.sleep(.05)
    raise AssertionError('timeout: ' + label)


def state():
    return json.loads((ROOT / 'state.json').read_text())


def count(n):
    return wait(lambda: (lambda s: s if len(s['windows']) == n else None)(state()), f'{n} registered windows')


def request(operation='objects', launch=False, **fields):
    payload = dict(version=1, id=str(uuid.uuid4()), deadline=time.time() + 10,
                   operation=operation, **fields)
    command = [str(CLI)] + ([] if launch else ['--no-launch']) + ['--request', '-']
    result = subprocess.run(command, input=json.dumps(payload), text=True,
                            capture_output=True, timeout=12)
    reply = json.loads(result.stdout)
    assert result.returncode == 0, reply
    assert 'error' not in reply, reply
    return reply


def started():
    wait(SOCKET.exists, 'controller socket')
    def probe():
        try:
            return request()
        except AssertionError as error:
            if error.args and isinstance(error.args[0], dict) and error.args[0].get('error', {}).get('code') == 'delivery':
                return None
            raise
    return wait(probe, 'live controller response')


def remote(*arguments, cwd=None):
    result = subprocess.run([str(APP), *arguments], cwd=cwd, timeout=12)
    assert result.returncode == 0, result.returncode


def xdo(*arguments):
    result = subprocess.run(['xdotool', *map(str, arguments)], text=True, capture_output=True, timeout=10)
    assert result.returncode == 0, result.stderr
    return result.stdout.strip()


def window_ids(pid):
    return xdo('search', '--onlyvisible', '--pid', pid).splitlines()


def close(window):
    xdo('windowfocus', '--sync', window, 'key', '--clearmodifiers', 'ctrl+q')


def finish(process=None):
    (ROOT / 'quit').touch()
    if process is not None:
        assert process.wait(10) == 0
    wait(lambda: not SOCKET.exists(), 'socket cleanup after native quit')
    shutdown = wait(lambda: json.loads((ROOT / 'shutdown.json').read_text()), 'native shutdown completion')
    assert shutdown == {'registryEmpty': True, 'holdReleased': True}
    (ROOT / 'shutdown.json').unlink()
    (ROOT / 'quit').unlink()
    (ROOT / 'state.json').unlink(missing_ok=True)


def inventory(n, runtime):
    reply = request()
    assert reply['runtimeID'] == runtime, reply
    windows = [o for o in reply['objects'] if o['kind'] == 'window' and 'sessionID' not in o]
    assert len(windows) == n, reply
    return reply


def capture(pid, name):
    time.sleep(.3)
    window = window_ids(pid)[-1]
    xdo('windowmove', '--sync', window, '0', '0')
    result = subprocess.run(['import', '-silent', '-window', window, str(ROOT / (name + '.png'))], timeout=10)
    assert result.returncode == 0


def native_quit_probe():
    """Der vorhandene Prozess-Probe prüft Beenden ausschließlich über native Controls."""
    import ctypes,hashlib,json,os,subprocess,sys,time,uuid
    from pathlib import Path
    assert os.environ.get('FASTRA_ISOLATED_DISPLAY')=='1'
    assert ctypes.CDLL(None,use_errno=True).prctl(36,1,0,0,0)==0
    ROOT=Path(os.environ['FASTRA_LIFECYCLE_SELFTEST_DIR']);APP=Path(sys.argv[1]).resolve();CLI=APP.with_name('fastra-control')
    SOCKET=Path(os.environ['XDG_RUNTIME_DIR'])/'org.fastra.Fastra.Development.control.v1.sock'
    os.environ.setdefault('FASTRA_TOOL_WIDTH','760')
    DE=os.environ.get('LANGUAGE',os.environ.get('LANG','')).startswith('de')
    L=lambda de,en:de if DE else en
    C=L('Abbrechen','Cancel');D=L('Ohne Speichern schließen','Close without saving');S=L('Speichern und schließen','Save and close')
    def wait(fn,label,seconds=15):
     end=time.monotonic()+seconds
     while time.monotonic()<end:
      try:
       result=fn()
       if result:return result
      except (FileNotFoundError,json.JSONDecodeError,KeyError,StopIteration):pass
      time.sleep(.05)
     raise AssertionError('Timeout '+label+'\n'+json.dumps(state(),ensure_ascii=False)[-13000:])
    def state():return json.loads((ROOT/'state.json').read_text())
    def windows(n=None):
     s=state()['windows']
     return s if n is None or len(s)==n else None
    def xdo(*args):
     r=subprocess.run(['xdotool',*map(str,args)],capture_output=True,text=True,timeout=10)
     assert r.returncode==0,r.stderr
     return r.stdout.strip()
    def request(op='objects',**fields):
     payload=dict(version=1,id=str(uuid.uuid4()),deadline=time.time()+10,operation=op,**fields)
     r=subprocess.run([str(CLI),'--no-launch','--request','-'],input=json.dumps(payload),text=True,capture_output=True,timeout=12)
     assert r.returncode==0,(r.stdout,r.stderr)
     result=json.loads(r.stdout);assert 'error' not in result,result
     return result
    def remote(*args):assert subprocess.run([str(APP),*map(str,args)],timeout=12).returncode==0
    def controls(label=None,kind=None,xid=None):
     return [(w,b) for w in state()['native'] if xid is None or w['xid']==xid for b in w['widgets'] if (label is None or (b['label'] or '').replace('_','')==label) and (kind is None or b['kind']==kind) and b['width']>0 and b['height']>0]
    def click(label=None,kind=None,xid=None):
     w,b=wait(lambda:next(((w,b) for w,b in controls(label,kind,xid) if b['sensitive']),None),'control '+str((label,kind,xid)))
     xdo('windowraise',w['xid'],'windowfocus','--sync',w['xid'],'mousemove','--window',w['xid'],round(b['x']+w['surfaceX']),round(b['y']+w['surfaceY']),'click',1)
     return w['xid']
    def key(xid,*keys):xdo('windowraise',xid,'windowfocus','--sync',xid,'key','--clearmodifiers',*keys)
    def type_source(xid,text):
     if document(xid)['pathBytes'] is None:
      key(xid,'ctrl+t')
      wait(lambda:any(w['xid']==xid and len(w['documents'])>1 and w['documents'][-1]['active'] for w in windows()),'fresh typing tab')
     else:click(kind='source',xid=xid)
     key(xid,'ctrl+End');xdo('type','--clearmodifiers','--delay',2,text)
     wait(lambda:any(text in d['text'] for w in windows() if w['xid']==xid for d in w['documents']),'typed '+text)
    def document(xid):return next(w for w in windows() if w['xid']==xid)['documents'][-1]
    def choose(label):
     xid=click(label)
     wait(lambda:not SOCKET.exists() or not any(w['xid']==xid for w in state()['native']),'dialog dismissed')
    def abort_settled(n):wait(lambda:len(windows())==n and all(not w['closeActive'] for w in windows()),'abort settled')
    def start(service=True):
     for name in ['state.json','shutdown.json']:(ROOT/name).unlink(missing_ok=True)
     p=subprocess.Popen([str(APP),*(['--local-control-service']if service else[])])
     wait(SOCKET.exists,'socket');wait(lambda:(ROOT/'state.json').exists(),'state')
     runtime=wait(lambda:request().get('runtimeID'),'runtime')
     return p,runtime
    def capture(xid,name):
     xdo('windowraise',xid,'windowfocus','--sync',xid,'windowmove','--sync',xid,0,0);time.sleep(.2)
     assert subprocess.run(['import','-silent','-window',str(xid),str(ROOT/(name+'.png'))],timeout=10).returncode==0
    def complete(p):
     assert p.wait(15)==0
     wait(lambda:not SOCKET.exists(),'socket removed')
     assert json.loads((ROOT/'shutdown.json').read_text())=={'registryEmpty':True,'holdReleased':True}
     print('PASS native process exit0, registry/service/socket cleanup',flush=True)

    a=ROOT/'a.txt';b=ROOT/'b.txt';a.write_text('A BASE\n');b.write_text('B BASE\n')
    p,runtime=start();assert wait(lambda:windows(0) is not None,'service no window') is not None
    remote(a);wait(lambda:windows(1),'first window');remote(b);wait(lambda:windows(2),'second window')
    wa,wb=[w['xid'] for w in windows()]
    for wid in [wa,wb]:xdo('windowsize',wid,os.environ['FASTRA_TOOL_WIDTH'],950)
    wait(lambda:all(any(d['pathBytes'] for d in w['documents']) for w in windows()),'loaded')
    wait(lambda:all(any(n['xid']==wid and n['width']==int(os.environ['FASTRA_TOOL_WIDTH']) and n['height']==950 for n in state()['native']) for wid in [wa,wb]),'native resize settled');time.sleep(.35)
    remote();wait(lambda:windows(3),'clean close fixture');clean=windows()[-1]['xid'];key(clean,'ctrl+q');wait(lambda:windows(2),'actual clean CtrlQ removal');assert p.poll() is None and request()['runtimeID']==runtime
    print('PASS clean CtrlQ actually removes one window and preserves the service',flush=True)
    type_source(wa,'A DIRTY');type_source(wb,'B DIRTY')
    prior=[document(wid).copy() for wid in [wa,wb]]
    job=request('snapshot',path=str(a),sha256=hashlib.sha256(a.read_bytes()).hexdigest(),location=0,length=1)['job']
    wait(lambda:request('status',jobID=job['id'])['job']['state']=='ready','snapshot')
    assert any(o.get('sessionID')==job['sessionID'] for o in request()['objects'])
    capture(wa,'main-quit');capture(wb,'main-quit-b')
    key(wa,'ctrl+shift+q')
    first_dialog=wait(lambda:next((w for w,b in controls(D)),None),'first decision')
    key(first_dialog['xid'],'ctrl+shift+q');time.sleep(.1)
    assert len(windows())==2 and len(controls(D))==1
    choose(D)
    # Earlier Discard is only a permit: both windows/tabs still exist while B is asking.
    assert len(windows())==2
    choose(C);abort_settled(2)
    assert [document(wid) for wid in [wa,wb]]==prior
    assert request()['runtimeID']==runtime and p.poll() is None
    print('PASS A Discard then B Cancel retains both exact documents/revisions + service/snapshot',flush=True)
    # Ctrl+Q still means only the focused window and leaves all state on Cancel.
    key(wa,'ctrl+q');choose(C);abort_settled(2);assert len(windows())==2
    print('PASS plain CtrlQ remains window close',flush=True)
    # Exact Save receipt for A, followed by later Cancel in B.
    key(wa,'ctrl+shift+q');choose(S);choose(C);abort_settled(2)
    assert a.read_text()==document(wa)['text'] and not document(wa)['dirty']
    assert document(wb)==prior[1] and p.poll() is None
    print('PASS A Save + B Cancel leaves saved A open/clean and B open/dirty',flush=True)
    # Add an unsaved window and cancel its actual Save chooser.
    remote();wait(lambda:windows(3),'new unsaved window');wc=windows()[-1]['xid'];type_source(wc,'UNTITLED DIRTY')
    key(wa,'ctrl+shift+q');choose(D);choose(S)
    wait(lambda:bool(controls('Cancel') or controls(C)),'save chooser cancel');choose('Cancel' if controls('Cancel') else C);abort_settled(3)
    assert document(wc)['dirty'] and document(wc)['pathBytes'] is None
    print('PASS untitled Save chooser Cancel is terminal, all windows remain',flush=True)
    # Abort owns this Save chooser: RemoteOpen must dismiss it without blocking the new window.
    key(wa,'ctrl+shift+q');choose(D);choose(S)
    chooser=wait(lambda:next((w for w in state()['native'] if w['title']==L('Neues Dokument speichern','Save new document')),None),'owned chooser visible')
    opened=ROOT/'chooser-remote.txt';opened.write_text('CHOOSER REMOTE RETAINED\n');remote(opened)
    wait(lambda:windows(4),'remote open during chooser');abort_settled(4)
    wait(lambda:not document(wc)['saving'] and not any(w['xid']==chooser['xid'] for w in state()['native']),'owned chooser cancelled')
    assert document(wc)['dirty'] and document(wc)['pathBytes'] is None
    print('PASS RemoteOpen abort dismisses only the Quit-owned Save chooser and retains untitled contents/new file',flush=True)
    # Remote activate while B's decision is pending aborts the attempt and processes the new request.
    key(wa,'ctrl+shift+q');wait(lambda:bool(controls(D)),'decision before remote activate');remote();wait(lambda:windows(5),'activate preserved');abort_settled(5)
    assert document(wb)==prior[1] and document(wc)['dirty']
    print('PASS Activate aborts old attempt, retains new window and stale callback cannot close',flush=True)
    # Type while the actual existing-file Save is awaiting its terminal callback.
    type_source(wa,' SAVE STALE');attempted=document(wa)['text']
    key(wa,'ctrl+shift+q');choose(S)
    wait(lambda:document(wa)['saving'],'save in flight');type_source(wa,' LATE EDIT')
    abort_settled(5)
    assert a.read_text()==attempted and document(wa)['dirty'] and document(wa)['text']==attempted+' LATE EDIT'
    assert document(wb)==prior[1]
    print('PASS real source input during asynchronous Save returns Stale and retains all windows/newer text',flush=True)
    # Final Quit is invoked from the read-only Snapshot window through the real global shortcut.
    snapshot=wait(lambda:next((w for w in state()['native'] if (w['title'] or '').startswith('Snapshot:')),None),'snapshot native')
    key(snapshot['xid'],'ctrl+shift+q')
    for _ in range(3):choose(D)
    complete(p)
    print('PASS service-first, two-phase permits, repeated open/stale/chooser outcomes and snapshot global shortcut',flush=True)
    # GUI-first + service hold + clean second window; actual global Quit shortcut.
    p,runtime=start(False);wait(lambda:windows(1),'GUI-first');remote('--local-control-service');remote(a);wait(lambda:windows(2),'GUI-second')
    wait(lambda:any(d['pathBytes']==list(os.fsencode(a)) and d['text']==a.read_text() for w in windows() for d in w['documents']),'GUI second file fully loaded')
    key(windows()[0]['xid'],'ctrl+shift+q');complete(p)
    print('PASS GUI-first global Quit shuts down remote service hold',flush=True)


def native_asset_io_probe():
    """Echte Cancel/Source/Quit-Aktionen um die laufende Bildrücknahme abgrenzen."""
    import ctypes,hashlib,json,os,subprocess,sys,time,uuid
    from pathlib import Path
    assert os.environ.get('FASTRA_ISOLATED_DISPLAY')=='1'
    assert ctypes.CDLL(None,use_errno=True).prctl(36,1,0,0,0)==0
    ROOT=Path(os.environ['FASTRA_LIFECYCLE_SELFTEST_DIR']);APP=Path(sys.argv[1]).resolve();CLI=APP.with_name('fastra-control')
    SOCKET=Path(os.environ['XDG_RUNTIME_DIR'])/'org.fastra.Fastra.Development.control.v1.sock'
    os.environ.setdefault('FASTRA_TOOL_WIDTH','760')
    DE=os.environ.get('LANGUAGE',os.environ.get('LANG','')).startswith('de')
    L=lambda de,en:de if DE else en
    Q=L('Fastra beenden','Quit Fastra');C=L('Abbrechen','Cancel');D=L('Ohne Speichern schließen','Close without saving');S=L('Speichern und schließen','Save and close')
    def wait(fn,label,seconds=15):
     end=time.monotonic()+seconds
     while time.monotonic()<end:
      try:
       result=fn()
       if result:return result
      except (FileNotFoundError,json.JSONDecodeError,KeyError,StopIteration):pass
      time.sleep(.05)
     raise AssertionError('Timeout '+label+'\n'+json.dumps(state(),ensure_ascii=False)[-13000:])
    def state():return json.loads((ROOT/'state.json').read_text())
    def windows(n=None):
     s=state()['windows']
     return s if n is None or len(s)==n else None
    def xdo(*args):
     r=subprocess.run(['xdotool',*map(str,args)],capture_output=True,text=True,timeout=10)
     assert r.returncode==0,r.stderr
     return r.stdout.strip()
    def request(op='objects',**fields):
     payload=dict(version=1,id=str(uuid.uuid4()),deadline=time.time()+10,operation=op,**fields)
     r=subprocess.run([str(CLI),'--no-launch','--request','-'],input=json.dumps(payload),text=True,capture_output=True,timeout=12)
     assert r.returncode==0,(r.stdout,r.stderr)
     result=json.loads(r.stdout);assert 'error' not in result,result
     return result
    def remote(*args):assert subprocess.run([str(APP),*map(str,args)],timeout=12).returncode==0
    def controls(label=None,kind=None,xid=None):
     return [(w,b) for w in state()['native'] if xid is None or w['xid']==xid for b in w['widgets'] if (label is None or (b['label'] or '').replace('_','')==label) and (kind is None or b['kind']==kind) and b['width']>0 and b['height']>0]
    def click(label=None,kind=None,xid=None):
     w,b=wait(lambda:next(((w,b) for w,b in controls(label,kind,xid) if b['sensitive']),None),'control '+str((label,kind,xid)))
     xdo('windowraise',w['xid'],'windowfocus','--sync',w['xid'],'mousemove','--window',w['xid'],round(b['x']),round(b['y']),'click',1)
     return w['xid']
    def key(xid,*keys):xdo('windowraise',xid,'windowfocus','--sync',xid,'key','--clearmodifiers',*keys)
    def type_source(xid,text):
     click(kind='source',xid=xid);time.sleep(.15);key(xid,'ctrl+End');xdo('type','--clearmodifiers','--delay',2,text)
     wait(lambda:any(text in d['text'] for w in windows() if w['xid']==xid for d in w['documents']),'typed '+text)
    def document(xid):return next(w for w in windows() if w['xid']==xid)['documents'][-1]
    def choose(label):
     xid=click(label)
     wait(lambda:not SOCKET.exists() or not any(w['xid']==xid for w in state()['native']),'dialog dismissed')
    def abort_settled(n):wait(lambda:len(windows())==n and all(not w['closeActive'] for w in windows()),'abort settled')
    def start(service=True):
     for name in ['state.json','shutdown.json']:(ROOT/name).unlink(missing_ok=True)
     p=subprocess.Popen([str(APP),*(['--local-control-service']if service else[])])
     wait(SOCKET.exists,'socket');wait(lambda:(ROOT/'state.json').exists(),'state')
     runtime=wait(lambda:request().get('runtimeID'),'runtime')
     return p,runtime
    def capture(xid,name):
     xdo('windowraise',xid,'windowfocus','--sync',xid,'windowmove','--sync',xid,0,0);time.sleep(.2)
     assert subprocess.run(['import','-silent','-window',str(xid),str(ROOT/(name+'.png'))],timeout=10).returncode==0
    def complete(p):
     assert p.wait(15)==0
     wait(lambda:not SOCKET.exists(),'socket removed')
     assert json.loads((ROOT/'shutdown.json').read_text())=={'registryEmpty':True,'holdReleased':True}
     print('PASS native process exit0, registry/service/socket cleanup',flush=True)


    FIXED=os.environ.get('FASTRA_ASSET_GUARD_FIXED')=='1'
    MAIN=os.environ.get('FASTRA_ASSET_MAIN_POSTCHECK')=='1'
    a=ROOT/'asset.md';other=ROOT/'other.md';a.write_text('Asset source original.\n');other.write_text('Other original.\n')
    (ROOT/'pause-apply').touch();(ROOT/('pause-worker' if MAIN else 'pause-undo')).touch()
    if MAIN:(ROOT/'pause-restore').touch()
    p,runtime=start();remote(a);wait(lambda:windows(1),'A');remote(other);wait(lambda:windows(2),'B')
    wa,wb=[w['xid']for w in windows()];wait(lambda:all(any(d['pathBytes'] for d in w['documents']) for w in windows()),'loaded');time.sleep(.4)
    click(L('Rich-Markdown','Rich Markdown'),kind='check',xid=wa);wait(lambda:document(wa)['rich'] and bool(controls(kind='rich',xid=wa)),'rich mapped');time.sleep(.7)
    click(kind='rich',xid=wa);key(wa,'ctrl+End','ctrl+v')
    apply=L('Bilder speichern und einfügen','Save images and insert');wait(lambda:bool(controls(apply)),'real PNG clipboard asset preview')
    click(apply);wait(lambda:(ROOT/'ready-apply').exists(),'image physical publication before native completion')
    image=ROOT/'images/1.png';assert image.exists();original=image.read_bytes()
    click(C);assert controls(C),'first Cancel keeps committing preview open'
    (ROOT/'release-apply').touch();wait(lambda:(ROOT/('ready-worker'if MAIN else 'ready-undo')).exists(),'real compensation after undo')
    assert not image.exists()
    choose(C)
    click(L('Rich-Markdown','Rich Markdown'),kind='check',xid=wa)
    wait(lambda:not document(wa)['rich'] and bool(controls(kind='source',xid=wa)),'source mode detached old Rich while compensation pending')
    if MAIN:type_source(wb,' ![shared](images/1.png)')
    else:(ROOT/'neighbour.md').write_text('![shared](images/1.png)\n')
    assert not image.exists()
    if FIXED:
     key(wb,'ctrl+q');time.sleep(.15);assert len(windows())==2 and state()['pendingAssetIO']>0
    click(Q,xid=wa)
    if not FIXED:
     complete(p);assert not image.exists()
     assert list((ROOT/'images').glob('.fastra-image-undo-*'))
     print('CONFIRMED pre-fix: second native Cancel + Source detach hides active compensation; native Quit exits before postcheck and saved neighbour image remains absent',flush=True)
    else:
     wait(lambda:all(not w['closeActive'] for w in windows()),'native Quit blocked before document decisions')
     assert p.poll() is None and len(windows())==2 and state().get('pendingAssetIO',0)>0 and request()['runtimeID']==runtime
     assert not controls(D) and not controls(S)
     (ROOT/('release-worker'if MAIN else 'release-undo')).touch()
     if MAIN:
      wait(lambda:(ROOT/'ready-restore').exists(),'nested restore worker completed before final Main callback')
      assert image.read_bytes()==original and state()['pendingAssetIO']>0
      click(Q,xid=wa);wait(lambda:all(not w['closeActive']for w in windows()),'Quit held through nested restore Main completion')
      assert p.poll() is None and len(windows())==2
      (ROOT/'pause-main').touch();(ROOT/'release-restore').touch()
      wait(lambda:(ROOT/'ready-main').exists(),'nested worker returned; final Main continuation held')
      assert state()['pendingAssetIO']>0 and image.read_bytes()==original
      click(Q,xid=wa);time.sleep(.1);assert p.poll() is None and len(windows())==2
      (ROOT/'release-main').touch()
     wait(lambda:state().get('pendingAssetIO',1)==0 and image.exists(),'all mutation and Main postchecks completed')
     assert image.read_bytes()==original and a.read_text()=='Asset source original.\n'
     print('PASS global asset IO guard: inactive/detached Rich cannot hide pending rollback; native Quit held through '+('nested restore + final Main postcheck'if MAIN else 'undo + saved-neighbour protection/restore')+'; exact image bytes restored',flush=True)
     click(Q,xid=wa)
     if MAIN:choose(D)
     complete(p)
     print('PASS new native Quit succeeds only after complete owned mutation settles',flush=True)


def native_folder_quit_probe():
    """Echte Ordner-Dateiänderung/Rücknahme bis zum Main-Ergebnis vor Quit schützen."""
    import ctypes,hashlib,json,os,subprocess,sys,time,uuid
    from pathlib import Path
    assert os.environ.get('FASTRA_ISOLATED_DISPLAY')=='1'
    assert ctypes.CDLL(None,use_errno=True).prctl(36,1,0,0,0)==0
    ROOT=Path(os.environ['FASTRA_LIFECYCLE_SELFTEST_DIR']);APP=Path(sys.argv[1]).resolve();CLI=APP.with_name('fastra-control')
    SOCKET=Path(os.environ['XDG_RUNTIME_DIR'])/'org.fastra.Fastra.Development.control.v1.sock'
    os.environ.setdefault('FASTRA_TOOL_WIDTH','760')
    DE=os.environ.get('LANGUAGE',os.environ.get('LANG','')).startswith('de')
    L=lambda de,en:de if DE else en
    Q=L('Fastra beenden','Quit Fastra');C=L('Abbrechen','Cancel');D=L('Ohne Speichern schließen','Close without saving');S=L('Speichern und schließen','Save and close')
    def wait(fn,label,seconds=15):
     end=time.monotonic()+seconds
     while time.monotonic()<end:
      try:
       result=fn()
       if result:return result
      except (FileNotFoundError,json.JSONDecodeError,KeyError,StopIteration):pass
      time.sleep(.05)
     raise AssertionError('Timeout '+label+'\n'+json.dumps(state(),ensure_ascii=False)[-13000:])
    def state():return json.loads((ROOT/'state.json').read_text())
    def windows(n=None):
     s=state()['windows']
     return s if n is None or len(s)==n else None
    def xdo(*args):
     r=subprocess.run(['xdotool',*map(str,args)],capture_output=True,text=True,timeout=10)
     assert r.returncode==0,r.stderr
     return r.stdout.strip()
    def request(op='objects',**fields):
     payload=dict(version=1,id=str(uuid.uuid4()),deadline=time.time()+10,operation=op,**fields)
     r=subprocess.run([str(CLI),'--no-launch','--request','-'],input=json.dumps(payload),text=True,capture_output=True,timeout=12)
     assert r.returncode==0,(r.stdout,r.stderr)
     result=json.loads(r.stdout);assert 'error' not in result,result
     return result
    def remote(*args):assert subprocess.run([str(APP),*map(str,args)],timeout=12).returncode==0
    def controls(label=None,kind=None,xid=None):
     return [(w,b) for w in state()['native'] if xid is None or w['xid']==xid for b in w['widgets'] if (label is None or (b['label'] or '').replace('_','')==label) and (kind is None or b['kind']==kind) and b['width']>0 and b['height']>0]
    def click(label=None,kind=None,xid=None):
     w,b=wait(lambda:next(((w,b) for w,b in controls(label,kind,xid) if b['sensitive']),None),'control '+str((label,kind,xid)))
     xdo('windowraise',w['xid'],'windowfocus','--sync',w['xid'],'mousemove','--window',w['xid'],round(b['x']),round(b['y']),'click',1)
     return w['xid']
    def key(xid,*keys):xdo('windowraise',xid,'windowfocus','--sync',xid,'key','--clearmodifiers',*keys)
    def type_source(xid,text):
     click(kind='source',xid=xid);time.sleep(.15);key(xid,'ctrl+End');xdo('type','--clearmodifiers','--delay',2,text)
     wait(lambda:any(text in d['text'] for w in windows() if w['xid']==xid for d in w['documents']),'typed '+text)
    def document(xid):return next(w for w in windows() if w['xid']==xid)['documents'][-1]
    def choose(label):
     xid=click(label)
     wait(lambda:not SOCKET.exists() or not any(w['xid']==xid for w in state()['native']),'dialog dismissed')
    def abort_settled(n):wait(lambda:len(windows())==n and all(not w['closeActive'] for w in windows()),'abort settled')
    def start(service=True):
     for name in ['state.json','shutdown.json']:(ROOT/name).unlink(missing_ok=True)
     p=subprocess.Popen([str(APP),*(['--local-control-service']if service else[])])
     wait(SOCKET.exists,'socket');wait(lambda:(ROOT/'state.json').exists(),'state')
     runtime=wait(lambda:request().get('runtimeID'),'runtime')
     return p,runtime
    def capture(xid,name):
     xdo('windowraise',xid,'windowfocus','--sync',xid,'windowmove','--sync',xid,0,0);time.sleep(.2)
     assert subprocess.run(['import','-silent','-window',str(xid),str(ROOT/(name+'.png'))],timeout=10).returncode==0
    def complete(p):
     assert p.wait(15)==0
     wait(lambda:not SOCKET.exists(),'socket removed')
     assert json.loads((ROOT/'shutdown.json').read_text())=={'registryEmpty':True,'holdReleased':True}
     print('PASS native process exit0, registry/service/socket cleanup',flush=True)


    FIXED=os.environ.get('FASTRA_FOLDER_GUARD_FIXED')=='1'
    def wmclose(wid):
     class Data(ctypes.Union):_fields_=[('l',ctypes.c_long*5),('b',ctypes.c_char*20)]
     class Client(ctypes.Structure):_fields_=[('type',ctypes.c_int),('serial',ctypes.c_ulong),('send_event',ctypes.c_int),('display',ctypes.c_void_p),('window',ctypes.c_ulong),('message_type',ctypes.c_ulong),('format',ctypes.c_int),('data',Data)]
     class Event(ctypes.Union):_fields_=[('client',Client),('pad',ctypes.c_long*24)]
     x=ctypes.CDLL('libX11.so.6');x.XOpenDisplay.argtypes=[ctypes.c_char_p];x.XOpenDisplay.restype=ctypes.c_void_p;x.XInternAtom.argtypes=[ctypes.c_void_p,ctypes.c_char_p,ctypes.c_int];x.XInternAtom.restype=ctypes.c_ulong
     x.XSendEvent.argtypes=[ctypes.c_void_p,ctypes.c_ulong,ctypes.c_int,ctypes.c_long,ctypes.POINTER(Event)];x.XFlush.argtypes=[ctypes.c_void_p];x.XCloseDisplay.argtypes=[ctypes.c_void_p]
     display=x.XOpenDisplay(None);assert display;ev=Event();ev.client.type=33;ev.client.send_event=1;ev.client.display=display;ev.client.window=wid;ev.client.message_type=x.XInternAtom(display,b'WM_PROTOCOLS',0);ev.client.format=32;ev.client.data.l[0]=x.XInternAtom(display,b'WM_DELETE_WINDOW',0)
     assert x.XSendEvent(display,wid,0,0,ctypes.byref(ev));x.XFlush(display);x.XCloseDisplay(display)
    def native_present(wid):return any(w['xid']==wid for w in state()['native'])
    folder=ROOT/'changes';folder.mkdir();source=folder/'sample.txt';before=L('Katze Katze\n','cat cat\n');after=L('Hund Hund\n','dog dog\n');source.write_text(before)
    (ROOT/'pause-apply').touch();(ROOT/'pause-undo').touch()
    p,runtime=start();remote();wait(lambda:windows(1),'host A');remote();wait(lambda:windows(2),'host B');wa,wb=[w['xid']for w in windows()]
    click(L('Ordner durchsuchen …','Search folder …'),xid=wa)
    fw=wait(lambda:next((w for w in state()['native']if w['title']==L('Ordner · Vorschau und Ersetzen','Folder · Preview and Replace')),None),'folder window');wf=fw['xid']
    click(kind='entry',xid=wf);key(wf,'ctrl+a');xdo('type','--clearmodifiers',str(folder))
    click(L('Vorschau erstellen','Create preview'),xid=wf)
    apply=L('Freigegebene Treffer in Dateien anwenden','Apply approved matches to files');click(apply,xid=wf)
    wait(lambda:(ROOT/'ready-apply').exists(),'real file transaction completed before Main result')
    assert source.read_text()==after and state().get('pendingAssetIO',0)==0
    journals=list(folder.rglob('.fastra-transaction-*'));assert journals
    wmclose(wf);time.sleep(.15);assert native_present(wf),'own busy folder close must reject'
    if not FIXED:
     key(wf,'ctrl+shift+q');complete(p)
     assert source.read_text()==after
     assert not any(json.loads(path.read_text()).get('recovery_journals') for path in (ROOT/'state/fastra').glob('*.json'))
     print('CONFIRMED pre-fix: own Folder close rejects, but native global Quit destroys parent/tool and exits during real File Apply before Main journal/status completion',flush=True)
    else:
     wmclose(wa);time.sleep(.2);assert len(windows())==2 and native_present(wf)
     print('PARENT_WM_POLICY', 'app busy gate reached' if L('Dateivorgang','File operation') in windows()[0]['status'] else 'GTK modal layer holds before app handler',flush=True)
     key(wf,'ctrl+shift+q');time.sleep(.15);assert p.poll() is None and len(windows())==2 and native_present(wf) and request()['runtimeID']==runtime
     assert L('Dateivorgang','File operation') in windows()[0]['status']
     (ROOT/'release-apply').touch()
     undo=L('Dateiänderungen rückgängig','Undo file changes');wait(lambda:bool([(w,b)for w,b in controls(undo,xid=wf)if b['sensitive']]),'Apply Main completion enables Undo')
     wait(lambda:windows()[0]['session']['journalsEpoch']>0,'journal indexed after completion')
     print('PASS busy Folder Apply: own/tool/global close held; parent retained; actual busy gate reports its reason; actual file bytes and complete Main journal receipt retained',flush=True)
     click(undo,xid=wf);wait(lambda:(ROOT/'ready-undo').exists(),'real Undo complete before Main result');assert source.read_text()==before
     wmclose(wf);wmclose(wa);time.sleep(.15);assert native_present(wf)and len(windows())==2
     key(wf,'ctrl+shift+q');time.sleep(.15);assert p.poll() is None and len(windows())==2
     (ROOT/'release-undo').touch();wait(lambda:any(b['sensitive']for w,b in controls(L('Vorschau erstellen','Create preview'),xid=wf)),'Undo Main completion')
     assert source.read_text()==before
     wmclose(wf);wait(lambda:not native_present(wf),'idle folder close succeeds')
     wmclose(wb);wait(lambda:len(windows())==1,'unrelated host closes after native modality ends')
     wait(lambda:not windows()[0]['session']['busy'] and windows()[0]['session']['journalsEpoch']==windows()[0]['session']['journalsSaved'],'journal idle')
     key(wa,'ctrl+shift+q');complete(p)
     print('PASS busy Folder Undo: parent/global close held until real restoration and final Main completion; subsequent normal close and global Quit succeed',flush=True)


if os.environ.get('FASTRA_QUIT_FOLDER_SELFTEST') == '1':
    native_folder_quit_probe()
    sys.exit(0)


if os.environ.get('FASTRA_QUIT_ASSET_IO_SELFTEST') == '1':
    native_asset_io_probe()
    sys.exit(0)


if os.environ.get('FASTRA_QUIT_SELFTEST') == '1':
    native_quit_probe()
    sys.exit(0)


# Dienst zuerst; sekundäre Aufrufe müssen den ersten Prozess verwenden.
primary = subprocess.Popen([str(APP), '--local-control-service'])
runtime = started()['runtimeID']
assert primary.poll() is None
assert count(0)['held']
assert request()['objects'] == []
remote()
assert count(1)['held']
first = inventory(1, runtime)
first_ids = {o['id'] for o in first['objects']}
capture(primary.pid, 'service-first')
remote('--local-control-service')
remote('--local-control-service')
wait(lambda: state()['held'], 'service hold after remote call')
assert count(1)['held']
inventory(1, runtime)

# Pfade werden beim Remote-Aufrufer aufgelöst; Dateinamen bleiben rohe Bytes.
files = ROOT / 'caller'
files.mkdir(exist_ok=True)
regular = files / 'relative.txt'
regular.write_text('REMOTE CWD CONTENT\n')
raw = os.fsencode(files) + b'/raw-\xff.txt'
with open(raw, 'wb') as file:
    file.write(b'RAW PATH CONTENT\n')
remote('relative.txt', b'raw-\xff.txt', cwd=files)
expected = {os.fsencode(regular): 'REMOTE CWD CONTENT\n', raw: 'RAW PATH CONTENT\n'}

def paths_loaded():
    current = count(2)
    found = {bytes(d['pathBytes']): d['text'] for w in current['windows'] for d in w['documents'] if d['pathBytes'] is not None}
    return current if all(found.get(path) == text for path, text in expected.items()) else None

wait(paths_loaded, 'remote cwd and raw path content')
inventory(2, runtime)
uri = 'file://' + quote_from_bytes(raw, safe='/')
remote(uri)
wait(lambda: len(state()['windows']) == 3 and any(d['pathBytes'] == list(raw) and d['text'] == 'RAW PATH CONTENT\n' for d in state()['windows'][-1]['documents']), 'raw file URI')
inventory(3, runtime)

# Ein abgewiesenes Schließen darf Registry und ungesicherte Daten nicht verlieren.
blank = window_ids(primary.pid)[0]
prior = state()['windows'][0]['documents'][0]['text']
xdo('windowraise', blank, 'windowfocus', '--sync', blank, 'mousemove', '--window', blank, 400, 350, 'click', 1, 'key', 'ctrl+End')
xdo('type', '--clearmodifiers', '--delay', 5, 'LIFECYCLE DIRTY')
wait(lambda: any(d['dirty'] and 'LIFECYCLE DIRTY' in d['text'] for d in state()['windows'][0]['documents']), 'native dirty editor input')
close(blank)
time.sleep(.3)
assert len(state()['windows']) == 3
assert any(d['dirty'] and 'LIFECYCLE DIRTY' in d['text'] for d in state()['windows'][0]['documents'])
xdo('key', 'Escape')
time.sleep(.2)
inventory(3, runtime)
for _ in range(20):
    if not any(d['dirty'] for d in state()['windows'][0]['documents']):
        break
    xdo('windowfocus', '--sync', blank, 'key', 'ctrl+z')
    time.sleep(.1)
assert state()['windows'][0]['documents'][0]['text'] == prior
assert not state()['windows'][0]['documents'][0]['dirty']
for window in reversed(window_ids(primary.pid)):
    close(window)
count(0)
assert primary.poll() is None
inventory(0, runtime)
assert regular.read_bytes() == b'REMOTE CWD CONTENT\n'
assert Path(os.fsdecode(raw)).read_bytes() == b'RAW PATH CONTENT\n'
remote()
count(1)
reopened = inventory(1, runtime)
assert first_ids.isdisjoint(o['id'] for o in reopened['objects'])
capture(primary.pid, 'reopened')

# Native Snapshot-Sitzungen teilen sich weiterhin denselben Controller.
raw_bytes = regular.read_bytes()
job = request('snapshot', path=str(regular), sha256=hashlib.sha256(raw_bytes).hexdigest(), location=0, length=6)['job']
wait(lambda: request('status', jobID=job['id'])['job']['state'] == 'ready', 'snapshot readiness')
assert any(o.get('sessionID') == job['sessionID'] for o in request()['objects'])
request('close', sessionID=job['sessionID'])
wait(lambda: not any(o.get('sessionID') == job['sessionID'] for o in request()['objects']), 'snapshot close')
finish(primary)
print('PASS service-first, single primary, remote cwd/raw paths/URI, dirty close, reopen, snapshot, held native quit', flush=True)

# GLib erhält -- vor Bindestrich-Dateinamen. Nur den Optionsseparator entfernen.
primary = subprocess.Popen([str(APP), '--local-control-service'])
runtime = started()['runtimeID']
assert count(0)['held']
# Dieser Fall muss vor Existenz einer echten Datei -- laufen.
normal = files / 'normal.txt'
normal.write_text('NORMAL BEFORE SEPARATOR\n')
leading = files / '--leading.txt'
leading.write_text('ESCAPED FILE --leading.txt\n')
remote('normal.txt', '--', '--leading.txt', cwd=files)
def mixed_paths_loaded():
    current = count(1)
    documents = [d for w in current['windows'] for d in w['documents']]
    return all(any(d['pathBytes'] == list(os.fsencode(path)) and d['text'] == path.read_text()
                   for d in documents) for path in [normal, leading])
wait(mixed_paths_loaded, 'normal and escaped paths in mixed argument list')
inventory(1, runtime)
for number, name in enumerate(['--leading.txt', '--'], 2):
    target = files / name
    contents = 'ESCAPED FILE ' + name + '\n'
    target.write_text(contents)
    remote('--', name, cwd=files)
    def escaped_loaded():
        current = count(number)
        return current if any(d['pathBytes'] == list(os.fsencode(target)) and d['text'] == contents
                              for w in current['windows'] for d in w['documents']) else None
    wait(escaped_loaded, 'escaped filename ' + name)
    inventory(number, runtime)
finish(primary)
print('PASS option separator and literal double-dash filename', flush=True)

# GUI zuerst; CLI erfindet weder ein Fenster noch einen anderen Controller.
primary = subprocess.Popen([str(APP)])
runtime = started()['runtimeID']
assert not count(1)['held']
assert request()['runtimeID'] == runtime
assert not count(1)['held']
remote('--local-control-service')
wait(lambda: state()['held'], 'service hold after remote call')
assert count(1)['held']
inventory(1, runtime)
finish(primary)
print('PASS GUI-first, CLI inventory, remote service without extra window', flush=True)

# Ohne Diensthalterung beendet das letzte geschlossene Fenster die Anwendung.
primary = subprocess.Popen([str(APP)])
started()
count(1)
close(window_ids(primary.pid)[0])
assert primary.wait(10) == 0
wait(lambda: not SOCKET.exists(), 'ordinary shutdown cleanup')
(ROOT / 'shutdown.json').unlink()
(ROOT / 'state.json').unlink(missing_ok=True)
print('PASS ordinary last-window shutdown', flush=True)

# Nur Geschwisterbinaries sind eingehängt; CLI startet ohne Quellbaum.
reply = request(launch=True)
assert reply['objects'] == []
assert count(0)['held']
remote()
count(1)
inventory(1, reply['runtimeID'])
finish()
_, status = wait(lambda: (lambda pair: pair if pair[0] else None)(os.waitpid(-1, os.WNOHANG)), 'autolaunched process exit')
assert os.waitstatus_to_exitcode(status) == 0
print('PASS source-free sibling CLI autolaunch and later GUI', flush=True)

# Ein nicht nutzbarer Controller darf keinen unsichtbaren Dienst dauerhaft halten.
invalid_runtime = ROOT / 'invalid-runtime'
invalid_runtime.mkdir(mode=0o755)
invalid_runtime.chmod(0o755)
invalid_state = ROOT / 'invalid-runtime-state'
invalid_state.mkdir()
invalid_env = os.environ.copy()
invalid_env['XDG_RUNTIME_DIR'] = str(invalid_runtime)
invalid_env['FASTRA_LIFECYCLE_SELFTEST_DIR'] = str(invalid_state)
failed_service = subprocess.run([str(APP), '--local-control-service'], env=invalid_env,
                                capture_output=True, timeout=10)
assert failed_service.returncode != 0, failed_service
assert not (invalid_runtime / SOCKET.name).exists()
print('PASS failed controller startup exits without service hold', flush=True)
