#!/usr/bin/python3
"""Appfreie Menüroot-Prüfungen; Frameworks und echter AX-Input bleiben unbenutzt."""
import ctypes
import importlib.util
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
import uuid

sys.dont_write_bytecode = True
SENDER = Path(__file__).resolve().parents[1] / 'selftest-menu-root.py'
APP_DIRECTORY = SENDER.parent.parent
spec = importlib.util.spec_from_file_location('menu_root', SENDER)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def binding():
    return dict(version=1, test='multisearch', runNonce=str(uuid.uuid4()), runnerPid=101,
                runnerToken='runner start', appPid=102, appToken='app start', appExe='/bin/echo',
                senderPid=103, senderToken='sender start', senderExe='/bin/echo', senderScript=os.path.realpath('/tmp/sender.py'))


def request(bound):
    return {key: bound[key] for key in ('version', 'test', 'runNonce', 'appPid')} | dict(
        nonce=str(uuid.uuid4()), rootTitle='Datei')


class FakeAX:
    def __init__(self):
        self.trust = True
        self.foreground = 102
        self.root = object()
        self.reason = None
        self.error = 0
        self.calls = []
        self.on_press = lambda: None

    def trusted(self):
        return self.trust

    def focused_pid(self):
        return self.foreground

    def resolve(self, pid, title):
        return self.root, self.reason

    def press(self, root):
        self.calls.append(root)
        self.on_press()
        return self.error


