#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
icu=${FASTRA_ICU_PREFIX:-$fastra_cache/icu78.3-native/runtime}
profile=debug
while (($#)); do
  case $1 in
    --help|-h) echo 'Usage: ./linux/run.sh [--release] [--icu-prefix DIRECTORY] [-- APP_ARGUMENTS...]'; exit 0 ;;
    --release) profile=release; shift ;;
    --icu-prefix) (($# >= 2)) || fail '--icu-prefix needs a directory'; icu=$2; shift 2 ;;
    --) shift; break ;;
    *) break ;;
  esac
done
binary=${CARGO_TARGET_DIR:-$fastra_repo/target}/$profile/fastra-linux
[[ -x $binary ]] || fail "Build first with ./build.sh (or ./build.sh --release)."
[[ -d $icu/lib ]] || fail 'ICU runtime not found; use the same --icu-prefix as for build.sh.'
export LD_LIBRARY_PATH="$icu/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$binary" "$@"
