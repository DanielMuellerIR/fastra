#!/usr/bin/env python3
"""Fastra-spezifische Exchange-/Recovery-Grenze; kein produktiver Dateiadapter."""
import ctypes, errno, hashlib, json, os, pathlib, signal, subprocess, sys, tempfile
libc=ctypes.CDLL(None,use_errno=True)
rename=libc.renameat2
rename.argtypes=[ctypes.c_int,ctypes.c_char_p,ctypes.c_int,ctypes.c_char_p,ctypes.c_uint]
def exchange(fd,a,b):
    if rename(fd,os.fsencode(a),fd,os.fsencode(b),2):raise OSError(ctypes.get_errno(),os.strerror(ctypes.get_errno()))
results=[]
def check(label,ok):
    if not ok:raise AssertionError(label)
    results.append(label)
with tempfile.TemporaryDirectory(prefix='.fastra-exchange-',dir=sys.argv[1]) as temp:
    root=pathlib.Path(temp);target=root/'target';prepared=root/'prepared'
    target.write_bytes(b'old');prepared.write_bytes(b'new')
    target.chmod(0o640);prepared.chmod(0o640)
    fd=os.open(root,os.O_RDONLY|os.O_DIRECTORY|os.O_CLOEXEC)
    try:
        # Verdrängte Bytes bleiben unter dem vorbereiteten Namen nachprüfbar.
        original=os.stat(target);exchange(fd,'prepared','target')
        check('swap retains original bytes',target.read_bytes()==b'new' and prepared.read_bytes()==b'old')
        check('displaced inode retained',os.stat(prepared).st_ino==original.st_ino)
        check('mode explicitly preserved',os.stat(target).st_mode&0o777==0o640)
        exchange(fd,'prepared','target')
        check('rollback retains both versions',target.read_bytes()==b'old' and prepared.read_bytes()==b'new')
        target.write_bytes(b'foreign')
        exchange(fd,'prepared','target')
        check('raced target detectable after swap',prepared.read_bytes()!=b'old')
        exchange(fd,'prepared','target')
        check('foreign bytes restored',target.read_bytes()==b'foreign')
        # Ein Swap allein verhindert Symlink-/FIFO-Ziele nicht: Der Adapter
        # muss weiterhin nofollow/fstat und Identitätsprüfungen anwenden.
        target.unlink();target.symlink_to('foreign-file');exchange(fd,'prepared','target')
        check('kernel swaps symlink without following it',prepared.is_symlink() and target.read_bytes()==b'new')
        exchange(fd,'prepared','target');target.unlink();os.mkfifo(target)
        d=os.open(target,os.O_RDONLY|os.O_NONBLOCK|os.O_NOFOLLOW)
        import stat
        check('FIFO rejected by fstat without blocking',stat.S_ISFIFO(os.fstat(d).st_mode));os.close(d)
        target.unlink();target.write_bytes(b'old')
        child=os.fork()
        if child==0:
            exchange(fd,'prepared','target');os.kill(os.getpid(),signal.SIGKILL)
        _,status=os.waitpid(child,0)
        check('killed owner leaves both byte versions',os.WIFSIGNALED(status) and target.read_bytes()==b'new' and prepared.read_bytes()==b'old')
        check('crash is not automatic rollback',target.read_bytes()!=b'old')
        exchange(fd,'prepared','target')
        check('explicit recovery possible',target.read_bytes()==b'old')
    finally:os.close(fd)
print(json.dumps({'filesystem':subprocess.check_output(['findmnt','-T',sys.argv[1],'-no','FSTYPE'],text=True).strip(),'passed':results,'limit':'No product journal, multi-file transaction, fsync/crash-durability or hostile concurrent namespace guarantee.'},indent=2))
