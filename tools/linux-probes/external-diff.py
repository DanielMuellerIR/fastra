#!/usr/bin/env python3
"""Echter Helfervertrag; ausschließlich innerhalb der privaten Xvfb-/D-Bus-Sitzung des Runners."""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import shlex
import shutil
import subprocess
import time
import uuid

BUS = 'org.fastra.Fastra.Development'
PATH = '/org/fastra/Fastra/Development/Diff'
INTERFACE = 'org.fastra.Diff1.Deliver'


def run(arguments, **kwargs):
    return subprocess.run([str(a) for a in arguments], capture_output=True, timeout=15, **kwargs)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--bin-dir', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--peer', type=Path, required=True)
    options = parser.parse_args()
    assert os.environ.get('FASTRA_EXTERNAL_DIFF_PRIVATE_SESSION') == '1'
    directory = options.output.resolve()
    binary = options.bin_dir.resolve()
    helper = binary / 'fastra-diff'
    left, right = directory / '-ä left.txt', directory / '右 right.txt'
    left.write_text('one\ncafé 😀\nold\n')
    right.write_text('one\ncafé 😀\nnew\n')
    originals = [p.read_bytes() for p in (left, right)]
    results = []

    def check(arguments, code=0, executable=helper):
        result = run([executable, *arguments])
        assert result.returncode == code, (arguments, result.returncode, result.stderr)
        if code:
            assert not result.stdout and result.stderr.count(b'\n') == 1, result
            assert result.stderr.startswith(b'fastra-diff: '), result.stderr
        elif arguments != ['--capabilities', '--json']:
            assert not result.stdout and not result.stderr, result
        return result

    def windows():
        result = run(['xdotool', 'search', '--onlyvisible', '--name', '^Diff: '])
        return result.stdout.decode().split()

    def wait_windows(number):
        deadline = time.monotonic() + 4
        while time.monotonic() < deadline:
            values = windows()
            if len(values) == number:
                return values
            time.sleep(.025)
        raise AssertionError(('window count', number, windows()))

    def stop_application():
        result = run(['gdbus', 'call', '--session', '--dest', 'org.freedesktop.DBus',
                      '--object-path', '/org/freedesktop/DBus', '--method',
                      'org.freedesktop.DBus.GetConnectionUnixProcessID', BUS])
        match = re.search(rb'uint32 (\d+)', result.stdout)
        if not match:
            return
        pid = int(match.group(1))
        assert Path(f'/proc/{pid}/exe').resolve() == binary / 'fastra-linux'
        os.kill(pid, signal.SIGTERM)
        for _ in range(100):
            if not Path(f'/proc/{pid}/exe').exists():
                return
            time.sleep(.02)
        assert Path(f'/proc/{pid}/exe').resolve() == binary / 'fastra-linux'
        os.kill(pid, signal.SIGKILL)

    def request(**changes):
        value = dict(version=1, id=str(uuid.uuid4()), deadline=time.time()+10,
                     leftPath=str(left), rightPath=str(right), leftLabel='Original α',
                     rightLabel='Modified β', readOnly=True, focusDiff=False)
        value.update(changes)
        return value

    def deliver(value):
        result = run(['gdbus', 'call', '--session', '--dest', BUS, '--object-path', PATH,
                      '--method', INTERFACE, json.dumps(value, ensure_ascii=False)])
        assert result.returncode == 0, result.stderr
        match = re.fullmatch(rb'\((\d+),\)\n', result.stdout)
        assert match, result.stdout
        return int(match.group(1))

    arguments = ['--left-label', 'Links α', '--right-label', '--Literal', '--', str(left), str(right)]
    try:
        capabilities = check(['--capabilities', '--json'])
        assert json.loads(capabilities.stdout) == dict(protocol=1, fileDiff=True, readOnly=True,
              focusDiff=True, labels=True, existingInstanceIpc=True)
        check(['--', str(left)], 2)
        check(['--unsupported', '--', str(left), str(right)], 4)
        check(['--', str(directory/'missing'), str(right)], 3)
        fifo = directory/'fifo'
        os.mkfifo(fifo)
        check(['--', str(fifo), str(right)], 3)
        check(['--left-label', 'a'*65536, '--', str(left), str(right)], 2)
        results.append('capabilities, arguments, unsupported, missing, FIFO and oversized request')
        check(arguments)
        first = wait_windows(1)[0]
        time.sleep(.5)
        run(['xdotool', 'windowsize', '--sync', first, os.environ.get('FASTRA_TOOL_WIDTH', '1080'), '780'], check=True)
        run(['import', '-silent', '-window', first, directory/'comparison.png'], check=True)
        run(['xdotool', 'windowfocus', '--sync', first], check=True)
        run(['xdotool', 'key', '--clearmodifiers', 'ctrl+s', 'ctrl+shift+s'], check=True)
        assert [p.read_bytes() for p in (left,right)] == originals
        wait_windows(1)
        check(['--focus-diff', '--', str(left), str(right)])
        wait_windows(2)
        results.append('cold start, default readonly, labels, Save/SaveAs keyboard and second existing-instance request')
        value=request()
        assert deliver(value)==0
        count=len(wait_windows(3))
        assert deliver(value)==0
        upper=dict(value,id=value['id'].upper())
        assert deliver(upper)==0
        assert len(windows())==count
        assert deliver(dict(value,leftLabel='changed'))==6
        assert len(windows())==count
        for patch,code in [({'deadline':time.time()-1},6),({'deadline':time.time()+20},6),
                           ({'version':2},4),({'extra':True},4),({'rightPath':str(fifo)},3)]:
            candidate=request();candidate.update(patch)
            assert deliver(candidate)==code,(patch,code)
        assert len(windows())==count
        results.append('UUID idempotence including case, mismatched retry, deadlines, strict fields, version and FIFO rejection')
        stop_application()
        wait_windows(0)
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            list(pool.map(lambda _:check(arguments),range(4)))
        wait_windows(4)
        assert [p.read_bytes() for p in (left,right)] == originals
        results.append('four simultaneous cold calls, exactly four readonly windows, unchanged input bytes')
        stop_application()
        wait_windows(0)
        bundle = directory / 'deadline-bundle'
        bundle.mkdir()
        probe_helper = bundle / 'fastra-diff'
        shutil.copyfile(helper, probe_helper)
        probe_helper.chmod(0o755)
        marker = bundle / 'unexpected-app-start'
        app_stub = bundle / 'fastra-linux'
        app_stub.write_text('#!/bin/sh\nprintf started > ' + shlex.quote(str(marker)) + '\n')
        app_stub.chmod(0o755)
        for reply_code in (99, 999):
            with (directory / f'peer-{reply_code}.log').open('w') as log:
                peer = subprocess.Popen([str(options.peer), str(reply_code)], stdout=log, stderr=subprocess.STDOUT)
                try:
                    deadline = time.monotonic()+3
                    while 'READY' not in (directory / f'peer-{reply_code}.log').read_text():
                        assert peer.poll() is None
                        assert time.monotonic() < deadline
                        time.sleep(.02)
                    started = time.monotonic()
                    check(['--', str(left), str(right)], 6, executable=probe_helper)
                    elapsed = time.monotonic()-started
                    assert not marker.exists(), 'An existing or expired peer must not cause a fallback app start'
                    if reply_code == 999:
                        assert 9 <= elapsed <= 12.5, elapsed
                finally:
                    peer.terminate()
                    peer.wait(timeout=3)
        results.append('foreign reply maps to delivery failure; hanging existing peer times out without any fallback app start')
        report=dict(status='PASS',groups=results,input_sha256=[hashlib.sha256(v).hexdigest() for v in originals],
                    app_sha256=hashlib.sha256((binary/'fastra-linux').read_bytes()).hexdigest(),
                    helper_sha256=hashlib.sha256(helper.read_bytes()).hexdigest(),
                    boundary='Private Xvfb has no window manager; actual compositor focus policy is a separate acceptance gate.')
        (directory/'result.json').write_text(json.dumps(report,indent=2)+'\n')
        print('PASS external diff: '+ '; '.join(results),flush=True)
    finally:
        stop_application()


if __name__ == '__main__':
    main()
