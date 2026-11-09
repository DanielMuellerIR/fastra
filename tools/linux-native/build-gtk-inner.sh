#!/usr/bin/env bash
set -euo pipefail
mkdir /work/ubuntu-gtk-source
python3 - <<'PY'
from pathlib import Path
import hashlib,json,shutil
lock=json.loads(Path('/tools/gtk-source.lock.json').read_text())
for name,expected in lock['archives'].items():
 source=Path('/source-cache')/name
 assert source.is_file() and not source.is_symlink() and hashlib.sha256(source.read_bytes()).hexdigest()==expected,name
 shutil.copyfile(source,Path('/work/ubuntu-gtk-source')/name)
PY
cd /work/ubuntu-gtk-source
dpkg-source -x gtk4_4.14.5+ds-0ubuntu0.10.dsc
cd gtk4-4.14.5+ds
python3 - <<'PY'
from pathlib import Path
import hashlib,json
lock=json.loads(Path('/tools/gtk-source.lock.json').read_text())
assert hashlib.sha256(Path('debian/patches/series').read_bytes()).hexdigest()==lock['ubuntu_patch_series_sha256']
for name,expected in lock['ubuntu_patches'].items():assert hashlib.sha256((Path('debian/patches')/name).read_bytes()).hexdigest()==expected,name
series=[line.split('#',1)[0].strip().split()[0] for line in Path('debian/patches/series').read_text().splitlines() if line.split('#',1)[0].strip()]
assert Path('.pc/applied-patches').read_text().splitlines()==series
assert hashlib.sha256(Path('gtk/gtktextview.c').read_bytes()).hexdigest()==lock['gtktextview_before_sha256']
assert hashlib.sha256(Path('/tools/gtk-commit-preflight.patch').read_bytes()).hexdigest()==lock['own_patch']['sha256']
PY
patch -p1 --fuzz=0 --forward -i /tools/gtk-commit-preflight.patch
python3 - <<'PY'
from pathlib import Path
import hashlib,json,subprocess
lock=json.loads(Path('/tools/gtk-source.lock.json').read_text());text=Path('gtk/gtktextview.c').read_bytes()
assert hashlib.sha256(text).hexdigest()==lock['gtktextview_after_sha256']
assert text.count(b'g_signal_emit (text_view, signals[PREFLIGHT_COMMIT]')==1
subprocess.run(['meson','setup','/work/ubuntu-gtk-build',*lock['meson_options']],check=True)
PY
ninja -C /work/ubuntu-gtk-build -j2 gtk/libgtk-4.so.1.1400.5
mkdir /work/gtk-install
cp /work/ubuntu-gtk-build/gtk/libgtk-4.so.1.1400.5 /work/gtk-install/
python3 - <<'PY'
from pathlib import Path
import hashlib,json,subprocess,os
root=Path('/work/gtk-install');lock=Path('/tools/gtk-source.lock.json');data=json.loads(lock.read_text());lib=root/'libgtk-4.so.1.1400.5'
dynamic=subprocess.check_output(['readelf','-d',str(lib)],text=True)
assert 'RPATH' not in dynamic and 'RUNPATH' not in dynamic
receipt={'format':1,'source_lock_sha256':hashlib.sha256(lock.read_bytes()).hexdigest(),'builder_image':data['builder_image'],'own_patch':data['own_patch'],'library_sha256':hashlib.sha256(lib.read_bytes()).hexdigest(),'source_date_epoch':os.environ['SOURCE_DATE_EPOCH'],'meson_options':data['meson_options']}
(root/'SOURCE-BUILD.json').write_text(json.dumps(receipt,indent=2,sort_keys=True)+'\n');(root/'SOURCE-LOCK.json').write_bytes(lock.read_bytes())
(root/'builder-packages.tsv').write_text(subprocess.check_output(['dpkg-query','-W','-f=${binary:Package}\t${Version}\n'],text=True))
print(json.dumps({'gtk_build_verified':True,'library_sha256':receipt['library_sha256']}))
PY
