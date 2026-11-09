#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 5 ]]; then
  echo "Usage: $0 REPO ICU_PREFIX_OR_- ICU_LICENSE_OR_- VERSION NEW_OUTPUT_DIRECTORY" >&2
  echo 'Convenient entry point: ./linux/package.sh --help' >&2
  exit 2
fi
repo=$(realpath "$1")
icu=$2
icu_license=$3
version=$4
out=$(realpath -m "$5")
tools=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[[ $(uname -m) == x86_64 ]] || { echo 'Only x86_64 is verified.' >&2; exit 2; }
[[ ! -e $out && ! -L $out ]] || { echo 'Output must not exist.' >&2; exit 2; }
cache=${FASTRA_PACKAGE_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/fastra-linux/package}
mkdir -p "$cache/cargo" "$cache/target" "$cache/icu" "$out/source"
cache=$(realpath "$cache")
# Ein Snapshot verhindert gemischte Builds bei parallel fortgesetzter Entwicklung.
tar -C "$repo" --exclude='__pycache__' --exclude='*.pyc' -cf - Cargo.toml Cargo.lock rust-toolchain.toml crates LICENSE \
  THIRD-PARTY-NOTICES.md linux app/Info.plist app/Sources/Fastra/Resources \
  tools/linux-probes/regex/cases.json tools/linux-package | tar -xf - -C "$out/source"
export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(git -C "$repo" log -1 --format=%ct)}
[[ $SOURCE_DATE_EPOCH =~ ^[0-9]+$ ]] || { echo 'Invalid SOURCE_DATE_EPOCH.' >&2; exit 2; }
image=${FASTRA_PACKAGE_BUILDER:-fastra-linux-package-builder:local}
if [[ ${FASTRA_PACKAGE_SKIP_IMAGE_BUILD:-0} != 1 ]]; then docker build -t "$image" "$tools"; fi
mounts=()
if [[ $icu == - ]]; then
  archive=$(realpath "${FASTRA_ICU_ARCHIVE:?ICU archive is required}")
  mounts+=(-v "$archive:/icu-source.tgz:ro")
else
  icu=$(realpath "$icu"); icu_license=$(realpath "$icu_license")
  mounts+=(-v "$icu:/work/runtime:ro" -v "$icu_license:/icu-license:ro")
fi
exec {build_lock}>"$cache/build.lock"
flock "$build_lock"
docker run --rm --platform linux/amd64 --user "$(id -u):$(id -g)" \
  -v "$out/source:/src:ro" -v "$out/source/tools/linux-package:/package-tools:ro" \
  -v "$cache/icu:/icu-cache" "${mounts[@]}" \
  -v "$cache/cargo:/cargo" -v "$cache/target:/target" -v "$out:/output" \
  -e CARGO_HOME=/cargo -e CARGO_TARGET_DIR=/target -e RUSTUP_TOOLCHAIN=1.99.1 \
  -e 'RUSTFLAGS=-C target-cpu=x86-64 --remap-path-prefix=/src=/usr/src/fastra' \
  -e SOURCE_DATE_EPOCH "$image" bash -eu -o pipefail -c '
    if [[ -f /icu-source.tgz ]]; then
      exec 9>/icu-cache/build.lock
      flock 9
      if [[ ! -d /icu-cache/build/runtime ]]; then
        icu_work=$(mktemp -d /icu-cache/.build.XXXXXX)
        trap "rm -rf -- $icu_work" EXIT
        /package-tools/build-icu.sh /icu-source.tgz "$icu_work/build"
        mv -T -- "$icu_work/build" /icu-cache/build
        rm -rf -- "$icu_work"
        trap - EXIT
      fi
      flock -u 9
      icu=/icu-cache/build/runtime
      license=$icu/ICU-LICENSE
    else
      icu=/work/runtime
      license=/icu-license
    fi
    pcdir=$(python3 /package-tools/icu-pkgconfig.py "$icu" /tmp/pkgconfig)
    export PKG_CONFIG_PATH="$pcdir" LD_LIBRARY_PATH="$icu/lib"
    python3 /package-tools/identity.py /src "$1" /output
    cargo fetch --locked --target x86_64-unknown-linux-gnu
    cargo build --locked --release -p fastra-linux -p fastra-control -p fastra-diff-helper
    python3 /package-tools/stage.py --repo /src --binary /target/release/fastra-linux \
      --control-binary /target/release/fastra-control --diff-binary /target/release/fastra-diff \
      --icu-prefix "$icu" --icu-license "$license" --version "$1" --output /output/fastra
    bash /package-tools/package.sh /output/fastra "$1" /output/packages
    rustc -Vv > /output/toolchain.txt
    dpkg-query -W > /output/builder-packages.txt
  ' -- "$version"
docker image inspect "$image" --format '{{.Id}}' > "$out/builder-image.txt"
echo "$out/packages"
