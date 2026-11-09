#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 2 ]]; then
  echo "Usage: $0 ICU78.3_SOURCE_ARCHIVE OUTPUT_DIRECTORY" >&2
  exit 2
fi
archive=$(realpath "$1")
output=$(realpath -m "$2")
expected=3a2e7a47604ba702f345878308e6fefeca612ee895cf4a5f222e7955fabfe0c0
printf '%s  %s\n' "$expected" "$archive" | sha256sum --check --status
[[ ! -e $output ]] || { echo 'Output must not exist.' >&2; exit 2; }
mkdir -p "$output"
tar -xzf "$archive" -C "$output"
cd "$output/icu/source"
# Keine Maschinenoptimierung des Build-Hosts in die ausgelieferte ICU übernehmen.
CFLAGS='-O2 -march=x86-64 -mtune=generic' \
CXXFLAGS='-O2 -march=x86-64 -mtune=generic' \
./configure --prefix="$output/runtime" --disable-tests --disable-samples
make -j"${FASTRA_BUILD_JOBS:-4}"
make install
cp "$output/icu/LICENSE" "$output/runtime/ICU-LICENSE"
printf '%s\n' "$expected" > "$output/runtime/ICU-SOURCE-SHA256"
