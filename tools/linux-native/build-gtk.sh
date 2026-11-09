#!/usr/bin/env bash
set -euo pipefail
[[ $# == 2 ]] || { printf 'Usage: build-gtk.sh AUTHENTICATED_UBUNTU_SOURCE_CACHE NEW_OUTPUT_DIRECTORY\n' >&2; exit 2; }
tools=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
cache=$(realpath -- "$1");output=$(realpath -m -- "$2")
[[ ! -e $output && ! -L $output ]] || { printf 'Output must be new.\n' >&2; exit 2; }
image=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["builder_image"])' "$tools/gtk-source.lock.json")
[[ $(docker image inspect --format '{{.Id}}' "$image") == "$image" ]] || { printf 'Pinned native builder image is unavailable.\n' >&2; exit 2; }
mkdir -p -- "$output"
docker run --rm --network bridge -e ARTIFACT_UID="$(id -u)" -e ARTIFACT_GID="$(id -g)" -e SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:?Set SOURCE_DATE_EPOCH explicitly}" -e HOME=/work/home -v "$tools:/tools:ro" -v "$cache:/source-cache:ro" -v "$output:/work" "$image" bash -c '
 set -euo pipefail
 mapfile -t packages < <(python3 -c '\''import json;print("\n".join(k+"="+v for k,v in json.load(open("/tools/gtk-source.lock.json"))["additional_build_packages"].items()))'\'')
 apt-get update -o APT::Update::Error-Mode=any
 apt-get install -y --no-install-recommends "${packages[@]}"
 exec setpriv --reuid="$ARTIFACT_UID" --regid="$ARTIFACT_GID" --clear-groups bash /tools/build-gtk-inner.sh
'
