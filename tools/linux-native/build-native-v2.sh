#!/usr/bin/env bash
set -euo pipefail
[[ $# == 3 ]] || { printf 'Usage: build-native-v2.sh GTK_SOURCE_CACHE SOURCEVIEW_SOURCE_CACHE NEW_OUTPUT\n' >&2; exit 2; }
tools=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
gtk=$(realpath -- "$1");sourceview=$(realpath -- "$2");output=$(realpath -m -- "$3")
[[ ! -e $output && ! -L $output ]] || { printf 'Output must be new.\n' >&2; exit 2; }
image=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["builder_image"])' "$tools/gtk-native-v2.lock.json")
[[ $(docker image inspect --format '{{.Id}}' "$image") == "$image" ]] || { printf 'Pinned native-v2 builder unavailable.\n' >&2; exit 2; }
mkdir -p -- "$output"
docker run --rm --network none --user "$(id -u):$(id -g)" -e SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:?Set SOURCE_DATE_EPOCH}" -v "$tools:/tools:ro" -v "$gtk:/gtk-cache:ro" -v "$sourceview:/sourceview-cache:ro" -v "$output:/work" "$image" python3 /tools/build-native-v2-inner.py
