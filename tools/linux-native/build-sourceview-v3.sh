#!/usr/bin/env bash
set -euo pipefail
[[ $# == 2 ]] || { printf 'Usage: build-sourceview-v3.sh AUTHENTICATED_SOURCE_CACHE NEW_OUTPUT\n' >&2; exit 2; }
tools=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P);cache=$(realpath -- "$1");output=$(realpath -m -- "$2")
[[ ! -e $output && ! -L $output ]] || { printf 'Output must be new.\n' >&2;exit 2; }
image=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["builder_image"])' "$tools/sourceview-native-v3.lock.json")
[[ $(docker image inspect --format '{{.Id}}' "$image") == "$image" ]] || { printf 'Pinned builder unavailable.\n' >&2;exit 2; }
mkdir -p -- "$output"
docker run --rm --network none --user "$(id -u):$(id -g)" -e SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:?Set SOURCE_DATE_EPOCH}" -v "$tools:/tools:ro" -v "$cache:/source-cache:ro" -v "$output:/work" "$image" python3 /tools/build-sourceview-v3-inner.py
