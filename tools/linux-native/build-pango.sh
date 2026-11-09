#!/usr/bin/env bash
set -euo pipefail
[[ $# == 1 ]] || { printf 'Usage: build-pango.sh NEW_OUTPUT_DIRECTORY\n' >&2; exit 2; }
tools=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
output=$(realpath -m -- "$1")
[[ ! -e $output && ! -L $output ]] || { printf 'Output must be new.\n' >&2; exit 2; }
image=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["builder_image"])' "$tools/pango-source.lock.json")
[[ $(docker image inspect --format '{{.Id}}' "$image") == "$image" ]] || { printf 'Pinned native builder image is unavailable.\n' >&2; exit 2; }
mkdir -p -- "$output"
# Rootlose Artefakte; das Image enthält bereits alle Buildwerkzeuge und den Ubuntu-Keyring.
docker run --rm --network bridge -u "$(id -u):$(id -g)" -e SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:?Set SOURCE_DATE_EPOCH explicitly}" -e HOME=/work/home -v "$tools:/tools:ro" -v "$output:/work" "$image" bash /tools/build-pango-inner.sh
