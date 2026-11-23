#!/usr/bin/python3
"""Begrenzter AX-Client für drei native Selbsttests; kein Produkt-Eingang."""
import ctypes
import json
import os
import signal
import stat
import subprocess
import sys
import time
import uuid

TESTS = frozenset(('multisearch', 'softwrapprofiles', 'textworkflow'))
BINDING_KEYS = frozenset(('version', 'test', 'runNonce', 'runnerPid', 'runnerToken',
                          'appPid', 'appToken', 'appExe', 'senderPid', 'senderToken',
                          'senderExe', 'senderScript'))
REQUEST_KEYS = frozenset(('version', 'test', 'runNonce', 'appPid', 'nonce', 'rootTitle'))


def strict_json(data):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError('duplicate field')
            result[key] = value
        return result
    value = json.loads(data, object_pairs_hook=pairs)
    if type(value) is not dict:
        raise ValueError('object required')
    return value


class PrivateDirectory:
    def __init__(self, path):
        self.path = os.path.abspath(path)
        self.fd = os.open(self.path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        self.identity = os.fstat(self.fd)
        try:
            self.check()
        except BaseException:
            os.close(self.fd)
            raise

    def check(self):
        current = os.lstat(self.path)
        expected = self.identity
        if (not stat.S_ISDIR(current.st_mode) or current.st_uid != os.getuid()
                or stat.S_IMODE(current.st_mode) != 0o700
                or (current.st_dev, current.st_ino) != (expected.st_dev, expected.st_ino)):
            raise ValueError('unsafe exchange directory')

    def close(self):
        os.close(self.fd)

    def read(self, name):
        self.check()
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=self.fd)
        try:
            info = os.fstat(fd)
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                    or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1
                    or info.st_size > 16384):
                raise ValueError('unsafe exchange file')
            with os.fdopen(fd, 'rb', closefd=False) as handle:
                data = handle.read(16385)
            if len(data) > 16384:
                raise ValueError('oversized exchange file')
            return strict_json(data)
        finally:
            os.close(fd)

    def write(self, name, value):
        self.check()
        temporary = '.' + str(uuid.uuid4())
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                     0o600, dir_fd=self.fd)
        try:
            with os.fdopen(fd, 'wb', closefd=False) as handle:
                handle.write(json.dumps(value, separators=(',', ':'), allow_nan=False).encode())
                handle.flush()
                os.fsync(fd)
            self.check()
            os.rename(temporary, name, src_dir_fd=self.fd, dst_dir_fd=self.fd)
        finally:
            os.close(fd)
            try:
                os.unlink(temporary, dir_fd=self.fd)
            except FileNotFoundError:
                pass


def token(pid):
    return subprocess.check_output(['/bin/ps', '-p', str(pid), '-o', 'lstart='],
                                   text=True).lstrip().rstrip('\n')


def executable(pid):
    # libproc ist keine AX-API. Frameworks werden erst nach allen Bindungsprüfungen geladen.
    library = ctypes.CDLL('/usr/lib/libproc.dylib')
    library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    library.proc_pidpath.restype = ctypes.c_int
    buffer = ctypes.create_string_buffer(4096)
    if library.proc_pidpath(pid, buffer, len(buffer)) <= 0:
        raise ValueError('unreadable executable')
    return os.path.realpath(os.fsdecode(buffer.value))


