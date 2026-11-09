#!/usr/bin/env bash
set -euo pipefail
python3 /tools/fetch-pango.py --lock /tools/pango-source.lock.json --output /work/pango-source
cd /work/pango-source/pango1.0-1.52.1+ds
python3 - <<'PY'
from pathlib import Path
import hashlib,json
lock=json.loads(Path('/tools/pango-source.lock.json').read_text())
for name,expected in lock['own_patches'].items():
 assert hashlib.sha256((Path('/tools')/name).read_bytes()).hexdigest()==expected,name
PY
patch -p1 --fuzz=0 --forward -i /tools/pango-tab-wrap-v2.patch
patch -p1 --fuzz=0 --forward -i /tools/pango-capability-v1.patch
python3 - <<'PY'
from pathlib import Path
s=Path('pango/pango-layout.c').read_text();h=Path('pango/pango-layout.h').read_text()
assert s.count('LastTabState previous_tab = state->last_tab;')==1
assert s.count('pango_fastra_wrap_capability_v1 (void)')==1
assert s.count('return 0x46570002u;')==1 and h.count('unsigned int pango_fastra_wrap_capability_v1 (void);')==1
PY
meson setup /work/pango-build --prefix=/work/pango-install --libdir=lib --buildtype=release -Dintrospection=disabled -Dgtk_doc=false -Dinstall-tests=false -Dsysprof=disabled -Dxft=disabled
ninja -C /work/pango-build -j2
ninja -C /work/pango-build install
python3 - <<'PY'
from pathlib import Path
import ctypes,hashlib,json,subprocess
root=Path('/work/pango-install');lock=Path('/tools/pango-source.lock.json');j=json.loads(lock.read_text());libs={}
for p in sorted((root/'lib').glob('*.so.0.*')):
 dynamic=subprocess.check_output(['readelf','-d',str(p)],text=True)
 assert 'RPATH' not in dynamic and 'RUNPATH' not in dynamic,p.name
 libs[p.name]=hashlib.sha256(p.read_bytes()).hexdigest()
probe=ctypes.CDLL(str(root/'lib/libpango-1.0.so.0.5200.1')).pango_fastra_wrap_capability_v1;probe.restype=ctypes.c_uint32
assert probe()==0x46570002
receipt={'format':1,'source_lock_sha256':hashlib.sha256(lock.read_bytes()).hexdigest(),'builder_image':j['builder_image'],'own_patches':j['own_patches'],'libraries':libs,'capability':{'symbol':'pango_fastra_wrap_capability_v1','magic':'0x46570002'},'meson_buildtype':'release','source_date_epoch':__import__('os').environ['SOURCE_DATE_EPOCH']}
(root/'SOURCE-BUILD.json').write_text(json.dumps(receipt,indent=2,sort_keys=True)+'\n')
(root/'SOURCE-LOCK.json').write_bytes(lock.read_bytes())
(root/'builder-packages.tsv').write_text(subprocess.check_output(['dpkg-query','-W','-f=${binary:Package}\t${Version}\n'],text=True))
print(json.dumps({'pango_build_verified':True,'libraries':len(libs),'capability':'0x46570002'}))
PY
