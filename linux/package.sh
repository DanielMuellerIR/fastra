#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
icu=${FASTRA_ICU_PREFIX:-}
out=
key=
unsigned=0
release=${FASTRA_RELEASE_MODE:-0}
while (($#)); do
  case $1 in
    --help|-h) cat <<'EOF'
Usage: ./linux/package.sh [--output NEW_DIRECTORY] [--icu-prefix DIRECTORY]
                         [--key FINGERPRINT] [--unsigned] [--skip-image-build]
Builds all three Linux executables in the pinned Ubuntu 24.04 x86_64 Docker builder.
Creates DEB, portable tar.gz and ZIP, licenses, manifest and relative SHA256SUMS.
ICU 78.3 source is downloaded, hash-verified and built privately in the container
unless --icu-prefix / FASTRA_ICU_PREFIX supplies an already verified prefix.
Default output: dist/linux-VERSION-TIMESTAMP. No existing directory is replaced.
--key / FASTRA_SIGNING_KEY signs SHA256SUMS locally with an explicit OpenPGP
fingerprint. release.sh requires --key or explicit --unsigned. No upload, tag,
Git push or host installation. --skip-image-build uses FASTRA_PACKAGE_BUILDER.
Caches: FASTRA_LINUX_CACHE and FASTRA_PACKAGE_CACHE; no system packages installed.
EOF
      exit 0 ;;
    --output|--icu-prefix|--key) (($# >= 2)) || fail "$1 needs a value"; case $1 in --output) out=$2;; --icu-prefix) icu=$2;; --key) key=$2;; esac; shift 2 ;;
    --unsigned) release=0; unsigned=1; shift ;;
    --skip-image-build) export FASTRA_PACKAGE_SKIP_IMAGE_BUILD=1; shift ;;
    *) fail "Unknown option $1; see --help." ;;
  esac
done
[[ $unsigned != 1 || -z $key ]] || fail 'Choose either --key FINGERPRINT or --unsigned, not both.'
if [[ $unsigned == 1 ]]; then key=; else key=${key:-${FASTRA_SIGNING_KEY:-}}; fi
[[ $release != 1 || -n $key ]] || fail 'Release requires --key FINGERPRINT or explicit --unsigned.'
need python3; need docker; need realpath
[[ $(uname -m) == x86_64 ]] || fail 'Only x86_64 Linux packages are currently verified.'
v=$(version)
out=${out:-$fastra_repo/dist/linux-$v-$(date -u +%Y%m%dT%H%M%SZ)}
out=$(realpath -m "$out")
[[ ! -e $out && ! -L $out ]] || fail 'Output must not exist.'
if [[ -n $key ]]; then
  [[ $key =~ ^([[:xdigit:]]{40}|[[:xdigit:]]{64})$ ]] || fail 'Use a full OpenPGP signing fingerprint.'
  need gpg
  gpg --batch --list-secret-keys "$key" >/dev/null 2>&1 || fail 'The explicitly selected signing key is unavailable.'
fi
if [[ -n $icu ]]; then
  prepare_icu
  license=$icu/ICU-LICENSE
else
  icu_archive
  export FASTRA_ICU_ARCHIVE=$archive
  icu=-; license=-
fi
export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(git -C "$fastra_repo" log -1 --format=%ct)}
mkdir -p "$(dirname "$out")"
work=$(mktemp -d "$(dirname "$out")/.fastra-release.XXXXXX")
cleanup() { rm -rf -- "$work"; }
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 141' PIPE
"$fastra_repo/tools/linux-package/build.sh" "$fastra_repo" "$icu" "$license" "$v" "$work/build"
if [[ -n $key ]]; then "$fastra_repo/linux/sign.sh" --key "$key" "$work/build/packages"; fi
# Erst der vollständige Erfolg macht den Ergebnisordner sichtbar.
[[ ! -e $out && ! -L $out ]] || fail 'Output appeared during the build; refusing to replace it.'
mv -T -n -- "$work/build" "$out"
[[ ! -e $work/build ]] || fail "Output already exists: $out"
printf 'Linux artifacts: %s/packages\n' "$out"
