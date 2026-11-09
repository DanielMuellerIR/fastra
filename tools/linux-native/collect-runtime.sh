#!/usr/bin/env bash
set -euo pipefail
[[ $# == 2 ]] || { printf 'Usage: collect-runtime.sh VERIFIED_GTK_BUILD_PREFIX NEW_OUTPUT_DIRECTORY\n' >&2; exit 2; }
tools=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
gtk=$(realpath -- "$1")
output=$(realpath -m -- "$2")
[[ ! -e $output && ! -L $output ]] || { printf 'Output must be new.\n' >&2; exit 2; }
image=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["builder_image"])' "$tools/runtime-input.lock.json")
[[ $(docker image inspect --format '{{.Id}}' "$image") == "$image" ]] || { printf 'Pinned package builder image is unavailable.\n' >&2; exit 2; }
mkdir -p -- "$output"
docker run --rm --network none --user "$(id -u):$(id -g)" -v "$gtk:/gtk:ro" -v "$tools:/tools:ro" -v "$output:/work" "$image" bash -c '
 set -euo pipefail
 python3 /tools/collect-runtime.py --gtk-prefix /gtk --output /work/raw
'
printf 'Raw snapshot: %s/raw\n' "$output"
