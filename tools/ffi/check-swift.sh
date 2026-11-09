#!/bin/bash
set -euo pipefail
# ICU 78.3 und Swift müssen für dieselbe Zielplattform bereitstehen.
root=$(cd "$(dirname "$0")/../.." && pwd)
scratch=$(mktemp -d /tmp/fastra-ffi-check.XXXXXX)
trap 'rm -rf "$scratch"' EXIT
cd "$root"
cargo build --locked -p fastra-ffi --features bindgen
target_dir=${CARGO_TARGET_DIR:-"$root/target"}
[[ "$target_dir" = /* ]] || target_dir="$root/$target_dir"
case "$(uname -s)" in
    Darwin) library="$target_dir/debug/libfastra_ffi.dylib" ;;
    Linux) library="$target_dir/debug/libfastra_ffi.so" ;;
    *) echo "Unsupported host" >&2; exit 2 ;;
esac
"$target_dir/debug/fastra-bindgen" generate --library "$library" --language swift --out-dir "$scratch/generated"
swiftc -parse-as-library "$root/tools/ffi/client.swift" "$scratch/generated/fastra_ffi.swift" \
    -Xcc -fmodule-map-file="$scratch/generated/fastra_ffiFFI.modulemap" -I "$scratch/generated" \
    -L "$(dirname "$library")" -lfastra_ffi -Xlinker -rpath -Xlinker "$(dirname "$library")" -o "$scratch/check"
"$scratch/check"
