#!/usr/bin/env python3
"""F03: dauerhafter Intent und lesende Zustandsprüfung, kein Apply-Adapter."""
import ctypes
import hashlib
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import tempfile


def fingerprint(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise ValueError('regular file with one link required')
        digest = hashlib.sha256()
        while block := os.read(fd, 65536):
            digest.update(block)
        after = os.fstat(fd)
        fields = ('st_dev', 'st_ino', 'st_size', 'st_mtime_ns', 'st_ctime_ns', 'st_mode')
        if any(getattr(before, key) != getattr(after, key) for key in fields):
            raise ValueError('file changed while reading')
        # ctime ändert sich beim Exchange; Identität und Inhalt bleiben gebunden.
        return dict(device=after.st_dev, inode=after.st_ino, size=after.st_size,
                    mode=stat.S_IMODE(after.st_mode), sha256=digest.hexdigest())
    finally:
        os.close(fd)


def sync_directory(root):
    fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def prepare(root):
    for name, data in (('target', b'original\r\n'), ('prepared', b'replacement\r\n')):
        with (root / name).open('xb') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
    parent = root.stat()
    record = dict(version=1, directory=[parent.st_dev, parent.st_ino],
                  original=fingerprint(root / 'target'), replacement=fingerprint(root / 'prepared'))
    with (root / 'intent.tmp').open('x') as stream:
        json.dump(record, stream)
        stream.flush()
        os.fsync(stream.fileno())
    os.rename(root / 'intent.tmp', root / 'intent.json')
    sync_directory(root)


def inspect(root):
    """Keine Mutation, auch nicht bei eindeutigem Zustand; keine TOCTOU-Zusage."""
    try:
        if not stat.S_ISDIR(root.lstat().st_mode):
            return 'blocked'
        fd = os.open(root / 'intent.json', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, 'rb') as stream:
            if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                return 'blocked'
            record = json.loads(stream.read(16385))
        parent = root.stat()
        if record['version'] != 1 or record['directory'] != [parent.st_dev, parent.st_ino]:
            return 'blocked'
        actual = [fingerprint(root / name) for name in ('target', 'prepared')]
        expected = [record['original'], record['replacement']]
        if actual == expected:
            return 'not-exchanged'
        if actual == expected[::-1]:
            return 'exchanged'
        return 'blocked'
    except (OSError, ValueError, KeyError, TypeError):
        return 'blocked'


def exchange(root):
    libc = ctypes.CDLL(None, use_errno=True)
    rename = libc.renameat2
    rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        if rename(fd, b'prepared', fd, b'target', 2):
            raise OSError(ctypes.get_errno(), 'RENAME_EXCHANGE failed')
    finally:
        os.close(fd)


def child(root, phase):
    prepare(root)
    if phase != 'intent':
        exchange(root)
    if phase == 'directory-sync':
        sync_directory(root)
    os.kill(os.getpid(), signal.SIGKILL)


def probe(base):
    passed = []
    with tempfile.TemporaryDirectory(prefix='fastra-recovery-', dir=base) as temporary:
        workspace = Path(temporary)
        for phase in ('intent', 'exchange', 'directory-sync'):
            root = workspace / phase
            root.mkdir()
            process = subprocess.run([sys.executable, __file__, '--child', str(root), phase],
                                     timeout=15, check=False)
            assert process.returncode == -signal.SIGKILL, (phase, process.returncode)
            expected = 'not-exchanged' if phase == 'intent' else 'exchanged'
            # Ein neuer Prozess liest ausschließlich den persistenten Nachweis.
            state = subprocess.check_output([sys.executable, __file__, '--inspect', str(root)],
                                            text=True, timeout=15).strip()
            assert state == expected, (phase, state)
            wanted = [b'original\r\n', b'replacement\r\n']
            if phase != 'intent':
                wanted.reverse()
            assert [(root / name).read_bytes() for name in ('target', 'prepared')] == wanted
            passed.append('SIGKILL after ' + phase)

        def scenario(label, mutate):
            root = workspace / label
            root.mkdir()
            prepare(root)
            exchange(root)
            mutate(root)
            assert inspect(root) == 'blocked', label
            passed.append(label)

        scenario('foreign-target', lambda p: (p / 'target').write_bytes(b'foreign'))
        scenario('foreign-original', lambda p: (p / 'prepared').write_bytes(b'foreign'))

        def same_bytes_new_inode(root):
            (root / 'foreign').write_bytes(b'replacement\r\n')
            os.replace(root / 'foreign', root / 'target')
        scenario('same-bytes-new-inode', same_bytes_new_inode)

        def symlink(root):
            (root / 'target').unlink()
            (root / 'target').symlink_to('prepared')
        scenario('symlink-target', symlink)

        def fifo(root):
            (root / 'target').unlink()
            os.mkfifo(root / 'target')
        scenario('fifo-target', fifo)
        scenario('missing-original', lambda p: (p / 'prepared').unlink())
        scenario('truncated-intent', lambda p: (p / 'intent.json').write_bytes(b'{'))

        def journal_symlink(root):
            (root / 'intent.json').rename(root / 'other.json')
            (root / 'intent.json').symlink_to('other.json')
        scenario('symlink-intent', journal_symlink)

        def journal_fifo(root):
            (root / 'intent.json').unlink()
            os.mkfifo(root / 'intent.json')
        scenario('fifo-intent', journal_fifo)
        scenario('hardlinked-target', lambda p: os.link(p / 'target', p / 'alias'))
        scenario('changed-mode', lambda p: (p / 'target').chmod(0o400))

        root = workspace / 'intent'
        relocated = workspace / 'relocated'
        root.rename(relocated)
        assert inspect(relocated) == 'not-exchanged'
        passed.append('same-directory-relocated')
        root.mkdir()
        for name in ('target', 'prepared', 'intent.json'):
            (root / name).write_bytes((relocated / name).read_bytes())
        assert inspect(root) == 'blocked'
        passed.append('copied-directory-rejected')
        alias = workspace / 'alias'
        alias.symlink_to(relocated, target_is_directory=True)
        assert inspect(alias) == 'blocked'
        passed.append('symlink-directory-rejected')
    return dict(filesystem=subprocess.check_output(
        ['findmnt', '-T', base, '-no', 'FSTYPE'], text=True).strip(), passed=passed,
        limit='Single-file read-only inspection after process death; no power-loss, hostile concurrent namespace, automatic rollback or multi-file durability guarantee.')


if __name__ == '__main__':
    if sys.argv[1] == '--child':
        child(Path(sys.argv[2]), sys.argv[3])
    elif sys.argv[1] == '--inspect':
        print(inspect(Path(sys.argv[2])))
    else:
        print(json.dumps(probe(sys.argv[1]), indent=2))
