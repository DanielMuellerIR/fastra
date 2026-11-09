"""Gemeinsame Prüfungen für den ausschließlich optionalen nativen Laufzeitbaum."""

import hashlib
import os
import stat
from pathlib import Path, PurePosixPath


def digest(file):
    h = hashlib.sha256()
    with file.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def name(value):
    p = PurePosixPath(value)
    if (
        not value
        or p.is_absolute()
        or p.as_posix() != value
        or ".." in p.parts
        or "\\" in value
        or any(ord(c) < 32 for c in value)
    ):
        raise ValueError(f"Unsafe relative path: {value!r}")
    return p


def virtual(root, value):
    """Links im virtuellen Paketroot auflösen, niemals am Host-/usr oder /etc."""
    pending = list(name(value).parts)
    resolved = []
    hops = 0
    while pending:
        part = pending.pop(0)
        if part in ("", "."):
            continue
        if part == "..":
            if not resolved:
                raise ValueError(f"Symlink escapes runtime: {value}")
            resolved.pop()
            continue
        candidate = root.joinpath(*resolved, part)
        mode = candidate.lstat().st_mode
        if stat.S_ISLNK(mode):
            hops += 1
            if hops > 40:
                raise ValueError(f"Symlink loop: {value}")
            target = os.readlink(candidate)
            if any(ord(c) < 32 for c in target) or "\\" in target:
                raise ValueError(f"Unsafe link target: {value}")
            target = PurePosixPath(target)
            if target.is_absolute():
                resolved = []
            pending = [p for p in target.parts if p != "/"] + pending
        else:
            if pending and not stat.S_ISDIR(mode):
                raise ValueError(f"Non-directory link parent: {value}")
            resolved.append(part)
    return Path(*resolved)


def inventory(root):
    hashes = {}
    links = {}
    modes = {}
    for p in sorted(root.rglob("*")):
        key = p.relative_to(root).as_posix()
        name(key)
        st = p.lstat()
        if stat.S_ISLNK(st.st_mode):
            target = os.readlink(p)
            if target.startswith("/"):
                raise ValueError(f"Absolute normalized link: {key}")
            final = virtual(root, key)
            if not (root / final).exists():
                raise ValueError(f"Dangling normalized link: {key}")
            links[key] = target
        elif stat.S_ISREG(st.st_mode):
            if stat.S_IMODE(st.st_mode) not in (0o644, 0o755):
                raise ValueError(f"Non-normalized file mode: {key}")
            if key != "manifest.json":
                hashes[key] = digest(p)
            modes[key] = stat.S_IMODE(st.st_mode)
        elif not stat.S_ISDIR(st.st_mode):
            raise ValueError(f"Special file: {key}")
        elif st.st_mode & 0o7000:
            raise ValueError(f"Special directory bits: {key}")
    return hashes, links, modes
