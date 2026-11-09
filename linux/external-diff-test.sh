#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
if [[ $# != 2 || ! -x $1/fastra-linux || ! -x $1/fastra-diff || -e $2 || -L $2 ]]; then
  echo 'Usage: linux/external-diff-test.sh BINARY_DIRECTORY NEW_TEMPORARY_OUTPUT_DIRECTORY' >&2
  exit 2
fi
for program in cc pkg-config realpath python3 timeout dbus-run-session xvfb-run gdbus xdotool import; do
  command -v "$program" >/dev/null || { echo "Required test tool is missing: $program" >&2; exit 2; }
done
binary=$(realpath "$1")
output=$(realpath -m "$2")
mkdir -m 700 -- "$output"
profile=$(mktemp -d "$output/profile.XXXXXX")
trap 'rm -rf -- "$profile"' EXIT
mkdir -p "$profile/runtime" "$profile/config" "$profile/data" "$profile/cache" "$profile/state" "$profile/tmp"
chmod 700 "$profile/runtime"
export TMPDIR="$profile/tmp"
cc -std=c11 -Wall -Wextra -Werror "$repo/tools/linux-probes/external-diff-peer.c" \
  $(pkg-config --cflags --libs gio-2.0) -o "$profile/fake-peer"
export HOME="$profile" XDG_RUNTIME_DIR="$profile/runtime" XDG_CONFIG_HOME="$profile/config"
export XDG_DATA_HOME="$profile/data" XDG_CACHE_HOME="$profile/cache" XDG_STATE_HOME="$profile/state"
export GDK_BACKEND=x11 GSK_RENDERER=cairo GTK_A11Y=none GSETTINGS_BACKEND=memory GIO_USE_VFS=local
export LANG=C.UTF-8 LANGUAGE=${LANGUAGE:-en} FASTRA_EXTERNAL_DIFF_PRIVATE_SESSION=1
# Eigener Bus und eigener Bildschirm; kein Fokuszugriff auf den Benutzerdesktop.
timeout 75s dbus-run-session --config-file="$repo/linux/test-dbus.conf" -- \
  xvfb-run -a -s '-screen 0 1800x1200x24 -nolisten tcp' \
  python3 "$repo/tools/linux-probes/external-diff.py" --bin-dir "$binary" --output "$output" --peer "$profile/fake-peer"
