#!/usr/bin/env python3
"""Serialisiert die kurze Besitzerprüfung und Änderung der GUI-Test-Sperre."""

import fcntl
import os
import stat
import subprocess
import sys


def main() -> int:
    if len(sys.argv) < 3:
        return 2
    descriptor = None
    try:
        # Die leere Guard-Datei bleibt absichtlich bestehen. Unlink würde
        # wartende und neue Runner auf verschiedene Inodes verteilen, sodass
        # beide anschließend ihre vermeintlich gleiche Sperre halten könnten.
        descriptor = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid():
            raise OSError("Guard ist keine eigene reguläre Datei")
        if metadata.st_nlink != 1 or metadata.st_mode & 0o022:
            raise OSError("Guard ist verlinkt oder für andere schreibbar")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("✗ Eine Fenster-Test-Sperre wird gerade geprüft oder geändert.", file=sys.stderr)
            return 2
        # Auch der Shell-Helfer hält den Deskriptor offen. Stirbt dieser
        # Python-Prozess, bleibt die Sperre bis zum Ende der Änderung wirksam.
        # Das Betriebssystem gibt sie beim letzten close automatisch frei.
        return subprocess.run(sys.argv[2:], pass_fds=(descriptor,), timeout=10).returncode
    except (OSError, subprocess.TimeoutExpired) as error:
        print(f"✗ Fenster-Test-Sperre konnte nicht sicher geändert werden: {error}", file=sys.stderr)
        return 2
    finally:
        if descriptor is not None:
            os.close(descriptor)


if __name__ == "__main__":
    raise SystemExit(main())