def process_argv(pid):
    if sys.platform != 'darwin' or ctypes.sizeof(ctypes.c_void_p) != 8 or type(pid) is not int or pid <= 1:
        raise ValueError('unsupported process arguments')
    library = ctypes.CDLL(None)
    library.sysctl.argtypes = [ctypes.POINTER(ctypes.c_int), ctypes.c_uint, ctypes.c_void_p,
                               ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p, ctypes.c_size_t]
    library.sysctl.restype = ctypes.c_int
    # CTL_KERN/KERN_PROCARGS2 liefert argc, Executable, Padding und NUL-getrennte
    # Argumente. ps command= bewahrt deren Grenzen und Quotierung nicht.
    query = (ctypes.c_int * 3)(1, 49, pid)
    size = ctypes.c_size_t()
    header_size = ctypes.sizeof(ctypes.c_int)
    if library.sysctl(query, len(query), None, ctypes.byref(size), None, 0) != 0 or size.value <= header_size:
        raise ValueError('unreadable process arguments')
    buffer = ctypes.create_string_buffer(size.value)
    if library.sysctl(query, len(query), buffer, ctypes.byref(size), None, 0) != 0 or size.value > len(buffer):
        raise ValueError('unreadable process arguments')
    offset = header_size
    if size.value <= offset:
        raise ValueError('invalid process arguments')
    count = ctypes.c_int.from_buffer(buffer).value
    if count <= 0 or count > size.value - offset:
        raise ValueError('invalid process argument count')

    def read_argument():
        nonlocal offset
        start = offset
        while offset < size.value and buffer[offset] != b'\0':
            offset += 1
        if offset == size.value:
            raise ValueError('unterminated process argument')
        value = ctypes.string_at(ctypes.addressof(buffer) + start, offset - start)
        offset += 1
        return os.fsdecode(value)

    read_argument()  # Das Executable steht zusätzlich vor argv.
    # XNUs exec_extract_strings richtet argv auf die 8-Byte-Zielpointerbreite aus;
    # das vorangestellte argc zählt nicht mit. Weitere NULs gehören zu leeren Args.
    arguments_start = header_size + ((offset - header_size + 7) // 8) * 8
    if arguments_start >= size.value or any(buffer[index] != b'\0' for index in range(offset, arguments_start)):
        raise ValueError('invalid process argument padding')
    offset = arguments_start
    # Hinter argc Argumenten liegen Umgebungsdaten; diese weder lesen noch ausgeben.
    return [read_argument() for _ in range(count)]


def valid_binding(binding):
    if set(binding) != BINDING_KEYS or type(binding['version']) is not int or binding['version'] != 1:
        raise ValueError('invalid binding fields')
    if binding['test'] not in TESTS:
        raise ValueError('unsupported test')
    if str(uuid.UUID(binding['runNonce'])) != binding['runNonce'].lower():
        raise ValueError('invalid run nonce')
    for key in ('runnerPid', 'appPid', 'senderPid'):
        if type(binding[key]) is not int or binding[key] <= 1:
            raise ValueError('invalid pid')
    for key in BINDING_KEYS - {'version', 'test', 'runNonce', 'runnerPid', 'appPid', 'senderPid'}:
        if type(binding[key]) is not str or not binding[key]:
            raise ValueError('invalid identity')
    for key in ('appExe', 'senderExe', 'senderScript'):
        if not os.path.isabs(binding[key]) or os.path.realpath(binding[key]) != binding[key]:
            raise ValueError('noncanonical executable')
    return binding


def identities_match(binding, get_token=token, get_exe=executable):
    try:
        return all(get_token(binding[role + 'Pid']) == binding[role + 'Token']
                   for role in ('runner', 'app', 'sender')) and all(
                       get_exe(binding[role + 'Pid']) == binding[role + 'Exe']
                       for role in ('app', 'sender'))
    except (OSError, ValueError, subprocess.SubprocessError):
        return False


class RequestProcessor:
    def __init__(self, binding, ax, identity_check=identities_match):
        self.binding = valid_binding(binding)
        self.ax = ax
        self.identity_check = identity_check
        self.consumed = set()

    def process(self, request):
        binding = self.binding
        if set(request) != REQUEST_KEYS or type(request['version']) is not int or request['version'] != 1:
            raise ValueError('invalid request fields')
        if any(request[key] != binding[key] or type(request[key]) is not type(binding[key])
               for key in ('version', 'test', 'runNonce', 'appPid')):
            raise ValueError('request binding mismatch')
        if (type(request['nonce']) is not str or str(uuid.UUID(request['nonce'])) != request['nonce'].lower()
                or type(request['rootTitle']) is not str or not request['rootTitle']):
            raise ValueError('invalid request')
        if request['nonce'] in self.consumed:
            return None
        # Auch Guardfehler verbrauchen die Nonce. Ein späterer Fokuswechsel löst keinen Retry aus.
        self.consumed.add(request['nonce'])
        reply = dict(request, senderPid=binding['senderPid'], binding=binding)
        def environment(reason):
            return dict(reply, phase='preInputEnvironment', reason=reason)
        if not self.identity_check(binding):
            return environment('processIdentityChanged')
        if not self.ax.trusted():
            return environment('accessibilityNotTrusted')
        if self.ax.focused_pid() != binding['appPid']:
            return environment('foreignForeground')
        root, reason = self.ax.resolve(binding['appPid'], request['rootTitle'])
        if root is None:
            return environment(reason)
        if not self.identity_check(binding):
            return environment('processIdentityChanged')
        if self.ax.focused_pid() != binding['appPid']:
            return environment('foreignForeground')
        error = self.ax.press(root)
        return dict(reply, phase='actionReturned', axError=error)


class NativeAX:
    def __init__(self):
        self.ax = ctypes.CDLL('/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices')
        self.cf = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
        pointer = ctypes.c_void_p
        self.ax.AXIsProcessTrusted.restype = ctypes.c_bool
        self.ax.AXUIElementCreateApplication.argtypes = [ctypes.c_int]
        self.ax.AXUIElementCreateApplication.restype = pointer
        self.ax.AXUIElementCreateSystemWide.restype = pointer
        self.ax.AXUIElementCopyAttributeValue.argtypes = [pointer, pointer, ctypes.POINTER(pointer)]
        self.ax.AXUIElementCopyActionNames.argtypes = [pointer, ctypes.POINTER(pointer)]
        self.ax.AXUIElementPerformAction.argtypes = [pointer, pointer]
        self.ax.AXUIElementGetPid.argtypes = [pointer, ctypes.POINTER(ctypes.c_int)]
        self.cf.CFStringCreateWithCString.argtypes = [pointer, ctypes.c_char_p, ctypes.c_uint32]
        self.cf.CFStringCreateWithCString.restype = pointer
        self.cf.CFStringGetCString.argtypes = [pointer, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32]
        self.cf.CFStringGetCString.restype = ctypes.c_bool
        self.cf.CFArrayGetCount.argtypes = [pointer]
        self.cf.CFArrayGetCount.restype = ctypes.c_long
        self.cf.CFArrayGetValueAtIndex.argtypes = [pointer, ctypes.c_long]
        self.cf.CFArrayGetValueAtIndex.restype = pointer
        self.cf.CFGetTypeID.argtypes = [pointer]
        self.cf.CFGetTypeID.restype = ctypes.c_ulong
        self.cf.CFStringGetTypeID.restype = ctypes.c_ulong
        self.cf.CFArrayGetTypeID.restype = ctypes.c_ulong
        self.cf.CFRelease.argtypes = [pointer]
        self.references = []

    def keep(self, value):
        if value:
            self.references.append(value)
        return value

    def close(self):
        for value in reversed(self.references):
            self.cf.CFRelease(value)
        self.references.clear()

    def string(self, text):
        return self.keep(self.cf.CFStringCreateWithCString(None, text.encode(), 0x08000100))

    def attribute(self, element, name):
        value = ctypes.c_void_p()
        error = self.ax.AXUIElementCopyAttributeValue(element, self.string(name), ctypes.byref(value))
        return self.keep(value.value) if error == 0 else None

    def text(self, value):
        if not value or self.cf.CFGetTypeID(value) != self.cf.CFStringGetTypeID():
            return None
        buffer = ctypes.create_string_buffer(4096)
        return buffer.value.decode() if self.cf.CFStringGetCString(value, buffer, len(buffer), 0x08000100) else None

    def array(self, value):
        if not value or self.cf.CFGetTypeID(value) != self.cf.CFArrayGetTypeID():
            return []
        return [self.cf.CFArrayGetValueAtIndex(value, i) for i in range(self.cf.CFArrayGetCount(value))]

    def pid(self, element):
        pid = ctypes.c_int()
        return pid.value if element and self.ax.AXUIElementGetPid(element, ctypes.byref(pid)) == 0 else None

    def trusted(self):
        return self.ax.AXIsProcessTrusted()

    def focused_pid(self):
        system = self.keep(self.ax.AXUIElementCreateSystemWide())
        return self.pid(self.attribute(system, 'AXFocusedApplication'))

    def resolve(self, pid, title):
        app = self.keep(self.ax.AXUIElementCreateApplication(pid))
        menu = self.attribute(app, 'AXMenuBar')
        roots = [item for item in self.array(self.attribute(menu, 'AXChildren'))
                 if self.text(self.attribute(item, 'AXRole')) == 'AXMenuBarItem'
                 and self.text(self.attribute(item, 'AXTitle')) == title and self.pid(item) == pid]
        if len(roots) != 1:
            return None, 'rootNotUnique'
        actions = ctypes.c_void_p()
        if self.ax.AXUIElementCopyActionNames(roots[0], ctypes.byref(actions)) != 0:
            return None, 'actionNamesUnavailable'
        self.keep(actions.value)
        if 'AXPress' not in [self.text(action) for action in self.array(actions.value)]:
            return None, 'pressUnsupported'
        print('MENU_ROOT role=AXMenuBarItem pressOffered=true root=' + title, file=sys.stderr, flush=True)
        return roots[0], None

    def press(self, root):
        return self.ax.AXUIElementPerformAction(root, self.string('AXPress'))


def main(arguments):
    if len(arguments) != 8:
        raise ValueError('expected directory/test/runner/token/app/token/exe/timeout')
    path, test, runner, runner_token, app, app_token, app_exe, timeout = arguments
    if test not in TESTS or not timeout.isdecimal() or int(timeout) <= 0:
        raise ValueError('invalid sender invocation')
    # Der Default beendet auch einen blockierenden ctypes-Aufruf; kein Python-Handler.
    signal.signal(signal.SIGALRM, signal.SIG_DFL)
    signal.alarm(int(timeout))
    directory = PrivateDirectory(path)
    ax = None
    try:
        ready = dict(senderPid=os.getpid(), senderToken=token(os.getpid()),
                     senderExe=executable(os.getpid()), senderScript=os.path.realpath(__file__))
        directory.write('ready.json', ready)
        binding = None
        while binding is None:
            if token(int(runner)) != runner_token or token(int(app)) != app_token or executable(int(app)) != app_exe:
                return 2
            try:
                binding = valid_binding(directory.read('binding.json'))
            except FileNotFoundError:
                time.sleep(0.02)
        expected = dict(ready, version=1, test=test, runnerPid=int(runner), runnerToken=runner_token,
                        appPid=int(app), appToken=app_token, appExe=app_exe, runNonce=binding['runNonce'])
        if binding != expected or not identities_match(binding):
            return 2
        print('MENU_ROOT binding=' + json.dumps(binding, sort_keys=True), file=sys.stderr, flush=True)
        ax = NativeAX()
        processor = RequestProcessor(binding, ax)
        while identities_match(binding):
            try:
                reply = processor.process(directory.read('request.json'))
                if reply is not None:
                    directory.write('reply.json', reply)
                    print('MENU_ROOT reply=' + json.dumps(reply, sort_keys=True), file=sys.stderr, flush=True)
            except FileNotFoundError:
                pass
            time.sleep(0.02)
        return 0
    finally:
        if ax is not None:
            ax.close()
        directory.close()


if __name__ == '__main__':
    try:
        raise SystemExit(main(sys.argv[1:]))
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print('MENU_ROOT sender failed: ' + str(error), file=sys.stderr)
        raise SystemExit(2)