@unittest.skipUnless(sys.platform == 'darwin', 'macOS process arguments required')
class ProcessArgumentTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='menu root argv-', dir='/tmp')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.script = self.root / 'sender with spaces.py'
        self.script.write_text('#!/usr/bin/python3\nimport pathlib, sys, time\n'
                               'pathlib.Path(sys.argv[1]).touch()\ntime.sleep(30)\n')
        self.arguments = ['/usr/bin/python3', str(self.script), str(self.root / 'child ready'),
                          'argument with spaces', 'literal \'"\\ characters', '']
        self.child = subprocess.Popen(self.arguments, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(self.stop_child)
        for _ in range(200):
            if (self.root / 'child ready').exists():
                break
            if self.child.poll() is not None:
                self.fail('own argument fixture exited before readiness')
            time.sleep(.005)
        else:
            self.fail('own argument fixture readiness missing')
        self.child_token = m.token(self.child.pid)
        self.own_pid = os.getpid()
        self.own_token = m.token(self.own_pid)
        self.own_exe = m.executable(self.own_pid)

    def stop_child(self):
        if self.child.poll() is None:
            self.child.terminate()
        self.child.wait(timeout=5)

    def runner_fragment(self, marker, arguments):
        source = (APP_DIRECTORY / 'selftest.sh').read_text()
        code = source.split("<<'" + marker + "'\n", 1)[1].split('\n' + marker + '\n', 1)[0]
        # Die echten Runnerprüfungen laufen mit eigenen Prozessen, ohne AX oder App.
        return subprocess.run(['/usr/bin/python3', '-c', code] + list(map(str, arguments)),
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5).returncode

    def test_native_argv_preserves_boundaries_and_rejects_exited_pid(self):
        actual = m.process_argv(self.child.pid)
        # Apples /usr/bin/python3 startet den Framework-Interpreter mit neuem argv[0].
        self.assertTrue(os.path.realpath(actual[0]) == m.executable(self.child.pid), 'interpreter argv mismatch')
        self.assertTrue(actual[1:] == self.arguments[1:], 'script/argument boundaries changed')
        self.stop_child()
        with self.assertRaises(ValueError):
            m.process_argv(self.child.pid)

    def test_empty_argv0_preserves_boundaries_without_consuming_environment(self):
        code = r'''import ctypes, os, sys
library = ctypes.CDLL(None)
library.execve.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_char_p), ctypes.POINTER(ctypes.c_char_p)]
library.execve.restype = ctypes.c_int
arguments = (ctypes.c_char_p * 3)(b'', b'30', None)
environment = (ctypes.c_char_p * 2)(os.fsencode(sys.argv[2]), None)
library.execve(os.fsencode(sys.argv[1]), arguments, environment)
raise SystemExit(99)
'''
        environment_value = 'FASTRA_MENU_ARGV_FIXTURE=' + str(uuid.uuid4())
        # Acht Pfadlängen belegen jede Paddinglänge des echten 64-Bit-Darwin-Layouts.
        for suffix in range(8):
            with self.subTest(path_length=suffix):
                executable = self.root / ('sleep-' + 'x' * suffix)
                executable.symlink_to('/bin/sleep')
                child = subprocess.Popen(['/usr/bin/python3', '-c', code, str(executable), environment_value],
                                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                try:
                    for _ in range(200):
                        if child.poll() is not None:
                            self.fail('own empty-argv fixture exited before readiness')
                        if m.executable(child.pid) == os.path.realpath('/bin/sleep'):
                            break
                        time.sleep(.005)
                    else:
                        self.fail('own empty-argv fixture readiness missing')
                    actual = m.process_argv(child.pid)
                    self.assertTrue(actual == ['', '30'], 'empty argv[0] or argument boundaries changed')
                    self.assertTrue(all(environment_value not in argument for argument in actual),
                                    'process environment consumed as an argument')
                finally:
                    if child.poll() is None:
                        child.terminate()
                    child.wait(timeout=5)

    def test_fake_app_requires_its_exact_script_and_real_interpreter(self):
        arguments = [self.child.pid, self.script, '1', SENDER]
        self.assertEqual(self.runner_fragment('PYIDENTITY', arguments), 0)
        foreign = self.root / 'foreign script.py'
        foreign.write_text(self.script.read_text())
        self.assertNotEqual(self.runner_fragment('PYIDENTITY', [self.child.pid, foreign, '1', SENDER]), 0)
        self.assertNotEqual(self.runner_fragment('PYIDENTITY', [self.child.pid, self.script, '0', SENDER]), 0)
        # Ein passender Skriptname allein macht einen anderen Interpreter nicht gültig.
        foreign_process = subprocess.Popen(['/bin/sleep', '30'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            self.assertNotEqual(self.runner_fragment('PYIDENTITY', [foreign_process.pid, self.script, '1', SENDER]), 0)
            self.assertIsNone(foreign_process.poll())
        finally:
            foreign_process.terminate()
            foreign_process.wait(timeout=5)

    def test_sender_start_and_completion_keep_script_token_and_executable_guards(self):
        exchange = self.root / 'exchange'
        exchange.mkdir(mode=0o700)
        directory = m.PrivateDirectory(exchange)
        self.addCleanup(directory.close)
        ready = dict(senderPid=self.child.pid, senderToken=self.child_token,
                     senderExe=m.executable(self.child.pid), senderScript=os.path.realpath(self.script))
        directory.write('ready.json', ready)
        arguments = [SENDER, exchange, 'multisearch', self.own_pid, self.own_token,
                     self.own_pid, self.own_token, self.own_exe, self.child.pid,
                     self.child_token, self.script]
        self.assertEqual(self.runner_fragment('PYBIND', arguments), 0)
        bound = directory.read('binding.json')
        self.assertEqual(self.runner_fragment('PYSENDERSTATE', [SENDER, exchange]), 0)
        for change in ({'senderScript': str(self.root / 'foreign script.py')},
                       {'senderToken': 'foreign start'}, {'senderExe': os.path.realpath('/bin/sleep')}):
            with self.subTest(guard=next(iter(change))):
                directory.write('binding.json', bound | change)
                self.assertNotEqual(self.runner_fragment('PYSENDERSTATE', [SENDER, exchange]), 0)
                directory.write('ready.json', ready | change)
                changed_arguments = arguments.copy()
                if 'senderScript' in change:
                    changed_arguments[-1] = change['senderScript']
                self.assertNotEqual(self.runner_fragment('PYBIND', changed_arguments), 0)
                self.assertIsNone(self.child.poll())
        directory.write('binding.json', bound)
        self.stop_child()
        self.assertNotEqual(self.runner_fragment('PYSENDERSTATE', [SENDER, exchange]), 0)


class RequestTests(unittest.TestCase):
    def test_start_token_preserves_existing_shell_contract(self):
        with mock.patch.object(m.subprocess, 'check_output', return_value='  Sun Nov 15 10:25:41 2026    \n'):
            self.assertEqual(m.token(123), 'Sun Nov 15 10:25:41 2026    ')

    def test_positive_and_duplicate(self):
        bound, ax = binding(), FakeAX()
        processor = m.RequestProcessor(bound, ax, lambda _: True)
        req = request(bound)
        # Reentranz unmittelbar vor C-Rückkehr darf keine zweite Wirkung erzeugen.
        ax.on_press = lambda: self.assertIsNone(processor.process(req))
        result = processor.process(req)
        self.assertEqual((result['phase'], result['axError']), ('actionReturned', 0))
        self.assertEqual(result['binding'], bound)
        self.assertEqual(len(ax.calls), 1)
        self.assertIsNone(processor.process(req))
        self.assertEqual(len(ax.calls), 1)

    def test_cannot_complete_is_failure_and_not_retried(self):
        bound, ax = binding(), FakeAX()
        ax.error = -25204
        processor = m.RequestProcessor(bound, ax, lambda _: True)
        req = request(bound)
        result = processor.process(req)
        self.assertEqual((result['phase'], result['axError']), ('actionReturned', -25204))
        self.assertNotIn('reason', result)
        self.assertIsNone(processor.process(req))
        self.assertEqual(len(ax.calls), 1)

    def test_all_preinput_guards_have_zero_input(self):
        for mode in ('trust', 'foreground', 'identity', 'second-identity', 'second-foreground',
                     'rootNotUnique', 'pressUnsupported', 'actionNamesUnavailable'):
            with self.subTest(mode=mode):
                bound, ax = binding(), FakeAX()
                checks = []
                def identity(_):
                    checks.append(True)
                    return mode != 'identity' and (mode != 'second-identity' or len(checks) == 1)
                if mode == 'trust':
                    ax.trust = False
                if mode == 'foreground':
                    ax.foreground = 999
                if mode == 'second-foreground':
                    focus = iter((102, 999))
                    ax.focused_pid = lambda: next(focus)
                if mode in ('rootNotUnique', 'pressUnsupported', 'actionNamesUnavailable'):
                    ax.root, ax.reason = None, mode
                processor = m.RequestProcessor(bound, ax, identity)
                req = request(bound)
                result = processor.process(req)
                self.assertEqual(result['phase'], 'preInputEnvironment')
                self.assertNotIn('axError', result)
                self.assertEqual(ax.calls, [])
                self.assertIsNone(processor.process(req))

    def test_identity_checks_each_token_and_executable(self):
        bound = binding()
        tokens = {bound[role + 'Pid']: bound[role + 'Token'] for role in ('runner', 'app', 'sender')}
        exes = {bound[role + 'Pid']: bound[role + 'Exe'] for role in ('app', 'sender')}
        self.assertTrue(m.identities_match(bound, tokens.__getitem__, exes.__getitem__))
        for role in ('runner', 'app', 'sender'):
            wrong = dict(tokens, **{})
            wrong[bound[role + 'Pid']] = 'reused pid'
            self.assertFalse(m.identities_match(bound, wrong.__getitem__, exes.__getitem__))
        for role in ('app', 'sender'):
            wrong = dict(exes)
            wrong[bound[role + 'Pid']] = '/bin/false'
            self.assertFalse(m.identities_match(bound, tokens.__getitem__, wrong.__getitem__))

    def test_malformed_requests_and_binding_have_zero_input(self):
        for key in ('version', 'test', 'runNonce', 'appPid', 'nonce', 'rootTitle'):
            bound, ax = binding(), FakeAX()
            processor = m.RequestProcessor(bound, ax, lambda _: True)
            for value in (None, True, [], {}, 999, ''):
                req = request(bound)
                req[key] = value
                with self.subTest(key=key, value=value), self.assertRaises((ValueError, TypeError, AttributeError)):
                    processor.process(req)
                self.assertEqual(ax.calls, [])
        for change in ({'version': 2}, {'test': 'search'}, {'appPid': True}, {'appExe': '/tmp/../bin/echo'}):
            with self.assertRaises((ValueError, TypeError)):
                m.valid_binding(binding() | change)
        with self.assertRaises(ValueError):
            m.strict_json('{"nonce":"old","nonce":"new"}')

    def test_native_resolution_contract_without_loading_frameworks(self):
        # NativeAX.resolve selbst läuft mit einer internen Datenattrappe. Damit
        # bleiben Eindeutigkeit, direkte Kinder, Rolle, PID und AXPress testbar.
        for mode in ('valid', 'wrong-role', 'wrong-title', 'wrong-pid', 'duplicate', 'nested', 'unsupported'):
            with self.subTest(mode=mode):
                root = dict(role='AXMenuBarItem', title='Datei', pid=102)
                if mode == 'wrong-role': root['role'] = 'AXMenuItem'
                if mode == 'wrong-title': root['title'] = 'Bearbeiten'
                if mode == 'wrong-pid': root['pid'] = 999
                children = [root, root] if mode == 'duplicate' else [root]
                if mode == 'nested': children = [dict(role='AXMenuItem', children=[root])]
                native = object.__new__(m.NativeAX)
                class API:
                    def AXUIElementCreateApplication(self, pid): return {'menu': {'children': children}}
                    def AXUIElementCopyActionNames(self, element, output):
                        ctypes.cast(output, ctypes.POINTER(ctypes.c_void_p))[0] = ctypes.c_void_p(1)
                        return 0
                native.ax = API()
                native.keep = lambda value: value
                native.attribute = lambda element, name: element.get({
                    'AXMenuBar': 'menu', 'AXChildren': 'children', 'AXRole': 'role', 'AXTitle': 'title'}[name])
                native.text = lambda value: value
                native.pid = lambda element: element.get('pid')
                native.array = lambda value: ([] if mode == 'unsupported' else ['AXPress']) if value == 1 else (value or [])
                result, reason = native.resolve(102, 'Datei')
                self.assertEqual(result is not None, mode == 'valid')
                if mode != 'valid': self.assertIsNotNone(reason)

    def test_private_directory_modes_symlinks_replacement_and_stale_data(self):
        with tempfile.TemporaryDirectory(prefix='menu-root-unit-', dir='/tmp') as root:
            os.chmod(root, 0o700)
            directory = m.PrivateDirectory(root)
            try:
                directory.write('reply.json', {'nonce': 'old'})
                self.assertEqual(directory.read('reply.json'), {'nonce': 'old'})
                directory.write('reply.json', {'nonce': 'current'})
                self.assertEqual(directory.read('reply.json'), {'nonce': 'current'})
                self.assertEqual(stat.S_IMODE(os.stat(root + '/reply.json').st_mode), 0o600)
                os.chmod(root + '/reply.json', 0o644)
                with self.assertRaises(ValueError): directory.read('reply.json')
                os.unlink(root + '/reply.json')
                os.symlink('/etc/passwd', root + '/reply.json')
                with self.assertRaises(OSError): directory.read('reply.json')
                os.chmod(root, 0o755)
                with self.assertRaises(ValueError): directory.check()
                with self.assertRaises(ValueError): m.PrivateDirectory(root)
                os.chmod(root, 0o700)
                os.symlink(root, root + '/link')
                with self.assertRaises(OSError): m.PrivateDirectory(root + '/link')
                moved = root + '-old'
                os.rename(root, moved)
                os.mkdir(root, 0o700)
                try:
                    with self.assertRaises(ValueError): directory.write('reply.json', {})
                finally:
                    os.rmdir(root)
                    os.rename(moved, root)
            finally:
                directory.close()

    def test_default_alarm_terminates_real_blocking_ctypes(self):
        # Der echte main-Pfad setzt die Frist. Nur AX wird intern ersetzt;
        # ein Entfernen des Alarms im Sender muss diesen Test rot machen.
        code = r'''import ctypes, importlib.util, os, pathlib, sys
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('menu_root', sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
class BlockingAX:
    def trusted(self): return True
    def focused_pid(self): return int(sys.argv[6])
    def resolve(self, pid, title): return object(), None
    def press(self, root):
        pathlib.Path(sys.argv[2], 'blocked').touch(mode=0o600)
        libc = ctypes.CDLL(None)
        libc.sleep.argtypes = [ctypes.c_uint]
        libc.sleep(30)
        return 0
    def close(self): pass
m.NativeAX = BlockingAX
raise SystemExit(m.main(sys.argv[2:]))
'''
        with tempfile.TemporaryDirectory(prefix='menu-root-alarm-', dir='/tmp') as root:
            os.chmod(root, 0o700)
            directory = m.PrivateDirectory(root)
            own_pid = os.getpid()
            arguments = [root, 'multisearch', str(own_pid), m.token(own_pid),
                         str(own_pid), m.token(own_pid), m.executable(own_pid), '1']
            started = time.monotonic()
            child = subprocess.Popen(['/usr/bin/python3', '-c', code, str(SENDER)] + arguments,
                                     stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
            try:
                for _ in range(100):
                    try:
                        ready = directory.read('ready.json')
                        break
                    except FileNotFoundError:
                        time.sleep(.005)
                else:
                    self.fail('sender readiness missing')
                bound = dict(ready, version=1, test='multisearch', runNonce=str(uuid.uuid4()),
                             runnerPid=own_pid, runnerToken=m.token(own_pid), appPid=own_pid,
                             appToken=m.token(own_pid), appExe=m.executable(own_pid))
                directory.write('binding.json', bound)
                directory.write('request.json', request(bound))
                _, output = child.communicate(timeout=4)
                self.assertEqual(child.returncode, -signal.SIGALRM, output)
                self.assertTrue(Path(root, 'blocked').exists(), output)
                self.assertFalse(Path(root, 'reply.json').exists(), 'blocked C action claimed return')
                self.assertLess(time.monotonic() - started, 4)
            finally:
                directory.close()
                if child.poll() is None:
                    child.kill()
                    child.wait()


FAKE_APP_C = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv) {
  const char *mode = getenv("FASTRA_TEST_MENU_MODE");
  FILE *f = fopen(getenv("FASTRA_TEST_MENU_PIDS"), "a");
  fprintf(f, "app %d\n", getpid()); fclose(f);
  if (!strcmp(mode, "early-fail")) {
    fprintf(stderr, "SELFTEST-RESULT v=1 test=multisearch status=FAIL\nSELFTEST multisearch: FAIL independent product assertion\n");
    fflush(stderr); return 17;
  }
  if (!strcmp(mode, "default-independent")) {
    fprintf(stderr, "SELFTEST-RESULT v=1 test=search status=PASS\nSELFTEST search: PASS fixture\n");
    fflush(stderr); for (;;) sleep(1);
  }
  char path[4096]; snprintf(path, sizeof(path), "%s/.fixture-bound", getenv("FASTRA_SELFTEST_MENU_ROOT_DIR"));
  for (int i=0; i<500 && access(path, F_OK); ++i) usleep(10000);
  if (access(path, F_OK)) return 97;
  if (!strncmp(mode, "app-dies", 8)) return 17;
  if (!strcmp(mode, "app-identity")) { execl("/bin/sleep", argv[0], "30", NULL); return 98; }
  const char *test = getenv("FASTRA_SELFTEST");
  if (!test) test = argv[2];
  fprintf(stderr, "SELFTEST-RESULT v=1 test=%s status=PASS\nSELFTEST %s: PASS fixture\n", test, test);
  fflush(stderr);
  for (;;) sleep(1);
}
'''
FAKE_SENDER = r'''#!/usr/bin/python3
import importlib.util, json, os, signal, subprocess, sys, time
from pathlib import Path
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('menu_root', os.environ['FASTRA_TEST_MENU_REAL_SENDER'])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
mode = os.environ['FASTRA_TEST_MENU_MODE']
pids = Path(os.environ['FASTRA_TEST_MENU_PIDS'])
with pids.open('a') as f: f.write('sender %d\n' % os.getpid())
if mode == 'term-start':
    marker = Path(os.environ['FASTRA_TEST_MENU_BOOKING'])
    while not marker.exists(): time.sleep(.01)
    os.kill(int(sys.argv[3]), signal.SIGTERM)
    Path(os.environ['FASTRA_TEST_MENU_FIRED']).touch()
    while True: time.sleep(.05)
for _ in range(100):
    if pids.exists() and any(line.startswith('app ') for line in pids.read_text().splitlines()): break
    time.sleep(.01)
else: raise AssertionError('fake app did not start')
directory = m.PrivateDirectory(sys.argv[1])
ready = dict(senderPid=os.getpid(), senderToken=m.token(os.getpid()), senderExe=m.executable(os.getpid()),
             senderScript=os.path.realpath(__file__))
if mode == 'sender-identity': ready['senderToken'] = 'reused start'
directory.write('ready.json', ready)
while True:
    try: binding = directory.read('binding.json'); break
    except FileNotFoundError: time.sleep(.01)
assert binding['senderPid'] == os.getpid()
assert m.identities_match(binding)
if mode == 'sender-hangs':
    def term(*_):
        with open(os.environ['FASTRA_TEST_MENU_SIGNALS'], 'a') as f: f.write('TERM\n')
    signal.signal(signal.SIGTERM, term)
    child_code = "import ctypes,os,pathlib,signal,sys; signal.signal(signal.SIGTERM, signal.SIG_IGN); f=open(sys.argv[1],'a'); f.write('child %d\\n'%os.getpid()); f.close(); pathlib.Path(sys.argv[2]).touch(); ctypes.CDLL(None).sleep(90)"
    child_ready = Path(os.environ['FASTRA_TEST_MENU_CHILD_READY'])
    subprocess.Popen(['/usr/bin/python3', '-c', child_code, str(pids), str(child_ready)])
    while not child_ready.exists(): time.sleep(.01)
reply = dict(version=1, test=binding['test'], runNonce=binding['runNonce'], appPid=binding['appPid'],
             senderPid=os.getpid(), nonce='00000000-0000-4000-8000-000000000001', rootTitle='Datei',
             phase='actionReturned', axError=0, binding=binding)
directory.write('reply.json', reply)
if mode.endswith('cleanup-failure'): Path(os.environ['FASTRA_TEST_MENU_CLEANUP_MARKER']).touch()
Path(sys.argv[1], '.fixture-bound').touch(mode=0o600)
if mode == 'app-identity':
    for _ in range(100):
        if not m.identities_match(binding): break
        time.sleep(.01)
    else: raise AssertionError('app did not change executable')
else:
    with open(os.environ['FASTRA_TEST_MENU_INPUTS'], 'a') as f: f.write('input\n')
if mode == 'sender-exits': raise SystemExit(7)
while True: time.sleep(.05)
'''
FAKE_OPEN = r'''#!/usr/bin/python3
import os, subprocess, sys
arguments = sys.argv[1:]
environment = os.environ.copy()
for index, arg in enumerate(arguments):
    if arg == '--env':
        key, value = arguments[index + 1].split('=', 1)
        environment[key] = value
stderr = open(arguments[arguments.index('--stderr') + 1], 'wb')
app_args = arguments[arguments.index('--args') + 1:]
subprocess.Popen([os.path.realpath(os.environ['FASTRA_SELFTEST_APP_BIN'])] + app_args, env=environment,
                 stdout=subprocess.DEVNULL, stderr=stderr, start_new_session=True)
'''


def runner_case(mode, root):
    root = Path(root)
    sandbox = root / 'sandboxes'
    sandbox.mkdir(exist_ok=True)
    binary = root / 'Fastra.app/Contents/MacOS/Fastra'
    binary.parent.mkdir(parents=True)
    (binary.parent.parent / 'Info.plist').write_text('''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>de.dm0.fastra</string></dict></plist>''')
    source = root / 'fake.c'
    source.write_text(FAKE_APP_C)
    subprocess.run(['/usr/bin/clang', '-O0', str(source), '-o', str(binary)], check=True, capture_output=True)
    fake_sender = root / 'fake-sender.py'
    fake_sender.write_text(FAKE_SENDER)
    fake_open = root / 'open'
    fake_open.write_text(FAKE_OPEN)
    fake_ls = root / 'lsregister'
    fake_ls.write_text('#!/bin/bash\nexit 0\n')
    bin_dir = root / 'bin'
    bin_dir.mkdir(exist_ok=True)
    # Nur die beiden exakten Fremd-App-Abfragen gehören zur Fixturegrenze.
    # Alle Kindprozessabfragen verwenden weiterhin das echte pgrep.
    (bin_dir / 'pgrep').write_text(r'''#!/bin/bash
if [ "$#" -eq 2 ] && [ "$1" = -f ]; then
  case "$2" in
    '/Fastra\.app/Contents/MacOS/Fastra([[:space:]]|$)'|'/[^/]+\.app/Contents/MacOS/Fastra([[:space:]]|$)') exit 1 ;;
  esac
fi
exec /usr/bin/pgrep "$@"
''')
    (bin_dir / 'osascript').write_text('#!/bin/bash\nexit 0\n')
    hook = root / 'pretoken'
    hook.write_text(r'''#!/bin/bash
command=$(/bin/ps -p "$1" -o command=)
case "$command" in
  *fake-sender.py*)
    printf '%s\n' "$1" > "$FASTRA_TEST_MENU_HOOK_PID"
    if [ "$FASTRA_TEST_MENU_MODE" = term-start ]; then
      : > "$FASTRA_TEST_MENU_BOOKING"
      for tick in {1..100}; do
        [ -e "$FASTRA_TEST_MENU_FIRED" ] && exit 0
        /bin/sleep .01
      done
      exit 99
    fi
    for tick in {1..100}; do
      [ -e "$FASTRA_SELFTEST_MENU_ROOT_DIR/ready.json" ] && break
      /bin/sleep .01
    done
    kill -TERM "$PPID" ;;
esac
''')
    for path in (fake_sender, fake_open, fake_ls, hook, bin_dir / 'pgrep', bin_dir / 'osascript'):
        path.chmod(0o755)
    pids, signals = root / 'pids', root / 'signals'
    env = os.environ.copy()
    domain = env.get('FASTRA_SELFTEST_PRODUCT_DEFAULTS_DOMAIN')
    saved = env.get('FASTRA_SELFTEST_PRODUCT_SAVED_STATE_DIR')
    if not domain or not saved:
        raise AssertionError('fixture requires existing throwaway product targets')
    env.update(PATH=str(bin_dir) + ':' + env.get('PATH', '/usr/bin:/bin'),
               FASTRA_SELFTEST_APP_BIN=str(binary), FASTRA_SELFTEST_APP_BUNDLE=str(binary.parents[2]),
               FASTRA_SELFTEST_TEST_CONSOLE_UNLOCKED='1', FASTRA_TEST_LSREGISTER=str(fake_ls),
               FASTRA_TEST_OPEN_COMMAND=str(fake_open), FASTRA_TEST_SANDBOX_PARENT=str(sandbox),
               FASTRA_GUI_LOCK_DIR=str(root / 'gui.lock'), FASTRA_TEST_MENU_MODE=mode,
               FASTRA_TEST_MENU_PIDS=str(pids), FASTRA_TEST_MENU_SIGNALS=str(signals),
               FASTRA_TEST_MENU_REAL_SENDER=str(SENDER), FASTRA_SELFTEST_TEST_MENU_ROOT_SENDER=str(fake_sender),
               FASTRA_TEST_MENU_HOOK_PID=str(root / 'hook-pid'), FASTRA_TEST_MENU_BOOKING=str(root / 'booking'),
               FASTRA_TEST_MENU_FIRED=str(root / 'term-fired'), FASTRA_TEST_MENU_INPUTS=str(root / 'inputs'),
               FASTRA_TEST_MENU_CLEANUP_MARKER=str(root / 'cleanup-marker'), FASTRA_TEST_MENU_CHILD_READY=str(root / 'child-ready'))
    if mode in ('term-start', 'term-adopt'): env['FASTRA_TEST_TRACKED_PID_PRETOKEN_HOOK'] = str(hook)
    if mode.endswith('cleanup-failure'):
        # Die Prozesse werden wirklich beendet; nur der Nachweis ihrer eigenen
        # Gruppe wird nach dem Start unlesbar. Der bestehende Cleanup muss
        # dann geschlossen fehlschlagen und seine Sandbox erhalten.
        ps = bin_dir / 'ps'
        ps.write_text(r'''#!/bin/bash
if [ -e "$FASTRA_TEST_MENU_CLEANUP_MARKER" ] && [[ " $* " == *" -o pgid= "* ]]; then exit 1; fi
exec /bin/ps "$@"
''')
        ps.chmod(0o755)
    test = 'textworkflow' if mode.startswith('app-dies') else 'multisearch'
    tests = [test]
    if mode in ('default-stopped', 'default-denied'):
        tests = ['multisearch', 'softwrapprofiles', 'textworkflow']
    if mode in ('default-stopped', 'default-independent'):
        env.pop('FASTRA_SELFTEST_TEST_MENU_ROOT_SENDER')
    if mode == 'default-independent':
        tests = ['multisearch', 'softwrapprofiles', 'textworkflow', 'search']
    if mode == 'default-denied':
        # Ohne Fixture-Isolation bleibt der bestehende Override-Guard aktiv.
        # Die Ablehnung muss vor Snapshot, Appstart und Senderstart erfolgen.
        for key in ('FASTRA_TEST_SANDBOX_PARENT', 'FASTRA_SELFTEST_PRODUCT_DEFAULTS_DOMAIN',
                    'FASTRA_SELFTEST_PRODUCT_SAVED_STATE_DIR'):
            env.pop(key, None)
    control = subprocess.Popen(['/usr/bin/python3', '-c', 'import time; time.sleep(90)'], start_new_session=True)
    started = time.monotonic()
    process = subprocess.Popen(['/bin/bash', str(APP_DIRECTORY / 'selftest.sh')] + tests, env=env,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        output, _ = process.communicate(timeout=35)
        print(output)
        expected = 0 if mode in ('success', 'sender-hangs') else (1 if mode.startswith('app-dies') or mode in ('app-identity', 'early-fail') else 2)
        if mode in ('term-start', 'term-adopt'):
            assert process.returncode in (2, 143, -signal.SIGTERM), (mode, process.returncode, output)
        else:
            assert process.returncode == expected, (mode, process.returncode, output)
        assert control.poll() is None, 'foreign control process was affected'
        if mode in ('default-stopped', 'default-denied'):
            assert not pids.exists(), 'stopped pilot started app or sender'
            assert not (root / 'inputs').exists(), 'stopped pilot allowed input'
            assert not list(sandbox.iterdir()), 'stopped pilot left sandbox data'
            assert not (root / 'gui.lock').exists()
            if mode == 'default-stopped':
                for stopped in tests:
                    assert output.count(f'SELFTEST-RESULT v=1 test={stopped} status=SKIP\n') == 1
                assert 'PASS: 0 · echte FAILs: 0 · Umgebungs-FAILs: 0 · übersprungen: 3' in output
                assert 'Buchhaltung geht nicht auf' not in output
            else:
                assert 'Menüroot-Sender-Override nur für isolierte Runner-Fixtures.' in output
                assert 'SELFTEST-RESULT' not in output
            print('RUNNER-CASE ' + mode + ' PASS appStarted=false senderStarted=false inputs=0')
            return
        if mode == 'default-independent':
            assert pids.read_text().count('app ') == 1
            assert 'sender ' not in pids.read_text()
            assert 'SELFTEST-RESULT v=1 test=search status=PASS' in output
            assert 'PASS: 1 · echte FAILs: 0 · Umgebungs-FAILs: 0 · übersprungen: 3' in output
            for stopped in tests[:-1]:
                assert output.count(f'SELFTEST-RESULT v=1 test={stopped} status=SKIP\n') == 1
            assert 'Buchhaltung geht nicht auf' not in output
        recorded = [line.split() for line in pids.read_text().splitlines()]
        assert any(role == 'app' for role, _ in recorded)
        if mode not in ('early-fail', 'default-independent'): assert any(role == 'sender' for role, _ in recorded), recorded
        for role, value in recorded:
            pid = int(value)
            for _ in range(100):
                try: os.kill(pid, 0)
                except ProcessLookupError: break
                time.sleep(.02)
            else: raise AssertionError('owned process still exists: ' + role + ' ' + value)
        remaining = list(sandbox.iterdir())
        retains_sandbox = mode.endswith('cleanup-failure')
        retains_evidence = retains_sandbox or mode in (
            'app-dies', 'sender-identity', 'app-identity', 'early-fail',
        )
        if retains_evidence:
            evidence, = (entry for entry in remaining
                         if entry.name.startswith('fastra-selftest-befunde-'))
            assert evidence.is_dir() and not evidence.is_symlink()
            log, = evidence.iterdir()
            assert log.name == f'{test}.stderr' and log.is_file() and not log.is_symlink()
            assert f'Diagnose: {log}' in output
            if mode == 'early-fail':
                assert 'independent product assertion' in log.read_text()
            remaining.remove(evidence)
        if retains_sandbox:
            run_sandbox, = remaining
            assert run_sandbox.name.startswith('fastra-selftest-run.')
            assert run_sandbox.is_dir() and not run_sandbox.is_symlink()
        else:
            assert not remaining, 'sandbox removed only after all owned children ended'
        assert not (root / 'gui.lock').exists()
        if mode == 'sender-hangs':
            assert signals.read_text().splitlines() and set(signals.read_text().splitlines()) == {'TERM'}
            assert 'Killed: 9' in output, 'KILL escalation not observed'
        if mode in ('sender-identity', 'app-identity', 'term-start', 'term-adopt', 'early-fail', 'default-independent'):
            assert not (root / 'inputs').exists(), 'guard or cancelled start allowed input'
        else:
            assert (root / 'inputs').read_text() == 'input\n'
        if mode.startswith('app-dies'):
            assert 'LaunchServices-Testprozess endete vorzeitig' in output
            assert time.monotonic() - started < 30, 'live sender masked dead app'
        if mode in ('term-start', 'term-adopt'): assert (root / 'hook-pid').exists()
        print('RUNNER-CASE ' + mode + ' PASS owned-ended=true foreign-alive=true sandbox-retained=' + str(mode.endswith('cleanup-failure')))
    finally:
        if process.poll() is None:
            process.terminate()
            try: process.wait(timeout=10)
            except subprocess.TimeoutExpired: process.kill(); process.wait()
        # Unabhängiger Notausgang, auch wenn eine neue Runnerregression die
        # eigentliche Assertion verhindert. Nur die zufälligen eigenen Pfade
        # und eine unmittelbar erneut geprüfte Startidentität erlauben KILL.
        if pids.exists():
            for line in pids.read_text().splitlines():
                _, value = line.split()
                pid = int(value)
                try:
                    start = m.token(pid)
                    command = subprocess.check_output(['/bin/ps', '-p', value, '-o', 'command='], text=True)
                    if (str(root.resolve()) in command or str(root) in command) and m.token(pid) == start:
                        os.kill(pid, signal.SIGKILL)
                except (ProcessLookupError, ValueError, subprocess.SubprocessError):
                    pass
        control.terminate()
        control.wait()


class RunnerDefaultStopTests(unittest.TestCase):
    def test_stopped_pilot_and_independent_test(self):
        for mode in ('default-stopped', 'default-denied', 'default-independent'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory(prefix='menu-root-stop-', dir='/tmp') as root:
                sandbox = Path(root, 'sandboxes')
                sandbox.mkdir()
                with mock.patch.dict(os.environ, {
                    'FASTRA_SELFTEST_PRODUCT_DEFAULTS_DOMAIN': 'Fastra-Test-Product-' + str(uuid.uuid4()),
                    'FASTRA_SELFTEST_PRODUCT_SAVED_STATE_DIR': str(sandbox / ('saved-state-' + str(uuid.uuid4()))),
                }):
                    runner_case(mode, root)


if __name__ == '__main__':
    if len(sys.argv) == 4 and sys.argv[1] == '--runner-case':
        runner_case(sys.argv[2], sys.argv[3])
    else:
        if '--unit-only' in sys.argv: sys.argv.remove('--unit-only')
        unittest.main()
