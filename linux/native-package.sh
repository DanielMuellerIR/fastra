#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == --help || ${1:-} == -h ]]; then
 cat <<'EOF'
Usage: linux/native-package.sh --app-stage VERIFIED_APP_STAGE
       --runtime-stage VERIFIED_NATIVE_STAGE --host-broker ELF --git-helper ELF --four-d-worker ELF
       --host-proof ELF_PROOF.json --output NEW_DIRECTORY --epoch SOURCE_DATE_EPOCH
       [--app-verifier PATH] [--archive NEW_ARCHIVE.tar.gz]

Creates a separate optional native candidate from existing verified stages.
Requires all three GTK/ICU-free reviewed helpers. No downloads, installs,
version bump, signing or upload. The system launcher remains the default;
bin/fastra-native explicitly selects the private runtime.
See tools/linux-native/README.md for the locked source build and normalization.
EOF
 exit 0
fi
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || { printf 'Native packaging is verified only on x86_64 Linux.\n' >&2; exit 2; }
repo=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
command -v python3 >/dev/null;command -v readelf >/dev/null
exec python3 "$repo/tools/linux-native/stage.py" "$@"
