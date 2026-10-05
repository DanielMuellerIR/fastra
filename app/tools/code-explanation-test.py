"""Playerprüfung im bereits geschützten Controlhost; keine eigene App starten."""
import hashlib
import json
import os
from pathlib import Path
import time
import uuid


def capture_images(base, visual, language, stage, timeout=5):
    token = stage + '-' + str(uuid.uuid4())
    files = [visual / f'{token}.{language}.{width}.png' for width in (400, 900)]
    temporary = base / 'host-capture.tmp'
    temporary.write_text(token)
    temporary.replace(base / 'host-capture')
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            marker = (base / 'host-captured').read_text()
            if f'token={token} ' in marker:
                assert marker.startswith('PASS '), marker
                assert all(path.is_file() and path.read_bytes().startswith(b'\x89PNG\r\n\x1a\n') for path in files), 'fresh screenshot pair missing'
                return files
        except FileNotFoundError:
            pass
        time.sleep(.03)
    raise AssertionError('matching screenshot confirmation missing: ' + token)


def verify(base, cli, ae, ready, cli_only, visual):
    def request(operation, **fields):
        return dict(version=1, id=str(uuid.uuid4()), deadline=time.time()+10, operation=operation, **fields)

    artifact = Path(os.environ.get('FASTRA_CONTROL_EXPLANATION_PACKAGE', str(base / 'explanation-package')))
    artifact.mkdir(parents=True, exist_ok=True)
    manifest = artifact / 'explanation.json'
    if not manifest.exists():
        texts = ['func load() {\n    validate()\n}\n', 'func validate() -> Bool {\n    return true\n}\n']
        sources, steps = [], []
        for index, text in enumerate(texts):
            filename = f'source{index}.swift'
            raw = text.encode('utf-8'); (artifact / filename).write_bytes(raw)
            identity = str(uuid.uuid4())
            sources.append(dict(id=identity, path=filename, sha256=hashlib.sha256(raw).hexdigest(), encoding='utf8'))
            steps.append(dict(id=str(uuid.uuid4()), sourceID=identity, title=['Aufruf', 'Prüfung'][index],
                text=['Die Ladefunktion ruft die Prüfung auf. Die Quelle bleibt an ihre gespeicherten Bytes gebunden.',
                      'Die Prüfung liefert in diesem kleinen Beispiel immer true. Die Erklärung ist vorbereitet und braucht beim Wiederöffnen keine KI.'][index],
                location=text.index('validate') if index == 0 else text.index('return'), length=8 if index == 0 else 11))
        manifest.write_text(json.dumps(dict(schemaVersion=1, id=str(uuid.uuid4()), title='Vom Aufruf zur Prüfung',
            question='Wie gelangt die Ladefunktion zur Prüfung?', language='de', createdAt='2026-10-04T18:00:00+02:00',
            projectID=str(uuid.uuid4()), projectName='Lokales Beispiel', sources=sources, steps=steps,
            codeFontSize=13, explanationFontSize=14), ensure_ascii=False), encoding='utf8')
    package = json.loads(manifest.read_text())
    value = request('explanation', path=str(manifest.resolve()))
    accepted = cli(value)
    assert accepted['job']['state'] == 'accepted', accepted
    if not cli_only:
        assert json.loads(ae(value))['job']['id'] == accepted['job']['id']
    job = ready(accepted['job']); assert job['state'] == 'ready', job
    assert job['sha256'] == package['sources'][0]['sha256']
    session = job['sessionID']

    def action(name):
        token = str(uuid.uuid4())
        command = dict(token=token, sessionID=session, action=name)
        temporary = base / 'host-player.tmp'
        temporary.write_text(json.dumps(command)); temporary.replace(base / 'host-player')
        deadline = time.monotonic()+5
        while time.monotonic()<deadline:
            try:
                result = json.loads((base / 'host-player-result').read_text())
                if result.get('token') == token: return result
            except (FileNotFoundError, json.JSONDecodeError): pass
            time.sleep(.02)
        raise AssertionError('native player action did not complete: '+name)

    def settled():
        deadline = time.monotonic()+5
        while time.monotonic()<deadline:
            result = action('report')
            if result['state'] != 'loadingStep': return result
            time.sleep(.02)
        raise AssertionError('player never completed step')

    def capture(stage):
        if visual:
            capture_images(base, Path(visual), os.environ.get('FASTRA_CONTROL_TEST_LANGUAGE'), stage)

    first = settled(); assert first['step'] == 0 and first['state'] == 'ready' and not first['editable'], first
    capture('explanation-ready')
    initial = action('report')
    unwrapped = action('wrap'); assert not unwrapped['wrapped'] and unwrapped['horizontalScroller'], unwrapped
    wrapped = action('wrap'); assert wrapped['wrapped'] and not wrapped['horizontalScroller'], wrapped
    grown = action('grow')
    assert grown['explanationHeight'] >= initial['explanationHeight'] + 140, (initial, grown)
    assert abs(grown['codeHeight'] - initial['codeHeight']) < 2, (initial, grown)
    split = action('split')
    assert split['explanationHeight'] >= grown['explanationHeight'] + 45, (grown, split)
    assert split['content'] == initial['content'] and split['selectionLocation'] == initial['selectionLocation'], split
    capture('explanation-expanded')
    action('next'); second = settled()
    assert second['step'] == 1 and second['state'] == 'completed' and second['documentID'] != first['documentID'], second
    action('previous'); back = settled(); assert back['documentID'] == first['documentID']
    action('fonts'); fonts=settled()
    assert fonts['codeFontSize'] == 14 and fonts['explanationFontSize'] == 13 and fonts['state'] == 'paused', fonts
    action('explore'); explored=settled()
    assert explored['state'] == 'paused' and explored['selectionLocation'] == 0 and explored['selectionLength'] == 0
    time.sleep(.15); assert action('report')['selectionLocation'] == 0
    capture('explanation-paused')
    action('return'); returned=settled()
    assert returned['selectionLocation'] == package['steps'][0]['location'], returned
    action('next'); action('pause'); assert settled()['state'] == 'paused'
    action('return'); assert settled()['state'] == 'completed'
    action('end'); assert action_after_close(cli, request, session)

    previous = artifact / 'previous-runtime.json'
    runtime = cli(request('capabilities'))['runtimeID']
    if previous.exists():
        old=json.loads(previous.read_text())
        assert old['runtimeID'] != runtime, 'reopening must use a restarted host'
        assert cli(request('status', jobID=old['jobID']))['error']['code'] == 'invalidID'
        print('PASS: saved package reopened after real app-process restart without AI/checkout; old runtime job invalid')
    previous.write_text(json.dumps(dict(runtimeID=runtime,jobID=job['id'])))

    bad = artifact / 'bad.json'
    bad_package = dict(package, title='Invalid schema', schemaVersion=999)
    bad.write_text(json.dumps(bad_package))
    failed=ready(cli(request('explanation', path=str(bad.resolve())))['job'])
    assert failed['state']=='failed' and failed['error']['code']=='invalidRequest', failed
    capture('explanation-error')
    cli(request('close',sessionID=failed['sessionID']))
    print('PASS: native Back/Next/Pause/Return/End, frozen sources/document IDs, separate local fonts, exploration and invalid package')


def action_after_close(cli, request, session):
    return cli(request('close', sessionID=session))['error']['code']=='invalidID'
