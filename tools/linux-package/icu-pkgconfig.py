#!/usr/bin/env python3
"""ICU-pc-Dateien für einen verschobenen Präfix atomar und stabil bereitstellen."""
import hashlib
import os
from pathlib import Path
import sys
import tempfile

prefix = Path(sys.argv[1]).resolve(strict=True)
cache = Path(sys.argv[2])
files = {}
for source in sorted((prefix / 'lib/pkgconfig').glob('*.pc')):
    lines = source.read_text().splitlines()
    files[source.name] = '\n'.join('prefix=' + str(prefix) if line.split('=', 1)[0].strip() == 'prefix' else line for line in lines) + '\n'
if not files:
    raise ValueError('ICU prefix contains no pkg-config metadata.')
identity = hashlib.sha256()
for name, content in files.items():
    identity.update(name.encode() + b'\0' + content.encode() + b'\0')
directory = cache / ('icu-' + identity.hexdigest())
directory.mkdir(parents=True, exist_ok=True)
for name, content in files.items():
    destination = directory / name
    if destination.is_file() and not destination.is_symlink() and destination.read_text() == content:
        continue
    fd, temporary = tempfile.mkstemp(prefix='.pc-', dir=directory)
    try:
        with os.fdopen(fd, 'w') as file:
            file.write(content)
        os.replace(temporary, destination)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
print(directory)
