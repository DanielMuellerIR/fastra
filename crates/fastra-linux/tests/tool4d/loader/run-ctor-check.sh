#!/usr/bin/env bash
# Headless-Loaderregression; nur eigener Wegwerfcontainer und temporäre Bibliothek.
set -euo pipefail
if [[ $# != 3 ]]; then
  echo 'Usage: run-ctor-check.sh STAGED_APP BUILDER_IMAGE RUNTIME_IMAGE' >&2
  exit 2
fi
app=$(realpath "$1")
builder=$2
runtime=$3
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[[ -f $app/libexec/fastra-linux && -d $app/lib ]]
work=$(mktemp -d "${TMPDIR:-/tmp}/fastra-loader-check.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
# -Bsymbolic erlaubt die vorhandene Ubuntu-System-libz.a ohne Dependency-Neubau.
docker run --rm --pull=never --network none \
  -v "$source_dir:/source:ro" -v "$work:/output" "$builder" bash -euc '
    archive=/usr/lib/x86_64-linux-gnu/libz.a
    [[ -f $archive ]] || archive=/usr/lib/libz.a
    [[ -f $archive ]] || { echo "Existing SDK libz.a required" >&2; exit 2; }
    cc -shared -fPIC -Wall -Wextra -Werror /source/ctor.c -Wl,-Bsymbolic \
      -Wl,--whole-archive "$archive" -Wl,--no-whole-archive \
      -Wl,-soname,libz.so.1 -o /output/libz.so.1
  '
docker run --rm --pull=never --network none \
  -v "$app:/app:ro" -v "$work:/runtime/lib:ro" "$runtime" bash -euc '
    for kind in old fixed; do
      if [[ $kind == old ]]; then search=/app/lib:/runtime/lib; else search=/app/lib; fi
      printf "{}" | env -i PATH=/usr/bin:/bin LANG=C.UTF-8 LD_LIBRARY_PATH="$search" \
        timeout 10 /app/libexec/fastra-linux --fastra-4d-worker \
        > "/tmp/$kind.json" 2> "/tmp/$kind.err"
    done
    [[ $(grep -c UNTRUSTED_RUNTIME_LIBRARY_LOADED /tmp/old.err) == 1 ]]
    [[ $(grep -c UNTRUSTED_RUNTIME_LIBRARY_LOADED /tmp/fixed.err || true) == 0 ]]
    python3 - <<"PYTHON"
import json
for kind in ("old", "fixed"):
    with open("/tmp/" + kind + ".json") as stream:
        response = json.load(stream)
    assert response["version"] == 1
    assert response["result"]["Err"]["kind"] == "protocol"
    assert response["result"]["Err"]["detail"] == "Invalid worker request"
PYTHON
    printf "Old worker search path: "
    grep UNTRUSTED_RUNTIME_LIBRARY_LOADED /tmp/old.err
    printf "Fixed worker search path: no runtime constructor\n"
    printf "PASS: constructor ran before request validation only with runtime/lib\n"
  '
