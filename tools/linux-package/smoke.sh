#!/usr/bin/env bash
# Ausschließlich im Wegwerf-Docker-Container: Paketinstallation und private GUI-Sitzungen.
set -euo pipefail
if [[ ${FASTRA_DISPOSABLE_CONTAINER:-} != 1 || ! -e /.dockerenv || $# != 2 ]]; then
  echo "Requires disposable Docker + FASTRA_DISPOSABLE_CONTAINER=1; usage: $0 PACKAGE.deb PORTABLE.tar.gz" >&2
  exit 2
fi
id fastra >/dev/null
# WebKit darf seinen eigenen User-/PID-/Proc-Sandbox-Aufbau nicht verlieren.
runuser -u fastra -- bwrap --unshare-user --unshare-pid --ro-bind / / --proc /proc /usr/bin/true
dpkg -i "$1"
dpkg --audit
[[ $(readlink -f /usr/bin/fastra) == /opt/fastra/bin/fastra ]]
[[ $(readlink -f /usr/bin/fastra-control) == /opt/fastra/bin/fastra-control ]]
[[ $(readlink -f /usr/bin/fastra-diff) == /opt/fastra/bin/fastra-diff ]]
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
tar -xzf "$2" -C "$work"
runtimes=("$work"/*/manifest.json)
[[ ${#runtimes[@]} == 1 ]]
runtime=${runtimes[0]%/manifest.json}
mkdir -p "$work/runtime" "$work/config" "$work/cache" "$work/data"
chmod 700 "$work/runtime"
cat > "$work/preview.md" <<'MARKDOWN'
# PORTABLE PREVIEW OK

Offline resources loaded from the packaged app.

Inline math: $x^2 + 1$.

```mermaid
graph LR; PORTABLE-->VERIFIED;
```

| Input | Output |
|---|---|
| local | rendered |
MARKDOWN
cat > "$work/dbus.conf" <<'DBUS'
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig><type>session</type><listen>unix:tmpdir=/tmp</listen><policy context="default"><allow own="*"/><allow send_destination="*"/><allow receive_sender="*"/></policy></busconfig>
DBUS
cat > "$work/client.sh" <<'CLIENT'
#!/bin/bash
set -euo pipefail
"$FASTRA_SMOKE_LAUNCHER" "$FASTRA_SMOKE_WORK/preview.md" &
app=$!
trap 'kill "$app" 2>/dev/null || true; wait "$app" 2>/dev/null || true' EXIT
window=
for attempt in {1..100}; do
  kill -0 "$app"
  window=$(xdotool search --onlyvisible --pid "$app" 2>/dev/null | head -1 || true)
  [[ -z $window ]] || break
  sleep 0.1
done
[[ -n $window ]]
xdotool windowsize --sync "$window" 1400 900
sleep 1
import -silent -window "$window" "$FASTRA_SMOKE_WORK/$FASTRA_SMOKE_KIND-before.png"
# Vorschauknopf der kompakten Titelleiste, geprüft bei 1400×900 (1.190.0).
# Bei Layoutänderungen anhand der Vorher-Aufnahme neu bestimmen.
read -r x y <<< "${FASTRA_SMOKE_MARKDOWN_POINT:?}"
[[ $x =~ ^[0-9]+$ && $y =~ ^[0-9]+$ ]]
xdotool mousemove --window "$window" "$x" "$y" click 1
found=0
for attempt in {1..100}; do
  kill -0 "$app"
  for status in /proc/[0-9]*/status; do
    IFS= read -r first < "$status" || continue
    if [[ $first == *WebKitWebProces* ]]; then found=1; break; fi
  done
  [[ $found == 0 ]] || break
  sleep 0.1
done
[[ $found == 1 ]]
sleep 2
import -silent -window "$window" "$FASTRA_SMOKE_WORK/$FASTRA_SMOKE_KIND-markdown.png"
: > "$FASTRA_SMOKE_WORK/$FASTRA_SMOKE_KIND-sandbox.txt"
for status in /proc/[0-9]*/status; do
  IFS= read -r first < "$status" || continue
  if [[ $first == *WebKitWebProces* ]]; then
    # Inneres Seccomp bleibt trotz freigegebener äußerer Docker-Syscalls aktiv.
    [[ $(awk '/^Seccomp:/ {print $2}' "$status") == 2 ]]
    [[ $(awk '/^NoNewPrivs:/ {print $2}' "$status") == 1 ]]
    [[ $(awk '/^NSpid:/ {print NF}' "$status") -ge 3 ]]
    awk '/^(Name|NSpid|NoNewPrivs|Seccomp):/' "$status" >> "$FASTRA_SMOKE_WORK/$FASTRA_SMOKE_KIND-sandbox.txt"
  fi
done
[[ -s $FASTRA_SMOKE_WORK/$FASTRA_SMOKE_KIND-sandbox.txt ]]
CLIENT
chown -R fastra:fastra "$work"
for kind in installed relocated; do
  if [[ $kind == installed ]]; then root=/opt/fastra; launcher=/usr/bin/fastra; else root=$runtime; launcher=$runtime/bin/fastra; fi
  runuser -u fastra -- "$root/bin/fastra-control" --capabilities --json > "$work/$kind-control.json"
  python3 - "$work/$kind-control.json" <<'CONTROL'
import json, sys
with open(sys.argv[1]) as file:
    reply = json.load(file)
assert reply["protocolVersion"] == 1
assert reply["capabilities"]["readOnly"] is True
CONTROL
  runuser -u fastra -- "$root/bin/fastra-diff" --capabilities --json > "$work/$kind-diff.json"
  python3 - "$work/$kind-diff.json" <<'DIFF'
import json, sys
with open(sys.argv[1]) as file:
    reply = json.load(file)
assert reply == {"protocol": 1, "fileDiff": True, "readOnly": True,
                 "focusDiff": True, "labels": True, "existingInstanceIpc": True}
DIFF
  dependencies=$(LD_LIBRARY_PATH="$root/lib" ldd "$root/libexec/fastra-linux")
  [[ $dependencies != *'not found'* ]]
  for component in data uc i18n; do
    [[ $dependencies == *"libicu${component}.so.78 => $root/lib/"* ]]
  done
  python3 - "$root" <<'PYTHON'
import hashlib,json,sys
from pathlib import Path
root=Path(sys.argv[1]);manifest=json.loads((root/'manifest.json').read_text())
for name,expected in manifest['sha256'].items():
    assert hashlib.sha256((root/name).read_bytes()).hexdigest()==expected,name
print('PASS runtime manifest:',manifest['version'],manifest['source_sha256'])
PYTHON
  runuser -u fastra -- env FASTRA_SMOKE_WORK="$work" FASTRA_SMOKE_KIND="$kind" FASTRA_SMOKE_LAUNCHER="$launcher" \
    FASTRA_SMOKE_MARKDOWN_POINT="${FASTRA_SMOKE_MARKDOWN_POINT:-1348 18}" \
    XDG_CONFIG_HOME="$work/config" XDG_CACHE_HOME="$work/cache" XDG_DATA_HOME="$work/data" XDG_RUNTIME_DIR="$work/runtime" \
    GTK_A11Y=none GDK_BACKEND=x11 GSK_RENDERER=cairo GTK_THEME=Adwaita LANGUAGE=en GSETTINGS_BACKEND=memory GIO_USE_VFS=local \
    env -u WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS -u WAYLAND_DISPLAY \
    xvfb-run -a -s '-screen 0 1600x1000x24 -nolisten tcp' \
    dbus-run-session --config-file="$work/dbus.conf" -- bash "$work/client.sh"
  cat "$work/$kind-sandbox.txt"
  printf 'PASS: %s launcher, private ICU, manifest, visible GUI and sandboxed WebKit\n' "$kind"
done
if [[ -n ${FASTRA_SMOKE_EVIDENCE:-} ]]; then
  mkdir -p "$FASTRA_SMOKE_EVIDENCE"
  cp "$work"/*.png "$work"/*-sandbox.txt "$FASTRA_SMOKE_EVIDENCE/"
fi
