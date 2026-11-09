#!/usr/bin/env python3
"""ZIP mit relativen Pfaden, Unix-Modusbits, Links und festen Zeitstempeln."""
from pathlib import Path
import os
import stat
import sys
import time
import zipfile
stage, output = Path(sys.argv[1]), Path(sys.argv[2])
# ZIP kann keine Zeiten vor 1980 darstellen und speichert nur gerade Sekunden.
epoch = max(315532800, min(int(sys.argv[3]), 4354819198))
date = time.gmtime(epoch)[:6]
with zipfile.ZipFile(output, "x", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
    for file in sorted(stage.rglob("*")):
        if file.is_dir() and not file.is_symlink():
            continue
        name = stage.name + "/" + file.relative_to(stage).as_posix()
        info = zipfile.ZipInfo(name, date)
        info.create_system = 3
        info.external_attr = file.lstat().st_mode << 16
        info.compress_type = zipfile.ZIP_DEFLATED
        data = os.readlink(file).encode() if file.is_symlink() else file.read_bytes()
        archive.writestr(info, data)
